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

# Resolve the box's tailnet IP or fail. Prints the IP on stdout; on failure prints one message to
# stderr and returns 1 (NOT exit -- callers run this in `ip="$(_require_ip)"`, a subshell, where
# exit would only kill the subshell). Caller pattern:  ip="$(_require_ip)" || exit 1
_require_ip() {
  local ip; ip="$(_ip)"
  [ -n "$ip" ] || { echo "robot ('$(_host)') is not on the tailnet. Provisioned & up?" >&2; return 1; }
  printf '%s\n' "$ip"
}

# The IP-appears gate predicate for _wait_until.
_have_ip() { [ -n "$(_ip)" ]; }

# Poll <probe> every <interval>s until it succeeds or <deadline> (epoch seconds) passes. Prints
# <label> then a progress dot per attempt; returns 0 when ready, 1 on timeout (prints " TIMEOUT").
# <probe> is a command -- usually a small predicate function -- run in the loop condition, so it is
# the test seam: inject a fake probe that flips after N calls. The deadline is passed in (not a
# global) so callers can share one budget across several gates, and tests can pass a past deadline.
_wait_until() {
  local label="$1" interval="$2" deadline="$3" probe="$4"
  printf 'waiting for %s' "$label"
  until "$probe"; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo ' TIMEOUT'; return 1; }
    printf '.'; sleep "$interval"
  done
  echo ' ok'
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
