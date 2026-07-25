#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Tests for the Provisioner (files/provision.sh), the imperative half of first-boot setup
# (ADR 0006). The interface IS the test surface: config arrives via provision.env + .ts-authkey,
# and PROVISION_SKIP_HOST=1 stubs the calls that need real hardware, so the script runs on its own.
#
# Two layers:
#   1. static    -- shellcheck + `bash -n`. Always runs here.
#   2. container -- run it TWICE in ubuntu:24.04 and assert idempotency + agent-user steps land.
#                   Needs docker/podman + network; skipped otherwise.

fail=0

# --- 1. static -------------------------------------------------------------------------------
echo "==> static checks"
bash -n files/provision.sh || { echo "syntax error in files/provision.sh"; fail=1; }
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck files/provision.sh || fail=1
else
  echo "shellcheck not found — skipping (pacman -S shellcheck)"
fi

# --- 2. container idempotency smoke ----------------------------------------------------------
runtime="$(command -v docker || command -v podman || true)"
if [ -z "$runtime" ]; then
  echo "==> no docker/podman — skipping container smoke"
  if [ "$fail" -eq 0 ]; then echo "provision tests OK (static only)"; exit 0; fi
  echo "provision tests FAILED"; exit 1
fi

echo "==> container smoke ($runtime, ubuntu:24.04, double run)"
"$runtime" run --rm -v "$PWD/files:/files:ro" ubuntu:24.04 bash -euo pipefail -c '
  apt-get update -qq && apt-get install -y -qq sudo curl ca-certificates git >/dev/null

  # A fake robot user + injected non-secret config. No real tailnet key needed: SKIP_HOST stubs
  # the tailscale/systemctl/chage calls that would use it.
  useradd -m -s /bin/bash robot
  mkdir -p /opt/robot
  cp /files/provision.sh /opt/robot/provision.sh && chmod 0755 /opt/robot/provision.sh
  cat > /opt/robot/provision.env <<EOF
ROBOT_USER=robot
GIT_AUTHOR_NAME=robot-test
GIT_AUTHOR_EMAIL=test@example.com
TS_HOSTNAME=robot
TS_TAGS=tag:server
EOF

  export PROVISION_SKIP_HOST=1
  echo "-- run 1"; bash /opt/robot/provision.sh
  echo "-- run 2"; bash /opt/robot/provision.sh   # must be idempotent

  # Assertions: readiness marker set, git identity landed exactly once (not duplicated).
  test -f /opt/robot/.provisioned
  n=$(sudo -u robot git config --global --get-all user.email | grep -c test@example.com)
  test "$n" = 1 || { echo "git identity duplicated on re-run: $n"; exit 1; }
  echo "container smoke OK"
' || fail=1

if [ "$fail" -eq 0 ]; then echo "provision tests OK"; else echo "provision tests FAILED"; exit 1; fi
