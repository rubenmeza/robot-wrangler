#!/usr/bin/env python3
"""Command-boundary tests; no network, root, or real package manager required."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent


class RobotUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "files").mkdir()
        for name in ("_common.sh", "robot-update.sh"):
            source = ROOT / "scripts" / name
            if source.exists():
                shutil.copy(source, self.root / "scripts" / name)
        source = ROOT / "files" / "robot-update.sh"
        if source.exists():
            shutil.copy(source, self.root / "files" / source.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = os.environ | {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "ROBOT_UPDATE_DIR": str(self.root / "state"),
            "ROBOT_UPDATE_REBOOT_FILE": str(self.root / "reboot-required"),
        }
        self.stub("ssh", 'echo unexpected-ssh >&2; exit 99\n')
        self.stub("dpkg", 'echo "configured packages"\n')
        self.stub("apt-get", 'echo "packages: $*"\n')
        self.stub("systemctl", '''
if [ -f "$ROBOT_UPDATE_DIR/service-active" ]; then echo active; exit 0; fi
echo inactive
exit 3
''')
        self.stub("systemd-run", '''
exec python3 - "$@" <<'PY'
import os, pathlib, subprocess, sys
args = sys.argv[1:]
command = args[args.index('/bin/bash'):]
active = pathlib.Path(os.environ['ROBOT_UPDATE_DIR']) / 'service-active'
active.touch()
supervisor = """import pathlib, subprocess, sys
try:
    subprocess.run(sys.argv[2:])
finally:
    pathlib.Path(sys.argv[1]).unlink(missing_ok=True)
"""
subprocess.Popen([sys.executable, '-c', supervisor, str(active), *command],
                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                 stderr=subprocess.DEVNULL, start_new_session=True)
PY
''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def local(self, answer, *args):
        return subprocess.run(
            ["bash", "scripts/robot-update.sh", *args], cwd=self.root,
            input=answer, text=True, capture_output=True, env=self.env, timeout=10,
        )

    def remote(self, action):
        return subprocess.run(
            ["bash", str(ROOT / "files/robot-update.sh"), action],
            text=True, capture_output=True, env=self.env, timeout=10,
        )

    def finished(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            result = self.remote("status")
            if "Active: yes" not in result.stdout:
                return result
            time.sleep(0.03)
        self.fail("worker did not finish")

    def test_refusal_and_eof_do_not_contact_robot_or_create_state(self):
        for answer in ("no\n", "", "y\n"):
            with self.subTest(answer=answer):
                result = self.local(answer)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("cancelled", result.stdout)
                self.assertNotIn("unexpected-ssh", result.stderr)
                self.assertFalse((self.root / "state").exists())

    def test_package_success_persists_steps_log_and_pending_reboot(self):
        (self.root / "reboot-required").touch()
        started = self.remote("start")
        self.assertEqual(started.returncode, 0, started.stderr)
        result = self.finished()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for expected in ("packages-updated", "configure-packages", "update-indexes",
                         "upgrade-packages", "Pending reboot: yes",
                         "Full maintenance completion is not verified"):
            self.assertIn(expected, result.stdout)
        log = Path(next(line.removeprefix("Log: ") for line in result.stdout.splitlines()
                        if line.startswith("Log: "))).read_text()
        self.assertIn("packages:", log)
        self.assertIn("upgrade", log)

    def test_upgrade_allows_new_dependencies_without_package_removal(self):
        self.stub("apt-get", '''
if [[ "$*" == *upgrade ]]; then
  [[ " $* " == *" --with-new-pkgs "* ]] || exit 22
  [[ " $* " != *" dist-upgrade "* ]] || exit 23
fi
''')
        self.remote("start")
        result = self.finished()
        self.assertIn("State: packages-updated", result.stdout)

    def test_failure_stops_steps_retains_log_and_can_retry(self):
        self.stub("apt-get", '''
echo "packages: $*"
if [[ "$*" == *upgrade ]] && [ -f "$ROBOT_UPDATE_DIR/fail-packages" ]; then
  touch "$ROBOT_UPDATE_REBOOT_FILE"
  echo 'controlled package failure' >&2
  exit 42
fi
''')
        (self.root / "state").mkdir()
        (self.root / "state/fail-packages").touch()
        self.remote("start")
        failed = self.finished()
        self.assertEqual(failed.returncode, 1, failed.stdout)
        self.assertIn("State: failed", failed.stdout)
        self.assertIn("Failed/interrupted step: upgrade-packages", failed.stdout)
        self.assertIn("configure-packages", failed.stdout)
        self.assertIn("update-indexes", failed.stdout)
        self.assertNotIn("\nupgrade-packages\n", failed.stdout)
        self.assertIn("Pending reboot: yes", failed.stdout)
        old_log = Path(next(line[5:] for line in failed.stdout.splitlines()
                            if line.startswith("Log: ")))
        self.assertIn("controlled package failure", old_log.read_text())
        (self.root / "state/fail-packages").unlink()
        self.assertEqual(self.remote("start").returncode, 0)
        retried = self.finished()
        self.assertEqual(retried.returncode, 0, retried.stdout)
        self.assertIn("State: packages-updated", retried.stdout)
        self.assertNotEqual(failed.stdout.splitlines()[0], retried.stdout.splitlines()[0])
        self.assertIn("controlled package failure", old_log.read_text())

    def test_detached_worker_and_concurrent_invocations_share_one_operation(self):
        self.stub("apt-get", '''
echo "packages: $*"
while [ ! -f "$ROBOT_UPDATE_DIR/release" ]; do sleep 0.03; done
''')
        # Both clients start together; the worker must outlive both initiating processes.
        command = ["bash", str(ROOT / "files/robot-update.sh"), "start"]
        clients = [subprocess.Popen(command, env=self.env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                   for _ in range(2)]
        try:
            outputs = [client.communicate(timeout=10) for client in clients]
            for client, (out, err) in zip(clients, outputs):
                self.assertEqual(client.returncode, 0, out + err)
                self.assertIn("Active: yes", out)
            self.assertEqual(outputs[0][0].splitlines()[0], outputs[1][0].splitlines()[0])
            status = self.remote("status")
            self.assertIn("Active: yes", status.stdout)
        finally:
            (self.root / "state/release").touch()
            finished = self.finished()
        self.assertEqual(finished.returncode, 0, finished.stdout)
        self.assertIn("State: packages-updated", finished.stdout)

    def test_connection_loss_after_launch_does_not_stop_worker(self):
        self.stub("tailscale", 'echo \'{"Peer":{"robot":{"HostName":"robot","TailscaleIPs":["100.64.0.9"]}}}\'\n')
        self.stub("ssh", '''
command="${*: -1}"
bash -s -- "${command##* }"
if [[ "$command" == *start ]]; then exit 255; fi
''')
        self.stub("apt-get", '''
while [ ! -f "$ROBOT_UPDATE_DIR/release" ]; do sleep 0.03; done
echo 'package work survived disconnection'
''')
        try:
            result = self.local("yes\n")
            self.assertEqual(result.returncode, 255, result.stdout + result.stderr)
            self.assertIn("maintenance may still be running", result.stderr)
            self.assertIn("Active: yes", self.local("", "status").stdout)
        finally:
            (self.root / "state/release").touch()
            finished = self.finished()
        self.assertIn("State: packages-updated", finished.stdout)

    def test_killed_worker_is_reported_interrupted_and_retry_is_safe(self):
        self.stub("apt-get", 'kill -KILL "$PPID"\n')
        self.remote("start")
        result = self.finished()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("State: interrupted", result.stdout)
        self.assertIn("Failed/interrupted step: update-indexes", result.stdout)
        self.stub("apt-get", 'echo repaired\n')
        self.remote("start")
        self.assertIn("State: packages-updated", self.finished().stdout)

    def test_launch_failure_is_recorded_and_status_does_not_start_work(self):
        self.assertIn("No maintenance operation", self.remote("status").stdout)
        self.assertFalse((self.root / "state").exists())
        self.stub("systemd-run", 'echo "controlled launch failure" >&2; exit 1\n')
        result = self.remote("start")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Failed/interrupted step: launch", result.stdout)
        self.assertIn("State: failed", self.remote("status").stdout)


if __name__ == "__main__":
    unittest.main()
