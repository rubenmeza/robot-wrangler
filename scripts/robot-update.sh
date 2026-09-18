#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh

action="${1:-start}"
case "$action" in
  start)
    echo 'Finish or stop agent work before updating the Robot.'
    echo 'Maintenance may interrupt sessions and restart services; the box will reboot if required.'
    echo 'Herdr may restart; previous agents do not automatically resume.'
    read -r -p 'Start OS package and Herdr maintenance? Type yes: ' answer || answer=''
    if [ "$answer" != yes ]; then
      echo 'Maintenance cancelled; no changes made.'
      exit 0
    fi
    ;;
  status) ;;
  *) echo 'Usage: robot-update.sh [start|status]' >&2; exit 2 ;;
esac

_load_env
readarray -t ssh_options < <(_ssh_optv)
wait_seconds="${ROBOT_UPDATE_RECONNECT_SECONDS:-300}"
[[ "$wait_seconds" =~ ^[0-9]+$ ]] && [ "$wait_seconds" -gt 0 ] && [ "$wait_seconds" -le 300 ] || {
  echo 'Reconnection budget must be between 1 and 300 seconds.' >&2; exit 2;
}
deadline=0
updates_completed=no
last_report=''
request="$action"
request_id="$(date +%s%N)-$RANDOM-$RANDOM"

budget() {
  local limit="$1" remaining
  if [ "$deadline" -ne 0 ]; then
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] || return 1
    if [ "$remaining" -lt "$limit" ]; then limit="$remaining"; fi
  fi
  printf '%s' "$limit"
}

while true; do
  resolve_budget="$(budget 5)" || break
  ip="$(timeout --signal=KILL "${resolve_budget}s" bash scripts/robot-ip.sh 2>/dev/null)" || ip=''
  attempt_budget="$(budget 10)" || break
  rc=255
  output=''
  if [ -n "$ip" ]; then
    if output="$(timeout --signal=KILL "${attempt_budget}s" ssh "${ssh_options[@]}" \
      -o BatchMode=yes -o ConnectionAttempts=1 -o "ConnectTimeout=$attempt_budget" \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=1 "$(_host)@$ip" \
      "sudo -n bash -s -- $request $request_id" < files/robot-update.sh 2>&1)"; then rc=0; else rc=$?; fi
    # After an uncertain launch, inspect persisted state; never blindly submit a second start.
    if [ "$request" = start ]; then request=poll; fi
  fi
  if [ "$action" = status ]; then printf '%s\n' "$output"; exit "$rc"; fi
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    if [ "$output" != "$last_report" ]; then printf '%s\n' "$output"; last_report="$output"; fi
    if [ "$rc" -ne 0 ]; then exit "$rc"; fi
    if [[ "$output" == *'Update steps: completed'* ]]; then updates_completed=yes; fi
    if [[ "$output" == *'State: complete'* ]]; then exit 0; fi
    if [ "$updates_completed" = yes ]; then
      if [ "$deadline" -eq 0 ]; then deadline=$((SECONDS + wait_seconds)); fi
    else
      deadline=0  # The five-minute return budget does not limit healthy package installation.
    fi
  else
    if [ "$deadline" -eq 0 ]; then
      deadline=$((SECONDS + wait_seconds))
      echo 'Connection unavailable; waiting for the Robot. Persisted maintenance may still be running.' >&2
    fi
  fi
  pause="${ROBOT_UPDATE_POLL_SECONDS:-2}"
  remaining="$(budget 2)" || break
  # Cap even a custom polling interval so no sleep can overrun the return deadline.
  [[ "$pause" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo 'Invalid polling interval.' >&2; exit 2; }
  pause="$(awk -v p="$pause" -v r="$remaining" 'BEGIN { print p < r ? p : r }')"
  sleep "$pause"
done

if [ "$updates_completed" = yes ]; then
  echo 'Updates completed, but reconnection/final verification timed out; maintenance is not complete.' >&2
else
  echo 'Reconnection timed out; update outcome is unknown. This is not a reported package or Herdr failure.' >&2
fi
echo 'Open DigitalOcean → robot droplet → Recovery Console; check boot, networking, Tailscale, and SSH.' >&2
echo 'Then rerun make robot-update to resume the persisted operation without repeating completed updates.' >&2
exit 1
