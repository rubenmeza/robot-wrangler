# 1. No public ingress — the box is born locked, reachable only via Tailscale

Date: 2026-07-22

Status: Accepted

## Context

The box runs an AI agent with broad shell access and a long-lived subscription token. The
reference we started from (a tweet) sets this up manually: create the box with public SSH, log
in over the public IP, install the overlay network, verify it by hand, and only THEN close the
firewall — with an explicit human "verify before you lock" gate.

We want that whole thing automated behind `make robot-wrangler`. Automating a
harden-*after*-exposure sequence is exactly where people brick boxes: lock the firewall one step
too early and you lose the only way in.

## Decision

The box has **no public ingress at any point**. The DigitalOcean cloud firewall denies all
inbound from creation (outbound-only). Reachability is established outbound: cloud-init installs
Tailscale with a single-use, pre-authorized, tagged key and joins the tailnet on first boot. SSH
is key-only, root and passwords disabled, and only ever transited over the tailnet. The
long-lived agent token is never placed in instance metadata — it is pushed over SSH after the
box is on the tailnet.

## Consequences

- No exposure window and no human "verify before lock" gate — the risky manual steps disappear,
  so the flow is safe to automate.
- The box is **cattle**: if Tailscale fails to come up on first boot, the box is unreachable
  except via the provider console. We do not debug it in place — we `make robot-destroy &&
  make robot-wrangler`. Acceptable only because the box holds nothing precious until data is
  deliberately added and backed up.
- The pre-auth key must be single-use and tagged (tagged nodes don't expire), so a leaked
  `user_data` blob yields only a spent key.
- Break-glass is the provider web console, nothing else.

## Alternatives considered

- **Manual harden-after-exposure (the tweet's sequence):** rejected — not safely automatable;
  the human gate is the whole point of its safety.
- **Cloudflare Tunnel:** aimed at exposing services to the public web, which we explicitly do
  not want; adds an account and a daemon for no benefit to a private control box.
- **Tailscale SSH (no OpenSSH keys):** simpler auth, but no mosh support and no per-device keys —
  both of which we chose, for mobile resilience and a clear one-key-per-device model.
