# Setup guide — robot-wrangler

Stand up the private agent box from zero. ~30 min, most of it clicking tokens in web consoles.
**Do the steps in order** — two are order-sensitive (Tailnet policy *before* auth key/enrollment; device key *before*
first Robot server apply).

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

## 3. Apply the Tailnet policy  ⚠️ order matters
The `tailnet/` OpenTofu root owns the **whole** policy, including `tag:server`, from its own local
state (`tailnet/terraform.tfstate`). Robot server provisioning and teardown never touch this state
(ADR 0012). Apply it **before creating the robot auth key or enrolling any Personal host**.

In the admin console's **DNS** page, enable **MagicDNS** and **HTTPS Certificates**. These are
Tailnet prerequisites for T3 Code's Tailscale Serve HTTPS endpoint. Serve issues certificates
itself; you do not need to run `tailscale cert` manually. HTTPS certificate names appear in public
certificate transparency logs; network access remains private. See [Tailscale's HTTPS setup](https://tailscale.com/docs/how-to/set-up-https-certificates).

Create `.env` now if it does not exist; keep it for the rest of the setup:
```bash
cd /home/pollo/Dev/robot-wrangler
test -f .env || cp .env.example .env
$EDITOR .env
```
Fill only the policy settings for this step:

- `TAILSCALE_API_KEY`: admin **Settings → Keys → API access tokens → Generate access token**.
  This is an API access token, separate from the single-use node auth key in step 4. It stays on
  your machine and expires after the chosen 1–90 days; rotate it here when needed.
- `TAILSCALE_TAILNET`: the Tailnet ID from the admin console (legacy Tailnet names also work).
- `TF_VAR_tailnet_owner`: your **exact** login identity from **Users** (`you@example.com`,
  `username@github`, or `username@passkey`). Keep Personal hosts and control-surface clients
  untagged and signed in as this user. A device tag replaces the user's identity.

Back up the existing policy from **Access Controls** before the first apply. Review the replacement:
```bash
make tailnet-plan
make tailnet-apply          # prompts before replacing the entire live policy
```
The provider checks Tailscale's built-in policy tests during planning and on apply. The grant admits
only the owner's user-owned devices to other owner devices and `tag:server` on SSH TCP 22, mosh UDP
60000–61000, and HTTPS TCP 443. The tagged robot cannot initiate access to any Personal host; all
other traffic is denied by default. This uses ordinary OpenSSH, not Tailscale SSH.

The module replaces existing policy contents, so carry any unrelated rules you need into
`tailnet/main.tf` **before** applying. Back up its state with your other local state files. Never
run policy destroy: `prevent_destroy` blocks it, and `reset_acl_on_destroy = false` prevents the
provider from restoring Tailscale's default allow-all policy if that safeguard is deliberately
removed. `make robot-destroy` remains safe because it only uses the Robot server's root and state.

For the first real rollout, confirm a good apply succeeds, then verify test rejection without
changing the live policy: temporarily add `"tag:server"` to the grant's `src`, run
`make tailnet-plan`, and expect the `tag:server` → Personal host denial tests to fail. Restore the
grant and run `make tailnet-plan` again. **Do not apply the deliberately broken edit.**
`make test` checks the module with `tofu validate` without API credentials; only a real plan/apply
can evaluate Tailscale's policy tests. See the [provider's policy resource](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/resources/acl).

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
$EDITOR .env   # keep step 3 settings; add DIGITALOCEAN_TOKEN, TF_VAR_tailscale_authkey, CLAUDE_CODE_OAUTH_TOKEN, GH_TOKEN
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
Removes droplet + firewall; the separate Tailnet policy and its state remain intact. The tailnet node is tagged — delete it in the admin console if it lingers.

## Troubleshooting
- **Box never appears on the tailnet / `wait-ready` times out:** almost always the Tailnet policy/tag (step 3)
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
