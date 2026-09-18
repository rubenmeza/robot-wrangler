# Robot maintenance

Run `make robot-update` from a Control surface on the Tailnet. Finish or stop agent work first:
package and Herdr updates may restart services, interrupt sessions, and require a reboot. Finish
or stop agents before confirming; previous agents do not automatically resume. Type `yes` at
the prompt to start. Any other answer (including end of input) cancels without maintenance
changes. The command uses the same hostname and SSH device key as `make robot-ssh`.

The update runs as a root systemd service on the box, independently of SSH. Once accepted by
systemd it continues if the Control surface disconnects, including requesting any required
reboot after successful updates. The local command follows progress until final verification
completes or fails. If the connection drops during launch, it checks persisted state instead of
blindly submitting another update. Each invocation has a persisted request ID, so an uncertain
launch cannot mistake a previous operation's completion for its own. If no operation was
recorded for that request, the command fails and asks for a rerun.

Use `make robot-update-status` to inspect the latest operation without starting maintenance.
Invoking `make robot-update` while an operation is active reports it instead of starting another.
After full completion, another confirmed invocation starts a new operation. If updates finished
but reboot/access/session verification is pending or failed, a confirmed rerun resumes that
same operation. Completed package
changes are retained; there is no rollback. A retry first configures unpacked packages, then
refreshes package indexes and upgrades installed packages, then updates Herdr and verifies the
configured shared session. Failures stop subsequent steps.
APT lock contention also fails safely; wait for the other package manager and retry.

Status lists completed steps, the current or failed step, installed/target Herdr versions, the
previous binary's path, session verification, the pending reboot marker, and the operation log
path. `Herdr installed` is the version observed at the start of this attempt; `Herdr target` is
the release this attempt installs and activates. Operations and logs are retained under `/var/lib/robot-update/operations/`
on the box. Read the reported log with `make robot-ssh` and `sudo cat <log-path>`.
An unexpected worker interruption is reported explicitly; inspect its log before retrying.
An expected reboot has its own persisted state and is not reported as an update failure.

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

Retries after an update failure resolve the stable release again. If that version is already
installed, they skip download/replacement and retain the previous binary backup. Once all
update steps have succeeded, retries reuse that operation's recorded target and verify without
repeating package work or release discovery. If the target server is already healthy, they
verify it without restarting it.

## Reboot, reconnection, and completion

The initial confirmation authorizes a reboot when `/var/run/reboot-required` exists after
successful package, Herdr, and session steps. Failures in those steps stop maintenance and
report the marker instead of rebooting. The box saves and flushes the operation and boot ID
before requesting an asynchronous reboot with
[`systemctl reboot --no-block`](https://manpages.ubuntu.com/manpages/noble/man1/systemctl.1.html).

The Control surface waits up to five minutes for return and final verification. Tailnet
resolution, individual SSH attempts, and polling sleeps are bounded by the remaining budget;
healthy package installation is not limited to five minutes. A reboot is considered observed
only after the kernel boot ID changes. A reconnect to the old boot cannot complete the update.

After the box returns, the command launches a detached verifier for the persisted operation.
It checks the installed Herdr version against the saved target, retains the provisioned profile,
starts the configured `robot` session if needed, and checks attachment. A newly created tmux
session, like Herdr, inherits the Robot's existing agent credentials. Previous agents are not
automatically resumed. If the reboot marker remains after a new boot, verification fails rather
than rebooting repeatedly. The no-reboot path also requires session and SSH access checks.

| State | Meaning and next action |
| --- | --- |
| `queued` / `running` | An on-box worker is active; a second start reports it. |
| `awaiting-reboot` | Updates succeeded and reboot was requested; wait for a different boot ID. |
| `awaiting-access` | On-box session checks passed; the next successful command poll verifies SSH access. |
| `complete` | Updates, expected Herdr version, configured session, and SSH access passed. |
| `failed` / `interrupted` | Inspect the failing phase and log. `Update steps: completed` distinguishes final verification failures from update failures. |

`make robot-update-status` is read-only; it reports state without advancing it. Use
`make robot-update` to resume pending verification after closing the Control surface. No boot
service repeats maintenance automatically: persisted state waits for the command to reconnect.
If a live SSH reply is lost after completion, polling reports that same completed operation.

Reconnection timeout exits unsuccessfully and says whether updates were known to have completed
or their outcome could not be obtained. This is separate from a reported package/Herdr failure;
the unreachable box's state is not overwritten. Open **DigitalOcean → robot droplet → Recovery
Console**, inspect boot/networking, Tailscale, and SSH, then rerun `make robot-update`. The
persisted operation can finish verification without reinstalling completed updates.

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

Only `complete` means maintenance passed every required check. Logs, previous binaries, and
pending-reboot reports remain available after failures; automatic rollback is not performed.
