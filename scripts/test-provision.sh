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
for script in files/provision.sh files/setup-t3.sh; do
  bash -n "$script" || { echo "syntax error in $script"; fail=1; }
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck files/provision.sh files/setup-t3.sh || fail=1
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
# shellcheck disable=SC2016
"$runtime" run --rm -v "$PWD/files:/files:ro" -v "$PWD/cloud-init.yaml.tftpl:/manifest:ro" ubuntu:24.04 bash -euo pipefail -c '
  # Use the manifests package declaration, so omitting a runtime dependency breaks smoke.
  mapfile -t manifest_packages < <(sed -n "/^packages:/,/^$/p" /manifest | sed -n "s/^  - //p")
  apt-get update -qq && apt-get install -y -qq sudo "${manifest_packages[@]}" >/dev/null

  # A fake robot user + injected non-secret config. No real tailnet key needed: SKIP_HOST stubs
  # the tailscale/systemctl/chage calls that would use it.
  useradd -m -s /bin/bash robot
  mkdir -p /opt/robot
  cp /files/provision.sh /files/setup-t3.sh /opt/robot/
  chmod 0755 /opt/robot/provision.sh /opt/robot/setup-t3.sh
  cat > /opt/robot/provision.env <<EOF
ROBOT_USER=robot
GIT_AUTHOR_NAME=robot-test
GIT_AUTHOR_EMAIL=test@example.com
TS_HOSTNAME=robot
TS_TAGS=tag:server
EOF

  # Existing owner settings survive the resume merge.
  sudo -u robot -H mkdir -p /home/robot/.t3/userdata
  printf "%s\n" "{\"theme\":\"light\",\"custom\":{\"keep\":true},\"continueThreadsAfterServerUpdate\":false}" > /home/robot/.t3/userdata/settings.json
  chown robot:robot /home/robot/.t3/userdata/settings.json

  export PROVISION_SKIP_HOST=1
  echo "-- run 1"; bash /opt/robot/provision.sh
  test -f /opt/robot/.provisioned

  # T3 is a working standalone binary, with its shared-library runtime available.
  sudo -u robot -H /home/robot/.local/bin/t3 --version
  dpkg-query -s libatomic1 | grep -qx "Status: install ok installed"
  runtime_path=$(find /home/robot/.t3/runtime/versions -type f -name t3 -print -quit)
  test -n "$runtime_path"
  if ldd "$runtime_path" | grep -q "not found"; then
    echo "T3 runtime has an unresolved shared library"; exit 1
  fi
  ! command -v node >/dev/null || { echo "unexpected system Node runtime"; exit 1; }
  settings=/home/robot/.t3/userdata/settings.json
  unit=/home/robot/.config/systemd/user/t3code.service
  dropin=/home/robot/.config/systemd/user/t3code.service.d/10-tailnet.conf
  launcher=/home/robot/.config/t3code/start.sh
  jq -e ".continueThreadsAfterServerUpdate == true and .theme == \"light\" and .custom.keep == true" "$settings" >/dev/null
  test "$(stat -c %a "$settings")" = 600
  test "$(stat -c %U "$settings")" = robot
  test "$(stat -c %a /home/robot/.t3/userdata)" = 700
  test "$(stat -c %a "$unit")" = 600
  test "$(stat -c %U "$unit")" = robot
  test "$(stat -c %a "$launcher")" = 700
  grep -qx "WantedBy=default.target" "$unit"
  grep -qx "Environment=T3CODE_TRACE_MIN_LEVEL=Warn" "$unit"
  grep -qx "Environment=T3CODE_AUTO_BOOTSTRAP_PROJECT_FROM_CWD=false" "$unit"
  grep -qx "Environment=T3CODE_TAILSCALE_SERVE=true" "$dropin"
  grep -q -- "--mode web --no-browser --host 127.0.0.1 --port 3773 --log-level warn" "$launcher"
  sha256sum "$settings" "$unit" "$dropin" "$launcher" > /tmp/t3-files.sha256

  echo "-- run 2"; bash /opt/robot/provision.sh   # must be idempotent

  sha256sum -c /tmp/t3-files.sha256

  # A stream of objects is not a valid settings JSON document. Fail without replacing it or
  # reporting readiness; this also covers preservation on parse errors.
  printf "%s\n" "{} {}" > "$settings"
  cp "$settings" /tmp/invalid-settings.json
  rm -f /opt/robot/.provisioned
  if bash /opt/robot/provision.sh > /tmp/rejected.log 2>&1; then
    echo "Provisioner accepted invalid settings JSON"; exit 1
  fi
  cmp "$settings" /tmp/invalid-settings.json
  grep -q "T3 settings must be a valid JSON object" /tmp/rejected.log
  test ! -f /opt/robot/.provisioned

  # Git identity landed exactly once (not duplicated).
  n=$(sudo -u robot git config --global --get-all user.email | grep -c test@example.com)
  test "$n" = 1 || { echo "git identity duplicated on re-run: $n"; exit 1; }
  echo "container smoke OK"
' || fail=1

if [ "$fail" -eq 0 ]; then echo "provision tests OK"; else echo "provision tests FAILED"; exit 1; fi
