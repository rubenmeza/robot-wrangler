#!/usr/bin/env bash
# Sourced by the robot-* scripts AFTER they cd to the repo root. Not run directly.

_load_env() { if [ -f .env ]; then set -a; . ./.env; set +a; fi; }
_host() { printf '%s' "${TF_VAR_ts_hostname:-robot}"; }
_key()  { printf '%s' "${ROBOT_SSH_KEY:-$HOME/.ssh/robot_ed25519}"; }

# The box's tailnet IP, resolved by hostname from the LOCAL tailscale daemon.
_ip() {
  tailscale status --json | jq -r --arg h "$(_host)" \
    '.Peer[]? | select(.HostName==$h) | .TailscaleIPs[0] // empty' | head -n1
}

# ssh with the robot device identity. Extra args/opts pass through.
_ssh() {
  ssh -i "$(_key)" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "$@"
}
