#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

: "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN in .env (run: claude setup-token)}"
: "${GH_TOKEN:?set GH_TOKEN in .env (classic PAT, repo scope: https://github.com/settings/tokens)}"
ip="$(_require_ip)" || exit 1

# Write the secrets into ~/.robot-env on the box (mode 600). Sourced on login by the box's
# /etc/profile.d/10-robot.sh drop-in (ADR 0006).
# GH_TOKEN authenticates gh and git (github.com over HTTPS) as the owner — see ADR 0002.
# MOSHI_PAIRING_TOKEN is optional (Moshi push, ADR 0007); an `if` (not `&&`) keeps the group's exit
# status 0 under pipefail when it's unset.
{
  printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CLAUDE_CODE_OAUTH_TOKEN"
  printf 'export GH_TOKEN=%q\n' "$GH_TOKEN"
  if [ -n "${MOSHI_PAIRING_TOKEN:-}" ]; then
    printf 'export MOSHI_PAIRING_TOKEN=%q\n' "$MOSHI_PAIRING_TOKEN"
  fi
} | _ssh "$(_host)@$ip" 'umask 077; cat > "$HOME/.robot-env" && echo "tokens installed on box"'

# Optional: Codex CLI subscription auth (ADR 0008). CODEX_AUTH_JSON points to a local ~/.codex/
# auth.json captured from a `codex login` (or `codex login --device-auth`). Pushed to the box so the
# headless Codex TUI runs authed from your ChatGPT subscription — no API billing. Codex refreshes
# the token on the box. Treat the file like a password; it never touches git or metadata.
if [ -n "${CODEX_AUTH_JSON:-}" ] && [ -f "$CODEX_AUTH_JSON" ]; then
  _ssh "$(_host)@$ip" 'umask 077; mkdir -p "$HOME/.codex"; cat > "$HOME/.codex/auth.json" && chmod 600 "$HOME/.codex/auth.json" && echo "codex auth installed on box"' < "$CODEX_AUTH_JSON"
fi

# Optional: wire Moshi push notifications (ADR 0007). MOSHI_PAIRING_TOKEN comes from the Moshi app
# (Settings -> Hooks). Pair the on-box moshi-hook daemon, install the Claude Code hooks
# (PreToolUse/Notification/Stop), and (re)install its linger-backed --user service. Idempotent, so
# re-running robot-auth just refreshes it. Moshi Pro (multi-device push) is redeemed in the app on
# your phone, NOT a server secret — nothing about it belongs on the box.
if [ -n "${MOSHI_PAIRING_TOKEN:-}" ]; then
  _ssh "$(_host)@$ip" 'set -a; . "$HOME/.robot-env"; set +a
    export PATH="$HOME/.local/bin:$PATH" XDG_RUNTIME_DIR="/run/user/$(id -u)"
    moshi-hook pair --token "$MOSHI_PAIRING_TOKEN" >/dev/null
    moshi-hook install >/dev/null
    moshi-hook service install >/dev/null
    echo "moshi-hook paired + push service installed"'
fi
