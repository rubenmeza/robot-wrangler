# Context — robot-wrangler

Glossary for the owner's agent hosts — machines that run an AI coding agent, reachable only from
the owner's own devices over a private network. This file is a glossary, not a spec — no
implementation details.

## Terms

### Agent host
A machine that runs the agent and holds the live session devices attach to. There are two, and
they are not alike: the Robot server (sealed, always-on, in the cloud) and the Workstation
(trusted, opened by hand, on the desk). "Which host?" is a real question the owner answers per
piece of work.

### Robot server (the box)
The always-on cloud Agent host. Tended like a pet (named, cared for), not one of a fleet. Called
"the box" or by its hostname `robot`.

### Workstation (the bench)
The owner's own machine (`omarchy`), acting as the second Agent host. Unlike the box it is not
sealed: the agent runs as the owner, on the owner's real repositories, keys and dotfiles. It is
also not always reachable — it accepts inbound sessions only while the bench is open. Called "the
bench". See ADR 0009.

### Open bench
The state in which the Workstation accepts inbound sessions from the Control surface. Shut by
default and after every reboot; opened deliberately, by hand, at the keyboard, for as long as the
owner is away. Closing is *hard*: no attachment survives it, though the sessions and the agents
inside them do. The mirror image of Born-locked — the box is sealed by provisioning and stays
that way; the bench is a door with a hand on it.

### Agent
Claude Code running on an Agent host inside a persistent terminal session, doing the actual work.
The reason the hosts exist.

### Control surface
The set of clients the owner uses to reach and drive the agent: the laptop (native terminal), and
the phone + tablet (Moshi). Each is a distinct entry point holding its own Device key. The laptop
sits on both sides of the model — it is a Control-surface client for the box *and* the Workstation
the phone and tablet reach.

### Moshi
The mobile Control-surface client (iOS/Android app) on the Pixel and iPad, replacing Blink and
Termux. Speaks SSH/mosh over the tailnet and drives whatever Multiplexer the box runs. It is a
client only — never a multiplexer, never installed on the box.

### Multiplexer
The on-host program that owns the persistent sessions every device attaches to — the thing that
makes handoff work. On the box: exactly one Multiplexer owning exactly one session, `robot`, fixed
at provision time and never chosen per attach, so no two devices can land in different sessions.
On the bench that invariant does not hold and is not wanted: tmux runs many sessions, one per
project, and an arriving device lands in the most recent. The choice is really a *profile*: it also
fixes the transport — Herdr pairs with plain SSH (full-fidelity TUI), tmux pairs with mosh
(drop-proof). _Avoid_: "session manager".

### Herdr
An agent-aware Multiplexer (FOSS binary on the box) that can play the Multiplexer role instead
of tmux, adding semantic agent state (blocked / working / done / idle) that plain tmux lacks.

### Tailnet
The owner's private Tailscale network. Every Agent host and every control-surface device is a
member. The only path to either host.

### Born-locked
How the box is provisioned: shut to the public internet from the moment it boots. There is no
"log in over the public IP first" step — access exists only through the tailnet, established by
the box itself on first boot.

### Pre-auth key
A single-use Tailscale key handed to the box at creation so it can join the tailnet unattended.
Spent the instant it is used, so a later leak is worthless.

### Device key
A per-device SSH keypair. One per control-surface device — the key identifies the *device*, not
the host, so the same public half admits that device to either Agent host. The public halves are
the only credentials that can open a session. Never one shared key. Revoking a lost device means
deleting its tailnet node *and* pulling its public half.

### Handover
The on-box briefing document (`CLAUDE.md`) that tells the agent what the box is, how it is
reached, and the standing rules it must never break. Priming, not configuration.

### Provisioner
The single ordered first-boot script (`files/provision.sh`) that turns a bare, born-locked droplet
into the robot: joins the tailnet, installs the agent and multiplexer, sets the git identity, marks
readiness. It is the imperative *how*, split out from the cloud-init *manifest* — the declarative
*what* (packages, user, files) that ships it and invokes it with one line. Runs once as root;
shellcheck-clean and container-runnable. See ADR 0006.

### Break-glass
The only recovery path if the tailnet route is lost: the provider's out-of-band web console.
Not an everyday door.

### Agent GitHub access
The robot acts on GitHub as the owner's own identity, via a token that is present on every
spawn. It reads issues and delivers work as pull requests. It never writes to `main`. The
token is delivered and held exactly like the agent's other secret — see Handover's standing
rules — and can be revoked instantly, which is the kill-switch.

### PR-only delivery
The standing rule for how the robot's GitHub work lands: always a feature branch and a pull
request, never a direct push to `main` or any protected branch. The owner reviews and merges.
