#!/usr/bin/env bash
set -euo pipefail

# The Provisioner (ADR 0006). Runs once as root on first boot, invoked by the single runcmd in
# the cloud-init manifest. It is all the imperative "how" that turns a bare, born-locked droplet
# into the robot: join the tailnet, install the agent + multiplexer, set the git identity, mark
# readiness. The manifest holds only the declarative "what".
#
# This file ships VERBATIM (base64 write_files) -- no ${} templating -- so it is shellcheck-clean
# and runnable on its own. Render-time config arrives at runtime, not render time:
#   - /opt/robot/provision.env   non-secret config, sourced below (ROBOT_USER, GIT_*, TS_*)
#   - /opt/robot/.ts-authkey     the single-use tailnet key (0600), read then shredded
#
# PROVISION_SKIP_HOST=1 stubs the calls that need real hardware (tailscale up, systemctl, chage),
# so the script runs end-to-end in a throwaway ubuntu:24.04 container for tests. See
# scripts/test-provision.sh.

ENV_FILE="${PROVISION_ENV:-/opt/robot/provision.env}"
AUTHKEY_FILE="${PROVISION_AUTHKEY_FILE:-/opt/robot/.ts-authkey}"

skip_host() { [ "${PROVISION_SKIP_HOST:-0}" = 1 ]; }

load_env() {
  # shellcheck source=/dev/null
  [ -f "$ENV_FILE" ] && . "$ENV_FILE"
  : "${ROBOT_USER:?provision.env missing ROBOT_USER}"
  : "${GIT_AUTHOR_NAME:?provision.env missing GIT_AUTHOR_NAME}"
  : "${GIT_AUTHOR_EMAIL:?provision.env missing GIT_AUTHOR_EMAIL}"
  : "${TS_HOSTNAME:?provision.env missing TS_HOSTNAME}"
  : "${TS_TAGS:?provision.env missing TS_TAGS}"
}

# Apply the SSH hardening drop-in the manifest wrote.
harden_ssh() {
  if skip_host; then echo "skip: systemctl restart ssh (SKIP_HOST)"; return; fi
  systemctl restart ssh
}

# Join the tailnet with the single-use, pre-authorized, tagged key, then shred it. Tagged nodes
# never expire (what we want for a server). The key was on its own 0600 channel (ADR 0006); once
# spent it is worthless, but shred it anyway so it does not linger on disk.
join_tailnet() {
  if skip_host; then echo "skip: tailscale up (SKIP_HOST)"; return; fi
  curl -fsSL https://tailscale.com/install.sh | sh
  local key; key="$(cat "$AUTHKEY_FILE")"
  tailscale up --authkey="$key" --hostname="$TS_HOSTNAME" --advertise-tags="$TS_TAGS"
  shred -u "$AUTHKEY_FILE" 2>/dev/null || rm -f "$AUTHKEY_FILE"
}

# GitHub CLI from its official apt repo (not in Ubuntu's default repos). The agent uses it to
# read issues and open PRs, and git uses it as the github.com credential helper (ADR 0002).
install_gh() {
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update
  apt-get install -y gh
}

# Clear password aging on BOTH root and the robot account. cloud-init leaves the shadow
# last-change field at epoch 0, which PAM treats as "password must be changed". install_agent
# runs `sudo -u ROBOT_USER` AS ROOT, and PAM trips on ROOT's expiry first ("unable to change
# expired password"), so the installer would silently never run. This MUST come before
# install_agent.
fix_password_aging() {
  if skip_host; then echo "skip: chage (SKIP_HOST)"; return; fi
  local today; today="$(date +%Y-%m-%d)"
  chage -d "$today" -m 0 -M -1 -I -1 -E -1 root
  chage -d "$today" -m 0 -M -1 -I -1 -E -1 "$ROBOT_USER"
}

# Install the agent AS the robot user (not root): Claude Code + herdr into ~/.local/bin, and the
# git identity. Both multiplexers are always present (tmux+mosh from apt); the auto-attach target
# is decided by the profile.d drop-in, not here (ADR 0003). PATH / secret env / auto-attach all
# live in /etc/profile.d/10-robot.sh, so this no longer edits ~/.bashrc.
install_agent() {
  sudo -u "$ROBOT_USER" -H env \
    GIT_AUTHOR_NAME="$GIT_AUTHOR_NAME" GIT_AUTHOR_EMAIL="$GIT_AUTHOR_EMAIL" \
    bash -euo pipefail -c '
      # Claude Code native installer (installs to ~/.local/bin/claude).
      curl -fsSL https://claude.ai/install.sh | bash
      # herdr: agent-aware multiplexer (ADR 0003), installed like claude into ~/.local/bin.
      curl -fsSL https://herdr.dev/install.sh | sh
      # moshi-hook: on-box daemon that bridges Claude Code hooks -> Moshi push notifications
      # (ADR 0007). The binary is token-independent; pairing + the user service happen post-boot,
      # once MOSHI_PAIRING_TOKEN is on the box (scripts/robot-auth.sh).
      curl -fsSL https://getmoshi.app/install.sh | sh
      # Codex CLI: OpenAI's coding agent, standalone installer (no Node) into ~/.local/bin/codex
      # (ADR 0008). Auth is a subscription auth.json pushed post-boot, same channel as the other
      # secrets; the binary here is credential-independent.
      curl -fsSL https://chatgpt.com/codex/install.sh | sh
      # Git identity: the robot commits as the owner (ADR 0002).
      git config --global user.name "$GIT_AUTHOR_NAME"
      git config --global user.email "$GIT_AUTHOR_EMAIL"
      # Route github.com HTTPS auth through gh, which reads GH_TOKEN from ~/.robot-env.
      git config --global --replace-all credential.https://github.com.helper "!gh auth git-credential"
      git config --global --replace-all credential.https://gist.github.com.helper "!gh auth git-credential"
    '
}

# Let the robot user's systemd --user services run without an active login. moshi-hook installs
# itself as a --user service (ADR 0007); linger is what keeps it running after the provisioning SSH
# session ends and across reboots. Harmless when Moshi is unused (no user service is installed).
enable_linger() {
  if skip_host; then echo "skip: loginctl enable-linger (SKIP_HOST)"; return; fi
  loginctl enable-linger "$ROBOT_USER"
}

# Readiness marker the laptop polls (wait-ready.sh) before pushing the agent token over SSH.
mark_provisioned() {
  mkdir -p /opt/robot
  touch /opt/robot/.provisioned
}

main() {
  load_env
  harden_ssh
  join_tailnet
  install_gh
  fix_password_aging
  install_agent
  enable_linger
  mark_provisioned
  echo "provisioned"
}

main "$@"
