# Personal hosts, each enrolled with a reachability mode

Any of the owner's PCs or laptops can be **enrolled** as a **Personal host**: an Agent host that is
also a Control-surface client for the others. Enrollment runs on the machine itself, at its keyboard,
and fixes two things: an owner-chosen tailnet name (two Omarchy machines would otherwise both be
`omarchy`) and a **Reachability mode**: **Always-on** or **Open by hand**. The desk PC is Always-on;
the laptop stays Open by hand. This generalises [ADR 0009](0009-workstation-second-agent-host.md)
from one laptop to any machine, and amends its central claim that a personal machine must never be
standing-reachable.

## Why Always-on is allowed at all

ADR 0009 bounded the laptop by *time*: the door exists only while the owner is away, and opening it
needs physical presence. That defence is useless for the real use case now: the PC stays home,
always running, and the owner drives it from the laptop or phone from anywhere. Requiring a hand on
the PC's keyboard to open it would defeat the point.

So an Always-on host is bounded by *who*, not *when*: the tailnet policy (ADR 0012) admits only the
owner's own devices to Personal hosts. The robot (`tag:server`) can reach none of them: it runs an
unsupervised agent, and a confused or compromised robot must not be one hop from the owner's keys.

## Considered options

- **Separate, limited agent user on Always-on hosts.** Rejected for the same reason 0009 gave: it
  cannot see the repositories, keys and dotfiles that are the reason to use the PC.
- **Open by hand everywhere.** Rejected: opening the PC before leaving the house is a step the
  owner will forget, and the cost of forgetting is losing the PC for the whole trip.
- **Always-on everywhere.** Rejected for the laptop: it travels, sleeps, and sits on untrusted
  networks; 0009's time-boxing still fits it.

## Consequences

- Power follows the mode: enrollment disables suspend on an Always-on host so agents never stall;
  an Open-by-hand host is left alone and keeps 0009's lid discipline.
- Every enrolled host registers its own Device key (`devices/<name>.pub`). Each host admits every
  device key except its own; enrolling a new machine means re-running enrollment on the others.
- No PR-only rule on any Personal host, Always-on included: the owner is the operator there,
  wherever they are sitting.
- `moshi-hook` runs on every Personal host (ADR 0007), so any host's agent can raise the phone.
- The rest of 0009 stands for Open-by-hand hosts: `sshd` over Tailscale SSH, hard close, permanent
  firewall rules, plain `sudo`, tmux with attach-most-recent.
