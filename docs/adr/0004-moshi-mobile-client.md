# Moshi as the mobile control-surface client

The Pixel and iPad reach the box through **Moshi** (a closed-source iOS/Android terminal app),
replacing Blink (iPad) and Termux (Pixel). It speaks SSH/mosh over the tailnet and drives whatever
Multiplexer the box runs — it is a client only, never installed on the box. The laptop keeps its
native terminal (Moshi is mobile-only).

## The trade-off

The rest of the stack is deliberately FOSS/OpenTofu. Moshi is a proprietary, optionally-paid app —
a real deviation. It wins because the project's stated top goal is a *mobile-first* control surface,
and Moshi is purpose-built for driving remote coding agents from a phone: mosh transport, in-app
key management, agent-status kanban, and push notifications. Blink/Termux are generic terminals
that do none of that natively.

## Cost

Start on Moshi's **free** tier — it already covers SSH, mosh, agent monitoring, and push
notifications — so the deviation costs $0. Pro ($7.99/mo · $69.99/yr · $199 lifetime, up to 3
devices/account) is opt-in only if a Pro feature (e.g. voice-to-terminal) later earns it.

## Consequences

- Moshi generates its own SSH keypair in-app; `devices/ipad.pub` and `devices/pixel.pub` are
  regenerated from Moshi and the old Blink/Termux-origin keys retired.
- Moshi push (free) + herdr agent-state becomes the notification path, retiring the parked
  ntfy/Telegram plan. Verify push fires while the app is closed; if it's connection-only, revisit.
- Lock-in is shallow: Moshi is just an SSH/mosh client. Dropping it means going back to any SSH
  client with a device key — no box-side change.
