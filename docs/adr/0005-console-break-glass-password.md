# Console-only break-glass password

The `robot` user has an optional password (`TF_VAR_robot_console_password_hash`) usable ONLY at
DigitalOcean's out-of-band web console -- never over SSH, which keeps `PasswordAuthentication no`.
It exists so a box that fails to join the tailnet on first boot is still diagnosable. Empty hash
(the default) keeps the account fully password-locked.

## Why it's needed

Born-locked provisioning (no public ingress, ADR 0001) means the only path to the box is the
tailnet. If `tailscale up` fails on first boot, there is otherwise NO way in: DO's default
"Droplet Console" is itself SSH-based and gets dropped by the deny-all firewall ("timed out while
waiting for handshake"), and the out-of-band noVNC/recovery console needs an OS credential the box
doesn't have (root is locked, the robot user is key-only). The box becomes undiagnosable exactly
when you most need to look -- which is how a stray em-dash silently voiding cloud-init went unseen
across two rebuilds. A console-only password restores break-glass.

## Why it doesn't weaken born-locked

- Only the password **hash** is in cloud-init user_data (never plaintext).
- SSH password auth stays disabled, so the password is useless over the network -- only the
  hypervisor-level console accepts it.
- Reaching the DO console already requires DO account access, which can destroy/recreate/snapshot
  the box anyway, so the password grants no capability an account holder lacks.

## Consequences

- Generate with `openssl passwd -6` and single-quote it in `.env` (it contains `$`).
- The on-box `CLAUDE.md` tells the agent this console password is deliberate: do not disable it,
  and never extend password auth to SSH.
