# Moshi push via the on-box moshi-hook daemon

Push notifications for agent events (Claude Code finishing a task or waiting for input) are
delivered by **`moshi-hook`**, a small daemon installed **on the box**. It registers Claude Code's
hooks (`PreToolUse`, `Notification`, `Stop`), keeps a WebSocket open to Moshi, and forwards each
event to your phone — whether or not a Moshi terminal session is attached. This amends
[ADR 0004](0004-moshi-mobile-client.md), which assumed Moshi was "a client only, never installed on
the box" and that free push over a plain connection was enough.

## Why the original plan didn't fire

ADR 0004 parked the notification path as "Moshi push (free) + herdr agent-state" and flagged:
*"Verify push fires while the app is closed; if it's connection-only, revisit."* It was. A plain
SSH/mosh session pushes nothing on its own — Moshi only raises agent-event notifications when
`moshi-hook` on the host relays them. Without the daemon, leaving an issue running and walking away
produced silence. So the daemon is not optional decoration; it is the notification path.

## The two secrets, and where each lives

Getting this wrong is easy, so it's explicit:

- **Pairing token** (`MOSHI_PAIRING_TOKEN`) — a *server* secret. It authorizes this host to the
  Moshi account. It rides the same post-boot channel as the Claude and GitHub tokens: written into
  `~/.robot-env` by `scripts/robot-auth.sh`, never through cloud-init/metadata. From the app:
  Settings -> Hooks.
- **Pro license key** (`MOSHI-…`) — **not** a server secret. It is redeemed **in the app**
  (Settings -> Your License) and attaches to the paired host through your Moshi account. `moshi-hook`
  has no license flag or env var; a license key placed in `.env` is dead config. We tried it, found
  it does nothing on the box, and removed it.

## Install / pair / serve

- **Binary** (token-independent): the Provisioner installs `moshi-hook` into `~/.local/bin`
  alongside `claude`/`herdr` at first boot. Harmless when Moshi is unused.
- **Pairing** (token-dependent): once the token is on the box, `robot-auth.sh` runs
  `moshi-hook pair && moshi-hook install && moshi-hook service install`. Idempotent — re-running
  refreshes it.
- **Persistence**: `moshi-hook` runs as a systemd `--user` service. The Provisioner enables
  **linger** for the robot user (`loginctl enable-linger`) so that service survives the provisioning
  SSH session and reboots without anyone logged in.

## Reconnect: sshd keepalive

Mobile connections drop without a clean FIN. With sshd's default `ClientAliveInterval 0`, the box
never reaps the half-open session, and Moshi's reconnect reuses it and hits
*"failed to open channel."* The hardening drop-in now sets `ClientAliveInterval 20` /
`ClientAliveCountMax 3`, so a dead client is dropped in ~60s and the next reconnect gets a clean
channel. This matters most on the free tier (no mosh); with Pro's mosh transport the session
survives network changes outright.

## Cost: Pro, not free

ADR 0004 started on the free tier at $0. We took **Pro** — the deciding feature was unified
**multi-device push** (one paired host fanning notifications to both the Pixel and the iPad) plus
the higher event rate, mosh, and multiplexer pairing. Pro is redeemed in-app and attaches to host
`robot`; `moshi-hook status` then reports `Moshi Pro attached (usage scope: license)`.

## Consequences

- The box is no longer Moshi-agnostic: it installs a proprietary daemon and registers Claude Code
  hooks. Lock-in is still shallow — drop `MOSHI_PAIRING_TOKEN` and the daemon never pairs; the box
  is otherwise unchanged.
- Rebuilds re-pair automatically from `MOSHI_PAIRING_TOKEN` in `.env`. If a pairing token is
  single-use or rotated, mint a fresh one in the app (Settings -> Hooks) before rebuilding — same
  ritual as the Tailscale key.
- Notifications are independent of an attached session: you can start work on the box, close the
  app, and still get the "done / needs input" push.
