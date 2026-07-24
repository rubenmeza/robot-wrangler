# devices/

One `*.pub` file per control-surface device. **Public keys only** — safe to commit.
Every `*.pub` here is seeded into the robot user's `authorized_keys` on the box.

> If this directory has zero `*.pub` files, provisioning locks you out. Add at least one
> (your laptop) before running `make robot-wrangler`. `preflight` checks this.

## Laptop (Arch)
```bash
ssh-keygen -t ed25519 -f ~/.ssh/robot_ed25519 -C robot-arch
cp ~/.ssh/robot_ed25519.pub devices/arch.pub
```
Point the scripts at the private half: `export ROBOT_SSH_KEY="$HOME/.ssh/robot_ed25519"` (in `.env`).

## Pixel 8 Pro + iPad Air M1 (Moshi)

Both mobile devices use the **Moshi** app (App Store / Google Play) — one app, same steps on
each — replacing the old Termux (Pixel) and Blink (iPad) setups (ADR 0004). In Moshi, generate a
new SSH key (ed25519), copy its **public** half, and paste it into the matching file on your
laptop: `devices/pixel.pub` and `devices/ipad.pub`. Public keys only — never paste a private key.

Connection, per device: install the Tailscale app and sign in (so the box is reachable on the
tailnet), then add a host in Moshi pointing at the `robot` tailnet name/IP, user `robot`, with the
key above. Transport follows the box's multiplexer profile (ADR 0003): **herdr → SSH**,
**tmux → mosh**. On login you auto-attach the shared `robot` session — same one the laptop sees.

After adding a device key to an already-running box, re-seed with:
`make robot-destroy && make robot-wrangler` (cattle, not pet), or append it manually to
`~/.ssh/authorized_keys` on the box over the tailnet.
