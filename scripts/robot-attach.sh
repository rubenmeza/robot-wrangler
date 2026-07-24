#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

ip="$(_ip)"; [ -n "$ip" ] || { echo "robot not on the tailnet" >&2; exit 1; }

# Multiplexer + transport are a coupled profile fixed at provision time (ADR 0003):
#   herdr -> plain SSH (full-fidelity Rust/Ratatui TUI, agent-state kanban)
#   tmux  -> mosh       (battle-proven, survives cellular drops)
# Both land every device in the SAME shared `robot` session, so handoff is unaffected.
# (herdr auto-attaches via .bashrc on login, so a bare interactive shell would also work;
#  we ask explicitly here so a non-login ssh still lands in the session.)
if [ "$(_mux)" = herdr ]; then
  exec ssh -t -i "$(_key)" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
    "$(_host)@$ip" -- herdr --session robot
else
  exec mosh --ssh="ssh -i $(_key) -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
    "$(_host)@$ip" -- tmux new -A -s robot
fi
