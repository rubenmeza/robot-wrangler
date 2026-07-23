#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

ip="$(_ip)"
[ -n "$ip" ] || { echo "robot ('$(_host)') is not on the tailnet yet. Provisioned & up?" >&2; exit 1; }
printf '%s\n' "$ip"
