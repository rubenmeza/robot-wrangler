# Tailnet policy as code, in its own OpenTofu state

The tailnet policy (ACLs, `tagOwners`) moves from hand edits in the Tailscale admin console into the
repo, applied by OpenTofu's Tailscale provider from a **separate root module with its own state**.
It is now the security boundary for Always-on Personal hosts (ADR 0010), so it must be reviewed,
reproducible, and impossible to lose by accident.

## Why its own state

The robot is rebuilt and torn down routinely (`make teardown`). If the policy shared the robot's
state, a teardown would destroy the policy resource, and Tailscale falls back to its default policy:
**allow all**. That would let the robot reach every Personal host: the exact path ADR 0010 forbids,
opened silently by a routine command. A separate root means robot lifecycle commands can never touch
the policy.

## Considered options

- **Same root with `prevent_destroy`:** blocks the full teardown instead of skipping the policy,
  forcing targeted destroys. A footgun kept, not removed.
- **Policy file in the repo, pasted into the console by hand:** no new secret, but the repo and the
  live policy drift, and nothing tells you when.

## Consequences

- A Tailscale API credential joins `.env`, for the policy root only.
- The policy ships first, before any Personal host opens a door: the boundary exists before the
  thing it bounds.
- `SETUP.md`'s manual "define `tag:server`" step becomes part of the policy.
