# Context — robot-wrangler

Glossary for the "robot server": a single cloud box that runs an AI coding agent, reachable
only from the owner's own devices over a private network. This file is a glossary, not a spec —
no implementation details.

## Terms

### Robot server (the box)
The single always-on cloud host that runs the coding agent. Tended like a pet (named, cared
for), not one of a fleet. Called "the box" or by its hostname `robot`.

### Agent
Claude Code running on the box inside a persistent terminal session, doing the actual work.
The reason the box exists.

### Control surface
The set of clients the owner uses to reach and drive the agent: the laptop (native terminal),
and the phone + tablet (Moshi). Each is a distinct entry point holding its own key.

### Moshi
The mobile Control-surface client (iOS/Android app) on the Pixel and iPad, replacing Blink and
Termux. Speaks SSH/mosh over the tailnet and drives whatever Multiplexer the box runs. It is a
client only — never a multiplexer, never installed on the box.

### Multiplexer
The on-box program that owns the single persistent `robot` session every device attaches to —
the thing that makes handoff work. Exactly one runs per box; which one is fixed at provision
time, never chosen per attach. The choice is really a *profile*: it also fixes the transport —
Herdr pairs with plain SSH (full-fidelity TUI), tmux pairs with mosh (drop-proof). _Avoid_:
"session manager".

### Herdr
An agent-aware Multiplexer (FOSS binary on the box) that can play the Multiplexer role instead
of tmux, adding semantic agent state (blocked / working / done / idle) that plain tmux lacks.

### Tailnet
The owner's private Tailscale network. The box and every control-surface device are members.
The only path to the box.

### Born-locked
How the box is provisioned: shut to the public internet from the moment it boots. There is no
"log in over the public IP first" step — access exists only through the tailnet, established by
the box itself on first boot.

### Pre-auth key
A single-use Tailscale key handed to the box at creation so it can join the tailnet unattended.
Spent the instant it is used, so a later leak is worthless.

### Device key
A per-device SSH keypair. One per control-surface device. The public halves are the only
credentials that can open a session on the box. Never one shared key.

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
