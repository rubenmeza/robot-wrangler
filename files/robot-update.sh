#!/usr/bin/env bash
# Streamed over SSH; start persists a self-contained worker before handing it to systemd.
set -euo pipefail
umask 077
root="${ROBOT_UPDATE_DIR:-/var/lib/robot-update}"
reboot_file="${ROBOT_UPDATE_REBOOT_FILE:-/var/run/reboot-required}"
provision_file="${ROBOT_UPDATE_PROVISION_FILE:-/opt/robot/provision.env}"
profile_file="${ROBOT_UPDATE_PROFILE_FILE:-/etc/profile.d/10-robot.sh}"
boot_file="${ROBOT_UPDATE_BOOT_FILE:-/proc/sys/kernel/random/boot_id}"
request_id="${2:-}"
if [ -n "$request_id" ] && ! [[ "$request_id" =~ ^[a-zA-Z0-9_-]{1,100}$ ]]; then
  echo 'Invalid maintenance request ID.' >&2
  exit 2
fi

disable_agent_resume() {
  local config="$robot_home/.config/herdr/config.toml"
  if [ -f "$config" ] && [ ! -f "$operation/herdr-config.previous" ]; then
    cp -p "$config" "$operation/herdr-config.previous"
  fi
  # Preserve unrelated TOML verbatim and validate the complete document before replacing it.
  as_robot python3 - "$config" <<'PY'
import copy, os, pathlib, re, sys, tempfile, tomllib
path = pathlib.Path(sys.argv[1]).resolve()
text = path.read_text() if path.exists() else ''
if text and not text.endswith('\n'):
    text += '\n'
before = tomllib.loads(text)
expected = copy.deepcopy(before)
expected.setdefault('session', {})['resume_agents_on_restore'] = False
if before == expected:
    sys.exit(0)
header = re.search(r'(?m)^[ \t]*\[session\][ \t]*(?:#[^\n]*)?$', text)
setting = 'resume_agents_on_restore = false\n'
if header:
    start = header.end() + 1
    following = re.search(r'(?m)^[ \t]*\[', text[start:])
    end = start + following.start() if following else len(text)
    section = text[start:end]
    section, count = re.subn(r'(?m)^[ \t]*resume_agents_on_restore[ \t]*=.*$',
                            setting.rstrip(), section)
    if not count:
        section = setting + section
    updated = text[:start] + section + text[end:]
else:
    updated = text + '\n[session]\n' + setting
if tomllib.loads(updated) != expected:
    raise ValueError('Cannot safely edit Herdr session settings; config unchanged')
path.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as file:
    staged = pathlib.Path(file.name)
    try:
        file.write(updated)
        file.flush()
        os.chmod(staged, path.stat().st_mode & 0o777 if path.exists() else 0o600)
        os.replace(staged, path)
    finally:
        staged.unlink(missing_ok=True)
PY
}

verify_attachment() {
  local command rc
  # Exercise the real client in a disposable PTY. A healthy attachment stays open until
  # timeout detaches this probe; an early exit is a failure, not an attachable session.
  if [ "$profile" = herdr ]; then
    printf -v command 'timeout --signal=TERM --kill-after=2s 3s %q session attach robot' "$binary"
  else
    command='timeout --signal=TERM --kill-after=2s 3s tmux attach-session -t =robot'
  fi
  command="stty rows 40 cols 120 && $command"
  if as_robot env TERM=xterm-256color script -q -e -c "$command" /dev/null < /dev/null; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 124 ]
}

load_robot() {
  # Read the box's provisioned identity/profile, never the Control surface's .env.
  # shellcheck source=/dev/null
  source "$provision_file"
  robot_home="$(getent passwd "$ROBOT_USER" | cut -d: -f6)"
  [ -n "$robot_home" ] && [ -d "$robot_home" ]
  profile="$(sed -nE 's/^  if \[ "(herdr|tmux)" = herdr \].*/\1/p' "$profile_file")"
  case "$profile" in herdr|tmux) ;; *) echo 'Unrecognized on-box multiplexer profile'; return 1 ;; esac
  as_robot() {
    sudo -H -u "$ROBOT_USER" env "HOME=$robot_home" \
      "PATH=$robot_home/.local/bin:$PATH" "XDG_RUNTIME_DIR=/run/user/$(id -u "$ROBOT_USER")" "$@"
  }
  binary="$robot_home/.local/bin/herdr"
}

maintain_herdr() {
  step=inspect-profile
  save_state running
  load_robot
  echo "$profile" > "$operation/profile"
  binary="$robot_home/.local/bin/herdr"
  echo "$binary" > "$operation/binary"
  {
    echo 'Connect over the Tailnet: ./scripts/robot-ssh.sh -t bash --noprofile --norc'
    echo 'After connecting, load existing agent credentials if present: source ~/.robot-env'
    echo 'Manually start/attach the configured session (previous agents do not automatically resume):'
    if [ "$profile" = herdr ]; then printf '  %q session attach robot\n' "$binary"
    else echo '  tmux new-session -A -s robot'; fi
  } > "$operation/recovery"
  maintenance_root="$(dirname "$(dirname "$operation")")"
  if [ -e "$maintenance_root/previous-herdr" ]; then
    readlink -f "$maintenance_root/previous-herdr" > "$operation/backup"
  fi
  installed="$(as_robot "$binary" --version)"
  installed="${installed#herdr }"
  echo "$installed" > "$operation/installed"
  echo "$step" >> "$operation/completed"

  step=discover-herdr
  save_state running
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
    https://herdr.dev/latest.json -o "$operation/release.json"
  target="$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$operation/release.json")"
  echo "$target" > "$operation/target"
  echo "Herdr installed: $installed; target: $target"
  echo "$step" >> "$operation/completed"

  if [ "$installed" != "$target" ]; then
    step=download-herdr
    save_state running
    case "$(uname -m)" in
      x86_64|amd64) platform=linux-x86_64 ;;
      aarch64|arm64) platform=linux-aarch64 ;;
      *) echo 'Unsupported Herdr architecture'; return 1 ;;
    esac
    url="$(jq -er --arg p "$platform" '.assets[$p] | select(startswith("https://"))' "$operation/release.json")"
    checksum="$(jq -er --arg p "$platform" '.sha256[$p] | select(test("^[0-9a-fA-F]{64}$"))' "$operation/release.json")"
    candidate="$(mktemp "$robot_home/.local/bin/.herdr-update.XXXXXX")"
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$candidate"
    printf '%s  %s\n' "$checksum" "$candidate" | sha256sum -c -
    chmod 0755 "$candidate"
    [ "$(as_robot "$candidate" --version)" = "herdr $target" ]
    echo "$step" >> "$operation/completed"

    step=replace-herdr
    save_state running
    cp -p "$binary" "$operation/herdr.previous"
    echo "$operation/herdr.previous" > "$operation/backup"
    ln -sfn "$operation/herdr.previous" "$maintenance_root/previous-herdr"
    chown --reference="$binary" "$candidate"
    mv -T "$candidate" "$binary"
    candidate=''
    echo "$step" >> "$operation/completed"
  fi
  activate_session
}

activate_session() {
  step=activate-session
  save_state running
  if [ "$profile" = tmux ]; then
    if ! as_robot tmux has-session -t =robot; then
      # shellcheck disable=SC2016 # Read credentials inside the Robot-user shell.
      as_robot /bin/bash -eu -c '
        if [ -f "$HOME/.robot-env" ]; then . "$HOME/.robot-env"; fi
        exec tmux new-session -d -s robot
      '
    fi
    [ "$(as_robot tmux display-message -p -t =robot '#{session_name}')" = robot ]
  else
    disable_agent_resume
    as_robot timeout 10s "$binary" --session robot status server --json > "$operation/session.json"
    if ! jq -e --arg version "$target" \
      '.running == true and .version == $version and .compatible == true and .endpoint_compatible == true' \
      "$operation/session.json" >/dev/null; then
      if jq -e '.running == true' "$operation/session.json" >/dev/null; then
        as_robot timeout 15s "$binary" session stop robot
      fi
      # A separate service owns the server and its panes after the maintenance worker exits.
      # shellcheck disable=SC2016 # Expand HOME/argv inside the Robot-user service, not here.
      systemd-run --quiet --collect --unit="robot-herdr-$(basename "$operation")" \
        --uid="$ROBOT_USER" --property=Type=exec --property="WorkingDirectory=$robot_home" \
        --property="StandardOutput=append:$operation/herdr-server.log" --property=StandardError=inherit \
        --setenv="HOME=$robot_home" --setenv="PATH=$robot_home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        --setenv="XDG_RUNTIME_DIR=/run/user/$(id -u "$ROBOT_USER")" \
        /bin/bash -eu -c '
          if [ -f "$HOME/.robot-env" ]; then . "$HOME/.robot-env"; fi
          exec "$@"
        ' robot-herdr "$binary" --session robot server
    fi
    deadline=$((SECONDS + 30))
    until as_robot timeout 5s "$binary" --session robot status server --json > "$operation/session.json" &&
      jq -e --arg version "$target" \
        '.running == true and .version == $version and .session == "robot" and .compatible == true and .endpoint_compatible == true' \
        "$operation/session.json" >/dev/null; do
      [ "$SECONDS" -lt "$deadline" ] || { echo 'Herdr activation timed out'; return 1; }
      sleep 1
    done
  fi
  echo "$step" >> "$operation/completed"
  step=verify-session
  save_state running
  verify_attachment
  echo "$step" >> "$operation/completed"
  echo "$profile robot" > "$operation/verified"
}

worker() {
  set -euo pipefail
  # EXIT may run after the function scope unwinds on errexit; keep its state shell-wide.
  operation="$1"
  reboot_file="$2"
  provision_file="$3"
  profile_file="$4"
  boot_file="$5"
  mode="$6"
  outcome=awaiting-access
  candidate=''
  step=starting
  exec >> "$operation/operation.log" 2>&1
  save_state() {
    printf '%s %s\n' "$1" "$step" > "$operation/state.tmp"
    mv "$operation/state.tmp" "$operation/state"
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
  finish() {
    local rc=$?
    trap - EXIT
    if [ -n "$candidate" ]; then rm -f -- "$candidate"; fi
    if [ "$rc" -eq 0 ] || [ "$outcome" = awaiting-reboot ]; then
      save_state "$outcome"
    else
      save_state failed
    fi
    if [ -f "$reboot_file" ]; then
      echo 'yes' > "$operation/reboot-required"
    else
      echo 'no' > "$operation/reboot-required"
    fi
    printf '%s: ended with exit %s; pending reboot: %s\n' \
      "$(date -u +%FT%TZ)" "$rc" "$(cat "$operation/reboot-required")"
    exit "$rc"
  }
  trap finish EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  if [ "$mode" = verify ]; then
    step=final-verification
    save_state running
    rm -f "$operation/verified"
    expected_profile="$(cat "$operation/profile")"
    expected_binary="$(cat "$operation/binary")"
    target="$(cat "$operation/target")"
    load_robot
    [ "$profile" = "$expected_profile" ] && [ "$binary" = "$expected_binary" ]
    [ "$(as_robot "$binary" --version)" = "herdr $target" ]
    activate_session
    finish_updates
    exit 0
  fi
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  step=configure-packages
  save_state running
  echo "$(date -u +%FT%TZ): $step"
  dpkg --force-confdef --force-confold --configure -a
  echo "$step" >> "$operation/completed"
  step=update-indexes
  save_state running
  echo "$(date -u +%FT%TZ): $step"
  apt-get -o APT::Update::Error-Mode=any update
  echo "$step" >> "$operation/completed"
  step=upgrade-packages
  save_state running
  echo "$(date -u +%FT%TZ): $step"
  apt-get -y --with-new-pkgs -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  echo "$step" >> "$operation/completed"
  maintain_herdr
  : > "$operation/updates-completed"
  finish_updates
  exit 0
}

finish_updates() {
  if [ -f "$reboot_file" ]; then
    step=reboot
    # Never loop through reboots if the reboot marker survives an actual new boot.
    if [ -f "$operation/boot-before" ] &&
      [ "$(cat "$operation/boot-before")" != "$(cat "$boot_file")" ]; then
      echo 'Reboot remains required after restart; inspect the box before retrying.'
      return 1
    fi
    cat "$boot_file" > "$operation/boot-before"
    outcome=awaiting-reboot
    save_state "$outcome"
    sync -f "$operation"
    if systemctl reboot --no-block; then
      echo 'Reboot requested; completed updates are preserved. Awaiting a new boot and SSH verification.'
    else
      rc=$?
      outcome=failed
      return "$rc"
    fi
  else
    cat "$boot_file" > "$operation/verified-boot"
    outcome=awaiting-access
  fi
}

# Unknown systemd errors fail closed: never infer that it is safe to start a second worker.
active() {
  local state unit
  unit="robot-update-$(basename "$operation").service"
  if [ -f "$operation/unit" ]; then unit="$(cat "$operation/unit")"; fi
  state="$(systemctl is-active "$unit")" || true
  case "$state" in
    active|activating|reloading|deactivating) return 0 ;;
    inactive|failed|unknown) return 1 ;;
    *) echo 'Cannot determine maintenance service state.' >&2; exit 1 ;;
  esac
}

report() {
  local state step is_active=no
  if active; then is_active=yes; fi
  read -r state step < "$operation/state"
  if [ "$is_active" = no ] && { [ "$state" = running ] || [ "$state" = queued ]; }; then
    state=interrupted
  fi
  printf 'Operation: %s\nActive: %s\nState: %s\nCurrent/last step: %s\n' \
    "$(basename "$operation")" "$is_active" "$state" "$step"
  echo 'Completed steps:'
  if [ -s "$operation/completed" ]; then cat "$operation/completed"; else echo '(none)'; fi
  if [ "$state" = failed ] || [ "$state" = interrupted ]; then
    echo "Failed/interrupted step: $step"
  fi
  if [ -f "$reboot_file" ]; then echo 'Pending reboot: yes'; else echo 'Pending reboot: no'; fi
  if [ -f "$operation/reboot-required" ]; then
    echo "Pending reboot at operation end: $(cat "$operation/reboot-required")"
  fi
  echo "Log: $operation/operation.log"
  for field in profile installed target backup verified; do
    [ -f "$operation/$field" ] || continue
    case "$field" in
      profile) label='Multiplexer profile' ;;
      installed) label='Herdr installed' ;;
      target) label='Herdr target' ;;
      backup) label='Previous Herdr binary' ;;
      verified) label='Session verified' ;;
    esac
    printf '%s: %s\n' "$label" "$(cat "$operation/$field")"
  done
  if [ "$state" = failed ] || [ "$state" = interrupted ]; then
    if [ -f "$operation/recovery" ]; then cat "$operation/recovery"; fi
    if [ -f "$operation/backup" ] && [ -f "$operation/binary" ]; then
      local backup binary
      backup="$(cat "$operation/backup")"
      binary="$(cat "$operation/binary")"
      echo 'Restore the previous binary only if the installed version cannot run (manual recovery):'
      printf '  sudo cp -p -- %q %q\n' "$backup" "$binary.restore"
      printf '  sudo mv -T -- %q %q\n' "$binary.restore" "$binary"
      echo 'Then stop any running Herdr session and use the configured session command above.'
      echo 'No automatic rollback was performed.'
    fi
  fi
  if [ -f "$operation/updates-completed" ]; then echo 'Update steps: completed'; fi
  if [ "$state" = complete ]; then
    echo 'Maintenance complete: updates, configured session, and SSH access verified.'
  else
    echo 'Maintenance is not complete; inspect the state and any pending reboot.'
  fi
  [ "$state" != failed ] && [ "$state" != interrupted ]
}

launch_worker() {
  local mode="$1" unit
  unit="robot-update-$(basename "$operation")-$(date +%s%N).service"
  echo "$unit" > "$operation/unit"
  printf 'queued %s\n' "$mode" > "$operation/state"
  if systemd-run --quiet --collect --unit="$unit" \
    --property=Type=exec /bin/bash "$operation/worker.sh" "$operation" "$reboot_file" \
    "$provision_file" "$profile_file" "$boot_file" "$mode" >> "$operation/operation.log" 2>&1; then
    report
  else
    printf 'failed launch\n' > "$operation/state"
    report
    return 1
  fi
}

# Called under the launch lock. A successful SSH poll is the final access check.
resume_operation() {
  local state step
  if active; then report; return; fi
  read -r state step < "$operation/state"
  if [ "$state" = awaiting-reboot ] &&
    [ "$(cat "$operation/boot-before")" = "$(cat "$boot_file")" ]; then
    report
  elif [ "$state" = awaiting-access ] &&
    [ "$(cat "$operation/verified-boot")" = "$(cat "$boot_file")" ] && [ ! -f "$reboot_file" ]; then
    echo verify-access >> "$operation/completed"
    printf 'complete verify-access\n' > "$operation/state.tmp"
    mv "$operation/state.tmp" "$operation/state"
    report
  elif [ "$state" = awaiting-reboot ] || [ "$state" = awaiting-access ] || [ "${1:-}" = retry ]; then
    launch_worker verify
  else
    report
  fi
}

bind_request() {
  if [ -n "$request_id" ]; then
    mkdir -p "$root/requests"
    ln -s "$operation" "$root/requests/$request_id"
  fi
}

case "${1:-}" in
  status)
    if [ ! -e "$root/current" ]; then echo 'No maintenance operation recorded.'; exit 0; fi
    # Serialize status with launch, but never create state during a read-only request.
    exec 9< "$root/launch.lock"
    flock -s 9
    operation="$(readlink -f "$root/current")"
    report
    ;;
  poll)
    if [ ! -e "$root/current" ]; then echo 'No maintenance operation recorded; rerun make robot-update.'; exit 1; fi
    exec 9< "$root/launch.lock"
    flock -x 9
    if [ -n "$request_id" ]; then
      if [ ! -e "$root/requests/$request_id" ]; then
        echo 'No operation recorded for this request; rerun make robot-update.'
        exit 1
      fi
      operation="$(readlink -f "$root/requests/$request_id")"
    else
      operation="$(readlink -f "$root/current")"
    fi
    resume_operation
    ;;
  start)
    mkdir -p "$root/operations"
    exec 9> "$root/launch.lock"
    flock 9
    if [ -n "$request_id" ] && [ -e "$root/requests/$request_id" ]; then
      operation="$(readlink -f "$root/requests/$request_id")"
      resume_operation
      exit
    fi
    if [ -e "$root/current" ]; then
      operation="$(readlink -f "$root/current")"
      if active; then bind_request; report; exit; fi
      read -r state _ < "$operation/state"
      if [ -f "$operation/updates-completed" ] && [ "$state" != complete ]; then
        bind_request
        resume_operation retry
        exit
      fi
    fi
    operation="$(mktemp -d "$root/operations/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
    printf 'queued launch\n' > "$operation/state"
    : > "$operation/completed"
    : > "$operation/operation.log"
    { printf '#!/usr/bin/env bash\n'; declare -f worker maintain_herdr load_robot activate_session disable_agent_resume verify_attachment finish_updates; printf 'worker "$@"\n'; } > "$operation/worker.sh"
    ln -sfn "$operation" "$root/current"
    bind_request
    launch_worker update
    ;;
  *) echo 'Usage: robot-update.sh start|status|poll' >&2; exit 2 ;;
esac
