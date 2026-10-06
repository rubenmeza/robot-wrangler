# The laptop as a Personal host, opened by hand

> **Amended by [ADR 0010](0010-personal-hosts-reachability-modes.md) and [ADR 0011](0011-t3-code-beside-ssh.md):**
> The laptop is one Personal host in Open-by-hand mode; personal machines may also be
> Always-on, bounded by tailnet policy instead of time. Closing also turns off T3's Tailscale Serve.

The original decision made the laptop a second **Agent host** — a peer to the box, not a replacement —
reachable from the Pixel and iPad over the same tailnet. It is shut by default and opened
deliberately with `make open` for as long as the owner is away from the desk, then hard-closed
on return. This puts a listener on the owner's personal machine, which reads like a contradiction of
[ADR 0001](0001-no-public-ingress.md), and widens this repo from "provision the box" to "wrangle my
agent hosts". Both are deliberate.

## Why a second host at all

The box and the laptop are good at different things. The box is always on: it keeps working while
the laptop is shut, and it is sealed, so an agent loose on it can damage nothing that matters. The
laptop is where the owner's actual repositories, toolchain, dotfiles and half-finished branches live;
agent work that needs *this* working tree can only happen here. Before this decision, walking away
from a laptop session meant abandoning it. Now it can be picked up on the phone.

## Why open-by-hand instead of always reachable

The box earns permanent tailnet presence because it holds nothing personal. The laptop does the
opposite: an inbound session lands in a full shell as `pollo`, with the owner's SSH keys (including
the one that opens the box), gh auth, and `~/Dev`. A sandboxed agent user was considered and
rejected — it cannot see the repositories that are the entire reason to reach the laptop, so it would
buy isolation by removing the point.

Given that blast radius, the mitigation is *time*, not privilege: the door exists only during the
window the owner intends to be mobile, and opening it requires physical presence at the keyboard
(plain `sudo`, no NOPASSWD carve-out). `sshd` is never `enable`d, so a reboot is shut. So the two
hosts are not inconsistent — they are the same principle, minimum standing exposure, applied to
machines with different contents.

## Considered options

- **Tailscale SSH** instead of `sshd` — no keys, ACL-checked, connection logging, one-call toggle.
  Rejected: it depends on admin-console ACL edits, its mosh story is murkier, and it is a second
  auth model alongside the device keys the box already uses. `sshd` bound to the tailnet addresses
  reuses `devices/*.pub` unchanged.
- **Separate agent user on the laptop** — rejected above.
- **Sleep inhibitor held for the duration of remote mode** — rejected in favour of a discipline:
  leave the lid up. Nothing in software makes a suspended laptop reachable, and an inhibitor that
  outlives a forgotten `close` is its own hazard.
- **Soft close** (stop new logins, let live sessions run out) — rejected. `mosh-server` outlives
  `sshd`, so a soft close would leave a live shell in the owner's pocket for hours after the door was
  believed shut. Close means closed.

## Consequences

- `close` kills attachments, not work: tmux sessions and the agents in them survive; a phone
  still attached is dropped mid-sentence. `status` is therefore trustworthy.
- Firewall rules (22/tcp, 60000-61000/udp on `tailscale0`) are permanent, not toggled — with `sshd`
  stopped there is nothing behind them, and a toggle that half-fails leaves state that lies.
- `sshd` binds the tailnet addresses only, so on café wifi there is no listener on that NIC at all,
  independent of ufw.
- The lid stays up; agent work starts inside tmux or T3 so it can go mobile; a device that can
  reach the laptop can hop to the box from it.
- The laptop inherits no [PR-only delivery](../../GLOSSARY.md) rule. That rule protects the owner from
  a sealed agent acting unsupervised; on the laptop the owner is the operator, and a rule that only
  binds while mobile is unenforceable anyway — nothing on the box knows where the owner is sitting.
- Push (ADR 0007) applies to both hosts: `moshi-hook` runs on the laptop too, always, so a laptop agent
  can raise the phone. Whether one `MOSHI_PAIRING_TOKEN` pairs several hosts remains
  **UNVERIFIED** until the first real enrollments.
