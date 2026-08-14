#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

ip="$(_require_ip)" || exit 1
_ssh "$(_host)@$ip" "$@"
