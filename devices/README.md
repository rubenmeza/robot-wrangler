# Device keys

One `devices/<name>.pub` file per control-surface device. **Public keys only** — safe to commit.
The filename without `.pub` is the device's exact Tailnet node name and T3 Pairing label.
Every Personal host admits all these keys except its own; the Robot server seeds every key into
its user's `authorized_keys` at provision time. At least one key must exist before provisioning,
or you would lock yourself out; Robot-server preflight checks this.

## Personal hosts (Arch/Omarchy)

At the host's keyboard, run `make enroll`, choose its unique Tailnet name and Reachability mode.
Enrollment uses `~/.ssh/robot_ed25519`, generating a key if absent, and copies its public half to
`devices/<name>.pub`. To use another existing key, export `ROBOT_SSH_KEY` in the shell before
enrollment; enrollment does not load `.env`.

If the chosen key matches legacy `devices/arch.pub`, enrollment renames that public file to the
chosen host name. Keep its existing private half. A nonmatching legacy key is left untouched:
identify its real device and rename it consistently before pairing or revocation. Each machine
has its own private key; do not copy one host's private key to another.

Enrollment also writes `hosts/<name>.json` with the host's name and actual Unix user. Commit both
public files and any legacy rename, pull them on every other Personal host, and re-run
`make enroll` there. Rebuild the robot to propagate keys there. See
[host inventory](../hosts/README.md) and the [ordered setup guide](../SETUP.md).

Robot scripts load `.env`, so set `ROBOT_SSH_KEY` there if their private key path differs from the
default. Personal enrollment uses the exported shell setting instead.

## Pixel + iPad (Moshi)

Install Tailscale and sign in as the owner. Rename their Tailnet nodes to `pixel` and `ipad`.
In Moshi, generate a distinct ed25519 SSH key on each device; copy **only the public half** into
`devices/pixel.pub` or `devices/ipad.pub` on a Personal host. Commit, pull everywhere and
re-enroll Personal hosts; rebuild the robot if already provisioned.

Add each Agent host in Moshi using its Tailnet name, that host's **Unix user**, and the device's
key. Personal-host users are recorded in `hosts/<name>.json`, not derived from Tailscale login
names. Personal hosts attach the latest tmux session; use SSH or mosh. The robot uses user
`robot` by default, with **Herdr → SSH** or **tmux → mosh** according to its provisioned profile;
every device attaches the same `robot` session. Moshi Pro supplies mosh.

## Pairing and revocation

At a trusted terminal on each host, manually run `t3 pair --tailscale --label pixel` (or the exact
other device name) and scan the one-time code in that device's T3 client. Open an Open-by-hand
host before pairing, then close it afterward. Never log, screenshot or commit codes or URLs.
Pairings are per host and separate from SSH Device keys.

Use `make revoke DEVICE=<name>` from another Personal host with current keys and inventory.
See [device revocation](../docs/device-revocation.md) for credentials, retries and propagation.
A filename, Tailnet node and T3 label must match exactly for revocation to cover all three.
