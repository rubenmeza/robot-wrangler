#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh

# An alternate filesystem root lets command-boundary tests use a throwaway host.
host_root="${PERSONAL_HOST_ROOT:-}"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/robot-wrangler"
state_file="$config_dir/personal-host.json"
_fail() { printf '%s\n' "$*" >&2; exit 1; }

_personal_preflight() {
  local os_id command status
  os_id=$(sed -n 's/^ID=//p' "$host_root/etc/os-release" | tr -d '"')
  [ "$os_id" = arch ] || _fail 'Enrollment supports Arch/Omarchy only.'
  for command in sudo tailscale jq ssh-keygen; do
    command -v "$command" >/dev/null || _fail "Missing $command; install it before enrollment."
  done
  [ "$(id -u)" != 0 ] || _fail 'Run enrollment as your own user; it asks for sudo at the keyboard.'
  status=$(tailscale status --json) || _fail 'Tailscale is not running. Run sudo tailscale up first.'
  jq -e '.BackendState == "Running" and .Self.Online == true' <<< "$status" >/dev/null ||
    _fail 'Tailscale is not connected. Run sudo tailscale up first.'
  jq -e '.CurrentTailnet.MagicDNSEnabled == true' <<< "$status" >/dev/null ||
    _fail 'Enable MagicDNS in the Tailnet DNS settings before enrollment.'
  jq -e '(.CertDomains // []) | length > 0' <<< "$status" >/dev/null ||
    _fail 'Enable HTTPS certificates in the Tailnet DNS settings before enrollment.'
}

_write_user_file() {
  local path="$1" mode="$2" temporary
  temporary=$(mktemp)
  cat > "$temporary"
  mkdir -p "$(dirname "$path")"
  if ! cmp -s "$temporary" "$path"; then install -m "$mode" "$temporary" "$path"; fi
  chmod "$mode" "$path"
  rm -f "$temporary"
}

_enroll_keys() {
  local key own_material path material
  key="$(_key)"
  mkdir -p "$HOME/.ssh" devices
  chmod 700 "$HOME/.ssh"
  if [ ! -f "$key" ]; then
    mkdir -p "$(dirname "$key")"
    ssh-keygen -q -t ed25519 -N '' -f "$key" -C "$host_name"
    printf 'Created Device key %s.\n' "$key"
  fi
  if [ ! -f "$key.pub" ]; then
    ssh-keygen -y -f "$key" > "$key.pub"
  fi
  ssh-keygen -lf "$key.pub" >/dev/null || _fail "Invalid public key: $key.pub"
  own_material=$(awk 'NF >= 2 {print $1 " " $2; exit}' "$key.pub")
  path="devices/$host_name.pub"
  if [ -f "$path" ]; then
    material=$(awk 'NF >= 2 {print $1 " " $2; exit}' "$path")
    [ "$material" = "$own_material" ] || _fail "$path belongs to a different Device key; choose a different host name."
  else
    if [ -f devices/arch.pub ] && [ "$(awk 'NF >= 2 {print $1 " " $2; exit}' devices/arch.pub)" = "$own_material" ]; then
      mv devices/arch.pub "$path"
      printf 'Renamed devices/arch.pub to %s.\n' "$path"
    else
      cp "$key.pub" "$path"
      printf 'Registered %s.\n' "$path"
    fi
  fi
  # Exclude key material too: a stale alias must not admit this host to itself.
  awk -v own="$own_material" 'NF >= 2 && $1 !~ /^#/ {
    material=$1 " " $2
    if (material != own && !seen[material]++) print
  }' devices/*.pub | _write_user_file "$HOME/.ssh/authorized_keys" 600
  printf 'Commit %s and re-run enrollment on the other hosts to propagate Device keys.\n' "$path"
}

_write_system_file() {
  local path="$1" mode="$2" temporary
  temporary=$(mktemp)
  cat > "$temporary"
  if ! sudo cmp -s "$temporary" "$path"; then
    sudo install -D -m "$mode" "$temporary" "$path"
    printf 'Updated %s.\n' "$path"
  fi
  rm -f "$temporary"
}

_validate_sshd() {
  local effective line address listen_count=0
  sudo sshd -t || return 1
  # OpenSSH releases emit either lowercase or capitalized directive names.
  effective=$(sudo sshd -T | awk '{$1=tolower($1); print}') || return 1
  for line in 'allowusers '"$owner" 'permitrootlogin no' 'passwordauthentication no' \
    'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'authenticationmethods publickey' \
    'authorizedkeysfile .ssh/authorized_keys' 'authorizedkeyscommand none' \
    'trustedusercakeys none' 'hostbasedauthentication no'; do
    grep -Fxq "$line" <<< "$effective" || {
      printf 'Conflicting SSH setting: expected %s.\n' "$line" >&2
      return 1
    }
  done
  while read -r line address; do
    [ "$line" = listenaddress ] || continue
    listen_count=$((listen_count + 1))
    case "$address" in
      "$tailnet_ipv4:22"|"[$tailnet_ipv6]:22") ;;
      *) printf 'SSH would listen outside the Tailnet: %s. Remove conflicting ListenAddress directives.\n' "$address" >&2; return 1 ;;
    esac
  done <<< "$effective"
  [ "$listen_count" -gt 0 ] || { echo 'SSH has no Tailnet listener.' >&2; return 1; }
}

_enroll_ssh() {
  local dropin="$host_root/etc/ssh/sshd_config.d/00-robot-wrangler.conf" backup existed=0
  sudo pacman -S --needed --noconfirm openssh tmux ufw mosh
  sudo install -d -m 755 "$host_root/etc/ssh"
  sudo ssh-keygen -A -f "$host_root"
  tailnet_ipv4=$(tailscale ip -4)
  tailnet_ipv6=$(tailscale ip -6)
  [ -n "$tailnet_ipv4$tailnet_ipv6" ] || _fail 'Tailscale has no host addresses.'
  backup=$(mktemp)
  # sudo reads the system source; the destination is a user-owned temporary backup.
  # shellcheck disable=SC2024
  if sudo test -f "$dropin"; then sudo cat "$dropin" > "$backup"; existed=1; fi
  {
    printf '# Managed by robot-wrangler enrollment.\n'
    [ -z "$tailnet_ipv4" ] || printf 'ListenAddress %s\n' "$tailnet_ipv4"
    [ -z "$tailnet_ipv6" ] || printf 'ListenAddress %s\n' "$tailnet_ipv6"
    printf 'AllowUsers %s\n' "$owner"
    cat files/personal-sshd.conf
  } | _write_system_file "$dropin" 644
  # The writer runs in a pipeline subshell; compare its result with the saved file.
  local changed=1
  if [ "$existed" -eq 1 ] && sudo cmp -s "$backup" "$dropin"; then changed=0; fi
  if ! _validate_sshd; then
    if [ "$existed" -eq 1 ]; then sudo install -m 644 "$backup" "$dropin"; else sudo rm -f "$dropin"; fi
    rm -f "$backup"
    _fail 'SSH validation failed; restored the previous enrollment drop-in. SSH was not enabled.'
  fi
  rm -f "$backup"
  sudo ufw allow in on tailscale0 to any port 22 proto tcp
  sudo ufw allow in on tailscale0 to any port 60000:61000 proto udp
  # Arch normally has no socket unit. Still mask it against future activation.
  local socket_load
  socket_load=$(sudo systemctl show --property=LoadState --value sshd.socket)
  if [ "$socket_load" != not-found ]; then sudo systemctl disable --now sshd.socket; fi
  sudo systemctl mask sshd.socket
  sudo systemctl unmask sshd.service
  if ! sudo systemctl is-enabled --quiet sshd.service; then sudo systemctl enable sshd.service; fi
  if sudo systemctl is-active --quiet sshd.service; then
    if [ "$changed" -eq 1 ]; then sudo systemctl reload sshd.service; fi
  else
    sudo systemctl start sshd.service
  fi
}

_enroll_tmux() {
  local rc="$HOME/.bashrc" source_line
  case "${SHELL:-/bin/bash}" in
    */zsh) rc="$HOME/.zshrc" ;;
    */bash) ;;
    *) _fail 'Automatic SSH tmux attachment supports Bash and Zsh; configure your shell before enrolling.' ;;
  esac
  _write_user_file "$config_dir/ssh-tmux.sh" 644 <<'SH'
# Only interactive SSH shells outside tmux attach. File transfers and commands stay untouched.
case $- in
  *i*)
    if [ -n "${SSH_CONNECTION:-}" ] && [ -n "${SSH_TTY:-}" ] && [ -z "${TMUX:-}" ]; then
      _robot_tmux_session=$(tmux list-sessions -F '#{session_last_attached} #{session_id}' 2>/dev/null |
        sort -rn | head -n 1 | cut -d ' ' -f 2)
      if [ -n "$_robot_tmux_session" ]; then
        exec tmux attach-session -t "$_robot_tmux_session"
      else
        exec tmux new-session -s work
      fi
    fi
    ;;
esac
SH
  source_line='[ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/robot-wrangler/ssh-tmux.sh" ] || . "${XDG_CONFIG_HOME:-$HOME/.config}/robot-wrangler/ssh-tmux.sh"'
  if ! grep -Fxq "$source_line" "$rc" 2>/dev/null; then
    printf '\n%s\n' "$source_line" >> "$rc"
    printf 'Added interactive SSH tmux attachment to %s.\n' "$rc"
  fi
}

# Later tickets supply these services without changing enrollment orchestration.
_enroll_t3() { :; }
_enroll_moshi() { :; }
for personal_helper in scripts/_personal-t3.sh scripts/_personal-moshi.sh; do
  if [ -f "$personal_helper" ]; then
    # shellcheck source=/dev/null
    source "$personal_helper"
  fi
done

_enroll() {
  _personal_preflight
  local previous_name='' previous_mode='always-on' answer
  if [ -f "$state_file" ]; then
    previous_name=$(jq -er '.name' "$state_file") || _fail "Invalid enrollment state: $state_file"
    previous_mode=$(jq -er '.mode' "$state_file") || _fail "Invalid enrollment state: $state_file"
  fi
  printf 'Tailnet name [%s]: ' "$previous_name"
  read -r answer || _fail 'Enrollment needs a host name at the keyboard.'
  host_name="${answer:-$previous_name}"
  [[ "$host_name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    _fail 'Use a Tailnet name of 1–63 lowercase letters, numbers or interior hyphens.'
  printf 'Reachability mode (always-on / open-by-hand) [%s]: ' "$previous_mode"
  read -r answer || _fail 'Enrollment needs a reachability mode at the keyboard.'
  reachability="${answer:-$previous_mode}"
  [ "$reachability" = always-on ] || _fail 'This enrollment version supports always-on only.'
  owner=$(id -un)
  sudo -v
  sudo tailscale set "--hostname=$host_name" "--operator=$owner"
  _enroll_keys
  _enroll_ssh
  _enroll_tmux
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  _enroll_t3
  _enroll_moshi
  jq -n --arg name "$host_name" --arg mode "$reachability" '{name:$name,mode:$mode}' |
    _write_user_file "$state_file" 600
  printf 'Enrolled %s (%s).\n' "$host_name" "$reachability"
}

case "${1:-}" in
  enroll) _enroll ;;
  *) _fail 'Usage: personal-host.sh enroll' ;;
esac
