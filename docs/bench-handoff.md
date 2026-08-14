# Handoff — implementing the open bench

Design is settled and recorded: see [ADR 0009](adr/0009-workstation-second-agent-host.md) and the
`Agent host` / `Workstation (the bench)` / `Open bench` terms in [CONTEXT.md](../CONTEXT.md). **No
code has been written yet.** This file is the build list, plus the facts already verified so the next
session doesn't re-derive them. Delete it once the work lands.

## Verified facts about `omarchy` (checked 2026-08-13)

| Fact | Value |
|---|---|
| Tailnet name / IPv4 / IPv6 | `omarchy` · `100.104.10.77` · `fd7a:115c:a1e0::3201:abb` |
| Tailnet tags | none (owner-owned, unlike `robot` which is `tag:server`) |
| `sshd` | `disabled` **and** `inactive` — closed is already today's real state |
| Firewall | `ufw` active; `iptables`/`nft` inactive; `firewalld` absent |
| Existing sshd drop-ins | `20-systemd-userdb.conf`, `99-archlinux.conf` |
| Installed | `herdr`, `tmux`, `mosh`, `claude`, `codex` |
| Not installed | `moshi-hook` |
| Shell | bash; `~/.bashrc` uses the `[ -f X ] && source X` idiom |
| tmux habit | many sessions, one per project (`robot-wrangler`, `wp-calypso`, …) |
| Sleep | `hypridle` inactive, no lid override → logind default suspends on lid close |
| Device keys | `devices/{arch,ipad,pixel}.pub`; no `~/.ssh/authorized_keys` here yet |

## Check these first — the session stopped mid-verification

1. `ssh -V` — openssh ≥ 9.8 splits sessions into a separate `sshd-session` process. The kill pattern
   in `bench close` depends on which name this box uses.
2. `systemctl cat sshd.service` — if `KillMode=process`, live sessions survive `systemctl stop` and
   must be killed explicitly; if it's the default control-group kill, `stop` already takes them.
3. Whether `sshd.socket` exists/is enabled on Arch — socket activation would reopen the door behind
   `bench close`. Mask it if present.
4. `sudo ufw status verbose` — what's already allowed before adding the tailscale0 rules.

## Build list

- **`scripts/bench.sh`** — one script, subcommands `setup | open | close | status`. Match the house
  style: `set -euo pipefail`, `cd "$(dirname "$0")/.."`, `source scripts/_common.sh`, shellcheck-clean
  at `--severity=warning` (preflight lints `scripts/*.sh`, so it gates automatically).
  - `setup` (one-time, sudo): render the sshd drop-in with this box's tailnet addresses; ensure
    `sshd` is **not** enabled at boot; seed `~/.ssh/authorized_keys` (mode 600) from
    `devices/pixel.pub` + `devices/ipad.pub` — never `arch.pub`; add the permanent ufw rules; add the
    guarded rc line; finish with `sshd -t`. Idempotent — safe to re-run after adding a device key.
  - `open`: verify tailscale is up, then `sudo systemctl start sshd`. Print the reminders: lid stays
    up, work must be inside tmux.
  - `close`: `sudo systemctl stop sshd`, then kill `mosh-server` (owned by `pollo` — `mosh-client`,
    used for outbound sessions to the box, must survive) and any inbound sshd session processes.
    Report what was killed.
  - `status`: unit state, whether it's enabled at boot, actual listening addresses (`ss -tlnp`), live
    inbound sessions, `mosh-server` count, and the tmux session list. This is the "did I leave it
    open?" answer, so it must not guess.
- **`files/bench-sshd.conf.tmpl`** → rendered to `/etc/ssh/sshd_config.d/10-bench.conf`:
  `ListenAddress` for the two tailnet addresses only, `AllowUsers pollo`, `PermitRootLogin no`,
  `PasswordAuthentication no`, `AuthenticationMethods publickey`. No collision with the two existing
  drop-ins, so the `10-` prefix is for readability, not precedence.
- **`files/bench-attach.sh`** — sourced from `~/.bashrc`. Attach the most recent tmux session only
  when `$SSH_TTY` is set and `$TMUX` is empty, and never for non-interactive shells (so `scp`,
  `rsync` and `ssh omarchy <cmd>` keep working).
- **Makefile**: `bench-setup`, `bench-open`, `bench-close`, `bench-status`, added to `.PHONY` with
  `##` help strings.
- **`moshi-hook`** on the bench: install, `moshi-hook pair && moshi-hook install && moshi-hook service
  install` as a systemd `--user` service, always running (ADR 0007). Open question: whether the same
  `MOSHI_PAIRING_TOKEN` pairs both hosts or the bench needs its own — find out at pair time.
- **`scripts/preflight.sh`**: it currently hard-fails on box-only secrets. Bench work shouldn't need
  `DIGITALOCEAN_TOKEN`. Either leave preflight alone (bench targets don't call it) or split the checks
   — decide when writing `bench-setup`.
- **Tests** (`scripts/test-bench.sh`, run from `make test`): unit-test the pure helpers only, in the
  style of `test-common.sh` — inject fakes at the seams, no sudo, no listener. Good candidates: the
  tailnet-address resolver for the drop-in, and the "which processes would close kill" selector,
  which should be a pure function over a process list so it can be tested without killing anything.
- **README**: a bench section, and update the intro — the repo is now two hosts, not one.

## Device-side, manual

In Moshi on the Pixel and iPad: add a host → `omarchy` / `100.104.10.77`, user `pollo`, reusing the
existing device key. Transport mosh.

## Do not re-litigate

Decided, with reasons in ADR 0009: `sshd` over Tailscale SSH · full shell as `pollo` over a sandbox
user · hard close over soft · permanent ufw rules over toggled · plain `sudo` over NOPASSWD · lid
discipline over a sleep inhibitor · no PR-only rule on the bench.
