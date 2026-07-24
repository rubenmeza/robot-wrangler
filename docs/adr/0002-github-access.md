# 2. Robot acts as the owner on GitHub via a broad, long-lived token

Date: 2026-07-23

Status: Accepted

## Context

The robot needs to work issues from the owner's repositories: read an issue, write code,
and open a pull request. Those repos span the owner's personal account **and** several GitHub
organizations. The credential has to be present the moment any freshly-spawned box comes up
("ready every spawn"), and rotating it must not become a chore the owner hits mid-trip from a
phone.

This sits in tension with ADR 0001's tight posture. The box runs an agent with broad shell
access that can read its own secrets, so any GitHub credential we place on it is reachable by a
confused or compromised agent. The instinct is a fine-grained, minimal-permission,
short-lived token.

Two facts broke that instinct:

- **Fine-grained PATs need per-org opt-in.** They only reach an organization's repos if that
  org has enabled fine-grained PAT access. Orgs the owner does not administer are simply
  unreachable, and even owned orgs add a setup step per org.
- **Expiry only adds friction, never removes it.** Spawning a box already re-pushes the token
  automatically from `.env`; expiry does nothing there. Its only effect is forcing a browser
  re-mint when the token lapses — precisely the on-the-go interruption the owner wants to avoid.

## Decision

The robot authenticates to GitHub as the **owner's own identity** using a **classic Personal
Access Token with the single `repo` scope**, granted to **all** repositories (personal and org),
with **no expiry**.

Containment comes from three narrower choices, not from scoping the token down:

1. **`repo` scope only** — no `delete_repo`, no `workflow` (cannot edit CI files), no
   `admin:org`. The token can move code and drive issues/PRs, but cannot delete repositories,
   tamper with Actions, or manage organizations.
2. **PR-only delivery** — a standing rule in the on-box `CLAUDE.md`: work lands as a feature
   branch and a pull request, never a direct push to `main`. Nothing reaches a protected branch
   without human review.
3. **Same secret rails as the agent token** — the PAT is pushed over SSH into `~/.robot-env`
   (mode 600) after the box is on the tailnet, never placed in cloud-init/instance metadata
   (per ADR 0001). On the box, `git` routes github.com HTTPS auth through `gh`, which reads the
   token from the environment; the token exists in exactly one 0600 file.

The **kill-switch is instant revocation** from the GitHub settings UI — a ~10-second action from
any device, including the phone — which is treated as the real bound on a leak, in place of a
short expiry.

## Consequences

- A broad, forever token lives on the box. If the agent is subverted or the box is breached,
  the attacker gets code/issue/PR write on every repo the owner can access, until the owner
  notices and revokes. This is accepted, bounded by the `repo`-only scope, the PR-only gate,
  the tailnet-locked box, the `CLAUDE.md` non-exfiltration rule, and instant revoke.
- Zero access friction: any repo — personal or org — works with no per-org setup, and the box
  never breaks on token expiry.
- Rotation is deliberate, not scheduled: update `GH_TOKEN` in `.env` and re-run the secret push
  (or just re-spawn). There is no automatic rotation.
- The owner's git identity (`Ruben Meza <rmezar@gmail.com>`) is configured on the box, so the
  robot's commits are attributed to the owner and its gmail appears in public-repo history — the
  same as the laptop already does.

## Alternatives considered

- **Fine-grained PAT, minimal permissions (Contents/Issues/PRs), allowlisted repos:** the
  safest option and the initial lean. Rejected because it cannot reach org repos without each
  org opting in — including orgs the owner does not administer — which defeats "work on issues
  from my repos."
- **Short / bounded expiry (30–90 days):** rejected. It buys a smaller leak window at the cost
  of a recurring browser re-mint that lands at unpredictable times (e.g. on the phone, away from
  the desk). Instant revoke covers the same threat on demand without the standing chore.
- **Dedicated bot/machine user:** cleaner separation and easy revoke by removing the
  collaborator, but adds a second GitHub account to manage and per-repo/org invitations.
  Rejected as overkill for a single owner's personal + org repos.
- **GitHub App with short-lived installation tokens:** the best rotation and scoping story, but
  the most complex to wire headless (app private key on the box, a token-minting step) and still
  needs per-org installation. Rejected as disproportionate for one user.
- **SSH deploy keys per repo:** one key per repo does not scale to "all repos" and says nothing
  about issue/PR operations. Rejected.
