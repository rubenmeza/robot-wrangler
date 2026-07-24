# Setup guide — robot-wrangler

Stand up the private agent box from zero. ~30 min, most of it clicking tokens in web consoles.
**Do the steps in order** — two are order-sensitive (ACL tag *before* auth key; device key *before*
first apply).

Working dir: `/home/pollo/Dev/robot-wrangler`.

## 0. Accounts
- [ ] DigitalOcean account, API access, billing active (here: employer-paid).
- [ ] Tailscale account (free), you are tailnet admin.
- [ ] Claude **Pro or Max** subscription (Claude Code needs it).

## 1. Install local tools (Arch)
```bash
sudo pacman -S opentofu tailscale mosh openssh doctl jq make git
```
Verify: `tofu version && tailscale version && doctl version`.

## 2. Put THIS machine on the tailnet
```bash
sudo systemctl enable --now tailscaled
sudo tailscale up
```
Install the Tailscale app on the **Pixel** and **iPad** too, same account. (The **Moshi** app is
their SSH/mosh client — install it and add device keys later; see `devices/README.md` and ADR 0004.)

## 3. Tailscale ACL — define `tag:server`  ⚠️ order matters
Admin console → **Access Controls**. Ensure the policy contains:
```json
"tagOwners": {
  "tag:server": ["autogroup:admin"]
}
```
Save. Without this, the box's `tailscale up --advertise-tags=tag:server` **fails**, the box never
joins the tailnet, and you get an invisible, unreachable box.

## 4. Create the Tailscale auth key
Admin → **Settings → Keys → Generate auth key**:
- Reusable: **OFF**
- Ephemeral: **OFF**  (a server must persist across reboots)
- Pre-approved: **ON**
- Tags: **tag:server**

Copy it → `.env` as `TF_VAR_tailscale_authkey`. Single-use; spent on first boot.

## 5. DigitalOcean API token
<https://cloud.digitalocean.com/account/api/tokens> → Generate (write scope). Copy → `.env`
`DIGITALOCEAN_TOKEN`. (`doctl` is already authed; this token is for OpenTofu.)

## 6. Claude Code subscription token
On **this** machine (it has a browser):
```bash
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
claude setup-token
```
Copy the printed token → `.env` `CLAUDE_CODE_OAUTH_TOKEN`. Uses your subscription, no API billing.

## 7. Laptop SSH key (at least this one device)
```bash
ssh-keygen -t ed25519 -f ~/.ssh/robot_ed25519 -C robot-arch
cp ~/.ssh/robot_ed25519.pub devices/arch.pub
```
Pixel/iPad keys are optional now — add their `*.pub` later (means a rebuild). See `devices/README.md`.

## 8. Fill `.env`
```bash
cd /home/pollo/Dev/robot-wrangler
cp .env.example .env
$EDITOR .env   # DIGITALOCEAN_TOKEN, TF_VAR_tailscale_authkey, CLAUDE_CODE_OAUTH_TOKEN
```
`.env` is gitignored — never commit it. Optional: set `TF_VAR_robot_multiplexer` to `herdr`
(default) or `tmux` to pick the on-box multiplexer profile — herdr attaches over SSH, tmux over
mosh (ADR 0003). Leave it unset for herdr.

## 9. Preflight
```bash
make preflight
```
Fix anything it flags (missing tool, empty secret, no device key, local tailnet down, doctl auth).

## 10. Provision
```bash
tofu fmt && tofu init && tofu validate   # first-run sanity
make robot-wrangler
```
Flow: `tofu apply` → box boots **firewalled shut** → cloud-init joins the tailnet → waits for SSH +
cloud-init to finish → pushes the Claude token over SSH. ~3–6 min (apt upgrade dominates).

## 11. Verify + first session
```bash
make robot-status
make robot-attach          # shared 'robot' session (herdr/ssh or tmux/mosh per profile)
# on the box:
claude --version
claude                     # already authed — just talk to it
```
Detach and leave work running: **Ctrl-b d** (tmux) or herdr's detach key. Then close the laptop;
reattach from any device and you land back in the same live session.

## Daily use
From any device on the tailnet: `make robot-attach` → `claude`. That is the whole loop.

## Teardown
```bash
make robot-destroy
```
Removes droplet + firewall. The tailnet node is tagged — delete it in the admin console if it lingers.

## Troubleshooting
- **Box never appears on the tailnet / `wait-ready` times out:** almost always the ACL tag (step 3)
  or an auth key that isn't pre-approved/tagged (step 4). There is no public SSH to debug (by design)
  → `make robot-destroy`, fix, retry. To inspect: DO console → **Recovery Console**, then
  `cloud-init status --long` and `journalctl -u tailscaled`.
- **`backup_policy` apply error:** DO provider older than 2.43 → `tofu init -upgrade`, or drop the
  `backup_policy` block / set `backups = false`.
- **`tofu apply` auth error:** `DIGITALOCEAN_TOKEN` missing/typo in `.env`, or lacks write scope.
- **ssh permission denied:** the box only trusts keys that were in `devices/*.pub` at build time.
  Added one after? Rebuild, or append it to `~/.ssh/authorized_keys` on the box over the tailnet.
- **mosh won't start:** `mosh` not installed locally (`pacman -S mosh`), or the box is still finishing
  cloud-init. Fall back to `make robot-ssh`.
