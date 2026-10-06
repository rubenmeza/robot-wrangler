#!/usr/bin/env bash
# Safe to send over SSH stdin: reads only public auth metadata, never pairing material.
set -euo pipefail
device="${1:-}"
[[ "$device" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || exit 1
# User SSH sessions may not load profile PATH; installers use this stable launcher location.
export PATH="$HOME/.local/bin:$PATH"
for command in jq t3; do command -v "$command" >/dev/null || { echo "Missing $command." >&2; exit 1; }; done
failed=0
for kind in pairing session; do
  if ! metadata=$(t3 auth "$kind" list --json 2>/dev/null); then
    printf 'Could not list T3 %s metadata.\n' "$kind" >&2
    failed=1
    continue
  fi
  if ! jq -e 'type == "array" and all(.[]; type == "object")' <<< "$metadata" >/dev/null; then
    printf 'Invalid T3 %s metadata.\n' "$kind" >&2
    failed=1
    continue
  fi
  if [ "$kind" = pairing ]; then
    filter='.[] | select(.label == $device) | .id'
  else
    filter='.[] | select(.client.label == $device) | .sessionId'
  fi
  if ! ids=$(jq -er --arg device "$device" "[$filter] | if all(.[]; type == \"string\" and test(\"^[A-Za-z0-9_-]+$\")) then .[] else error(\"invalid auth ID\") end" <<< "$metadata"); then
    # jq -e exits 4 for an empty stream; distinguish no matches from malformed IDs.
    if ! jq -e --arg device "$device" "[$filter] | length == 0" <<< "$metadata" >/dev/null; then
      printf 'Invalid T3 %s identifiers.\n' "$kind" >&2
      failed=1
    fi
    continue
  fi
  while IFS= read -r id; do
    if ! t3 auth "$kind" revoke "$id" >/dev/null 2>&1; then
      printf 'Could not revoke T3 %s entry.\n' "$kind" >&2
      failed=1
    fi
  done <<< "$ids"
done
exit "$failed"
