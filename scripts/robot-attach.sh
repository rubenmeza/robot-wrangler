#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

ip="$(_ip)"; [ -n "$ip" ] || { echo "robot not on the tailnet" >&2; exit 1; }
exec mosh --ssh="ssh -i $(_key) -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
  "$(_host)@$ip" -- tmux new -A -s robot
