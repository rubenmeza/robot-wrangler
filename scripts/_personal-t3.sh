#!/usr/bin/env bash
# Enrollment runs as the owner; shared setup also serves the Robot Provisioner.
# personal-host.sh supplies reachability, owner and host_name to this sourced hook.
# shellcheck disable=SC2154
source files/setup-t3.sh

_enroll_t3() {
  local serve=false user_id dns_name device_key device_name
  if [ "$reachability" = always-on ]; then serve=true; fi
  sudo loginctl enable-linger "$owner"
  user_id=$(id -u)
  sudo systemctl start "user@$user_id.service"
  XDG_RUNTIME_DIR="/run/user/$user_id" setup_t3 "$serve" 1
  printf 'T3 Code installed and running as your user; interrupted turns resume after restart.\n'
  dns_name=$(tailscale status --json | jq -er '.Self.DNSName | rtrimstr(".")')
  printf 'T3 Tailnet address: https://%s\n' "$dns_name"
  printf 'At a trusted terminal on this host, pair each device by scanning its one-time code:\n'
  for device_key in devices/*.pub; do
    [ -f "$device_key" ] || continue
    device_name=${device_key##*/}; device_name=${device_name%.pub}
    [ "$device_name" != "$host_name" ] || continue
    printf '  t3 pair --tailscale --label %q\n' "$device_name"
  done
  printf 'Use the exact Device name as the label so revoke can find its Pairings. Never log, copy into the repo, or screenshot pairing codes.\n'
  if [ "$reachability" = open-by-hand ]; then
    printf 'Run make open before pairing; run make close afterward.\n'
  fi
}
