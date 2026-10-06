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
                     "tmux", "pacman", "id", "pgrep", "pkill", "ss", "t3", "curl", "kill", "moshi-hook"):
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

    def test_incomplete_checkout_refuses_enrollment_before_changing_host(self):
        (self.root / "scripts/_personal-t3.sh").unlink()
        result = self.local()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls("sudo"), [])
        self.assertFalse((self.home / ".config/robot-wrangler/personal-host.json").exists())

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
        for metadata in ('invalid synthetic-secret-json', '{"paired":"unknown","secret":"synthetic-secret-json"}',
                         '{"paired":true,"secret":"synthetic-secret-json"}'):
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

    def test_enrollment_accepts_omarchy_os_release_derived_from_arch(self):
        (self.host / "etc/os-release").write_text('NAME="Omarchy"\nID=omarchy\nID_LIKE=arch\n')
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Arch/Omarchy", result.stderr)

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
        self.assertIn(["sshd", "-T", "-ddd"], self.calls("sshd"))
        self.assertIn(["systemctl", "enable", "sshd.service"], self.calls("systemctl"))
        self.assertIn(["systemctl", "start", "sshd.service"], self.calls("systemctl"))
        self.assertIn(["ufw", "allow", "in", "on", "tailscale0", "to", "any", "port", "22", "proto", "tcp"], self.calls("ufw"))
        self.assertIn(["ufw", "allow", "in", "on", "tailscale0", "to", "any", "port", "60000:61000", "proto", "udp"], self.calls("ufw"))

    def test_enrollment_keeps_retrying_ssh_until_tailnet_addresses_arrive_after_boot(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        unit = self.host / "etc/systemd/system/sshd.service.d/10-robot-wrangler.conf"
        self.assertTrue(unit.exists(), "SSH needs persistent Tailnet ordering and bind retry policy")
        policy = unit.read_text()
        for setting in ("Wants=tailscaled.service", "After=tailscaled.service",
                        "StartLimitIntervalSec=0", "Restart=always", "RestartSec=5s"):
            self.assertIn(setting, policy)
        calls = self.calls("systemctl")
        self.assertLess(calls.index(["systemctl", "daemon-reload"]),
                        calls.index(["systemctl", "start", "sshd.service"]))

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

    def test_enrollment_rejects_conditional_ssh_bypasses_even_in_nested_includes(self):
        if not Path("/usr/bin/sshd").exists():
            self.skipTest("real OpenSSH server is unavailable")
        config_dir = self.host / "etc/ssh"
        config_dir.mkdir(parents=True, exist_ok=True)
        managed = config_dir / "sshd_config.d/00-robot-wrangler.conf"
        managed.parent.mkdir()
        config = config_dir / "sshd_config"
        outer = config_dir / "existing.conf"
        nested = config_dir / "nested.conf"
        self.stub("sshd", f'exec /usr/bin/sshd -f "{config}" "$@"\n')
        for match in ("User owner", "User root", "Address 100.100.100.100", "LocalPort 22"):
            with self.subTest(match=match):
                previous = "# previous enrollment configuration\n"
                managed.write_text(previous)
                config.write_text(f"HostKey {config_dir}/ssh_host_ed25519_key\n"
                                  f"Include {managed}\nInclude {outer}\n")
                outer.write_text(f"Include {nested}\n")
                nested.write_text(f"Match {match}\nPasswordAuthentication yes\n"
                                  "AuthenticationMethods password\nAllowUsers other\n"
                                  "PermitRootLogin yes\nAuthorizedKeysFile .ssh/other\n")
                result = self.local()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Match", result.stderr)
                self.assertEqual(managed.read_text(), previous)
                self.assertNotIn(["systemctl", "enable", "sshd.service"], self.calls("systemctl"))
                self.assertFalse((self.home / ".config/robot-wrangler/personal-host.json").exists())

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
                        "mv", "cp", "grep", "head", "sort", "cut", "sh", "python3", "test", "sleep"):
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


class PersonalDoorTests(unittest.TestCase):
    setUp = PersonalHostTests.setUp
    write_tailscale = PersonalHostTests.write_tailscale
    stub = PersonalHostTests.stub
    local = PersonalHostTests.local
    calls = PersonalHostTests.calls
    def test_open_by_hand_enrollment_keeps_doors_closed_and_power_untouched(self):
        (self.root / "missing-sshd-socket").touch()
        result = self.local("laptop\nopen-by-hand\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        units = json.loads((self.root / "systemctl.json").read_text())
        self.assertFalse(units["sshd.service"]["enabled"])
        self.assertFalse(units["sshd.service"]["active"])
        self.assertTrue(units["sshd.socket"]["masked"])
        self.assertNotIn("suspend.target", units)
        self.assertIn("T3CODE_TAILSCALE_SERVE=false",
                      (self.home / ".config/systemd/user/t3code.service.d/10-tailnet.conf").read_text())
        unit = (self.host / "etc/systemd/system/robot-wrangler-serve-off.service").read_text()
        self.assertIn("After=tailscaled.service", unit)
        self.assertIn("Requires=tailscaled.service", unit)
        self.assertIn("ExecStart=/usr/bin/tailscale serve --https=443 off", unit)
        self.assertNotIn("User=", unit)
        self.assertIn(["tailscale", "serve", "--https=443", "off"], self.calls("tailscale"))
        result = self.local("\n\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_mode_change_restores_only_enrollment_owned_power_masks(self):
        (self.root / "systemctl.json").write_text(json.dumps({"suspend.target": {"masked": True}}))
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.local("\nopen-by-hand\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        units = json.loads((self.root / "systemctl.json").read_text())
        self.assertTrue(units["suspend.target"]["masked"])
        for target in ("sleep.target", "hibernate.target", "hybrid-sleep.target"):
            self.assertFalse(units[target]["masked"])
        result = self.local("\nalways-on\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.host / "etc/systemd/system/robot-wrangler-serve-off.service").exists())
        self.assertTrue(json.loads((self.root / "systemctl.json").read_text())["sshd.service"]["enabled"])

    def test_interactive_mosh_without_ssh_tty_attaches_but_commands_do_not(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        snippet = self.home / ".config/robot-wrangler/ssh-tmux.sh"
        env = self.env | {"SSH_CONNECTION": "100.64.0.3 4000 100.64.0.2 22", "TMUX": ""}
        env.pop("SSH_TTY", None)
        for interactive in (True, False):
            count = len(self.calls("tmux"))
            result = subprocess.run(["bash", "--norc", "-ic" if interactive else "-c",
                                     '. "$1"', "bash", str(snippet)], env=env,
                                    text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = self.calls("tmux")[count:]
            self.assertEqual(bool(calls), interactive)
            if interactive:
                self.assertIn(["tmux", "attach-session", "-t", "$2"], calls)

    def test_open_publishes_both_doors_and_close_preserves_work_and_outbound_clients(self):
        result = self.local("laptop\nopen-by-hand\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.local("", "open")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("lid", result.stdout)
        self.assertIn("tmux", result.stdout)
        self.assertIn(["tailscale", "serve", "--bg", "--https=443", "http://127.0.0.1:3773"],
                      self.calls("tailscale"))
        self.assertTrue(json.loads((self.root / "systemctl.json").read_text())["sshd.service"]["active"])
        processes = {"200": "sshd", "201": "sshd-session", "202": "sshd-auth",
                     "203": "mosh-server", "204": "mosh-client", "205": "tmux",
                     "206": "t3", "207": "claude", "208": "ssh", "209": "ssh-agent"}
        (self.root / "processes.json").write_text(json.dumps(processes))
        result = self.local("", "close")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        remaining = json.loads((self.root / "processes.json").read_text())
        self.assertEqual(remaining, {pid: name for pid, name in processes.items() if int(pid) > 203})
        for pid in ("200", "201", "202", "203"):
            self.assertIn(pid, result.stdout)
            self.assertIn(processes[pid], result.stdout)
        self.assertIn(["tailscale", "serve", "--https=443", "off"], self.calls("tailscale"))
        self.assertTrue(json.loads((self.root / "systemctl.json").read_text())["t3code.service"]["active"])
        self.assertNotIn("--user", [arg for call in self.calls("systemctl") if "stop" in call for arg in call])
        result = self.local("", "close")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_status_reports_real_state_and_warns_when_closed_or_previous_boot_is_open(self):
        result = self.local("laptop\nopen-by-hand\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.local("", "status")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SSH unit: inactive", result.stdout)
        self.assertIn("SSH starts at boot: disabled", result.stdout)
        self.assertIn("T3 service: active", result.stdout)
        self.assertIn("T3 Tailnet Serve: off", result.stdout)
        self.assertIn("200 $2", result.stdout)
        self.assertNotIn("WARNING", result.stdout)
        units = json.loads((self.root / "systemctl.json").read_text())
        units["sshd.service"]["active"] = True
        (self.root / "systemctl.json").write_text(json.dumps(units))
        (self.root / "listeners").write_text("LISTEN 0 128 100.64.0.2:22 0.0.0.0:* users:((sshd,pid=200))\n")
        (self.root / "processes.json").write_text(json.dumps({"201": "sshd-session", "203": "mosh-server"}))
        result = self.local("", "status")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for value in ("WARNING", "100.64.0.2:22", "sshd-session", "201", "mosh-server", "203"):
            self.assertIn(value, result.stdout)
        result = self.local("", "open")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.local("", "status")
        self.assertNotIn("WARNING", result.stdout)
        boot = self.host / "proc/sys/kernel/random/boot_id"
        boot.parent.mkdir(parents=True)
        boot.write_text("a-new-boot\n")
        result = self.local("", "status")
        self.assertIn("WARNING", result.stdout)

    def test_open_refuses_disconnected_tailnet_and_rolls_back_publication_failure(self):
        result = self.local("laptop\nopen-by-hand\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        count = len(self.calls("systemctl"))
        self.state["BackendState"] = "Stopped"
        self.write_tailscale()
        result = self.local("", "open")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("neither door", result.stderr)
        self.assertEqual(self.calls("systemctl")[count:], [])
        self.state["BackendState"] = "Running"
        self.write_tailscale()
        (self.root / "fail-serve-publish").touch()
        result = self.local("", "open")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("opening failed", result.stderr)
        self.assertFalse(json.loads((self.root / "systemctl.json").read_text())["sshd.service"]["active"])
        self.assertEqual(json.loads((self.root / "serve.json").read_text()), {})

    def test_close_escalates_stubborn_handlers_and_reports_failures_without_stopping_work(self):
        result = self.local("laptop\nopen-by-hand\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        (self.root / "processes.json").write_text(json.dumps({"201": "sshd-session", "206": "t3"}))
        (self.root / "ignore-term").touch()
        result = self.local("", "close")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["kill", "-KILL", "201"], self.calls("kill"))
        self.assertEqual(json.loads((self.root / "processes.json").read_text()), {"206": "t3"})
        (self.root / "processes.json").write_text(json.dumps({"201": "sshd-session", "202": "sshd-session", "206": "t3"}))
        (self.root / "fail-kill").touch()
        (self.root / "fail-serve-off").touch()
        result = self.local("", "close")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Still live: sshd-session PIDs 201", result.stderr)
        self.assertIn("Failed to turn T3", result.stderr)
        self.assertIn("Close incomplete", result.stderr)
        self.assertNotIn("Closed sshd-session PID 201", result.stdout)
        self.assertNotIn("Closed sshd-session PID 202", result.stdout)
        self.assertEqual(json.loads((self.root / "processes.json").read_text())["206"], "t3")

    def test_open_failure_to_start_ssh_cleans_serve_and_status_flags_uninspectable_processes(self):
        result = self.local("laptop\nopen-by-hand\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        (self.root / "fail-start-sshd").touch()
        result = self.local("", "open")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not start SSH", result.stderr)
        self.assertEqual(json.loads((self.root / "serve.json").read_text()), {})
        (self.root / "fail-pgrep").touch()
        result = self.local("", "status")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("handlers/servers: unknown", result.stdout)
        self.assertIn("could not be fully inspected", result.stdout)
        result = self.local("", "close")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Close incomplete", result.stderr)
        self.assertNotIn("doors closed", result.stdout)


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
    elif args == ["serve", "status", "--json"]:
        print((root / "serve.json").read_text() if (root / "serve.json").exists() else "{}")
    elif args[:1] == ["serve"]:
        if (args[-1] == "off" and (root / "fail-serve-off").exists()) or (args[-1] != "off" and (root / "fail-serve-publish").exists()):
            sys.exit(1)
        if args[-1] == "off":
            (root / "serve.json").write_text("{}")
        else:
            (root / "serve.json").write_text(json.dumps({"TCP": {"443": {"HTTPS": True}}}))
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
        if "-ddd" in args:
            print("debug2: parse_server_config_depth: config /etc/ssh/sshd_config len 1", file=sys.stderr)
        print("listenaddress 100.64.0.2:22\nlistenaddress [fd7a:115c:a1e0::2]:22")
        if (root / "wide-sshd").exists():
            print("listenaddress 0.0.0.0:22")
        print("allowusers owner\npermitrootlogin no\npasswordauthentication no\n"
              "kbdinteractiveauthentication no\npubkeyauthentication yes\nauthenticationmethods publickey")
        print("authorizedkeysfile .ssh/authorized_keys\nhostbasedauthentication no\ntrustedusercakeys none")
        print("authorizedkeyscommand /usr/local/bin/external-keys" if (root / "external-ssh-authorization").exists()
              else "authorizedkeyscommand none")
elif name == "systemctl":
    if args == ["start", "sshd.service"] and (root / "fail-start-sshd").exists(): sys.exit(1)
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
    now = "--now" in args
    args = [arg for arg in args if arg != "--now"]
    action, *units = args
    if action.startswith("is-"):
        unit = state.get(units[0], {})
        value = unit.get(action[3:], False)
        if action == "is-enabled" and unit.get("masked"):
            print("masked")
            sys.exit(1)
        print(action[3:] if value else ("disabled" if action == "is-enabled" else "inactive"))
        sys.exit(0 if value else 1)
    for unit in units:
        entry = state.setdefault(unit, {})
        if action in ("enable", "disable"): entry["enabled"] = action == "enable"
        if action in ("start", "stop", "restart", "reload"): entry["active"] = action != "stop"
        if now and action in ("enable", "disable"): entry["active"] = action == "enable"
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
    if (root / "fail-pgrep").exists(): sys.exit(2)
    path = root / "processes.json"
    processes = json.loads(path.read_text()) if path.exists() else {}
    import re
    selected = [pid for pid, process in processes.items() if re.fullmatch(args[-1], process)]
    if selected: print("\n".join(selected))
    sys.exit(0 if selected else 1)
elif name == "ss":
    if (root / "listeners").exists(): print((root / "listeners").read_text())
elif name == "kill":
    path = root / "processes.json"
    processes = json.loads(path.read_text()) if path.exists() else {}
    if (root / "fail-kill").exists(): sys.exit(1)
    if args[0] != "-TERM" or not (root / "ignore-term").exists():
        for pid in args[1:]: processes.pop(pid, None)
    path.write_text(json.dumps(processes))
'''

class RevokeTests(unittest.TestCase):
    write_tailscale = PersonalHostTests.write_tailscale
    local = PersonalHostTests.local
    calls = PersonalHostTests.calls
    stub = PersonalHostTests.stub

    def setUp(self):
        PersonalHostTests.setUp(self)
        (self.root / '.env').write_text('TAILSCALE_API_KEY=test-api-credential\nTAILSCALE_TAILNET=example.ts.net\n')
        (self.root / 'devices/laptop.pub').write_text(self.public_keys['ipad'])
        (self.root / 'hosts').mkdir()
        for name, user in [('desk', 'owner'), ('laptop', 'alice')]:
            (self.root / 'hosts' / f'{name}.json').write_text(json.dumps({'name': name, 'user': user}))
        self.nodes = {'devices': [
            {'id': '1', 'name': 'pixel.example.ts.net', 'os': 'android'},
            {'id': '2', 'name': 'desk.example.ts.net', 'os': 'linux'},
            {'id': '3', 'name': 'laptop.example.ts.net', 'os': 'linux'},
            {'id': '4', 'name': 'robot.example.ts.net', 'os': 'linux', 'tags': ['tag:server']},
        ]}
        (self.root / 'api-nodes.json').write_text(json.dumps(self.nodes))
        for name in ('curl', 'ssh', 't3'):
            path = self.bin / name
            path.unlink(missing_ok=True)
            path.write_text(REVOKE_FAKE)
            path.chmod(0o755)

    def revoke(self, name='pixel'):
        return self.local('', 'revoke', name)

    def test_revoke_removes_node_key_and_both_pairing_kinds_on_every_host(self):
        result = self.revoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / 'devices/pixel.pub').exists())
        self.assertEqual(len(self.calls('curl')), 2)
        self.assertIn(['t3', 'auth', 'pairing', 'revoke', 'pending-pixel'], self.calls('t3'))
        self.assertIn(['t3', 'auth', 'session', 'revoke', 'session-pixel'], self.calls('t3'))
        ssh = self.calls('ssh')
        self.assertEqual({next(a for a in call if '@' in a) for call in ssh}, {'alice@laptop', 'robot@robot'})
        for call in ssh:
            self.assertIn('BatchMode=yes', call)
            self.assertIn('ConnectTimeout=5', call)
        self.assertNotIn('other-device', str(self.calls('t3')))
        self.assertIn('Commit', result.stdout)
        self.assertIn('enrollment', result.stdout)
        self.assertIn('rebuild', result.stdout)
        self.assertNotIn('test-api-credential', result.stdout + result.stderr + str(self.calls()))


    def test_unreachable_host_is_reported_and_can_be_retried_after_key_and_node_removal(self):
        (self.root / 'unreachable-laptop').touch()
        result = self.revoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unreachable Agent host: laptop', result.stderr)
        self.assertIn('Revoked T3 Pairings and sessions on robot', result.stdout)
        self.assertFalse((self.root / 'devices/pixel.pub').exists())
        receipt = self.home / '.local/state/robot-wrangler/revocations/pixel.json'
        self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
        # Even if the shared inventory later disappears, retry remembers the target.
        (self.root / 'hosts/laptop.json').unlink()
        (self.root / 'unreachable-laptop').unlink()
        count = len(self.calls('ssh'))
        result = self.revoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('already absent', result.stdout)
        self.assertTrue(any('alice@laptop' in call for call in self.calls('ssh')[count:]))

    def test_missing_host_inventory_stays_incomplete_even_if_node_later_disappears(self):
        (self.root / 'hosts/laptop.json').unlink()
        result = self.revoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing enrollment inventory for laptop', result.stderr)
        nodes = json.loads((self.root / 'api-nodes.json').read_text())
        nodes['devices'] = [node for node in nodes['devices'] if node['id'] != '3']
        (self.root / 'api-nodes.json').write_text(json.dumps(nodes))
        result = self.revoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing enrollment inventory for laptop', result.stderr)

    def test_unknown_and_unsafe_names_refuse_all_mutations(self):
        for name in ('missing', '../pixel', 'pixel;touch sentinel', '$(touch sentinel)'):
            with self.subTest(name=name):
                before = list(self.calls())
                result = self.revoke(name)
                self.assertNotEqual(result.returncode, 0)
                after = self.calls()[len(before):]
                self.assertEqual([c for c in after if c[0] in ('curl', 'ssh', 't3')], [])
                self.assertTrue((self.root / 'devices/pixel.pub').exists())
                self.assertFalse((self.root / 'sentinel').exists())

    def test_refuses_current_tailnet_host_and_enrolled_host_name(self):
        for name in ('desk', 'old-name'):
            if name == 'old-name':
                config = self.home / '.config/robot-wrangler/personal-host.json'
                config.parent.mkdir(parents=True)
                config.write_text(json.dumps({'name': name, 'mode': 'always-on'}))
            (self.root / 'devices' / f'{name}.pub').write_text(self.public_keys['pixel'])
            result = self.revoke(name)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Refusing to revoke', result.stderr)
            self.assertTrue((self.root / 'devices' / f'{name}.pub').exists())
        self.assertEqual(self.calls('curl'), [])
        self.assertEqual(self.calls('ssh'), [])

    def test_api_listing_failure_preserves_device_key_and_does_not_revoke_pairings(self):
        (self.root / 'api-error').touch()
        result = self.revoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('API listing failed', result.stderr)
        self.assertTrue((self.root / 'devices/pixel.pub').exists())
        self.assertEqual(self.calls('ssh'), [])
        self.assertEqual(self.calls('t3'), [])

    def test_api_delete_failure_is_incomplete_but_other_revocations_continue(self):
        (self.root / 'delete-error').touch()
        result = self.revoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('API delete failed', result.stderr)
        self.assertIn('Revoked T3 Pairings and sessions on robot', result.stdout)
        self.assertFalse((self.root / 'devices/pixel.pub').exists())
        (self.root / 'delete-error').unlink()
        result = self.revoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Deleted Tailnet node pixel', result.stdout)

    def test_session_revocation_failure_reports_every_failed_host(self):
        (self.root / 'session-error').touch()
        result = self.revoke()
        self.assertNotEqual(result.returncode, 0)
        for name in ('desk', 'laptop', 'robot'):
            self.assertIn(f'T3 revocation failed on {name}', result.stderr)
        self.assertNotIn('Revoked T3 Pairings and sessions', result.stdout)
        self.assertEqual(len([c for c in self.calls('t3') if c[1:4] == ['auth', 'pairing', 'revoke']]), 3)

    def test_ambiguous_exact_node_name_refuses_before_any_mutation(self):
        self.nodes['devices'].append({'id': 'other', 'name': 'pixel.other.ts.net', 'os': 'android'})
        (self.root / 'api-nodes.json').write_text(json.dumps(self.nodes))
        result = self.revoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Ambiguous', result.stderr)
        self.assertEqual(len(self.calls('curl')), 1)
        self.assertTrue((self.root / 'devices/pixel.pub').exists())
        self.assertEqual(self.calls('ssh'), [])

    def test_pairing_list_failure_is_not_an_empty_successful_revocation(self):
        (self.root / 'pairing-list-error').touch()
        result = self.revoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not list T3 pairing metadata', result.stderr)
        self.assertEqual(len([c for c in self.calls('t3') if c[1:4] == ['auth', 'session', 'revoke']]), 3)

    def test_unrelated_tailnet_name_is_never_deleted_by_prefix(self):
        self.nodes['devices'][0]['name'] = 'pixel-phone.example.ts.net'
        (self.root / 'api-nodes.json').write_text(json.dumps(self.nodes))
        result = self.revoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('already absent', result.stdout)
        self.assertEqual(len(self.calls('curl')), 1)

    def test_enrollment_records_real_unix_user_in_public_inventory(self):
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.root / 'hosts/desk.json').read_text()), {'name': 'desk', 'user': 'owner'})
        self.assertIn('Commit hosts/desk.json', result.stdout)
        self.assertNotIn('test-api-credential', (self.root / 'hosts/desk.json').read_text())

    def test_make_revoke_passes_device_as_one_argument_without_shell_evaluation(self):
        shutil.copyfile(ROOT / 'Makefile', self.root / 'Makefile')
        result = subprocess.run(['make', 'revoke', 'DEVICE=pixel'], cwd=self.root, env=self.env,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = subprocess.run(['make', 'revoke', 'DEVICE=pixel";touch sentinel;#'],
                                cwd=self.root, env=self.env, text=True, capture_output=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'sentinel').exists())

    def test_unregistered_linux_clients_are_not_assumed_to_be_agent_hosts(self):
        self.nodes['devices'].append({'id': 'visitor', 'name': 'visitor.example.ts.net', 'os': 'linux', 'user': 'another-owner'})
        (self.root / 'api-nodes.json').write_text(json.dumps(self.nodes))
        result = self.revoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('visitor', result.stdout + result.stderr)

REVOKE_FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as out:
    out.write(json.dumps([name, *args]) + '\n')
if name == 'curl':
    config = sys.stdin.read()
    assert 'test-api-credential' in config
    if (root / 'api-error').exists(): sys.exit(22)
    path = root / 'api-nodes.json'
    nodes = json.loads(path.read_text())
    if 'DELETE' in args:
        if (root / 'delete-error').exists(): sys.exit(22)
        assert args[-1].endswith('/device/1')
        nodes['devices'] = [node for node in nodes['devices'] if node['id'] != '1']
        path.write_text(json.dumps(nodes))
    else:
        assert args[-1] == 'https://api.tailscale.com/api/v2/tailnet/example.ts.net/devices'
        print(json.dumps(nodes))
elif name == 'ssh':
    destination = next(arg for arg in args if '@' in arg)
    if destination == 'alice@laptop' and (root / 'unreachable-laptop').exists(): sys.exit(255)
    sys.exit(subprocess.run(['bash', '-s', '--', 'pixel'], input=sys.stdin.read(), text=True).returncode)
elif name == 't3':
    if args == ['auth', 'pairing', 'list', '--json']:
        if (root / 'pairing-list-error').exists(): sys.exit(1)
        print(json.dumps([{'id': 'pending-pixel', 'label': 'pixel'}, {'id': 'other-device', 'label': 'ipad'}]))
    elif args == ['auth', 'session', 'list', '--json']:
        print(json.dumps([{'sessionId': 'session-pixel', 'client': {'label': 'pixel'}}, {'sessionId': 'other-device', 'client': {'label': 'ipad'}}]))
    elif args in (['auth', 'pairing', 'revoke', 'pending-pixel'], ['auth', 'session', 'revoke', 'session-pixel']):
        if args[1:3] == ['session', 'revoke'] and (root / 'session-error').exists(): sys.exit(1)
    else:
        raise AssertionError(args)
'''


if __name__ == "__main__":
    unittest.main()
