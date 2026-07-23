# Handoff — robot-wrangler (2026-07-22)

Cold-start brief to resume next session. Read this + `CONTEXT.md` + `docs/adr/0001-no-public-ingress.md`.

## Status: scaffold COMPLETE + committed. Not yet run.
- 23 files tracked; scaffold committed (`0b60ca3 "the beginning of time"`). `SETUP.md` / `HANDOFF.md` / README-pointer are staged, **uncommitted**. All 8 scripts pass `bash -n`. DO slugs verified live.
- **Not** yet validated with `tofu` (OpenTofu wasn't installed at build time).
- Working dir: `/home/pollo/Dev/robot-wrangler` (renamed from `dot_robot`).

## What this is
`make robot-wrangler` provisions a private, always-on DigitalOcean box running Claude Code,
reachable **only** over Tailscale (no public ingress). One command up, one down.
- Resume checklist → **SETUP.md**
- Overview → README.md · Glossary → CONTEXT.md · Rationale → docs/adr/0001-no-public-ingress.md

## Locked decisions (the non-obvious "why")
- **DigitalOcean**, 8GB/4vCPU (`s-4vcpu-8gb`, $48/mo), `nyc3`, Ubuntu 24.04. Chosen over cheaper
  Hetzner ONLY because employer pays DO ($0 to user). Location Querétaro MX → nyc3/sfo3 nearest.
- **Tailscale** overlay, `tag:server`, one-time pre-auth key baked into cloud-init.
- **OpenTofu + cloud-init**, thin Makefile wrapper.
- Agent auth = **Claude subscription** via `claude setup-token` (no API billing), pushed over SSH
  post-boot (never in metadata).
- Secrets in **`.env`** (gitignored).
- Control surface: native ssh+tmux (Arch), Termux (Pixel), Blink (iPad), **mosh** over the tailnet.
- **Born-locked** security: firewall denies all inbound from birth; box joins the tailnet outbound;
  no public-SSH bootstrap; no human "verify before lock" gate. This is the core idea (ADR 0001).

## DONE
- All infra code, cloud-init, 8 scripts, Makefile, README, SETUP, CONTEXT, ADR.
- Renamed `dot_robot` → `robot-wrangler` (dir + `make robot-wrangler` command + docs). Zero leftovers.
- `doctl` authed (rmezar@gmail.com); size/image/region slugs confirmed.

## NOT done — needs YOU (secrets / can't be scripted)
Everything is in **SETUP.md**, in order. Summary:
1. `sudo pacman -S opentofu tailscale mosh`
2. `sudo tailscale up`; Tailscale app on Pixel + iPad
3. Tailscale ACL: add `tag:server` — **before** minting the key
4. Mint: DO API token · Tailscale auth key (one-time / pre-approved / `tag:server`) · `claude setup-token`
5. Laptop key → `devices/arch.pub`
6. Fill `.env`
7. `make preflight` → `make robot-wrangler`

## Resume point (tomorrow)
Open **SETUP.md**, start at step 1. First milestone: `make preflight` passes. Then
`make robot-wrangler` for the first box. Consider `git commit` once it applies clean.

## Parked (later, not v1)
- Notifications (ntfy/Telegram → phone when Claude finishes/needs approval). Easy cloud-init add.
- Chat bridge (Telegram/Discord → drive Claude from phone w/o SSH). Higher risk (RCE surface); lock
  to your user, bind to tailnet.
- Nightly git-push backup of box data once real projects exist.
- Autostart Claude in tmux on boot (currently manual `claude`).

## Gotchas
- Box is **cattle**. If Tailscale fails to join on first boot → unreachable except DO console →
  destroy + recreate, don't debug in place.
- Missing `tag:server` ACL is the most likely first-run failure.
- `backup_policy` needs DO provider ≥ 2.43 (pinned `~> 2.43`).
- `robot` user has NOPASSWD sudo (convenience; access already key + tailnet gated).
- DO account is a personal gmail but **employer-billed** — mind ToS/data.
- Scaffold is committed; the `SETUP.md`/`HANDOFF.md` docs are staged, not yet committed.
