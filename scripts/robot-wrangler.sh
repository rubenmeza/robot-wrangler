#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh

./scripts/preflight.sh
_load_env

echo "==> tofu init"
tofu init -input=false >/dev/null

echo "==> tofu apply"
tofu apply -auto-approve

echo "==> waiting for the box to join the tailnet and finish cloud-init"
./scripts/wait-ready.sh

echo "==> pushing the agent token over SSH (never via metadata)"
./scripts/robot-auth.sh

ip="$(_ip)"
cat <<EOF

  robot is live at $ip

  make robot-ssh       ssh in over the tailnet
  make robot-attach    mosh + tmux session 'robot'
  then, on the box:    claude      (starts the agent, already authed)

EOF
