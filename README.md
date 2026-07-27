# robot-wrangler

A `make robot-wrangler` that provisions a **private, always-on box running Claude Code**, reachable
only from your own devices over Tailscale. No public ingress, ever. One command to build it, one
to tear it down.

Based on [@robj3d3's setup](https://x.com/robj3d3/status/2080018987849773315), reworked to be
automated and *born-locked* (see [ADR 0001](docs/adr/0001-no-public-ingress.md)). Glossary in
[CONTEXT.md](CONTEXT.md).

## What you get

- **DigitalOcean** droplet, 8GB/4vCPU, Ubuntu 24.04, NYC3, daily backups. Provisioned with
  **OpenTofu + cloud-init**.
- **Tailscale**-only access. The DO firewall denies all inbound; the box joins your tailnet on
  first boot via a single-use key. SSH is key-only, root/passwords disabled.
- **Claude Code** installed and authed with *your subscription* (no API billing), running inside a
  multiplexer so it survives disconnects — **herdr** by default (agent-aware TUI) or classic
  **tmux**, picked at provision time (see [ADR 0003](docs/adr/0003-multiplexer-profile-at-provision-time.md)).
- Reach it from your **laptop** (native ssh) and your **Pixel + iPad** (the **Moshi** app, see
  [ADR 0004](docs/adr/0004-moshi-mobile-client.md)). Transport follows the profile: herdr over
  plain SSH, tmux over **mosh** for sessions that survive network drops. Every device auto-attaches
  the **same** live `robot` session, so you can hand off mid-work between them.

## One-time setup

> Full step-by-step + troubleshooting: **[SETUP.md](SETUP.md)** · rebuilding? see [Rebuild & verify](#rebuild--verify)

1. **Tools** (Arch): `sudo pacman -S opentofu tailscale doctl jq mosh openssh`
2. **Tailscale**: `sudo tailscale up` on this laptop (and install the app on your phone + iPad).
   In the admin console, make sure your ACL defines `tag:server`.
3. **doctl**: `doctl auth init` (already active here).
4. **Device keys** — see [devices/README.md](devices/README.md). At minimum, your laptop:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/robot_ed25519 -C robot-arch
   cp ~/.ssh/robot_ed25519.pub devices/arch.pub
   ```
5. **Secrets**:
   ```bash
   cp .env.example .env
   claude setup-token        # paste output into CLAUDE_CODE_OAUTH_TOKEN
   ```
   Fill `DIGITALOCEAN_TOKEN`, `TF_VAR_tailscale_authkey` (one-time, pre-approved, `tag:server`),
   `CLAUDE_CODE_OAUTH_TOKEN`.

## Use

```bash
make preflight      # verify tools, secrets, tailnet, doctl auth
make robot-wrangler   # provision + join tailnet + push token   (idempotent)
make robot-attach   # attach the shared 'robot' session (herdr/ssh or tmux/mosh per profile); then run: claude
make robot-ssh      # plain ssh over the tailnet
make robot-status   # droplet + tailnet status
make robot-destroy  # tear it all down
```

From then on you just `make robot-attach` from any device and tell Claude what you want.

## How it stays safe

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

```bash
make preflight                  # tools, secrets, tailnet, doctl — plus a shellcheck of the
                                # Provisioner (files/provision.sh, ADR 0006)
make robot-wrangler             # provision → join tailnet → push tokens. Hands-off, ~5–8 min.
```

Verify it came up **turnkey** (no manual steps):

```bash
IP=$(make robot-ip)
ssh -i ~/.ssh/robot_ed25519 -o IdentitiesOnly=yes robot@$IP \
  'export PATH=$HOME/.local/bin:$PATH; herdr --version; claude --version; grep -o hasCompletedOnboarding ~/.claude.json'
# expect: herdr <ver> · claude <ver> · hasCompletedOnboarding

make robot-attach               # drops straight into the herdr 'robot' session
# then, in a pane:  claude      # no theme/login wizard → authed via the pushed token; say hi
```

### If `robot-wrangler` hangs on "waiting for tailnet IP"

Stale node not deleted (step 2), or a spent/wrong key in `.env`. There is **no public SSH** by
design, so read the boot log out-of-band: DO droplet `robot` → **Recovery Console** (noVNC) → log
in as `robot` with your console password (`TF_VAR_robot_console_password_hash`, see
[ADR 0005](docs/adr/0005-console-break-glass-password.md)) → `sudo tail -80 /var/log/cloud-init-output.log`.
