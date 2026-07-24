#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh

fail=0
need() { command -v "$1" >/dev/null 2>&1 || { printf 'MISSING: %-10s (%s)\n' "$1" "$2"; fail=1; }; }
warn() { command -v "$1" >/dev/null 2>&1 || printf 'optional: %-10s (%s)\n' "$1" "$2"; }

need tofu      "pacman -S opentofu"
need tailscale "pacman -S tailscale"
need doctl     "pacman -S doctl"
need jq        "pacman -S jq"
need ssh       "openssh"
warn mosh      "pacman -S mosh — needed for 'make robot-attach'"

if [ ! -f .env ]; then
  echo "MISSING: .env  (cp .env.example .env, then fill it in)"; fail=1
else
  _load_env
  for v in DIGITALOCEAN_TOKEN TF_VAR_tailscale_authkey CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN; do
    [ -n "${!v:-}" ] || { echo "MISSING in .env: $v"; fail=1; }
  done
fi

if ! ls devices/*.pub >/dev/null 2>&1; then
  echo "MISSING: at least one devices/*.pub — you would lock yourself out. See devices/README.md"; fail=1
fi

key="$(_key)"
[ -f "$key" ] || { echo "MISSING: ssh private key $key (set ROBOT_SSH_KEY or create it — see devices/README.md)"; fail=1; }

tailscale status >/dev/null 2>&1 || { echo "Local Tailscale not up: sudo tailscale up"; fail=1; }
doctl account get  >/dev/null 2>&1 || { echo "doctl not authenticated: doctl auth init"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "preflight OK"; else echo; echo "preflight FAILED — fix the above"; exit 1; fi
