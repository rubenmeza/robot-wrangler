#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

ip="$(_ip)"; [ -n "$ip" ] || { echo "robot not on the tailnet" >&2; exit 1; }

# Open an INTERACTIVE login; the box's ~/.bashrc auto-attaches the shared `robot` session in the
# provisioned multiplexer (ADR 0003). We deliberately do NOT pass an explicit `-- <mux> ...`:
# that runs non-interactively, skips ~/.bashrc, and can't resolve ~/.local/bin/herdr on PATH
# ("herdr: command not found"). Letting .bashrc drive keeps robot-attach, a bare ssh, and Moshi
# all identical. Transport follows the profile:
#   herdr -> plain SSH (full-fidelity Rust/Ratatui TUI)
#   tmux  -> mosh       (survives cellular drops)
if [ "$(_mux)" = herdr ]; then
  exec ssh -t -i "$(_key)" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "$(_host)@$ip"
else
  exec mosh --ssh="ssh -i $(_key) -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
    "$(_host)@$ip"
fi
