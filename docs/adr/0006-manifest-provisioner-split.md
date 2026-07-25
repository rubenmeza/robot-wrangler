# The manifest / Provisioner split

First-boot setup is split in two: `cloud-init.yaml.tftpl` is a declarative **manifest** (WHAT the
box has -- packages, user, files), and `files/provision.sh` is the **Provisioner** (all imperative
HOW -- the ordered first-boot sequence). The manifest's `runcmd` shrinks to a single line that
invokes the Provisioner; every other imperative step moved into it.

## Why

The imperative setup used to live as a shell heredoc inside the YAML inside the HCL `templatefile`
-- three quoting layers deep, un-runnable, un-lintable. It was the git-history hot spot: the fixes
for fresh-boot provisioning, the root-owned-home bug, and the `chage`/password-aging dance all
landed there blind, because the code only existed as a rendered blob at apply time. A stray em-dash
once decoded to a control char and silently voided the ENTIRE `#cloud-config` across two rebuilds.

Splitting WHAT from HOW makes the Provisioner a real file: shellcheck-clean, and runnable in a
throwaway `ubuntu:24.04` container with `PROVISION_SKIP_HOST=1` stubbing the calls that need real
hardware (`tailscale up`, `systemctl`, `chage`). The manifest keeps only cloud-init's declarative
strengths.

## The seam

The Provisioner's interface: source `/opt/robot/provision.env` (non-secret config -- robot user,
git identity, tailnet hostname/tags), read and shred `/opt/robot/.ts-authkey` (the single-use key,
on its own `0600` channel), then run. Config and credential arrive on separate channels, and both
are injectable, so tests supply their own without any secret discipline.

## Bug classes killed by construction

- **Voided config.** Every dynamic payload the manifest writes (Provisioner, config, authkey,
  Handover, login drop-in) ships `encoding: b64`. No non-ASCII byte can reach the YAML, so the
  "empty cloud config" failure is impossible. The preflight ASCII gate that guarded against it is
  retired (replaced by a shellcheck of the Provisioner).
- **`.bashrc` append-once.** PATH, secret-env sourcing, and auto-attach moved from idempotent
  appends into a static `/etc/profile.d/10-robot.sh` drop-in shipped by the manifest. There is no
  append to get wrong. The drop-in is guarded to the robot user so a root break-glass console
  login (ADR 0005) never auto-attaches a root-owned `robot` session.

## Consequences

- One `runcmd` line; the manifest is a thin list of WHAT.
- The Provisioner is the single home for imperative first-boot ordering, including the
  `chage`-before-`sudo` fix. Changing HOW touches one shellcheck-able file.
- The multiplexer profile's box-side auto-attach (ADR 0003) lives in the `profile.d` drop-in,
  baked at render time; the Provisioner no longer needs the mux value.
- The auth key sits on disk at `/opt/robot/.ts-authkey` (`0600`) between the `write_files` stage
  and the Provisioner's `tailscale up`, then is shredded. Same single-use/spent posture as
  ADR 0001; no new metadata exposure (it was always in `user_data`).
- Tests: `scripts/test-provision.sh` -- shellcheck + a container double-run asserting idempotency.
  `make preflight` also shellchecks the Provisioner when shellcheck is installed.
