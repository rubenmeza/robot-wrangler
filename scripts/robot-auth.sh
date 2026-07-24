#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

: "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN in .env (run: claude setup-token)}"
: "${GH_TOKEN:?set GH_TOKEN in .env (classic PAT, repo scope: https://github.com/settings/tokens)}"
ip="$(_ip)"; [ -n "$ip" ] || { echo "robot not on the tailnet" >&2; exit 1; }

# Write both secrets into ~/.robot-env on the box (mode 600). Sourced by the robot user's .bashrc.
# GH_TOKEN authenticates gh and git (github.com over HTTPS) as the owner — see ADR 0002.
{
  printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CLAUDE_CODE_OAUTH_TOKEN"
  printf 'export GH_TOKEN=%q\n' "$GH_TOKEN"
} | _ssh "$(_host)@$ip" 'umask 077; cat > "$HOME/.robot-env" && echo "tokens installed on box"'
