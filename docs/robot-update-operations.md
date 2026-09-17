# OS package maintenance

Run `make robot-update` from a Control surface on the Tailnet. Finish or stop agent work first:
package updates may restart services, interrupt sessions, and require a reboot. Type `yes` at
the prompt to start. Any other answer (including end of input) cancels without maintenance
changes. The command uses the same hostname and SSH device key as `make robot-ssh`.

The update runs as a root systemd service on the box, independently of SSH. Once accepted by
systemd it continues if the Control surface disconnects. If the connection drops during launch,
check status before retrying: the service may already have started.

Use `make robot-update-status` to inspect the latest operation without starting maintenance.
Invoking `make robot-update` while an operation is active reports it instead of starting another.
After an operation ends, another confirmed invocation starts a new attempt. Completed package
changes are retained; there is no rollback. A retry first configures unpacked packages, then
refreshes package indexes and upgrades installed packages. Failures stop subsequent steps.
APT lock contention also fails safely; wait for the other package manager and retry.

Status lists completed steps, the current or failed step, the pending reboot marker, and the
operation log path. Operations and logs are retained under `/var/lib/robot-update/operations/`
on the box. Read the reported log with `make robot-ssh` and `sudo cat <log-path>`.
If the box reboots or the worker is killed before it records an outcome, status reports the
operation as interrupted; inspect its log before retrying.

This first slice updates packages using the box's existing APT repositories within the current
Ubuntu release. It does not change repository configuration, run a release upgrade, rebuild the
box, or change its multiplexer profile. `apt-get --with-new-pkgs upgrade` permits dependencies
needed by updates (including kernel packages), but does not remove installed packages. Held or
phased updates and packages requiring removals may be kept back and are visible in the log.

**Package success is not full maintenance completion.** This command neither updates Herdr nor
verifies session activation. It reports `/var/run/reboot-required` even on failure, but does not
reboot automatically or verify access after reboot. Resolve pending reboot and activation
manually; automated handling belongs to the later maintenance tickets.
