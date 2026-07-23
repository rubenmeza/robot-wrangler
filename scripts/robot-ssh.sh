#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

ip="$(_ip)"; [ -n "$ip" ] || { echo "robot not on the tailnet" >&2; exit 1; }
exec _ssh "$(_host)@$ip" "$@"
