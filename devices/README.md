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

## Pixel 8 Pro (Termux)
```bash
pkg install openssh
ssh-keygen -t ed25519 -f ~/.ssh/robot -C robot-pixel
cat ~/.ssh/robot.pub    # paste into devices/pixel.pub on your laptop
```

## iPad Air M1 (Blink Shell)
`config` → Keys → new ed25519 key → copy the public key → paste into `devices/ipad.pub`.

After adding a device key to an already-running box, re-seed with:
`make robot-destroy && make robot-wrangler` (cattle, not pet), or append it manually to
`~/.ssh/authorized_keys` on the box over the tailnet.
