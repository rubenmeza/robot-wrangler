#!/usr/bin/env bash
# Streamed over SSH; start persists a self-contained worker before handing it to systemd.
set -euo pipefail
umask 077
root="${ROBOT_UPDATE_DIR:-/var/lib/robot-update}"
reboot_file="${ROBOT_UPDATE_REBOOT_FILE:-/var/run/reboot-required}"

worker() {
  set -euo pipefail
  # EXIT may run after the function scope unwinds on errexit; keep its state shell-wide.
  operation="$1"
  reboot_file="$2"
  step=starting
  exec >> "$operation/operation.log" 2>&1
  save_state() {
    printf '%s %s\n' "$1" "$step" > "$operation/state.tmp"
    mv "$operation/state.tmp" "$operation/state"
  }
  finish() {
    local rc=$?
    trap - EXIT
    if [ "$rc" -eq 0 ]; then save_state packages-updated; else save_state failed; fi
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
  exit 0
}

# Unknown systemd errors fail closed: never infer that it is safe to start a second worker.
active() {
  local state
  state="$(systemctl is-active "robot-update-$(basename "$operation").service")" || true
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
  echo 'Full maintenance completion is not verified; reboot/session activation may remain pending.'
  [ "$state" != failed ] && [ "$state" != interrupted ]
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
  start)
    mkdir -p "$root/operations"
    exec 9> "$root/launch.lock"
    flock 9
    if [ -e "$root/current" ]; then
      operation="$(readlink -f "$root/current")"
      if active; then report; exit; fi
    fi
    operation="$(mktemp -d "$root/operations/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
    printf 'queued launch\n' > "$operation/state"
    : > "$operation/completed"
    : > "$operation/operation.log"
    { printf '#!/usr/bin/env bash\n'; declare -f worker; printf 'worker "$@"\n'; } > "$operation/worker.sh"
    ln -sfn "$operation" "$root/current"
    if systemd-run --quiet --collect --unit="robot-update-$(basename "$operation")" \
      --property=Type=exec /bin/bash "$operation/worker.sh" "$operation" "$reboot_file" \
      >> "$operation/operation.log" 2>&1; then
      report
    else
      printf 'failed launch\n' > "$operation/state"
      report
      exit 1
    fi
    ;;
  *) echo 'Usage: robot-update.sh start|status' >&2; exit 2 ;;
esac
