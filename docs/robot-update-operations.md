# Robot maintenance

Run `make robot-update` from a Control surface on the Tailnet. Finish or stop agent work first:
package and Herdr updates may restart services, interrupt sessions, and require a reboot. Finish
or stop agents before confirming; previous agents do not automatically resume. Type `yes` at
the prompt to start. Any other answer (including end of input) cancels without maintenance
changes. The command uses the same hostname and SSH device key as `make robot-ssh`.

The update runs as a root systemd service on the box, independently of SSH. Once accepted by
systemd it continues if the Control surface disconnects. If the connection drops during launch,
check status before retrying: the service may already have started.

Use `make robot-update-status` to inspect the latest operation without starting maintenance.
Invoking `make robot-update` while an operation is active reports it instead of starting another.
After an operation ends, another confirmed invocation starts a new attempt. Completed package
changes are retained; there is no rollback. A retry first configures unpacked packages, then
refreshes package indexes and upgrades installed packages, then updates Herdr and verifies the
configured shared session. Failures stop subsequent steps.
APT lock contention also fails safely; wait for the other package manager and retry.

Status lists completed steps, the current or failed step, installed/target Herdr versions, the
previous binary's path, session verification, the pending reboot marker, and the operation log
path. `Herdr installed` is the version observed at the start of this attempt; `Herdr target` is
the release this attempt installs and activates. Operations and logs are retained under `/var/lib/robot-update/operations/`
on the box. Read the reported log with `make robot-ssh` and `sudo cat <log-path>`.
If the box reboots or the worker is killed before it records an outcome, status reports the
operation as interrupted; inspect its log before retrying.

Maintenance updates packages using the box's existing APT repositories within the current
Ubuntu release. It does not change repository configuration, run a release upgrade, rebuild the
box, or change its multiplexer profile. `apt-get --with-new-pkgs upgrade` permits dependencies
needed by updates (including kernel packages), but does not remove installed packages. Held or
phased updates and packages requiring removals may be kept back and are visible in the log.

## Herdr installation and activation

The authoritative stable release is [Herdr's manifest](https://herdr.dev/latest.json), also used
by its [official installer](https://herdr.dev/install.sh). Maintenance resolves that manifest,
reports the installed and target versions, downloads the matching Linux architecture binary,
checks its SHA-256 and executable version, then replaces the installed binary with an atomic
rename on the same filesystem. The old executable is copied into the operation directory
before replacement. Download, verification, or replacement failure leaves the original binary
intact. A successful replacement also retains the backup; no rollback happens automatically.

The profile comes from the box's provisioned `/etc/profile.d/10-robot.sh`, and the Robot user
comes from `/opt/robot/provision.env`. Local `.env` edits cannot switch the box's profile.
An unrecognized on-box profile fails explicitly.

- **Herdr profile:** inspect the running `robot` server; if its version differs or it is not
  running compatibly, stop it and start the target executable as the Robot user in a separate
  systemd service. Check the server's version, named session, and client compatibility, then
  exercise an actual client attachment in a short-lived PTY. The server and its panes survive
  maintenance-worker exit. Startup sources the existing `~/.robot-env` as the Robot user so
  new panes retain agent/GitHub credentials; secret values are not placed in service arguments.
  Server output is in `herdr-server.log` in the operation directory.
- **tmux profile:** replace the installed Herdr binary without starting Herdr. Preserve the
  running tmux session, create `robot` if absent, and verify its identity and client attachment.

Herdr's supported lifecycle commands (`herdr server`, `session stop`, `session attach`, and
`status server --json`) were verified against upstream v0.9.1 and the live Robot. See the
[CLI reference](https://herdr.dev/docs/cli-reference/). Compatible old servers can otherwise
remain running after binary replacement, so binary version alone is not considered activation.

Herdr enables [native agent resume](https://herdr.dev/docs/session-state/) by default. On
Herdr-profile boxes, maintenance sets `[session] resume_agents_on_restore = false` in the Robot
user's Herdr config before activation. The prior config is retained as `herdr-config.previous`
in the operation directory, and unrelated settings are preserved. This setting remains disabled
for subsequent attachments; restart agents deliberately after maintenance.

Retries resolve the stable release again. If that version is already installed, they skip the
download/replacement, retain the previous binary backup, and retry activation/verification.
If the target server is already healthy, they verify it without restarting it.

## Manual recovery

On failure, use `make robot-update-status` to identify the phase, log, backup, and pending reboot.
Completed OS and Herdr updates remain installed. Do not start recovery while `Active: yes`.

Connect over the Tailnet without entering the automatic attachment flow:

```bash
./scripts/robot-ssh.sh -t bash --noprofile --norc
```

In that shell, load the existing agent environment before starting a server:

```bash
if [ -f ~/.robot-env ]; then source ~/.robot-env; fi
export PATH="$HOME/.local/bin:$PATH" XDG_RUNTIME_DIR="/run/user/$(id -u)"
```

Start/attach the configured session using the **installed** binary:

```bash
# Herdr profile only:
~/.local/bin/herdr session attach robot
# tmux profile only:
tmux new-session -A -s robot
```

If a Herdr server is still running the old version, finish/stop its agents, run
`~/.local/bin/herdr session stop robot`, then attach again. Starting an existing session alone
does not necessarily activate the installed version.

If the installed executable cannot run, **restoring the binary is a separate manual action**.
Use the exact `Previous Herdr binary` path printed by status:

```bash
sudo cp -p -- /var/lib/robot-update/operations/<operation>/herdr.previous ~/.local/bin/herdr.restore
sudo mv -T -- ~/.local/bin/herdr.restore ~/.local/bin/herdr
```

Then, on Herdr-profile boxes, stop any running Herdr server and attach again. On tmux-profile
boxes, keep using tmux. Retained binaries and logs are not deleted on retry. Check the log and
pending reboot before deciding whether to retry the update or recover manually.

**Successful installation and session verification are not full maintenance completion.**
The command reports `/var/run/reboot-required` even on failure, but does not reboot automatically
or verify access after reboot. Automated reboot/reconnection handling belongs to issue #3.
