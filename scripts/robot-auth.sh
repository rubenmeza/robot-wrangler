#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

: "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN in .env (run: claude setup-token)}"
ip="$(_ip)"; [ -n "$ip" ] || { echo "robot not on the tailnet" >&2; exit 1; }

# Write the token into ~/.robot-env on the box (mode 600). Sourced by the robot user's .bashrc.
printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CLAUDE_CODE_OAUTH_TOKEN" \
  | _ssh "$(_host)@$ip" 'umask 077; cat > "$HOME/.robot-env" && echo "token installed on box"'
