#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh

# An alternate filesystem root lets command-boundary tests use a throwaway host.
host_root="${PERSONAL_HOST_ROOT:-}"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/robot-wrangler"
state_file="$config_dir/personal-host.json"
_fail() { printf '%s\n' "$*" >&2; exit 1; }

_personal_preflight() {
  local os_id command status
  os_id=$(sed -n 's/^ID=//p' "$host_root/etc/os-release" | tr -d '"')
  [ "$os_id" = arch ] || _fail 'Enrollment supports Arch/Omarchy only.'
  for command in sudo tailscale jq ssh-keygen; do
    command -v "$command" >/dev/null || _fail "Missing $command; install it before enrollment."
  done
  [ "$(id -u)" != 0 ] || _fail 'Run enrollment as your own user; it asks for sudo at the keyboard.'
  status=$(tailscale status --json) || _fail 'Tailscale is not running. Run sudo tailscale up first.'
  jq -e '.BackendState == "Running" and .Self.Online == true' <<< "$status" >/dev/null ||
    _fail 'Tailscale is not connected. Run sudo tailscale up first.'
  jq -e '.CurrentTailnet.MagicDNSEnabled == true' <<< "$status" >/dev/null ||
    _fail 'Enable MagicDNS in the Tailnet DNS settings before enrollment.'
  jq -e '(.CertDomains // []) | length > 0' <<< "$status" >/dev/null ||
    _fail 'Enable HTTPS certificates in the Tailnet DNS settings before enrollment.'
}

_write_user_file() {
  local path="$1" mode="$2" temporary
  temporary=$(mktemp)
  cat > "$temporary"
  mkdir -p "$(dirname "$path")"
  if ! cmp -s "$temporary" "$path"; then install -m "$mode" "$temporary" "$path"; fi
  chmod "$mode" "$path"
  rm -f "$temporary"
}

_enroll_keys() {
  local key own_material path material
  key="$(_key)"
  mkdir -p "$HOME/.ssh" devices
  chmod 700 "$HOME/.ssh"
  if [ ! -f "$key" ]; then
    mkdir -p "$(dirname "$key")"
    ssh-keygen -q -t ed25519 -N '' -f "$key" -C "$host_name"
    printf 'Created Device key %s.\n' "$key"
  fi
  if [ ! -f "$key.pub" ]; then
    ssh-keygen -y -f "$key" > "$key.pub"
  fi
  ssh-keygen -lf "$key.pub" >/dev/null || _fail "Invalid public key: $key.pub"
  own_material=$(awk 'NF >= 2 {print $1 " " $2; exit}' "$key.pub")
  path="devices/$host_name.pub"
  if [ -f "$path" ]; then
    material=$(awk 'NF >= 2 {print $1 " " $2; exit}' "$path")
    [ "$material" = "$own_material" ] || _fail "$path belongs to a different Device key; choose a different host name."
  else
    if [ -f devices/arch.pub ] && [ "$(awk 'NF >= 2 {print $1 " " $2; exit}' devices/arch.pub)" = "$own_material" ]; then
      mv devices/arch.pub "$path"
      printf 'Renamed devices/arch.pub to %s.\n' "$path"
    else
      cp "$key.pub" "$path"
      printf 'Registered %s.\n' "$path"
    fi
  fi
  # Exclude key material too: a stale alias must not admit this host to itself.
  awk -v own="$own_material" 'NF >= 2 && $1 !~ /^#/ {
    material=$1 " " $2
    if (material != own && !seen[material]++) print
  }' devices/*.pub | _write_user_file "$HOME/.ssh/authorized_keys" 600
  printf 'Commit %s and re-run enrollment on the other hosts to propagate Device keys.\n' "$path"
}

_write_system_file() {
  local path="$1" mode="$2" temporary
  temporary=$(mktemp)
  cat > "$temporary"
  if ! sudo cmp -s "$temporary" "$path"; then
    sudo install -D -m "$mode" "$temporary" "$path"
    printf 'Updated %s.\n' "$path"
  fi
  rm -f "$temporary"
}

_validate_sshd() {
  local effective line address listen_count=0
  sudo sshd -t || return 1
  # OpenSSH releases emit either lowercase or capitalized directive names.
  effective=$(sudo sshd -T | awk '{$1=tolower($1); print}') || return 1
  for line in 'allowusers '"$owner" 'permitrootlogin no' 'passwordauthentication no' \
    'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'authenticationmethods publickey' \
    'authorizedkeysfile .ssh/authorized_keys' 'authorizedkeyscommand none' \
    'trustedusercakeys none' 'hostbasedauthentication no'; do
    grep -Fxq "$line" <<< "$effective" || {
      printf 'Conflicting SSH setting: expected %s.\n' "$line" >&2
      return 1
    }
  done
  while read -r line address; do
    [ "$line" = listenaddress ] || continue
    listen_count=$((listen_count + 1))
    case "$address" in
      "$tailnet_ipv4:22"|"[$tailnet_ipv6]:22") ;;
      *) printf 'SSH would listen outside the Tailnet: %s. Remove conflicting ListenAddress directives.\n' "$address" >&2; return 1 ;;
    esac
  done <<< "$effective"
  [ "$listen_count" -gt 0 ] || { echo 'SSH has no Tailnet listener.' >&2; return 1; }
}

_enroll_ssh() {
  local dropin="$host_root/etc/ssh/sshd_config.d/00-robot-wrangler.conf" backup existed=0
  sudo pacman -S --needed --noconfirm openssh tmux ufw mosh
  sudo install -d -m 755 "$host_root/etc/ssh"
  sudo ssh-keygen -A -f "$host_root"
  tailnet_ipv4=$(tailscale ip -4)
  tailnet_ipv6=$(tailscale ip -6)
  [ -n "$tailnet_ipv4$tailnet_ipv6" ] || _fail 'Tailscale has no host addresses.'
  backup=$(mktemp)
  # sudo reads the system source; the destination is a user-owned temporary backup.
  # shellcheck disable=SC2024
  if sudo test -f "$dropin"; then sudo cat "$dropin" > "$backup"; existed=1; fi
  {
    printf '# Managed by robot-wrangler enrollment.\n'
    [ -z "$tailnet_ipv4" ] || printf 'ListenAddress %s\n' "$tailnet_ipv4"
    [ -z "$tailnet_ipv6" ] || printf 'ListenAddress %s\n' "$tailnet_ipv6"
    printf 'AllowUsers %s\n' "$owner"
    cat files/personal-sshd.conf
  } | _write_system_file "$dropin" 644
  # The writer runs in a pipeline subshell; compare its result with the saved file.
  local changed=1
  if [ "$existed" -eq 1 ] && sudo cmp -s "$backup" "$dropin"; then changed=0; fi
  if ! _validate_sshd; then
    if [ "$existed" -eq 1 ]; then sudo install -m 644 "$backup" "$dropin"; else sudo rm -f "$dropin"; fi
    rm -f "$backup"
    _fail 'SSH validation failed; restored the previous enrollment drop-in. SSH was not enabled.'
  fi
  rm -f "$backup"
  sudo ufw allow in on tailscale0 to any port 22 proto tcp
  sudo ufw allow in on tailscale0 to any port 60000:61000 proto udp
  # Arch normally has no socket unit. Still mask it against future activation.
  local socket_load
  socket_load=$(sudo systemctl show --property=LoadState --value sshd.socket)
  if [ "$socket_load" != not-found ]; then sudo systemctl disable --now sshd.socket; fi
  sudo systemctl mask sshd.socket
  sudo systemctl unmask sshd.service
  if [ "$reachability" = open-by-hand ]; then
    sudo systemctl disable --now sshd.service
    return
  fi
  if ! sudo systemctl is-enabled --quiet sshd.service; then sudo systemctl enable sshd.service; fi
  if sudo systemctl is-active --quiet sshd.service; then
    if [ "$changed" -eq 1 ]; then sudo systemctl reload sshd.service; fi
  else
    sudo systemctl start sshd.service
  fi
}

_enroll_tmux() {
  local rc="$HOME/.bashrc" source_line
  case "${SHELL:-/bin/bash}" in
    */zsh) rc="$HOME/.zshrc" ;;
    */bash) ;;
    *) _fail 'Automatic SSH tmux attachment supports Bash and Zsh; configure your shell before enrolling.' ;;
  esac
  _write_user_file "$config_dir/ssh-tmux.sh" 644 <<'SH'
# Only interactive SSH shells outside tmux attach. File transfers and commands stay untouched.
case $- in
  *i*)
    if [ -n "${SSH_CONNECTION:-}" ] && [ -z "${TMUX:-}" ]; then
      _robot_tmux_session=$(tmux list-sessions -F '#{session_last_attached} #{session_id}' 2>/dev/null |
        sort -rn | head -n 1 | cut -d ' ' -f 2)
      if [ -n "$_robot_tmux_session" ]; then
        exec tmux attach-session -t "$_robot_tmux_session"
      else
        exec tmux new-session -s work
      fi
    fi
    ;;
esac
SH
  source_line='[ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/robot-wrangler/ssh-tmux.sh" ] || . "${XDG_CONFIG_HOME:-$HOME/.config}/robot-wrangler/ssh-tmux.sh"'
  if ! grep -Fxq "$source_line" "$rc" 2>/dev/null; then
    printf '\n%s\n' "$source_line" >> "$rc"
    printf 'Added interactive SSH tmux attachment to %s.\n' "$rc"
  fi
}

# Later tickets supply these services without changing enrollment orchestration.
_enroll_t3() { :; }
_enroll_moshi() { :; }
for personal_helper in scripts/_personal-t3.sh scripts/_personal-moshi.sh scripts/_personal-revoke.sh; do
  if [ -f "$personal_helper" ]; then
    # shellcheck source=/dev/null
    source "$personal_helper"
  fi
done

_enroll_power() {
  local masks="$config_dir/power-masks" target enabled owned=''
  if [ "$reachability" = always-on ]; then
    [ ! -f "$masks" ] || owned=$(cat "$masks")
    for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
      enabled=$(sudo systemctl is-enabled "$target" 2>/dev/null || true)
      if [ "$enabled" != masked ]; then
        case " $owned " in *" $target "*) ;; *) owned="${owned:+$owned }$target" ;; esac
      fi
    done
    printf '%s\n' "$owned" | _write_user_file "$masks" 600
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  elif [ -f "$masks" ]; then
    for target in $(cat "$masks"); do
      case "$target" in sleep.target|suspend.target|hibernate.target|hybrid-sleep.target)
        sudo systemctl unmask "$target" ;; esac
    done
    rm -f "$masks"
  fi
}

_enroll_doors() {
  local unit="$host_root/etc/systemd/system/robot-wrangler-serve-off.service"
  if [ "$reachability" = open-by-hand ]; then
    _write_system_file "$unit" 644 <<'UNIT'
[Unit]
Description=Close robot-wrangler T3 Tailnet door at boot
Requires=tailscaled.service
After=tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/bin/tailscale serve --https=443 off
RemainAfterExit=yes
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable robot-wrangler-serve-off.service
    _door_intent closed
    _close_doors || _fail 'Could not close inbound doors during enrollment.'
  elif sudo test -f "$unit"; then
    sudo systemctl disable --now robot-wrangler-serve-off.service
    sudo rm -f "$unit"
    sudo systemctl daemon-reload
  fi
}

_load_host() {
  [ -f "$state_file" ] || _fail 'Enroll this Personal host first with make enroll.'
  host_name=$(jq -er '.name' "$state_file") || _fail 'Invalid Personal-host enrollment state.'
  reachability=$(jq -er '.mode' "$state_file") || _fail 'Invalid Personal-host enrollment state.'
}

_boot_id() { cat "${host_root}/proc/sys/kernel/random/boot_id" 2>/dev/null || cat /proc/sys/kernel/random/boot_id; }
_door_intent() {
  jq -n --arg boot "$(_boot_id)" --arg state "$1" '{boot:$boot,state:$state}' |
    _write_user_file "$config_dir/door-intent.json" 600
}

_process_pids() {
  local result rc=0
  result=$(sudo pgrep -x "$1") || rc=$?
  if [ "$rc" -gt 1 ]; then
    printf 'Could not inspect %s processes.\n' "$1" >&2
    return 1
  fi
  printf '%s\n' "$result"
}

_close_doors() {
  local failed=0 process pids pid remaining attempts inspected
  if ! sudo systemctl stop sshd.service; then
    printf 'Failed to stop SSH listener.\n' >&2; failed=1
  fi
  for process in sshd sshd-session sshd-auth mosh-server; do
    remaining=''; inspected=1
    if ! pids=$(_process_pids "$process"); then failed=1; continue; fi
    for pid in $pids; do
      if ! sudo kill -TERM "$pid"; then
        # A process may exit between enumeration and signaling; only survivors fail.
        if ! remaining=$(_process_pids "$process"); then failed=1; inspected=0; continue; fi
        if grep -Fxq "$pid" <<< "$remaining"; then
          printf 'Failed to terminate %s PID %s.\n' "$process" "$pid" >&2
        fi
      fi
    done
    attempts=0
    while [ "$attempts" -lt 10 ]; do
      if ! remaining=$(_process_pids "$process"); then failed=1; inspected=0; break; fi
      [ -n "$remaining" ] || break
      sleep 0.1
      attempts=$((attempts + 1))
    done
    if [ -n "${remaining:-}" ]; then
      for pid in $remaining; do
        sudo kill -KILL "$pid" || printf 'SIGKILL failed for %s PID %s.\n' "$process" "$pid" >&2
      done
      sleep 0.1
      if ! remaining=$(_process_pids "$process"); then failed=1; inspected=0; fi
    fi
    if [ -n "${remaining:-}" ]; then
      printf 'Still live: %s PIDs %s.\n' "$process" "$remaining" >&2; failed=1
    fi
    if [ "$inspected" = 1 ]; then
      for pid in $pids; do
        if ! grep -Fxq "$pid" <<< "$remaining"; then printf 'Closed %s PID %s.\n' "$process" "$pid"; fi
      done
    fi
  done
  if ! tailscale serve --https=443 off; then
    printf 'Failed to turn T3 Tailnet Serve off.\n' >&2; failed=1
  fi
  if [ "$failed" -ne 0 ]; then
    printf 'Close incomplete; inspect make status before trusting the doors are closed.\n' >&2
    return 1
  fi
  printf 'SSH and T3 Tailnet doors closed. T3, tmux and agents keep running.\n'
}

_open() {
  _load_host
  [ "$reachability" = open-by-hand ] || _fail 'Open is for Open-by-hand hosts; this host is Always-on.'
  local status
  status=$(tailscale status --json) || _fail 'Tailscale is not running; neither door was opened.'
  jq -e '.BackendState == "Running" and .Self.Online == true' <<< "$status" >/dev/null ||
    _fail 'Tailscale is not connected; neither door was opened.'
  sudo -v
  if ! sudo systemctl start sshd.service; then
    _close_doors || true
    _door_intent closed
    _fail 'Could not start SSH; opening failed and door cleanup was attempted.'
  fi
  if ! tailscale serve --bg --https=443 http://127.0.0.1:3773; then
    _close_doors || true
    _door_intent closed
    _fail 'Could not publish T3 Tailnet Serve; opening failed and door cleanup was attempted.'
  fi
  _door_intent open
  printf 'Opened SSH and T3 Tailnet doors. Keep the lid up; keep work inside tmux or T3.\n'
}

_close() {
  _load_host
  [ "$reachability" = open-by-hand ] || _fail 'Close is for Open-by-hand hosts; this host is Always-on.'
  sudo -v
  _door_intent closed
  _close_doors
}

_status() {
  _load_host
  local ssh_active ssh_enabled socket_active socket_enabled listeners serve_json serve_state=unknown
  local t3_active process pids count unexpected=0 failed=0 intended=closed tmux_sessions
  ssh_active=$(systemctl is-active sshd.service 2>/dev/null || true)
  ssh_enabled=$(systemctl is-enabled sshd.service 2>/dev/null || true)
  socket_active=$(systemctl is-active sshd.socket 2>/dev/null || true)
  socket_enabled=$(systemctl is-enabled sshd.socket 2>/dev/null || true)
  if [ -z "$ssh_active" ] || [ -z "$ssh_enabled" ] || [ -z "$socket_active" ] || [ -z "$socket_enabled" ]; then
    failed=1
  fi
  printf 'Personal host: %s (%s)\nSSH unit: %s\nSSH starts at boot: %s\nSSH socket: %s; boot: %s\n' \
    "$host_name" "$reachability" "${ssh_active:-unknown}" "${ssh_enabled:-unknown}" \
    "${socket_active:-unknown}" "${socket_enabled:-unknown}"
  if listeners=$(sudo ss -H -ltnp '( sport = :22 )'); then
    printf 'SSH listening addresses (actual TCP port 22):\n%s\n' "${listeners:-none}"
  else
    printf 'SSH listeners: unknown (inspection failed).\n'; failed=1
  fi
  if [ "$ssh_active" = active ] || [ "$ssh_enabled" = enabled ] ||
    [ "$socket_active" = active ] || [ "$socket_enabled" = enabled ]; then unexpected=1; fi
  [ -z "${listeners:-}" ] || unexpected=1
  for process in sshd sshd-session sshd-auth mosh-server; do
    if pids=$(_process_pids "$process"); then
      count=$(awk 'NF {count++} END {print count+0}' <<< "$pids")
      printf '%s handlers/servers: %s; PIDs: %s\n' "$process" "$count" "${pids:-none}"
      [ "$count" = 0 ] || unexpected=1
    else
      printf '%s handlers/servers: unknown.\n' "$process"; failed=1
    fi
  done
  if serve_json=$(tailscale serve status --json) && jq -e 'type == "object"' <<< "$serve_json" >/dev/null; then
    if jq -e '(.TCP // {} | has("443")) or (.Web // {} | keys | any(endswith(":443")))' <<< "$serve_json" >/dev/null; then
      serve_state=on; unexpected=1
    else serve_state=off; fi
    printf 'T3 Tailnet Serve: %s\nServe configuration: %s\n' "$serve_state" "$(jq -c . <<< "$serve_json")"
  else
    printf 'T3 Tailnet Serve: unknown (inspection failed).\n'; failed=1
  fi
  t3_active=$(systemctl --user is-active t3code.service 2>/dev/null || true)
  [ -n "$t3_active" ] || failed=1
  printf 'T3 service: %s\n' "${t3_active:-unknown}"
  if tmux_sessions=$(tmux list-sessions 2>/dev/null); then
    printf 'tmux sessions:\n%s\n' "$tmux_sessions"
  else printf 'tmux sessions: none or unavailable.\n'; fi
  if [ -f "$config_dir/door-intent.json" ]; then
    intended=$(jq -r --arg boot "$(_boot_id)" 'if .boot == $boot then .state else "closed" end' \
      "$config_dir/door-intent.json" 2>/dev/null) || intended=closed
  fi
  if [ "$reachability" = open-by-hand ]; then
    printf 'Door intent this boot: %s; reboot defaults to closed.\n' "$intended"
    if [ "$intended" != open ] && [ "$unexpected" = 1 ]; then
      printf 'WARNING: an Open-by-hand host intended closed has an open door or boot activation.\n'
    fi
    if [ "$ssh_enabled" = enabled ] || [ "$socket_enabled" = enabled ]; then
      printf 'WARNING: SSH activation is enabled at boot; this Open-by-hand host must reboot closed.\n'
    fi
    if [ "$failed" != 0 ]; then printf 'WARNING: door state could not be fully inspected.\n'; fi
  fi
  [ "$failed" = 0 ]
}

_enroll() {
  _personal_preflight
  local previous_name='' previous_mode='always-on' answer
  if [ -f "$state_file" ]; then
    previous_name=$(jq -er '.name' "$state_file") || _fail "Invalid enrollment state: $state_file"
    previous_mode=$(jq -er '.mode' "$state_file") || _fail "Invalid enrollment state: $state_file"
  fi
  printf 'Tailnet name [%s]: ' "$previous_name"
  read -r answer || _fail 'Enrollment needs a host name at the keyboard.'
  host_name="${answer:-$previous_name}"
  [[ "$host_name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    _fail 'Use a Tailnet name of 1–63 lowercase letters, numbers or interior hyphens.'
  printf 'Reachability mode (always-on / open-by-hand) [%s]: ' "$previous_mode"
  read -r answer || _fail 'Enrollment needs a reachability mode at the keyboard.'
  reachability="${answer:-$previous_mode}"
  case "$reachability" in always-on|open-by-hand) ;; *) _fail 'Choose always-on or open-by-hand.' ;; esac
  owner=$(id -un)
  sudo -v
  sudo tailscale set "--hostname=$host_name" "--operator=$owner"
  _enroll_keys
  _enroll_ssh
  _enroll_tmux
  _enroll_power
  _enroll_t3
  _enroll_moshi
  _enroll_doors
  _enroll_inventory
  jq -n --arg name "$host_name" --arg mode "$reachability" '{name:$name,mode:$mode}' |
    _write_user_file "$state_file" 600
  printf 'Enrolled %s (%s).\n' "$host_name" "$reachability"
}

case "${1:-}" in
  enroll) _enroll ;;
  open) _open ;;
  close) _close ;;
  status) _status ;;
  revoke) _revoke "${2:-}" ;;
  *) _fail 'Usage: personal-host.sh enroll | open | close | status | revoke <device-name>' ;;
esac
