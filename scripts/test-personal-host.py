#!/usr/bin/env python3
"""Personal-host command boundary tests: a temporary host, never the real one."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class PersonalHostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / "scripts", self.root / "scripts")
        shutil.copytree(ROOT / "files", self.root / "files")
        (self.root / "devices").mkdir()
        self.host = self.root / "host"
        (self.host / "etc").mkdir(parents=True)
        (self.host / "etc/os-release").write_text('ID=arch\n')
        self.home = self.root / "home"
        (self.home / ".ssh").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = os.environ | {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HOME": str(self.home), "SHELL": "/bin/bash",
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "PERSONAL_HOST_ROOT": str(self.host), "TEST_ROOT": str(self.root),
        }
        for name in ("DIGITALOCEAN_TOKEN", "GH_TOKEN", "ROBOT_SSH_KEY",
                     "CLAUDE_CODE_OAUTH_TOKEN", "MOSHI_PAIRING_TOKEN", "T3CODE_HOME"):
            self.env.pop(name, None)
        self.state = {
            "BackendState": "Running", "Self": {"Online": True,
                "DNSName": "desk.example.ts.net.",
                "TailscaleIPs": ["100.64.0.2", "fd7a:115c:a1e0::2"]},
            "CurrentTailnet": {"MagicDNSEnabled": True},
            "CertDomains": ["desk.example.ts.net"],
        }
        self.write_tailscale()
        dispatcher = self.bin / "fake-command"
        dispatcher.write_text(FAKE_COMMAND)
        dispatcher.chmod(0o755)
        for name in ("sudo", "tailscale", "systemctl", "loginctl", "ufw", "sshd",
                     "tmux", "pacman", "id", "pgrep", "pkill", "ss", "t3", "curl", "moshi-hook"):
            (self.bin / name).symlink_to(dispatcher)
        self.public_keys = {}
        for name in ("robot_ed25519", "pixel", "ipad"):
            key = self.home / ".ssh" / name
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "",
                            "-f", str(key), "-C", name], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.public_keys[name] = key.with_suffix(".pub").read_text()
        for name, key in (("arch", "robot_ed25519"), ("pixel", "pixel"), ("ipad", "ipad")):
            (self.root / "devices" / f"{name}.pub").write_text(self.public_keys[key])

    def write_tailscale(self):
        (self.root / "tailscale.json").write_text(json.dumps(self.state))

    def stub(self, name, body):
        path = self.bin / name
        path.unlink(missing_ok=True)
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def local(self, answer="desk\nalways-on\n", *args):
        return subprocess.run(["bash", "scripts/personal-host.sh", *(args or ("enroll",))],
                              cwd=self.root, env=self.env, input=answer, text=True,
                              capture_output=True, timeout=15)

    def calls(self, name=None):
        path = self.root / "calls.jsonl"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [call for call in calls if not name or call[0] == name]

    def test_enrollment_installs_missing_moshi_without_automatic_onboarding(self):
        (self.bin / "moshi-hook").unlink()
        self.stub("curl", '''[[ "$*" == "-fsSL https://getmoshi.app/install.sh" ]]
cat <<'INSTALLER'
#!/bin/sh
[ "$MOSHI_HOOK_SKIP_FIRST_RUN" = 1 ]
[ "$MOSHI_HOOK_SKIP_SERVICE" = 1 ]
mkdir -p "$HOME/.local/bin"
cp "$TEST_ROOT/bin/fake-command" "$HOME/.local/bin/moshi-hook"
chmod +x "$HOME/.local/bin/moshi-hook"
printf installed > "$TEST_ROOT/moshi-installed"
INSTALLER
''')
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "moshi-installed").exists())
        self.assertIn(["moshi-hook", "status", "--json"], self.calls("moshi-hook"))
        self.assertIn(["moshi-hook", "service", "install"], self.calls("moshi-hook"))
        self.assertIn(["loginctl", "enable-linger", "owner"], self.calls("loginctl"))

    def test_enrollment_keeps_existing_paired_moshi_and_user_hooks_untouched(self):
        (self.root / "moshi-status.json").write_text(json.dumps({
            "paired": True, "hostSecret": "synthetic-never-print-secret",
            "hooks": [{"target": "claude", "status": "installed"}]}))
        (self.root / "systemctl.json").write_text(json.dumps({
            "moshi-hook.service": {"enabled": True, "active": True}}))
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir()
        settings.write_text('{"hooks":{"Stop":[{"hooks":[{"command":"my-hook"}]}]}}')
        before = (settings.read_bytes(), settings.stat().st_mtime_ns)
        for answer in ("desk\nalways-on\n", "\n\n"):
            result = self.local(answer)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("synthetic-never-print-secret", result.stdout + result.stderr)
        self.assertEqual(before, (settings.read_bytes(), settings.stat().st_mtime_ns))
        self.assertEqual(self.calls("moshi-hook"), [["moshi-hook", "status", "--json"]] * 2)
        self.assertNotIn(["systemctl", "--user", "restart", "moshi-hook.service"],
                         self.calls("systemctl"))

    def test_unpaired_moshi_without_token_stops_with_keyboard_instructions(self):
        (self.root / "moshi-status.json").write_text(json.dumps({"paired": False, "hooks": []}))
        result = self.local()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Moshi", result.stderr)
        self.assertIn("MOSHI_PAIRING_TOKEN", result.stderr)
        self.assertNotIn(["moshi-hook", "service", "install"], self.calls("moshi-hook"))
        self.assertFalse((self.home / ".config/robot-wrangler/personal-host.json").exists())

    def test_enrollment_pairs_moshi_once_without_recording_or_printing_token(self):
        (self.root / "moshi-status.json").write_text(json.dumps({"paired": False, "hooks": []}))
        for supplied_by in ("environment", "keyboard"):
            with self.subTest(supplied_by=supplied_by):
                (self.root / "moshi-status.json").write_text(json.dumps({"paired": False, "hooks": []}))
                if supplied_by == "environment":
                    self.env["MOSHI_PAIRING_TOKEN"] = "synthetic-moshi-token"
                    answer = "desk\nalways-on\n"
                else:
                    self.env.pop("MOSHI_PAIRING_TOKEN", None)
                    answer = "desk\nalways-on\nsynthetic-moshi-token\n"
                count = len(self.calls("moshi-hook"))
                result = self.local(answer)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(["moshi-hook", "pair", "--name", "desk"], self.calls("moshi-hook")[count:])
                self.assertNotIn("synthetic-moshi-token", result.stdout + result.stderr)
                result = self.local("\n\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls("moshi-hook")[count:].count(
                    ["moshi-hook", "pair", "--name", "desk"]), 1)
                for path in (self.root / "calls.jsonl", self.root / "moshi-status.json",
                             self.home / ".config/robot-wrangler/personal-host.json"):
                    self.assertNotIn("synthetic-moshi-token", path.read_text())

    def test_enrollment_repairs_missing_moshi_hooks_and_stopped_service(self):
        (self.root / "moshi-status.json").write_text(json.dumps({
            "paired": True, "hooks": [{"target": "claude", "status": "stale"},
                                      {"target": "codex", "status": "not_found"}]}))
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["moshi-hook", "install"], self.calls("moshi-hook"))
        self.assertIn(["moshi-hook", "service", "install"], self.calls("moshi-hook"))
        count = len(self.calls("moshi-hook"))
        result = self.local("\n\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls("moshi-hook")[count:], [["moshi-hook", "status", "--json"]])

    def test_moshi_enrollment_requires_the_owners_systemd_user_manager(self):
        (self.root / "missing-user-manager").touch()
        result = self.local()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("user manager", result.stderr)
        self.assertEqual(self.calls("moshi-hook"), [])

    def test_invalid_moshi_pairing_metadata_never_re_pairs_or_prints_document(self):
        for metadata in ('invalid synthetic-secret-json', '{"paired":"unknown","secret":"synthetic-secret-json"}'):
            with self.subTest(metadata=metadata):
                (self.root / "moshi-status.json").write_text(metadata)
                result = self.local()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Moshi pairing metadata", result.stderr)
                self.assertNotIn("synthetic-secret-json", result.stdout + result.stderr)
                self.assertFalse(any(call[1:2] == ["pair"] for call in self.calls("moshi-hook")))

    def test_enrollment_refuses_unsupported_os_before_changing_host(self):
        (self.host / "etc/os-release").write_text("ID=ubuntu\n")
        result = self.local()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Arch/Omarchy", result.stderr)
        self.assertEqual(self.calls("sudo"), [])

    def test_enrollment_requires_running_tailnet_magicdns_and_https(self):
        for state, field, value, message in (
                (self.state, "BackendState", "Stopped", "Tailscale"),
                (self.state["CurrentTailnet"], "MagicDNSEnabled", False, "MagicDNS"),
                (self.state, "CertDomains", [], "HTTPS")):
            with self.subTest(message=message):
                previous = state[field]
                state[field] = value
                self.write_tailscale()
                result = self.local()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.calls("sudo"), [])
                state[field] = previous

    def test_enrollment_remembers_name_and_always_on_mode_and_sets_operator(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        saved = json.loads((self.home / ".config/robot-wrangler/personal-host.json").read_text())
        self.assertEqual(saved, {"name": "desk", "mode": "always-on"})
        self.assertIn(["sudo", "-v"], self.calls("sudo"))
        self.assertIn(["tailscale", "set", "--hostname=desk", "--operator=owner"],
                      self.calls("tailscale"))
        result = self.local("\n\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[desk]", result.stdout)
        self.assertIn("[always-on]", result.stdout)

    def test_enrollment_migrates_existing_key_and_admits_only_other_devices(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "devices/arch.pub").exists())
        self.assertEqual((self.root / "devices/desk.pub").read_text(),
                         self.public_keys["robot_ed25519"])
        authorized = self.home / ".ssh/authorized_keys"
        self.assertEqual(set(authorized.read_text().splitlines()),
                         {self.public_keys["pixel"].strip(), self.public_keys["ipad"].strip()})
        self.assertEqual(authorized.stat().st_mode & 0o777, 0o600)
        self.assertEqual(authorized.parent.stat().st_mode & 0o777, 0o700)
        self.assertIn("commit", result.stdout.lower())
        self.assertIn("other hosts", result.stdout)

    def test_enrollment_installs_valid_tailnet_only_ssh_and_permanent_firewall_rules(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        config = (self.host / "etc/ssh/sshd_config.d/00-robot-wrangler.conf").read_text()
        for line in ("ListenAddress 100.64.0.2", "ListenAddress fd7a:115c:a1e0::2",
                     "AllowUsers owner", "PermitRootLogin no", "PasswordAuthentication no",
                     "KbdInteractiveAuthentication no", "PubkeyAuthentication yes",
                     "AuthenticationMethods publickey"):
            self.assertIn(line, config)
        self.assertIn(["sshd", "-t"], self.calls("sshd"))
        self.assertIn(["sshd", "-T"], self.calls("sshd"))
        self.assertIn(["systemctl", "enable", "sshd.service"], self.calls("systemctl"))
        self.assertIn(["systemctl", "start", "sshd.service"], self.calls("systemctl"))
        self.assertIn(["ufw", "allow", "in", "on", "tailscale0", "to", "any", "port", "22", "proto", "tcp"], self.calls("ufw"))
        self.assertIn(["ufw", "allow", "in", "on", "tailscale0", "to", "any", "port", "60000:61000", "proto", "udp"], self.calls("ufw"))

    def test_enrollment_disables_socket_activation_and_suspend_for_always_on_host(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["systemctl", "mask", "sshd.socket"], self.calls("systemctl"))
        self.assertIn(["systemctl", "disable", "--now", "sshd.socket"], self.calls("systemctl"))
        self.assertIn(["systemctl", "mask", "sleep.target", "suspend.target",
                       "hibernate.target", "hybrid-sleep.target"], self.calls("systemctl"))

    def test_interactive_ssh_attaches_latest_tmux_but_other_shells_are_unaffected(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        snippet = self.home / ".config/robot-wrangler/ssh-tmux.sh"
        self.assertTrue(snippet.exists())
        rc = (self.home / ".bashrc").read_text()
        self.assertIn("ssh-tmux.sh", rc)
        for interactive, ssh, tmux, expected in (
                (True, True, False, True), (False, True, False, False),
                (True, False, False, False), (True, True, True, False)):
            with self.subTest(interactive=interactive, ssh=ssh, tmux=tmux):
                count = len(self.calls("tmux"))
                env = self.env | {"SSH_CONNECTION": "100.64.0.3 4000 100.64.0.2 22" if ssh else "",
                                  "SSH_TTY": "/dev/pts/1" if ssh else "", "TMUX": "existing" if tmux else ""}
                result = subprocess.run(["bash", "--norc", "-ic" if interactive else "-c",
                                         '. "$1"', "bash", str(snippet)], env=env,
                                        text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.calls("tmux")[count:]
                if expected:
                    self.assertIn(["tmux", "attach-session", "-t", "$2"], calls)
                else:
                    self.assertEqual(calls, [])

    def test_enrollment_handles_missing_arch_ssh_socket_and_generates_host_keys(self):
        (self.root / "missing-sshd-socket").touch()
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(["systemctl", "disable", "--now", "sshd.socket"], self.calls("systemctl"))
        self.assertIn(["systemctl", "mask", "sshd.socket"], self.calls("systemctl"))
        self.assertTrue((self.host / "etc/ssh/ssh_host_ed25519_key").exists())

    def test_rerunning_enrollment_preserves_files_keys_and_active_ssh(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        paths = [self.home / ".ssh/robot_ed25519", self.home / ".ssh/authorized_keys",
                 self.home / ".bashrc", self.home / ".config/robot-wrangler/ssh-tmux.sh",
                 self.home / ".config/robot-wrangler/personal-host.json",
                 self.host / "etc/ssh/sshd_config.d/00-robot-wrangler.conf",
                 self.host / "etc/ssh/ssh_host_ed25519_key", self.root / "devices/desk.pub"]
        before = [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths]
        call_count = len(self.calls("systemctl"))
        result = self.local("\n\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(before, [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths])
        calls = self.calls("systemctl")[call_count:]
        self.assertNotIn(["systemctl", "reload", "sshd.service"], calls)
        self.assertNotIn(["systemctl", "restart", "sshd.service"], calls)
        self.assertNotIn(["systemctl", "start", "sshd.service"], calls)

    def test_enrollment_rolls_back_ssh_when_existing_configuration_adds_public_listener(self):
        dropin = self.host / "etc/ssh/sshd_config.d/00-robot-wrangler.conf"
        dropin.parent.mkdir(parents=True)
        previous = "# previous enrollment configuration\n"
        dropin.write_text(previous)
        (self.root / "wide-sshd").touch()
        result = self.local()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the Tailnet", result.stderr)
        self.assertEqual(dropin.read_text(), previous)
        self.assertNotIn(["systemctl", "enable", "sshd.service"], self.calls("systemctl"))
        self.assertFalse((self.home / ".config/robot-wrangler/personal-host.json").exists())

    def test_invalid_ssh_configuration_never_enables_service_or_leaves_new_dropin(self):
        (self.root / "invalid-sshd").touch()
        result = self.local()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SSH validation failed", result.stderr)
        self.assertFalse((self.host / "etc/ssh/sshd_config.d/00-robot-wrangler.conf").exists())
        self.assertNotIn(["systemctl", "enable", "sshd.service"], self.calls("systemctl"))

    def test_enrollment_generates_missing_device_key_and_reuses_it(self):
        key = self.home / ".ssh/robot_ed25519"
        key.unlink()
        key.with_suffix(".pub").unlink()
        # The old arch key belongs to another host, so it must not be renamed.
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(key.exists())
        self.assertTrue((self.root / "devices/arch.pub").exists())
        own = (self.root / "devices/desk.pub").read_text()
        self.assertNotIn(own, (self.home / ".ssh/authorized_keys").read_text())
        private = key.read_bytes()
        result = self.local("\n\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(key.read_bytes(), private)

    def test_enrollment_never_sources_robot_secrets(self):
        (self.root / ".env").write_text('echo "robot-only secret file was sourced" >&2\nexit 97\n')
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("robot-only secret", result.stderr)

    def test_enrollment_rejects_duplicate_hostname_for_another_device(self):
        (self.root / "devices/desk.pub").write_text(self.public_keys["pixel"])
        result = self.local()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different Device key", result.stderr)
        self.assertFalse((self.home / ".ssh/authorized_keys").exists())

    def test_enrollment_refuses_existing_authorization_outside_registered_device_keys(self):
        (self.root / "external-ssh-authorization").touch()
        result = self.local()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Conflicting SSH setting", result.stderr)
        self.assertNotIn(["systemctl", "enable", "sshd.service"], self.calls("systemctl"))

    def test_enrollment_accepts_capitalized_directive_names_from_current_openssh(self):
        (self.root / "capitalized-sshd").touch()
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["systemctl", "enable", "sshd.service"], self.calls("systemctl"))

    def test_enrollment_runs_private_tailnet_t3_service_and_enables_resume(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        settings = self.home / ".t3/userdata/settings.json"
        self.assertTrue(settings.exists(), "Enrollment must configure T3 resume")
        self.assertTrue(json.loads(settings.read_text())["continueThreadsAfterServerUpdate"])
        unit = self.home / ".config/systemd/user/t3code.service"
        dropin = unit.with_suffix(".service.d") / "10-tailnet.conf"
        self.assertIn("T3CODE_TRACE_MIN_LEVEL=Warn", unit.read_text())
        self.assertIn("T3CODE_TAILSCALE_SERVE=true", dropin.read_text())
        for path in (settings, unit, dropin):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        launcher = self.home / ".config/t3code/start.sh"
        self.assertIn("--host 127.0.0.1 --port 3773 --log-level warn", launcher.read_text())
        self.assertIn(["loginctl", "enable-linger", "owner"], self.calls("loginctl"))
        self.assertIn(["systemctl", "--user", "enable", "t3code.service"], self.calls("systemctl"))
        self.assertIn(["systemctl", "--user", "restart", "t3code.service"], self.calls("systemctl"))
        self.assertEqual(self.calls("t3"), [], "Enrollment must never run pairing or native service install")
        self.assertEqual(self.calls("curl"), [], "Existing Omarchy T3 must be kept")

    def test_enrollment_shows_manual_pairing_for_exact_registered_device_labels(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("t3 pair --tailscale --label pixel", result.stdout)
        self.assertIn("t3 pair --tailscale --label ipad", result.stdout)
        self.assertIn("https://desk.example.ts.net", result.stdout)
        self.assertIn("Never log", result.stdout)
        self.assertNotIn("t3 pair --tailscale --label desk", result.stdout)
        self.assertEqual(self.calls("t3"), [])

    def test_t3_enrollment_preserves_settings_and_leaves_active_service_running(self):
        settings = self.home / ".t3/userdata/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"theme": "dark", "continueThreadsAfterServerUpdate": False}))
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(settings.read_text()),
                         {"theme": "dark", "continueThreadsAfterServerUpdate": True})
        paths = [settings, self.home / ".config/t3code/start.sh",
                 self.home / ".config/systemd/user/t3code.service",
                 self.home / ".config/systemd/user/t3code.service.d/10-tailnet.conf"]
        before = [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths]
        count = len(self.calls("systemctl"))
        result = self.local("\n\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(before, [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths])
        calls = self.calls("systemctl")[count:]
        self.assertNotIn(["systemctl", "--user", "daemon-reload"], calls)
        self.assertNotIn(["systemctl", "--user", "restart", "t3code.service"], calls)
        self.assertNotIn(["systemctl", "--user", "enable", "t3code.service"], calls)
        self.assertEqual(self.calls("curl"), [])
        self.assertEqual(self.calls("t3"), [])

    def test_t3_enrollment_refuses_invalid_settings_without_replacing_them(self):
        settings = self.home / ".t3/userdata/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text("{broken settings")
        result = self.local()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("valid JSON object", result.stderr)
        self.assertEqual(settings.read_text(), "{broken settings")
        self.assertNotIn(["systemctl", "--user", "restart", "t3code.service"], self.calls("systemctl"))
        self.assertFalse((self.home / ".config/robot-wrangler/personal-host.json").exists())

    def test_t3_enrollment_starts_owner_user_manager_with_matching_runtime_directory(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["systemctl", "start", "user@1000.service"], self.calls("systemctl"))
        runtime_dirs = (self.root / "user-runtime-dirs.jsonl").read_text().splitlines()
        self.assertTrue(runtime_dirs)
        self.assertEqual(set(runtime_dirs), {'"/run/user/1000"'})

    def test_t3_enrollment_installs_standalone_when_package_is_missing(self):
        # A controlled PATH excludes the machine's real T3 and any network installer.
        (self.bin / "t3").unlink()
        for command in ("bash", "dirname", "sed", "tr", "jq", "ssh-keygen", "awk",
                        "chmod", "mkdir", "mktemp", "cat", "cmp", "install", "rm",
                        "mv", "cp", "grep", "head", "sort", "cut", "sh", "python3"):
            (self.bin / command).symlink_to(shutil.which(command))
        self.env["PATH"] = str(self.bin)
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls("curl"), [["curl", "-fsSL", "https://t3.codes/install.sh"]])
        binary = self.home / ".local/bin/t3"
        self.assertTrue(binary.is_file())
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertIn(str(binary), (self.home / ".config/t3code/start.sh").read_text())
        result = self.local("\n\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.calls("curl")), 1)


FAKE_COMMAND = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["TEST_ROOT"])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps([name, *args]) + "\n")
if name == "sudo":
    if args == ["-v"]:
        sys.exit(0)
    sys.exit(subprocess.run(args).returncode)
if name == "sshd" and (root / "capitalized-sshd").exists():
    import builtins
    original_print = builtins.print
    def capitalized_print(*values, **kwargs):
        text = " ".join(str(value) for value in values)
        original_print("\n".join(line[:1].upper() + line[1:] for line in text.splitlines()), **kwargs)
    builtins.print = capitalized_print
if name == "id":
    print("1000" if args == ["-u"] else "owner")
elif name == "tailscale":
    state = json.loads((root / "tailscale.json").read_text())
    if args == ["status", "--json"]:
        print(json.dumps(state))
    elif args[:1] == ["ip"]:
        for ip in state["Self"]["TailscaleIPs"]:
            if (args[-1] == "-4" and ":" not in ip) or (args[-1] == "-6" and ":" in ip):
                print(ip)
elif name == "curl":
    if args != ["-fsSL", "https://t3.codes/install.sh"]:
        print("Unexpected installer URL", file=sys.stderr)
        sys.exit(1)
    print('mkdir -p "$HOME/.local/bin"\n'
          'printf "#!/bin/sh\\nexit 0\\n" > "$HOME/.local/bin/t3"\n'
          'chmod 700 "$HOME/.local/bin/t3"')
elif name == "sshd":
    if (root / "invalid-sshd").exists():
        print("invalid sshd config", file=sys.stderr)
        sys.exit(1)
    if "-T" in args:
        print("listenaddress 100.64.0.2:22\nlistenaddress [fd7a:115c:a1e0::2]:22")
        if (root / "wide-sshd").exists():
            print("listenaddress 0.0.0.0:22")
        print("allowusers owner\npermitrootlogin no\npasswordauthentication no\n"
              "kbdinteractiveauthentication no\npubkeyauthentication yes\nauthenticationmethods publickey")
        print("authorizedkeysfile .ssh/authorized_keys\nhostbasedauthentication no\ntrustedusercakeys none")
        print("authorizedkeyscommand /usr/local/bin/external-keys" if (root / "external-ssh-authorization").exists()
              else "authorizedkeyscommand none")
elif name == "systemctl":
    if "--user" in args:
        with (root / "user-runtime-dirs.jsonl").open("a") as stream:
            stream.write(json.dumps(os.environ.get("XDG_RUNTIME_DIR")) + "\n")
    if args == ["--user", "show-environment"]:
        sys.exit(1 if (root / "missing-user-manager").exists() else 0)
    state_path = root / "systemctl.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    args = [arg for arg in args if arg not in ("--user", "--quiet")]
    if args[:1] == ["show"]:
        print("not-found" if (root / "missing-sshd-socket").exists() else "loaded")
        sys.exit(0)
    if "sshd.socket" in args and args[:1] == ["disable"] and (root / "missing-sshd-socket").exists():
        print("Unit sshd.socket does not exist", file=sys.stderr)
        sys.exit(1)
    args = [arg for arg in args if arg != "--now"]
    action, *units = args
    if action.startswith("is-"):
        unit = state.get(units[0], {})
        value = unit.get(action[3:], False)
        print(action[3:] if value else "inactive")
        sys.exit(0 if value else 1)
    for unit in units:
        entry = state.setdefault(unit, {})
        if action in ("enable", "disable"): entry["enabled"] = action == "enable"
        if action in ("start", "stop", "restart", "reload"): entry["active"] = action != "stop"
        if action == "mask": entry["masked"] = True
        if action == "unmask": entry["masked"] = False
    state_path.write_text(json.dumps(state))
elif name == "moshi-hook":
    if args == ["status", "--json"]:
        status_path = root / "moshi-status.json"
        print(status_path.read_text() if status_path.exists() else json.dumps({
            "paired": True, "hooks": [{"target": "claude", "status": "installed"}]}))
    elif args[:1] == ["pair"]:
        if os.environ.get("MOSHI_PAIRING_TOKEN") != "synthetic-moshi-token":
            sys.exit(1)
        path = root / "moshi-status.json"
        state = json.loads(path.read_text())
        state["paired"] = True
        path.write_text(json.dumps(state))
        print("synthetic-moshi-token")
        print("synthetic-moshi-token", file=sys.stderr)
    elif args == ["install"]:
        path = root / "moshi-status.json"
        state = json.loads(path.read_text())
        for hook in state["hooks"]:
            if hook["status"] == "stale": hook["status"] = "installed"
        path.write_text(json.dumps(state))
    elif args == ["service", "install"]:
        path = root / "systemctl.json"
        state = json.loads(path.read_text()) if path.exists() else {}
        state["moshi-hook.service"] = {"enabled": True, "active": True}
        path.write_text(json.dumps(state))
elif name == "tmux":
    if args[:1] == ["list-sessions"]:
        print("100 $1\n200 $2")
elif name == "pgrep":
    sys.exit(1)
'''

if __name__ == "__main__":
    unittest.main()
