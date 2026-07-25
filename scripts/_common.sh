#!/usr/bin/env bash
# Sourced by the robot-* scripts AFTER they cd to the repo root. Not run directly.

# shellcheck source=/dev/null
_load_env() { if [ -f .env ]; then set -a; . ./.env; set +a; fi; }
_host() { printf '%s' "${TF_VAR_ts_hostname:-robot}"; }
_key()  { printf '%s' "${ROBOT_SSH_KEY:-$HOME/.ssh/robot_ed25519}"; }
_mux()  { printf '%s' "${TF_VAR_robot_multiplexer:-herdr}"; }

# The box's tailnet IP, resolved by hostname from the LOCAL tailscale daemon.
_ip() {
  tailscale status --json | jq -r --arg h "$(_host)" \
    '.Peer[]? | select(.HostName==$h) | .TailscaleIPs[0] // empty' | head -n1
}

# The robot device-identity ssh options, one per line. Single source: both _ssh (which execs)
# and _ssh_cmd (which emits a command string for mosh's --ssh=) read from here, so the identity
# contract lives in exactly one place.
_ssh_optv() {
  printf '%s\n' -i "$(_key)" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
}

# ssh with the robot device identity. Extra args/opts pass through.
_ssh() {
  local -a o; readarray -t o < <(_ssh_optv)
  ssh "${o[@]}" "$@"
}

# The same identity as a single shell-word string, for `mosh --ssh=...` (which wants a command,
# not argv). %q-quoted so a key path with spaces survives.
_ssh_cmd() {
  local -a o; readarray -t o < <(_ssh_optv)
  printf 'ssh'; printf ' %q' "${o[@]}"
}

# The laptop-side transport for the active multiplexer profile (ADR 0003): herdr rides plain SSH
# (full-fidelity TUI), tmux rides mosh (survives cellular drops). The box-side attach command is
# the profile's other column and lives in the profile.d drop-in.
_mux_transport() {
  case "$(_mux)" in
    tmux) printf mosh ;;
    *)    printf ssh ;;
  esac
}
