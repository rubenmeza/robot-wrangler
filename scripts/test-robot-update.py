#!/usr/bin/env python3
"""Command-boundary tests; no network, root, or real package manager required."""
import os
import hashlib
import json
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
        for name in ("_common.sh", "robot-update.sh", "robot-ip.sh"):
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
            "ROBOT_UPDATE_PROVISION_FILE": str(self.root / "provision.env"),
            "ROBOT_UPDATE_PROFILE_FILE": str(self.root / "profile.sh"),
            "ROBOT_UPDATE_BOOT_FILE": str(self.root / "boot-id"),
            "TEST_ROBOT_HOME": str(self.root / "home"),
            "TEST_ROOT": str(self.root),
        }
        self.home = self.root / "home"
        (self.root / "boot-id").write_text("boot-before\n")
        (self.home / ".local/bin").mkdir(parents=True)
        (self.home / ".robot-env").write_text(
            'export CLAUDE_CODE_OAUTH_TOKEN=dummy-claude\nexport GH_TOKEN=dummy-github\n')
        (self.root / "provision.env").write_text("ROBOT_USER=robot\n")
        self.profile("tmux")
        self.herdr_binary = self.home / ".local/bin/herdr"
        self.herdr_binary.write_text(self.herdr("0.9.0"))
        self.herdr_binary.chmod(0o755)
        release = self.root / "release-binary"
        release.write_text(self.herdr("0.9.1"))
        self.manifest = {
            "version": "0.9.1",
            "assets": {"linux-x86_64": "https://example.test/herdr"},
            "sha256": {"linux-x86_64": hashlib.sha256(release.read_bytes()).hexdigest()},
        }
        (self.root / "manifest.json").write_text(json.dumps(self.manifest))
        self.stub("uname", 'echo x86_64\n')
        self.stub("getent", 'echo "robot:x:1000:1000::${TEST_ROBOT_HOME}:/bin/bash"\n')
        self.stub("id", 'echo 1000\n')
        self.stub("sudo", 'shift 3; export HOME="$TEST_ROBOT_HOME"; exec "$@"\n')
        self.stub("curl", '''
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) output="$2"; shift 2 ;;
    https://herdr.dev/latest.json) source="$TEST_ROOT/manifest.json"; shift ;;
    https://example.test/herdr) source="$TEST_ROOT/release-binary"; shift ;;
    *) shift ;;
  esac
done
cp "$source" "$output"
''')
        self.stub("tmux", 'echo "$*" >> "$TEST_ROOT/tmux-calls"; echo robot\n')
        self.stub("script", 'exit 124\n')
        self.stub("ssh", 'echo unexpected-ssh >&2; exit 99\n')
        self.stub("dpkg", 'echo "configured packages"\n')
        self.stub("apt-get", 'echo "packages: $*"\n')
        self.stub("systemctl", '''
if [ "$1" = reboot ]; then
  echo reboot >> "$TEST_ROOT/reboots"
  exit 0
fi
if [ -f "$ROBOT_UPDATE_DIR/service-active" ]; then echo active; exit 0; fi
echo inactive
exit 3
''')
        self.stub("systemd-run", '''
exec python3 - "$@" <<'PY'
import os, pathlib, subprocess, sys
args = sys.argv[1:]
if '--uid=robot' in args:
    if (pathlib.Path(os.environ['TEST_ROOT']) / 'fail-herdr-start').exists():
        sys.exit(42)
    command = args[next(i for i, arg in enumerate(args) if arg.startswith('/')):]
    service_env = os.environ.copy()
    for arg in args:
        if arg.startswith('--setenv=HOME='):
            service_env['HOME'] = arg.removeprefix('--setenv=HOME=')
    sys.exit(subprocess.run(command, env=service_env).returncode)
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

    def profile(self, name):
        (self.root / "profile.sh").write_text(
            f'  if [ "{name}" = herdr ] && command -v herdr >/dev/null; then\n')

    @staticmethod
    def herdr(version):
        return f'''#!/usr/bin/env bash
set -euo pipefail
version={version}
if [ "$1" = --version ]; then echo "herdr $version"; exit; fi
echo "$*" >> "$TEST_ROOT/herdr-calls"
if [[ "$*" == *"status server --json" ]]; then
  if [ -f "$TEST_ROOT/herdr-running" ]; then
    running_version=$(cat "$TEST_ROOT/herdr-running")
    echo '{{"running":true,"version":"'"$running_version"'","session":"robot","compatible":true,"endpoint_compatible":true}}'
  else echo '{{"running":false}}'; fi
elif [[ "$*" == *"session stop robot" ]]; then
  rm -f "$TEST_ROOT/herdr-running"
elif [[ "$*" == *"session attach robot" ]] && [ "${{TEST_REQUIRE_PTY_SIZE:-}}" = yes ]; then
  [ "$(stty size)" = '40 120' ] || exit 43
  sleep 10
elif [[ "$*" == *server ]]; then
  if [ "${{CLAUDE_CODE_OAUTH_TOKEN:-}}" = dummy-claude ] && [ "${{GH_TOKEN:-}}" = dummy-github ]; then
    touch "$TEST_ROOT/server-has-credentials"
  fi
  echo "$version" > "$TEST_ROOT/herdr-running"
fi
'''

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

    def test_reboot_waits_for_new_boot_and_resumes_without_repeating_updates(self):
        (self.root / "reboot-required").touch()
        self.remote("start")
        before = self.finished()
        self.assertIn("State: awaiting-reboot", before.stdout)
        self.assertEqual((self.root / "reboots").read_text(), "reboot\n")
        repeated = self.remote("start")
        self.assertEqual(before.stdout.splitlines()[0], repeated.stdout.splitlines()[0])
        self.assertEqual((self.root / "reboots").read_text(), "reboot\n")
        self.stub("apt-get", 'echo repeated-package-work >&2; exit 99\n')
        self.stub("curl", 'echo repeated-release-discovery >&2; exit 99\n')
        (self.root / "boot-id").write_text("boot-after\n")
        (self.root / "reboot-required").unlink()
        self.remote("poll")
        self.finished()
        result = self.remote("poll")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("State: complete", result.stdout)
        self.assertIn("verify-access", result.stdout)
        self.assertEqual(before.stdout.splitlines()[0], result.stdout.splitlines()[0])

    def connect_locally(self):
        self.stub("tailscale", 'echo \'{"Peer":{"robot":{"HostName":"robot","TailscaleIPs":["100.64.0.9"]}}}\'\n')
        self.stub("ssh", '''
command="${*: -1}"
read -ra args <<< "${command#sudo -n bash -s -- }"
bash -s -- "${args[@]}"
''')
        self.env["ROBOT_UPDATE_POLL_SECONDS"] = "0.05"

    def test_no_reboot_command_waits_for_final_access_check(self):
        self.connect_locally()
        result = self.local("yes\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("State: complete", result.stdout)
        self.assertIn("verify-access", result.stdout)
        self.assertFalse((self.root / "reboots").exists())

    def test_failed_new_launch_cannot_claim_an_older_completed_operation(self):
        self.connect_locally()
        self.assertEqual(self.local("yes\n").returncode, 0)
        self.stub("ssh", '''
command="${*: -1}"
if [[ "$command" == *'-- start'* ]]; then exit 255; fi
read -ra args <<< "${command#sudo -n bash -s -- }"
bash -s -- "${args[@]}"
''')
        result = self.local("yes\n")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("State: complete", result.stdout)

    def test_reconnection_timeout_is_bounded_and_rerun_finishes_same_operation(self):
        self.connect_locally()
        self.env["ROBOT_UPDATE_RECONNECT_SECONDS"] = "2"
        (self.root / "reboot-required").touch()
        self.stub("ssh", '''
if [ -f "$TEST_ROOT/hang-next" ]; then sleep 20; exit 255; fi
command="${*: -1}"
read -ra args <<< "${command#sudo -n bash -s -- }"
bash -s -- "${args[@]}"
if [ -f "$TEST_ROOT/reboots" ]; then touch "$TEST_ROOT/hang-next"; fi
''')
        started = time.monotonic()
        result = self.local("yes\n")
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 4, result.stdout + result.stderr)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Updates completed, but reconnection/final verification timed out", result.stderr)
        self.assertIn("Recovery Console", result.stderr)
        self.stub("apt-get", 'exit 99\n')
        self.stub("curl", 'exit 99\n')
        self.connect_locally()
        (self.root / "boot-id").write_text("boot-returned\n")
        (self.root / "reboot-required").unlink()
        result = self.local("yes\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("State: complete", result.stdout)
        self.assertEqual(len(list((self.root / "state/operations").iterdir())), 1)

    def test_post_reboot_activation_failure_can_retry_without_reinstalling(self):
        self.profile("herdr")
        (self.root / "reboot-required").touch()
        self.remote("start")
        self.assertIn("State: awaiting-reboot", self.finished().stdout)
        (self.root / "boot-id").write_text("boot-returned\n")
        (self.root / "reboot-required").unlink()
        (self.root / "herdr-running").unlink()
        (self.root / "fail-herdr-start").touch()
        self.remote("poll")
        failed = self.finished()
        self.assertEqual(failed.returncode, 1)
        self.assertIn("Failed/interrupted step: activate-session", failed.stdout)
        self.assertIn("Update steps: completed", failed.stdout)
        self.assertIn("session attach robot", failed.stdout)
        self.assertIn("Restore the previous binary", failed.stdout)
        (self.root / "fail-herdr-start").unlink()
        self.stub("apt-get", 'exit 99\n')
        self.stub("curl", 'exit 99\n')
        self.remote("start")
        self.finished()
        self.assertIn("State: complete", self.remote("poll").stdout)

    def test_tmux_session_created_after_reboot_inherits_agent_credentials(self):
        (self.root / "reboot-required").touch()
        self.remote("start")
        self.assertIn("State: awaiting-reboot", self.finished().stdout)
        self.stub("tmux", '''
case "$1" in
  has-session) exit 1 ;;
  new-session)
    [ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = dummy-claude ] && [ "${GH_TOKEN:-}" = dummy-github ]
    ;;
  display-message) echo robot ;;
esac
''')
        (self.root / "boot-id").write_text("boot-returned\n")
        (self.root / "reboot-required").unlink()
        self.remote("poll")
        result = self.finished()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("State: complete", self.remote("poll").stdout)

    def test_reboot_request_failure_is_retryable_without_package_changes(self):
        (self.root / "reboot-required").touch()
        systemctl = (self.bin / "systemctl").read_text()
        (self.bin / "systemctl").write_text(systemctl.replace('echo reboot >> "$TEST_ROOT/reboots"', 'exit 42'))
        self.remote("start")
        failed = self.finished()
        self.assertEqual(failed.returncode, 1)
        self.assertIn("Failed/interrupted step: reboot", failed.stdout)
        self.assertIn("Update steps: completed", failed.stdout)
        (self.bin / "systemctl").write_text(systemctl)
        self.stub("apt-get", 'exit 99\n')
        self.remote("start")
        self.assertIn("State: awaiting-reboot", self.finished().stdout)

    def test_package_success_persists_steps_log_and_pending_reboot(self):
        (self.root / "reboot-required").touch()
        started = self.remote("start")
        self.assertEqual(started.returncode, 0, started.stderr)
        result = self.finished()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for expected in ("awaiting-reboot", "configure-packages", "update-indexes",
                         "upgrade-packages", "Pending reboot: yes",
                         "Maintenance is not complete"):
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
        self.assertIn("State: awaiting-access", result.stdout)

    def test_tmux_profile_updates_herdr_preserves_backup_and_verifies_tmux(self):
        original = self.herdr_binary.read_bytes()
        self.remote("start")
        result = self.finished()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Herdr installed: 0.9.0", result.stdout)
        self.assertIn("Herdr target: 0.9.1", result.stdout)
        self.assertIn("Session verified: tmux robot", result.stdout)
        backup = Path(next(line.removeprefix("Previous Herdr binary: ")
                           for line in result.stdout.splitlines()
                           if line.startswith("Previous Herdr binary: ")))
        self.assertEqual(backup.read_bytes(), original)
        self.assertIn("version=0.9.1", self.herdr_binary.read_text())
        self.assertFalse((self.root / "herdr-calls").exists())
        self.assertIn("has-session -t =robot", (self.root / "tmux-calls").read_text())

    def test_herdr_profile_activates_target_without_resuming_agents(self):
        self.profile("herdr")
        (self.root / "herdr-running").write_text("0.9.0")
        config = self.home / ".config/herdr/config.toml"
        config.parent.mkdir(parents=True)
        config.write_text('[session]\nresume_agents_on_restore = true\n[ui]\nmouse_capture = true\n')
        self.remote("start")
        result = self.finished()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Session verified: herdr robot", result.stdout)
        self.assertIn("session stop robot", (self.root / "herdr-calls").read_text())
        self.assertEqual((self.root / "herdr-running").read_text().strip(), "0.9.1")
        self.assertIn("resume_agents_on_restore = false", config.read_text())
        self.assertIn("mouse_capture = true", config.read_text())
        self.assertFalse((self.root / "tmux-calls").exists())
        self.assertTrue((self.root / "server-has-credentials").exists())

    def test_release_discovery_failure_preserves_installed_binary(self):
        before = self.herdr_binary.read_bytes()
        self.stub("curl", 'echo "upstream unavailable" >&2; exit 22\n')
        (self.root / "reboot-required").touch()
        self.remote("start")
        result = self.finished()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Failed/interrupted step: discover-herdr", result.stdout)
        self.assertIn("Pending reboot: yes", result.stdout)
        self.assertIn("upgrade-packages", result.stdout)
        self.assertEqual(self.herdr_binary.read_bytes(), before)

    def test_download_failure_and_checksum_mismatch_preserve_installed_binary(self):
        before = self.herdr_binary.read_bytes()
        curl = (self.bin / "curl").read_text()
        self.stub("curl", '''
if [[ "$*" == *https://example.test/herdr* ]]; then exit 22; fi
cp "$TEST_ROOT/manifest.json" "${*: -1}"
''')
        self.remote("start")
        result = self.finished()
        self.assertIn("Failed/interrupted step: download-herdr", result.stdout)
        self.assertEqual(self.herdr_binary.read_bytes(), before)
        (self.bin / "curl").write_text(curl)
        (self.root / "release-binary").write_text("corrupt download")
        self.remote("start")
        result = self.finished()
        self.assertIn("Failed/interrupted step: download-herdr", result.stdout)
        self.assertEqual(self.herdr_binary.read_bytes(), before)

    def test_replacement_failure_preserves_previous_binary_and_can_retry(self):
        before = self.herdr_binary.read_bytes()
        self.stub("mv", '''
if [ "${*: -1}" = "$TEST_ROBOT_HOME/.local/bin/herdr" ]; then exit 1; fi
exec /usr/bin/mv "$@"
''')
        self.remote("start")
        result = self.finished()
        self.assertIn("Failed/interrupted step: replace-herdr", result.stdout)
        self.assertEqual(self.herdr_binary.read_bytes(), before)
        self.assertIn("Previous Herdr binary:", result.stdout)
        (self.bin / "mv").unlink()
        self.remote("start")
        self.assertIn("State: awaiting-access", self.finished().stdout)

    def test_activation_failure_retains_update_and_backup_then_retries_without_download(self):
        self.profile("herdr")
        original = self.herdr_binary.read_bytes()
        self.stub("script", 'echo "client cannot attach" >&2; exit 1\n')
        (self.root / "reboot-required").touch()
        self.remote("start")
        failed = self.finished()
        self.assertEqual(failed.returncode, 1)
        self.assertIn("Failed/interrupted step: verify-session", failed.stdout)
        self.assertIn("session attach robot", failed.stdout)
        self.assertIn("Restore the previous binary", failed.stdout)
        self.assertIn("Pending reboot: yes", failed.stdout)
        self.assertFalse((self.root / "reboots").exists())
        backup = Path(next(line.removeprefix("Previous Herdr binary: ")
                           for line in failed.stdout.splitlines()
                           if line.startswith("Previous Herdr binary: ")))
        self.assertEqual(backup.read_bytes(), original)

        self.assertIn("version=0.9.1", self.herdr_binary.read_text())
        self.stub("script", 'exit 124\n')
        (self.root / "release-binary").unlink()  # a needless second download would fail
        self.remote("start")
        retried = self.finished()
        self.assertEqual(retried.returncode, 0, retried.stdout)
        self.assertIn("Herdr installed: 0.9.1", retried.stdout)
        self.assertIn(f"Previous Herdr binary: {backup}", retried.stdout)
        self.assertEqual(backup.read_bytes(), original)

    def test_server_start_failure_can_retry_incomplete_activation(self):
        self.profile("herdr")
        (self.root / "fail-herdr-start").touch()
        self.remote("start")
        result = self.finished()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Failed/interrupted step: activate-session", result.stdout)
        self.assertIn("session attach robot", result.stdout)
        (self.root / "fail-herdr-start").unlink()
        (self.root / "release-binary").unlink()
        self.remote("start")
        retried = self.finished()
        self.assertEqual(retried.returncode, 0, retried.stdout)
        self.assertIn("Session verified: herdr robot", retried.stdout)

    def test_attachment_probe_provides_a_usable_terminal(self):
        self.profile("herdr")
        self.env["TEST_REQUIRE_PTY_SIZE"] = "yes"
        (self.bin / "script").unlink()  # real local PTY, controlled Herdr client
        self.remote("start")
        result = self.finished()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Session verified: herdr robot", result.stdout)

    def test_tmux_attachment_failure_reports_recovery_and_retries_without_herdr(self):
        self.stub("script", 'exit 1\n')
        self.remote("start")
        failed = self.finished()
        self.assertEqual(failed.returncode, 1)
        self.assertIn("Failed/interrupted step: verify-session", failed.stdout)
        self.assertIn("tmux new-session -A -s robot", failed.stdout)
        self.assertIn("Previous Herdr binary:", failed.stdout)
        self.assertIn("version=0.9.1", self.herdr_binary.read_text())
        self.stub("script", 'exit 124\n')
        (self.root / "release-binary").unlink()
        self.remote("start")
        self.assertIn("Session verified: tmux robot", self.finished().stdout)
        self.assertFalse((self.root / "herdr-calls").exists())

    def test_unknown_profile_and_nonstable_release_fail_closed(self):
        self.profile("unexpected")
        self.remote("start")
        self.assertIn("Failed/interrupted step: inspect-profile", self.finished().stdout)
        self.profile("tmux")
        self.manifest["version"] = "0.10.0-preview.1"
        (self.root / "manifest.json").write_text(json.dumps(self.manifest))
        self.remote("start")
        self.assertIn("Failed/interrupted step: discover-herdr", self.finished().stdout)

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
        self.assertIn("State: awaiting-reboot", retried.stdout)
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
        self.assertIn("State: awaiting-access", finished.stdout)

    def test_connection_loss_after_launch_resumes_existing_operation(self):
        self.connect_locally()
        self.stub("ssh", '''
command="${*: -1}"
read -ra args <<< "${command#sudo -n bash -s -- }"
bash -s -- "${args[@]}"
if [[ "$command" == *'-- start'* ]]; then exit 255; fi
''')
        result = self.local("yes\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Connection unavailable", result.stderr)
        self.assertIn("State: complete", result.stdout)
        self.assertEqual(len(list((self.root / "state/operations").iterdir())), 1)

    def test_killed_worker_is_reported_interrupted_and_retry_is_safe(self):
        self.stub("apt-get", 'kill -KILL "$PPID"\n')
        self.remote("start")
        result = self.finished()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("State: interrupted", result.stdout)
        self.assertIn("Failed/interrupted step: update-indexes", result.stdout)
        self.stub("apt-get", 'echo repaired\n')
        self.remote("start")
        self.assertIn("State: awaiting-access", self.finished().stdout)

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
