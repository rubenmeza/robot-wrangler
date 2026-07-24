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
the phone (Termux), and the tablet (Blink). Each is a distinct entry point holding its own key.

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
