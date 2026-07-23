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
- **Claude Code** installed and authed with *your subscription* (no API billing), running in
  **tmux** so it survives disconnects.
- Reach it from your **laptop** (native ssh), **Pixel** (Termux), **iPad** (Blink) — **mosh** over
  the tailnet for sessions that survive network drops.

## One-time setup

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
make robot-attach   # mosh in + attach the 'robot' tmux session; then run: claude
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

## Re-provisioning / adding a device

Changing `cloud-init` or adding a `devices/*.pub` means a fresh box:
`make robot-destroy && make robot-wrangler`. The box is cattle; keep anything precious in git.
