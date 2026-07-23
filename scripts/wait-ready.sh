#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

deadline=$(( $(date +%s) + 900 ))   # 15 min
timeleft() { [ "$(date +%s)" -lt "$deadline" ]; }

printf 'waiting for tailnet IP'
ip=""
while :; do
  ip="$(_ip)"; [ -n "$ip" ] && break
  timeleft || { echo " TIMEOUT"; exit 1; }
  printf '.'; sleep 5
done
echo " -> $ip"

printf 'waiting for SSH'
while ! _ssh -o BatchMode=yes -o ConnectTimeout=5 "$(_host)@$ip" true 2>/dev/null; do
  timeleft || { echo " TIMEOUT"; exit 1; }
  printf '.'; sleep 5
done
echo ' ok'

printf 'waiting for cloud-init to finish'
while ! _ssh -o BatchMode=yes -o ConnectTimeout=5 "$(_host)@$ip" 'test -f /opt/robot/.provisioned' 2>/dev/null; do
  timeleft || { echo " TIMEOUT (cloud-init still running — check: make robot-ssh, then 'cloud-init status')"; exit 1; }
  printf '.'; sleep 10
done
echo ' done'
