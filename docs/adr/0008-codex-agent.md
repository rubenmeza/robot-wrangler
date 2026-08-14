# Codex as a second on-box agent

The box runs **OpenAI Codex CLI** alongside Claude Code. Both live in `~/.local/bin`, both attach
the same `robot` session, and both feed Moshi push (ADR 0007). Codex is authed from a **ChatGPT
subscription**, not an API key — matching how Claude runs on a subscription token, so a second agent
costs $0 extra rather than metered API billing.

## Install

The box has no Node.js (we install agents via their own `curl | sh` scripts, never npm). Codex ships
an official **standalone installer** — `curl -fsSL https://chatgpt.com/codex/install.sh | sh` — that
drops a static musl binary into `~/.local/bin/codex` with no runtime dependency. The manifest also
adds the `bubblewrap` package: Codex sandboxes tool calls with it, and without it Codex falls back to
a bundled copy and warns on every run.

## Auth: subscription via auth.json, not an API key

Codex's browser-OAuth login can't run on a headless, born-locked box. Two headless paths exist:

- **API key** (`codex login --with-api-key`) — fully automatable but metered per token.
- **ChatGPT subscription** — device-code login (`codex login --device-auth`) prints a URL + one-time
  code; you approve on your phone. It writes `~/.codex/auth.json` (access + refresh tokens, `0600`).
  Codex refreshes the token in place, so one login lasts.

We chose the subscription. The credential is a **file**, so it rides a slightly different channel
than the env-var secrets: `CODEX_AUTH_JSON` in `.env` points at a local copy of `~/.codex/auth.json`
(captured once, kept `0600` outside the repo), and `robot-auth.sh` pushes it to the box over SSH —
never through cloud-init/metadata, same discipline as the Claude and GitHub tokens.

## Notifications

`moshi-hook install` detects the Codex binary and registers Codex's hooks at `~/.codex/hooks.json`
(shown as `codex  current` in `moshi-hook status`). No extra wiring — Codex agent events push to the
phone exactly like Claude's.

## Consequences

- A rebuild re-pushes `auth.json` from `CODEX_AUTH_JSON` automatically. If it goes stale (revoked or
  rotated), re-run `codex login --device-auth` on the box and re-capture the file — same ritual as
  the other credentials.
- **Open guardrail gap.** git on the box routes github.com through the owner's `gh` credential helper,
  so Codex — like Claude — *can* push to `main`. Claude is restrained by the `~/CLAUDE.md` Handover
  brief (ADR 0002: "PR only, never push to main"), but Codex reads `AGENTS.md`, not `CLAUDE.md`, and
  no equivalent brief is installed for it yet. Until one is (e.g. a shared `~/.codex/AGENTS.md`
  carrying the same rules), the ADR 0002 workflow is convention-only for Codex. Tracked as the next
  step.
