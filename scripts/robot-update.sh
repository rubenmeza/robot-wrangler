#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh

action="${1:-start}"
case "$action" in
  start)
    echo 'Finish or stop agent work before updating the Robot.'
    echo 'Maintenance may interrupt sessions, restart services, and require a reboot.'
    read -r -p 'Start OS package maintenance? Type yes: ' answer || answer=''
    if [ "$answer" != yes ]; then
      echo 'Maintenance cancelled; no changes made.'
      exit 0
    fi
    ;;
  status) ;;
  *) echo 'Usage: robot-update.sh [start|status]' >&2; exit 2 ;;
esac

_load_env
ip="$(_require_ip)" || exit 1
if _ssh "$(_host)@$ip" "sudo -n bash -s -- $action" < files/robot-update.sh; then
  exit 0
else
  rc=$?
  if [ "$rc" -eq 255 ]; then
    echo 'Connection lost; maintenance may still be running. Use make robot-update-status.' >&2
  fi
  exit "$rc"
fi
