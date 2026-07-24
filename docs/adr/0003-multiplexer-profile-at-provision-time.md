# Multiplexer profile fixed at provision time

The box runs exactly one on-box Multiplexer for the shared `robot` session, chosen by a
provision-time variable (`MUX`, default `herdr`), never per attach. The choice is a coupled
*profile*: `herdr` pairs with plain SSH (full-fidelity Rust/Ratatui TUI, agent-state kanban);
`tmux` pairs with mosh (battle-proven, survives cellular drops). Both binaries are installed on
every box; the variable only decides which one auto-attach launches. Switching = rebuild.

## Why not choose at attach time

The killer feature is seamless multi-device handoff: every device auto-attaches the *same* live
`robot` session (`herdr --session robot` / `tmux new -A -s robot`). If the multiplexer were a
per-attach choice, two devices could land in different multiplexers — two separate live sessions,
handoff broken. Fixing it at provision time keeps one canonical session per box. This also fits
the existing cattle model: adding a device key already requires a rebuild, so does swapping mux.

## Why couple transport to the multiplexer

mosh's terminal model downsamples 24-bit colour to 256 and has no native scrollback, which dulls
herdr's colour-coded agent kanban; tmux over mosh is long-proven. herdr therefore rides plain SSH
(Moshi's own session-recovery + Tailscale cover drops), while tmux keeps mosh. One variable
selects both, so the two never mismatch.

## Consequences

- `robot-attach.sh` and the on-box `.bashrc` auto-attach branch on `MUX` for BOTH the multiplexer
  command and the transport.
- `MUX` lives in `.env` (`TF_VAR_...`), the single source read by both OpenTofu and the attach
  scripts.
- Verify on first herdr build: concurrent multi-client attach (two devices, one live pane) — the
  handoff invariant depends on it. herdr's docs imply support but don't state it outright.
