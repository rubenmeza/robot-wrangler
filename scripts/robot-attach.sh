#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

ip="$(_require_ip)" || exit 1

# Open an INTERACTIVE login; the box's /etc/profile.d/10-robot.sh auto-attaches the shared `robot`
# session in the provisioned multiplexer (ADR 0003). We deliberately do NOT pass an explicit
# `-- <mux> ...`: that runs non-interactively, skips the login-shell drop-in, and can't resolve
# ~/.local/bin/herdr on PATH ("herdr: command not found"). Letting the drop-in drive keeps
# robot-attach, a bare ssh, and Moshi all identical. Transport follows the profile (_mux_transport):
#   herdr -> plain SSH (full-fidelity Rust/Ratatui TUI)
#   tmux  -> mosh       (survives cellular drops)
# Both paths build the ssh identity from _common's single source (_ssh_cmd).
host="$(_host)@$ip"
if [ "$(_mux_transport)" = mosh ]; then
  exec mosh --ssh="$(_ssh_cmd)" "$host"
else
  # shellcheck disable=SC2046  # intentional word-split of the ssh option string into argv
  exec $(_ssh_cmd) -t "$host"
fi
