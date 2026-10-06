# Setup guide — robot-wrangler

Set up your Agent hosts in this order: **Tailnet policy → PC (Always-on) → laptop (Open by hand)
→ optional Robot server with T3 Code**. Run commands from your checkout of this repo.
Policy must precede opening any new host; Device keys must precede a Robot-server build.

## 1. Accounts, tools and Tailnet membership

You need a Tailscale account with Tailnet administrator access. For Personal hosts, use your own
Arch/Omarchy machine, local account and existing agent CLI authentication. Enrollment supports
Bash and Zsh and runs as your user at the keyboard, with ordinary `sudo` authentication.

On each Personal host:

```bash
sudo pacman -S tailscale openssh jq make git curl
sudo systemctl enable --now tailscaled
sudo tailscale up
```

Sign in as the same owner on every Personal host and control-surface device; keep them **untagged**.
Install Tailscale, Moshi and the T3 client on the Pixel and iPad. In the Tailscale admin console,
rename their nodes to `pixel` and `ipad`. A device's Tailnet name, Device-key filename and T3
Pairing label must match exactly; enrollment chooses Personal-host names later. See
[Device keys](devices/README.md).

On the machine from which you manage policy, also install OpenTofu:

```bash
sudo pacman -S opentofu
```

In the admin console's **DNS** page, enable **MagicDNS** and **HTTPS Certificates**. They are
prerequisites for T3 Code's Tailscale Serve endpoint and enrollment checks them before changing
the host. Serve issues certificates itself; you do not need to run `tailscale cert` manually.
HTTPS names appear in public certificate transparency logs; network access remains private.
See [Tailscale's HTTPS setup](https://tailscale.com/docs/how-to/set-up-https-certificates).

## 2. Apply the Tailnet policy before enrollment

The `tailnet/` OpenTofu root owns the **whole** policy, including `tag:server`, in its own local
state (`tailnet/terraform.tfstate`). Robot provisioning and teardown never touch this state
([ADR 0012](docs/adr/0012-tailnet-policy-as-code.md)). Apply it before enrolling any Personal host
or creating the robot's node auth key; there is no manual tag-definition step.

Create the local, gitignored `.env` if it does not exist:

```bash
test -f .env || cp .env.example .env
$EDITOR .env
```

Fill only the policy settings:

- `TAILSCALE_API_KEY`: admin **Settings → Keys → API access tokens → Generate access token**.
  This API credential is separate from a node auth key. It stays on the operator's machine,
  expires after the chosen 1–90 days, and must be rotated here when needed.
- `TAILSCALE_TAILNET`: the Tailnet ID from the admin console (legacy Tailnet names also work).
- `TF_VAR_tailnet_owner`: your **exact** login identity from **Users** (`you@example.com`,
  `username@github` or `username@passkey`). Tags replace user identity, so your Personal hosts
  and control-surface clients must remain untagged.

Back up the existing **Access Controls** policy before the first apply. Review the replacement:

```bash
make tailnet-plan
make tailnet-apply          # prompts before replacing the entire live policy
```

The provider checks Tailscale's built-in policy tests during planning and on apply. The grant
admits only the owner's user-owned devices to other owner devices and `tag:server` on SSH TCP
22, mosh UDP 60000–61000 and HTTPS TCP 443. The tagged robot cannot initiate access to any
Personal host; other traffic is denied by default. This uses OpenSSH, not Tailscale SSH.

Carry any unrelated rules you need into `tailnet/main.tf` before applying: this module replaces
existing policy contents. Back up its state alongside your other local state files. Do not
run policy destroy: `prevent_destroy` blocks it, and `reset_acl_on_destroy = false` prevents the
provider from restoring the default allow-all policy if that safeguard is deliberately removed.
`make robot-destroy` only uses the Robot server's root and state.

At the first rollout, verify policy test rejection without applying a broken policy: after a
successful good apply, temporarily add `"tag:server"` to the grant's `src`, run
`make tailnet-plan`, and expect the `tag:server` → Personal-host denial tests to fail. Restore
the grant and run `make tailnet-plan` again. **Do not apply the deliberately broken edit.**
This live check is **UNVERIFIED**. `make test` runs credential-free `tofu validate`; only a real
plan/apply evaluates Tailscale's policy tests. See the
[provider's policy resource](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/resources/acl).

## 3. Enroll the desktop PC as Always-on

Clone or pull this repo **on the PC** and run as your own user, at its keyboard:

```bash
make enroll
```

Choose a unique Tailnet name, for example `desk`, and mode `always-on`. Enrollment remembers
these choices for later runs. Enter your `sudo` password when prompted. Enrollment installs
SSH/tmux/mosh, registers your Device key, sets you as Tailscale operator, and configures:

- SSH bound to Tailnet addresses only, your Unix user only, public-key authentication only;
  no root or password login. SSH starts at boot; socket activation is masked.
- T3 Code as `t3code.service`, using an existing installation or the standalone installer, with
  user lingering and resuming interrupted turns enabled. T3 publishes itself on Tailnet HTTPS.
- `moshi-hook` as a persistent user service, and interactive SSH login attachment to the most
  recently attached tmux session (or a new `work` session). File transfers and remote commands
  do not attach.
- Permanent firewall rules on `tailscale0` for SSH and mosh, with effective SSH configuration
  checked before activation. Suspend and hibernation are disabled for this Always-on host.

Enrollment does **not** load `.env` or require a DigitalOcean token, robot auth key, Claude token
or GitHub token. Personal hosts use your existing local agent credentials. If Moshi is unpaired,
it asks for the app's **Settings → Hooks** token with **hidden input**. Enter it at the keyboard;
do not echo it, put it in shell history or record it. A working Moshi pairing and installed
hooks are preserved on re-enrollment. Whether one token works for several hosts remains
**UNVERIFIED**; check this at the first PC/laptop enrollment and obtain a fresh token if needed.

Enrollment uses `~/.ssh/robot_ed25519` by default, generating it if absent; export `ROBOT_SSH_KEY`
**in your shell** before enrollment to use a different key. It registers the public half as
`devices/desk.pub` and writes `hosts/desk.json` with the Tailnet name and actual Unix account.
These are public files; private keys and local service state stay on the host.

```bash
git add devices/desk.pub hosts/desk.json
git commit -m "Register desk Personal host"
make status
```

Push that public registration through your normal git workflow and pull it on every other
Personal host. Re-run enrollment there to seed admitted keys; each host omits its **own** Device
key. Host inventory records actual Unix users, which need not be the same across machines and
are not Tailscale login identities. Inventory lets revocation report offline hosts rather than
silently omitting them. See [host inventory](hosts/README.md).

## 4. Enroll the laptop as Open by hand

On the laptop, pull the PC's registration, then run at its keyboard:

```bash
make enroll
```

Choose a unique name, for example `laptop`, and mode `open-by-hand`. If your existing Device
key matches `devices/arch.pub`, enrollment renames that legacy file to `devices/laptop.pub`.
Keep the original private key; do not create a second identity for the same device. If the
legacy file belongs to a different key, enrollment leaves it alone; resolve its actual device
name before pairing or revoking. Each host must have its own private Device key.

Commit the laptop's public registration and legacy rename, push it through your normal git
workflow, then pull it on the PC and re-run `make enroll` there:

```bash
git add devices/ hosts/laptop.json
git commit -m "Register laptop Personal host"
```

Review the staged diff so it contains only intended public registrations. Also add the Pixel
and iPad's Moshi public keys as `devices/pixel.pub` and `devices/ipad.pub`, commit and pull them,
and re-enroll both hosts. Adding keys after building the Robot server requires a rebuild there.

The laptop gets the same services, SSH restrictions and tmux attachment as the PC, but SSH is
never enabled at boot, T3 stays loopback-only, and boot turns Tailscale Serve off. Enrollment
finishes by closing both remote doors. Laptop power settings stay untouched. Re-enrollment
preserves unchanged running services, settings and working pairings, but closes Open-by-hand
doors again.

```bash
make status        # SSH off, no inbound handlers, Serve off; T3 can still be active
make open          # verifies Tailnet, starts SSH and publishes T3 HTTPS
make status
make close         # stops SSH; kills inbound SSH/mosh; disables Serve
make status
```

Keep the **lid up** while open and start work inside **tmux or T3**. Hard close drops inbound
attachments and reports which handlers it killed. It leaves outbound `mosh-client`, tmux,
T3 and agents running. `status` reports actual listeners, SSH unit/socket and boot state,
inbound handlers, Serve, T3 and tmux; it warns if a host intended closed has an open door.
A reboot returns an Open-by-hand host to closed.

## 5. Pair devices and check Personal-host access

Pair **each device with each host** once, manually. For the laptop, run `make open` first.
At a trusted terminal on the host being paired, run this example for the Pixel:

```bash
t3 pair --tailscale --label pixel
```

Scan its one-time code with the Pixel's T3 client. Repeat for `ipad`, and for the other Personal
host's exact device name. Use the same exact name as the Tailnet node and `devices/<name>.pub`,
without `.pub`, as the label. Do not use a model name or a guessed prefix. Pairings are per
(device, host); they do not propagate through git. Codes and pairing URLs are **passwords**:
never log, commit or screenshot them. Close the laptop when finished.

For Moshi terminal access, add each Personal host's Tailnet name and **its Unix user**, selecting
that mobile device's SSH key. An interactive login lands in the most recent tmux session. From
the laptop you can likewise use SSH to the PC:

```bash
ssh -i ~/.ssh/robot_ed25519 -o IdentitiesOnly=yes YOUR_PC_USER@desk
```

Replace `YOUR_PC_USER` with `hosts/desk.json`'s `user` and the key path if overridden. T3 is
served at each host's `https://<host>.<tailnet>.ts.net` address, printed by enrollment. Open-by-hand
hosts expose it only while open. Phone/laptop pairing, actual remote access and PC Moshi push
are **UNVERIFIED** until tested on the real devices.

The repo owns `t3code.service` and its stable launcher. Native `t3 service install` is
intentionally bypassed because it immediately starts a server that can log pairing passwords.
The repo launcher binds `127.0.0.1:3773`, suppresses startup/trace INFO logs and disables automatic
project bootstrap. After updating T3 on any host:

```bash
t3 update
systemctl --user restart t3code.service
```

This uses the updated runtime and can interrupt turns; resume is enabled. A T3 restart must
not reopen a closed Open-by-hand host. See [ADR 0011](docs/adr/0011-t3-code-beside-ssh.md).

## 6. Optional: provision or rebuild the Robot server

The Robot server remains the sealed, always-on cloud path, with SSH/Herdr, Moshi and T3 together.
You need DigitalOcean API access and billing, a Claude Pro/Max subscription, and a GitHub token
for the robot. Keep robot-only credentials on the operator's machine, not on every Personal host.

Install the Robot-server tools and authenticate `doctl`:

```bash
sudo pacman -S doctl mosh openssh
doctl auth init
```

Create a **fresh single-use** Tailscale node auth key only after step 2:
admin **Settings → Keys → Generate auth key**, **Reusable OFF**, **Ephemeral OFF**,
**Pre-approved ON**, **tag:server**. Save it as `TF_VAR_tailscale_authkey` in `.env`.
For a rebuild, delete the stale `robot` node in the admin console first so the new host does
not become `robot-1`.

Keep the policy settings in `.env` and add:

- `DIGITALOCEAN_TOKEN`: DigitalOcean API token with write access.
- `CLAUDE_CODE_OAUTH_TOKEN`: generate with `claude setup-token` on a machine with a browser;
  the token uses your subscription and is pushed after boot over SSH.
- `GH_TOKEN`: your robot's GitHub token; see [ADR 0002](docs/adr/0002-github-access.md).
- Optional `MOSHI_PAIRING_TOKEN`: app **Settings → Hooks**, for robot push.
- Optional `CODEX_AUTH_JSON`: path to the local authentication file from `codex login`; see
  [ADR 0008](docs/adr/0008-codex-agent.md).
- Optional `ROBOT_SSH_KEY`: private key matching this operator device's registered public key.
- Optional `TF_VAR_robot_multiplexer`: `herdr` (default, SSH) or `tmux` (mosh).
- Optional `TF_VAR_robot_console_password_hash`: console-only break-glass password hash;
  see [ADR 0005](docs/adr/0005-console-break-glass-password.md).

Never commit `.env`, authentication files or private keys. Ensure all intended public Device
keys are in `devices/` before building. The robot admits every registered Device key.

```bash
make preflight                # Robot-server checks, not Personal-host enrollment checks
make robot-wrangler           # build, join Tailnet, wait for readiness, push agent credentials
make robot-status
make robot-attach             # shared robot session, Herdr/SSH or tmux/mosh
```

T3 installs as a standalone binary without Node; the Provisioner includes its runtime dependency
`libatomic1`, sets the robot user as Tailscale operator and enables the same resume setting.
T3 waits for post-boot agent credentials. **Pair after boot over SSH**, never through cloud-init:

```bash
make robot-ssh
# At the trusted terminal on the Robot server, once per device:
t3 pair --tailscale --label pixel
```

Repeat with each exact Device name. A rebuild needs new T3 Pairings; Moshi attempts to re-pair
from its token. Verify the agent CLIs, Herdr attachment, Moshi push and T3 from the real clients.
These rollout checks are **UNVERIFIED**. Keep valuable work in git; rebuilding destroys host state.
See [README rebuild guidance](README.md#rebuild--verify).

For maintenance, finish or stop agent work, then run `make robot-update`; inspect
`make robot-update-status`. SSH/Herdr sessions may be interrupted. T3 resumes interrupted turns
after server restart; terminal agents do not automatically resume. The maintenance command
updates OS packages and Herdr, not the Ubuntu release or T3 runtime. Run `t3 update` and restart
`t3code.service` separately as above. See [maintenance operations](docs/robot-update-operations.md).

`make robot-destroy` removes the droplet and firewall. The separate Tailnet policy remains;
delete any lingering tagged node in the admin console.

## Revoking a lost device

From another Personal host with current public keys and host inventory, set `TAILSCALE_API_KEY`
and `TAILSCALE_TAILNET` in its gitignored `.env`, with device listing/deletion permissions, then:

```bash
make revoke DEVICE=pixel
```

The command removes the Tailnet node, Device key and any host entry, and revokes matching T3
grants and established sessions on every reachable inventoried host and the robot. It refuses
to revoke itself. A nonzero exit means incomplete: bring listed hosts online or fix the failure
and retry the same command. Keep its private local retry receipt until all hosts are covered.
Commit the public key/inventory removal, pull it everywhere, re-enroll remaining Personal hosts
and rebuild the robot to remove the SSH credential. See
[device revocation](docs/device-revocation.md) for permissions, offline inventory and retries.

## Manual acceptance — UNVERIFIED

These checks require the owner's real Tailnet, hosts and mobile devices. No live policy apply,
enrollment, pairing, reboot, rebuild or revoke is implied by automated tests.

- [ ] **UNVERIFIED — live policy:** apply the good policy, confirm only owner devices reach hosts,
  confirm `tag:server` cannot reach Personal hosts, and run the deliberately broken-plan test
  from step 2 without applying it. Restore the policy afterward.
- [ ] **UNVERIFIED — PC:** from the laptop, SSH/T3 reach the PC as its actual Unix user; PC Moshi
  push reaches the phone with the app closed. Check token reuse across hosts or obtain separate
  tokens, preserving each working pairing on re-enrollment.
- [ ] **UNVERIFIED — pairing:** pair phone, tablet and laptop with each host using matching labels;
  verify T3 access through the Tailnet HTTPS address and actual Serve behavior.
- [ ] **UNVERIFIED — laptop:** open both doors, close while SSH and mosh are attached, confirm
  inbound attachments drop while agents/tmux/T3 and outbound mosh survive; reboot while open
  and verify both doors return closed. Confirm a T3 restart while closed keeps them closed.
- [ ] **UNVERIFIED — Robot server:** rebuild without changing policy state, confirm T3 and its
  runtime dependency, pair after boot, verify SSH/Herdr and Moshi push, and exercise
  `robot-update` and T3 update/restart with access and resume checks afterward.
- [ ] **UNVERIFIED — revoke:** pair a throwaway device on every host with matching names, revoke
  it from a different Personal host, cover an unreachable-host retry, propagate key removal,
  and verify new SSH access and established T3 sessions are denied everywhere.

## Troubleshooting

- **Enrollment rejects prerequisites:** start `tailscaled`, run `sudo tailscale up`, and enable
  MagicDNS/HTTPS in the Tailnet DNS settings. Run as your own user on Arch/Omarchy with Bash/Zsh.
- **SSH validation fails:** enrollment restores its prior drop-in and does not enable SSH.
  Remove conflicting SSH settings, especially non-Tailnet `ListenAddress` entries, then retry.
- **Moshi token rejected:** get a current token in **Settings → Hooks**, enter it at the hidden
  enrollment prompt and retry. Do not print its private state to debug.
- **T3 is unreachable:** check `make status`, the host's mode, Tailnet policy and Tailscale
  connection. For an Open-by-hand host, run `make open` at its keyboard. T3 service activity
  alone does not mean its Tailnet door is open.
- **Robot never joins / `wait-ready` times out:** check the applied policy and fresh, pre-approved
  `tag:server` auth key, and remove a stale robot node. There is no public SSH. Use DigitalOcean's
  out-of-band Recovery Console and the console credentials from ADR 0005 to inspect
  `cloud-init status --long` and `journalctl -u tailscaled`.
- **Robot apply auth error:** check `DIGITALOCEAN_TOKEN`, its write access and `doctl` authentication.
- **SSH permission denied:** pull public keys and re-enroll Personal hosts; the robot only trusts
  keys present at provision time, so rebuild it after key changes. Select the correct private key
  and the host's actual Unix user.
