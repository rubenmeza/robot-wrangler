#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh
_load_env

# Tailscale evaluates the policy's tests server-side; the provider does not run them during
# `tofu plan`, so a plan that breaks a deny test still succeeds. Send the exact policy the plan
# would write to the validate endpoint, which runs the tests and saves nothing, before showing
# (plan) or applying (apply) it. Usage: tailnet-policy.sh plan|apply
mode="${1:-}"
case "$mode" in plan|apply) ;; *) echo "usage: $0 plan|apply" >&2; exit 2 ;; esac
: "${TAILSCALE_API_KEY:?set TAILSCALE_API_KEY in .env}"
: "${TAILSCALE_TAILNET:?set TAILSCALE_TAILNET in .env}"
: "${TF_VAR_tailnet_owner:?set TF_VAR_tailnet_owner in .env}"

policy="$(mktemp)"
trap 'rm -f tailnet/tfplan "$policy"' EXIT

tofu -chdir=tailnet init -input=false
if [ "$mode" = plan ]; then
  tofu -chdir=tailnet plan -input=false -out=tfplan
else
  tofu -chdir=tailnet plan -input=false -out=tfplan >/dev/null
fi
tofu -chdir=tailnet show -json tfplan |
  jq -er '.resource_changes[] | select(.address == "tailscale_acl.policy") | .change.after.acl' >"$policy" ||
  { echo "could not read the planned Tailnet policy from tailnet/tfplan" >&2; exit 1; }

credential=${TAILSCALE_API_KEY//\\/\\\\}
credential=${credential//\"/\\\"}
# Config on stdin keeps the access credential out of process argv and logs.
response="$(printf 'header = "Authorization: Bearer %s"\n' "$credential" |
  curl --config - --silent --show-error --connect-timeout 5 --max-time 20 \
    --header 'Content-Type: application/json' --data-binary "@$policy" --write-out '\n%{http_code}' \
    "https://api.tailscale.com/api/v2/tailnet/$TAILSCALE_TAILNET/acl/validate")"
_acl_validate_verdict "${response##*$'\n'}" "${response%$'\n'*}"

# Apply re-plans and prompts as before; a saved plan would apply without asking.
if [ "$mode" = apply ]; then
  tofu -chdir=tailnet apply
fi
