# robot-wrangler

Set up all your **Agent hosts**: your own Arch/Omarchy PCs and laptops as **Personal hosts**, and
a sealed, always-on **Robot server** in DigitalOcean. Run agents where your work lives, then
drive them from your laptop, phone or tablet through **T3 Code** or SSH/Moshi. Every remote door
is private to your own devices over Tailscale.

Based on [@robj3d3's setup](https://x.com/robj3d3/status/2080018987849773315), reworked to be
automated and *born-locked* (see [ADR 0001](docs/adr/0001-no-public-ingress.md)). Glossary in
[GLOSSARY.md](GLOSSARY.md).

## What you get

- **Tailnet policy as code**, applied from its own OpenTofu root and state. Your devices can reach
  Agent hosts; the tagged Robot server cannot initiate connections to Personal hosts. Rebuilding
  the robot leaves that policy intact.
- **Personal-host enrollment** at the machine's keyboard: Tailnet-only, key-only SSH; T3 Code
  and Moshi push as persistent user services; tmux attachment on interactive SSH login; your
  Device key registered for other hosts. Choose **Always-on** for the desktop PC or
  **Open by hand** for the laptop.
- **T3 Code on every host**, running on loopback and published over Tailnet HTTPS. Per-device,
  per-host Pairings admit clients; interrupted T3 turns resume after a server restart.

The Robot-server path also provides:

- **DigitalOcean** droplet, 8GB/4vCPU, Ubuntu 24.04, NYC3, daily backups. Provisioned with
  **OpenTofu + cloud-init**.
- **Tailscale**-only access. The DO firewall denies all inbound; the box joins your tailnet on
  first boot via a single-use key. SSH is key-only, root/passwords disabled.
- **Claude Code** installed and authed with *your subscription* (no API billing), running inside a
  multiplexer so it survives disconnects — **herdr** by default (agent-aware TUI) or classic
  **tmux**, picked at provision time (see [ADR 0003](docs/adr/0003-multiplexer-profile-at-provision-time.md)).
- **OpenAI Codex CLI** as a second agent, also authed from *your ChatGPT subscription* (no API
  billing), sharing the same session (optional; see [ADR 0008](docs/adr/0008-codex-agent.md)).
- Reach it from your **laptop** (native ssh) and your **Pixel + iPad** (the **Moshi** app, see
  [ADR 0004](docs/adr/0004-moshi-mobile-client.md)). Transport follows the profile: herdr over
  plain SSH, tmux over **mosh** for sessions that survive network drops. Every device auto-attaches
  the **same** live `robot` session, so you can hand off mid-work between them.
- **Push notifications** for agent events. The on-box `moshi-hook` daemon relays Claude Code's
  "task done / needs input" to Moshi on your phone even when the app is closed
  (see [ADR 0007](docs/adr/0007-moshi-hook-push.md)). Optional — set `MOSHI_PAIRING_TOKEN` to enable.

## One-time setup

Follow **[SETUP.md](SETUP.md)** in order: apply the Tailnet policy, enroll the PC as Always-on,
enroll the laptop as Open by hand, then optionally provision or rebuild the Robot server with
T3 Code. MagicDNS and HTTPS certificates must be enabled before enrollment. Personal-host
commands need no DigitalOcean or robot agent credentials.

## Personal hosts

Run these commands from the repo on the machine being enrolled, as your own user at its keyboard:

```bash
make enroll       # asks for a unique Tailnet name, mode and sudo authentication
make status       # actual SSH listeners, boot activation, inbound handlers, Serve, T3 and tmux
```

Use `always-on` for the PC: SSH starts at boot, T3 publishes itself with Tailscale Serve, and
suspend is disabled. Use `open-by-hand` for the laptop: both remote doors start closed after
reboot; power settings stay untouched. The T3 server and Moshi push keep running in either mode.
Re-running enrollment preserves working services and pairings when their configuration is unchanged;
Open-by-hand enrollment closes its doors.

```bash
make open         # Open-by-hand hosts: open SSH and T3 HTTPS together
make close        # hard-close inbound SSH/mosh and Serve; agents keep running
```

Leave the laptop lid up while open, and keep work inside tmux or T3. `close` reports the inbound
handlers it killed, leaves outbound mosh clients alone, and leaves tmux, T3 and agents running.
`status` warns if a host intended closed has an open door.

Enrollment registers `devices/<name>.pub` and `hosts/<name>.json` (Tailnet name and actual Unix
user). Commit those public files, pull them on other Personal hosts and re-run `make enroll`
there; rebuild the Robot server to propagate new SSH keys. Each Personal host admits all Device
keys except its own. See [Device keys](devices/README.md) and [host inventory](hosts/README.md).
Moshi enrollment asks for its Hooks token with hidden input if unpaired; a working pairing is
preserved. Agent CLI authentication on Personal hosts remains your existing local setup.

Pair each client with each host once. At a trusted terminal **on that host**, run the following
for the Pixel, then repeat with each other device's exact name (for example `ipad` or `laptop`):

```bash
t3 pair --tailscale --label pixel
```

Open an Open-by-hand host before pairing, scan the one-time code in that device's T3 client,
then close it afterward. Use the same exact name for the Tailnet node, `devices/<name>.pub`
and T3 label, so revocation can find it. Pairing codes and URLs are passwords: never log, commit
or screenshot them.

The repo owns `t3code.service` and intentionally bypasses native `t3 service install`, whose
immediate startup can log pairing passwords. After `t3 update`, run
`systemctl --user restart t3code.service` as the host owner.

For a lost device, run `make revoke DEVICE=pixel` from another Personal host. It removes its
Tailnet node and public key and revokes its T3 Pairings and sessions across reachable hosts;
failed or unreachable hosts are listed for retry. Pull the key removal and re-enroll remaining
Personal hosts; rebuild the robot. See [device revocation](docs/device-revocation.md) for API
credentials, inventory and retry receipts.

## Robot server

```bash
make preflight      # Robot-server tools, secrets, Tailnet and doctl auth
make robot-wrangler   # provision + join tailnet + push token   (idempotent)
make robot-attach   # attach the shared 'robot' session (herdr/ssh or tmux/mosh per profile); then run: claude
make robot-ssh      # plain ssh over the tailnet
make robot-status   # droplet + tailnet status
make robot-update   # update OS + Herdr, reboot if needed, verify access and session
make robot-update-status # progress, failures, log path, and pending reboot
make robot-destroy  # tear it all down
```

From then on you just `make robot-attach` from any device and tell Claude what you want.

For maintenance, finish or stop agent work before confirming `make robot-update`.
Services and sessions may be interrupted; terminal agents do not automatically resume. T3
enables resuming interrupted turns after server restarts. The command updates OS packages and
Herdr, activates and checks the configured shared session, reboots when required, and verifies Tailnet/SSH access and the session afterward. See the
[maintenance operator guide](docs/robot-update-operations.md) for status, logs, and retry behavior.

## How it stays safe

Personal hosts run agents as you, with your real repositories and credentials. The shared Tailnet
policy limits inbound access to your own untagged devices and denies the tagged robot a path to
Personal hosts. SSH binds only Tailnet addresses; T3 binds loopback and uses Serve for private
HTTPS. Device keys and T3 Pairings are separate credentials, both covered by device revocation.

The box is **never** exposed to the public internet — not even for a first login. The firewall is
attached at birth denying all inbound; the box establishes its own outbound path onto your
tailnet. The powerful subscription token is pushed over SSH *after* the box is on the tailnet, so
it never lands in cloud metadata. The on-box [CLAUDE.md](files/CLAUDE.md.tmpl) tells the agent the
security model so it won't try to "helpfully" open a port. Full rationale in
[ADR 0001](docs/adr/0001-no-public-ingress.md).

## Rebuild & verify

The box is **cattle** — changing `cloud-init`, adding a `devices/*.pub`, or switching the
multiplexer profile all mean a fresh box. Keep anything precious in git; the robot delivers work as
PRs, so committed work is safe on GitHub.

```bash
make robot-destroy              # tofu destroy (type: yes)
```
Then, because the Tailscale auth key is **single-use** and the old node lingers:

1. **Mint a fresh Tailscale key** (Reusable OFF · Ephemeral OFF · Pre-approved ON · `tag:server`)
   → `.env` `TF_VAR_tailscale_authkey`.
2. **Delete the stale `robot` node** in the Tailscale admin console → Machines. Otherwise the new
   box registers as `robot-1` and `robot-ip`/`robot-attach` can't find it (false timeout).

T3 Pairings belong to the rebuilt host and must be created again after each rebuild. Once
`make robot-wrangler` finishes, use `make robot-ssh` and run this at the trusted terminal on the
robot, once for each device (replace `pixel` with its name from `devices/`):

```bash
t3 pair --tailscale --label pixel
```

Scan the one-time code from that device's T3 client. Pairing codes and URLs are passwords:
keep them out of logs, screenshots and the repo. No T3 pairing credential goes through cloud-init.
The Robot server publishes T3 at its Tailnet HTTPS name; SSH and Herdr remain available.
After `t3 update`, run `systemctl --user restart t3code.service` to use the new runtime.

Moshi push re-pairs automatically from `MOSHI_PAIRING_TOKEN` in `.env` (no action needed). If the
new box doesn't report `paired`, mint a fresh token in the app (Settings → Hooks) and re-run
`make robot-auth` (ADR 0007).

```bash
make preflight                  # tools, secrets, tailnet, doctl — plus a shellcheck of the
                                # Provisioner (files/provision.sh, ADR 0006)
make robot-wrangler             # provision → join tailnet → push tokens. Hands-off, ~5–8 min.
```

Check the provisioned binaries and credentials (T3 Pairings remain manual):

```bash
IP=$(make robot-ip)
ssh -i ~/.ssh/robot_ed25519 -o IdentitiesOnly=yes robot@$IP \
  'export PATH=$HOME/.local/bin:$PATH; export XDG_RUNTIME_DIR=/run/user/$(id -u)
   t3 --version; systemctl --user is-active t3code.service
   herdr --version; claude --version; grep -o hasCompletedOnboarding ~/.claude.json
   codex --version; codex login status
   moshi-hook status | grep -iE "status:|Pro|codex"'
# expect: t3 <ver> · active · herdr <ver> · claude <ver> · hasCompletedOnboarding · codex <ver> · Logged in using ChatGPT
#         · status: paired · Moshi Pro attached · codex current

make robot-attach               # drops straight into the herdr 'robot' session
# then, in a pane:  claude      # no theme/login wizard → authed via the pushed token; say hi
```

### If `robot-wrangler` hangs on "waiting for tailnet IP"

Stale node not deleted (step 2), or a spent/wrong key in `.env`. There is **no public SSH** by
design, so read the boot log out-of-band: DO droplet `robot` → **Recovery Console** (noVNC) → log
in as `robot` with your console password (`TF_VAR_robot_console_password_hash`, see
[ADR 0005](docs/adr/0005-console-break-glass-password.md)) → `sudo tail -80 /var/log/cloud-init-output.log`.

Live rollout checks are **UNVERIFIED** until performed on the real hosts. The
[acceptance checklist](SETUP.md#manual-acceptance--unverified) covers policy tests, reachability,
pairing, push, reboot behavior, robot maintenance and revocation.
