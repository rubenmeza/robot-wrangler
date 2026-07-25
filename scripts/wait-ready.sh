#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

# One shared 15-min budget across all three readiness gates (IP -> SSH -> cloud-init). The polling,
# timeout, and progress dots live in _wait_until (_common.sh); here we only name the gates and their
# probes.
deadline=$(( $(date +%s) + 900 ))
host="$(_host)"
ip=""

# Box-specific readiness predicates. They read $ip/$host from this scope; _wait_until runs them in
# its loop condition.
_ssh_ok()      { _ssh -o BatchMode=yes -o ConnectTimeout=5 "$host@$ip" true 2>/dev/null; }
_provisioned() { _ssh -o BatchMode=yes -o ConnectTimeout=5 "$host@$ip" 'test -f /opt/robot/.provisioned' 2>/dev/null; }

_wait_until "tailnet IP" 5 "$deadline" _have_ip || exit 1
ip="$(_ip)"; echo "  -> $ip"

_wait_until "SSH" 5 "$deadline" _ssh_ok || exit 1

_wait_until "cloud-init to finish" 10 "$deadline" _provisioned \
  || { echo "  (cloud-init still running — check: make robot-ssh, then 'cloud-init status')"; exit 1; }
