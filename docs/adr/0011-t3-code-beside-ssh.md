# T3 Code beside SSH, published only inside the tailnet

Every Agent host, the robot included, runs a **T3 Code** server as a user service,
published to the tailnet with **Tailscale Serve** and admitted to by per-device **Pairings**. T3 is
the main way to start and drive agents from any device: the laptop's desktop app in remote-only
mode, or the T3 phone and tablet apps. SSH stays as a second door for terminal work and Moshi:
Herdr on the robot, tmux on Personal hosts.

## Why both doors

T3 gives one agent UI across hosts and devices, with threads and agent processes living on the host,
so walking away from a client abandons nothing. SSH is the proven path (Moshi push, mosh over bad
networks, the box's whole Handover) and the only way in when T3, which is still early software,
breaks. Dropping either would trade a working path for a nicer one, or the reverse.

## Why Tailscale Serve, not T3 Connect or a bound port

- **T3 Connect** (T3's cloud relay with account sign-in) would cut the number of Pairings, but it
  routes access to the agents through a third-party service. That breaks the rule that the tailnet is
  the only path to any Agent host.
- **Binding `--host 0.0.0.0`** puts a listener on every interface, including café wifi. Serve keeps
  the server on loopback and lets `tailscaled` publish it over HTTPS to tailnet members only. HTTPS
  is also what the hosted T3 web app requires.

## Consequences

- Pairings are per (device, host). Pairing is done by hand by scanning `t3 pair`'s one-time code;
  revoking is scripted: one command revokes a lost device's Pairings on every reachable host, along
  with its tailnet node and SSH public key.
- **Who turns Serve on depends on the mode.** On the robot and Always-on hosts, T3 owns it
  (the user service sets `T3CODE_TAILSCALE_SERVE=true`). On an Open-by-hand host, T3 runs loopback-only and the repo's `open` and
  `close` switch Serve themselves: T3 re-enables Serve every time it starts, so if T3 owned it, any
  restart (update, crash) would silently reopen a closed host. Serve config also survives reboots,
  so an Open-by-hand host must also turn it off at boot.
- On an Open-by-hand host, `close` shuts both doors: it stops `sshd`, kills inbound sessions, and
  turns Serve off. The T3 server keeps running on loopback, so local use and running agents survive.
- A T3 server restart kills running turns (a client disconnect does not). Every host enables
  `continueThreadsAfterServerUpdate`, so an update or crash resumes the agent instead of leaving
  it stopped.
- Serve needs MagicDNS and HTTPS certificates on the tailnet, and the host's user set as the
  Tailscale operator; without the operator setting T3 only logs a warning and stays unreachable.
  The tailnet policy (ADR 0012) must grant the owner's devices `tag:server:443` for the robot.
- The repo owns `t3code.service` and its stable launcher. Native `t3 service install` starts
  `serve` immediately and logs pairing passwords before safe overrides can be applied. Our unit
  runs `t3 start --mode web --no-browser --host 127.0.0.1 --port 3773 --log-level warn`, with
  `T3CODE_TRACE_MIN_LEVEL=Warn` and automatic project bootstrap disabled. Both startup and trace
  INFO logs are suppressed. Always-on launchers wait for Tailscale readiness; the robot also
  waits for post-boot agent credentials, keeping them out of the Provisioner. `t3 update` updates the runtime; restart `t3code.service` afterward.
- Anyone holding a Pairing has full agent and terminal control on that host. Treat pairing codes like
  passwords: never screenshot or log them.
