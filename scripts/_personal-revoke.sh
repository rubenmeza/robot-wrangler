#!/usr/bin/env bash
# Sourced from personal-host.sh; revoke alone loads local administrative credentials.
# Enrollment globals are defined by that entry point.
# shellcheck disable=SC2154
_enroll_inventory() {
  jq -n --arg name "$host_name" --arg user "$owner" '{name:$name,user:$user}' |
    _write_user_file "hosts/$host_name.json" 644
  printf 'Commit hosts/%s.json with its Device key; pull both on every Agent host.\n' "$host_name"
}

_revoke_api() {
  local method="$1" path="$2" credential
  credential=${TAILSCALE_API_KEY//\\/\\\\}
  credential=${credential//\"/\\\"}
  # Config on stdin keeps the access credential out of process argv and logs.
  printf 'header = "Authorization: Bearer %s"\n' "$credential" |
    curl --config - --fail --silent --show-error --connect-timeout 5 --max-time 20 \
      --request "$method" "https://api.tailscale.com/api/v2/$path"
}

_revoke() {
  local device="${1:-}" status self_name robot_name robot_user receipt_dir receipt nodes matches node_id
  local targets path entry name user missing registered unresolved='[]' failed=0
  local -a key_paths
  [[ "$device" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    _fail 'Usage: personal-host.sh revoke <device-name> (1–63 lowercase letters, numbers or interior hyphens).'
  for command in tailscale jq curl ssh timeout; do
    command -v "$command" >/dev/null || _fail "Missing $command."
  done
  status=$(tailscale status --json) || _fail 'Cannot identify this host from Tailscale.'
  self_name=$(jq -er '.Self.DNSName | select(type == "string" and length > 0) | split(".")[0]' <<< "$status") ||
    _fail 'Cannot identify this host from Tailscale.'
  if [ "$device" = "$self_name" ] || { [ -f "$state_file" ] && [ "$device" = "$(jq -r .name "$state_file")" ]; }; then
    _fail 'Refusing to revoke the host this command is running on.'
  fi
  receipt_dir="${XDG_STATE_HOME:-$HOME/.local/state}/robot-wrangler/revocations"
  receipt="$receipt_dir/$device.json"
  [ -f "devices/$device.pub" ] || [ -f "$receipt" ] || _fail "Unknown device: $device. No changes made."
  _load_env
  [ -n "${TAILSCALE_API_KEY:-}" ] && [ -n "${TAILSCALE_TAILNET:-}" ] ||
    _fail 'Set TAILSCALE_API_KEY and TAILSCALE_TAILNET in .env; no DigitalOcean credentials are needed.'
  [[ "$TAILSCALE_API_KEY" != *$'\n'* && "$TAILSCALE_API_KEY" != *$'\r'* ]] || _fail 'Invalid API credential.'
  robot_name=$(_host)
  robot_user="${TF_VAR_robot_user:-robot}"
  nodes=$(_revoke_api GET "tailnet/$(jq -rn --arg name "$TAILSCALE_TAILNET" '$name | @uri')/devices") ||
    _fail 'Tailscale API listing failed; no changes made.'
  jq -e '.devices | type == "array" and all(.[]; (.name | type == "string" and length > 0) and (.id | type == "string" and length > 0))' <<< "$nodes" >/dev/null ||
    _fail 'Invalid Tailscale API device response; no changes made.'
  matches=$(jq -c --arg device "$device" '[.devices[] | select((.name | ascii_downcase | split(".")[0]) == $device)]' <<< "$nodes")
  [ "$(jq length <<< "$matches")" -le 1 ] || _fail 'Ambiguous Tailnet device name; no changes made.'
  node_id=$(jq -r '.[0].id // empty' <<< "$matches")
  targets='[]'
  if [ -f "$receipt" ]; then
    targets=$(jq -ce --arg device "$device" 'select(.device == $device) | .hosts | select(type == "array")' "$receipt") ||
      _fail 'Invalid private revocation receipt; no changes made.'
    unresolved=$(jq -ce '.missingHosts // [] | select(type == "array")' "$receipt") ||
      _fail 'Invalid private revocation receipt; no changes made.'
  fi
  shopt -s nullglob
  for path in hosts/*.json; do
    entry=$(jq -ce '{name:.name,user:.user}' "$path") || _fail "Invalid host inventory: $path"
    [ "$(jq -r .name <<< "$entry")" = "$(basename "$path" .json)" ] || _fail "Inventory name mismatch: $path"
    targets=$(jq -c --argjson entry "$entry" 'map(select(.name != $entry.name)) + [$entry]' <<< "$targets")
  done
  shopt -u nullglob
  targets=$(jq -c --arg name "$robot_name" --arg user "$robot_user" --arg device "$device" \
    'map(select(.name != $name and .name != $device)) + [{name:$name,user:$user}] | map(select(.name != $device))' <<< "$targets")
  jq -e 'all(.[]; (.name | type == "string" and test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")) and (.user | type == "string" and test("^[a-z_][a-z0-9_-]*[$]?$")))' <<< "$targets" >/dev/null ||
    _fail 'Unsafe host name or Unix user in inventory; no changes made.'
  # Registered Linux Device keys may be Personal hosts. Never silently omit their missing inventory.
  shopt -s nullglob
  key_paths=(devices/*.pub)
  shopt -u nullglob
  registered=$(jq -n --arg self "$self_name" --args '$ARGS.positional | map(split("/")[-1] | sub("\\.pub$";"")) + [$self]' "${key_paths[@]}")
  unresolved=$(jq -c --argjson targets "$targets" --argjson previous "$unresolved" --argjson registered "$registered" --arg owner "${TF_VAR_tailnet_owner:-}" --arg device "$device" \
    '([.devices[] | select(((.os // "") | ascii_downcase) == "linux") | select($owner == "" or .user == null or .user == $owner) | .name | ascii_downcase | split(".")[0] | . as $name | select(any($registered[]; . == $name))] + $previous) | unique | map(select(. != $device) | . as $name | select(all($targets[]; .name != $name)))' <<< "$nodes")
  jq -e 'all(.[]; type == "string" and test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"))' <<< "$unresolved" >/dev/null ||
    _fail 'Unsafe host name in unresolved inventory; no changes made.'
  missing=$(jq -r '.[]' <<< "$unresolved")
  mkdir -p "$receipt_dir"
  chmod 700 "$receipt_dir"
  jq -n --arg device "$device" --argjson hosts "$targets" --argjson missing "$unresolved" '{device:$device,hosts:$hosts,missingHosts:$missing}' |
    _write_user_file "$receipt" 600
  if [ -n "$node_id" ]; then
    if _revoke_api DELETE "device/$(jq -rn --arg id "$node_id" '$id | @uri')" >/dev/null; then
      printf 'Deleted Tailnet node %s.\n' "$device"
    else
      printf 'Tailscale API delete failed for %s.\n' "$device" >&2
      failed=1
    fi
  else
    printf 'Tailnet node %s is already absent.\n' "$device"
  fi
  rm -f "devices/$device.pub" "hosts/$device.json"
  while IFS= read -r entry; do
    name=$(jq -r .name <<< "$entry")
    user=$(jq -r .user <<< "$entry")
    local result=0
    if [ "$name" = "$self_name" ]; then
      timeout 30 bash files/revoke-t3.sh "$device" || result=$?
    else
      timeout 30 ssh -i "$(_key)" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 \
        "$user@$name" "bash -s -- $device" < files/revoke-t3.sh || result=$?
    fi
    case "$result" in
      0) printf 'Revoked T3 Pairings and sessions on %s.\n' "$name" ;;
      255|124) printf 'Unreachable Agent host: %s; retry revocation when reachable.\n' "$name" >&2; failed=1 ;;
      *) printf 'T3 revocation failed on %s; retry revocation.\n' "$name" >&2; failed=1 ;;
    esac
  done < <(jq -c '.[]' <<< "$targets")
  if [ -n "$missing" ]; then
    while IFS= read -r name; do printf 'Missing enrollment inventory for %s; re-enroll it and retry revocation.\n' "$name" >&2; done <<< "$missing"
    failed=1
  fi
  printf 'Commit the removed Device key and host inventory. Pull on Personal hosts and re-run enrollment; rebuild the Robot server to remove the SSH key everywhere.\n'
  if [ "$failed" -ne 0 ]; then printf 'Revocation incomplete. Retry make revoke DEVICE=%s; private retry metadata is saved locally.\n' "$device" >&2; fi
  return "$failed"
}
