#!/usr/bin/env bash
# Moshi enrollment runs as the host owner, independent of Robot server secrets.
# Globals host_name and owner come from the enrollment command.
# shellcheck disable=SC2154
_enroll_moshi() {
  local moshi metadata token paired XDG_RUNTIME_DIR
  XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export XDG_RUNTIME_DIR
  systemctl --user show-environment >/dev/null 2>&1 ||
    _fail 'Moshi needs your systemd user manager; log in locally as the owner and retry enrollment.'
  moshi=$(command -v moshi-hook || true)
  if [ -z "$moshi" ] && [ -x "$HOME/.local/bin/moshi-hook" ]; then
    moshi="$HOME/.local/bin/moshi-hook"
  fi
  if [ -z "$moshi" ]; then
    command -v curl >/dev/null || _fail 'Install curl before Moshi enrollment.'
    curl -fsSL https://getmoshi.app/install.sh |
      INSTALL_DIR="$HOME/.local/bin" MOSHI_HOOK_SKIP_FIRST_RUN=1 MOSHI_HOOK_SKIP_SERVICE=1 sh
    moshi="$HOME/.local/bin/moshi-hook"
    [ -x "$moshi" ] || _fail 'Moshi installer did not create ~/.local/bin/moshi-hook.'
  fi
  # Local status is supported metadata; never echo the document or inspect secret files.
  metadata=$("$moshi" status --json 2>/dev/null) ||
    _fail 'Cannot read Moshi pairing metadata; check moshi-hook status at the keyboard.'
  paired=$(jq -er 'if (.paired | type) == "boolean" then .paired | tostring else error("invalid") end' \
    <<< "$metadata" 2>/dev/null) || _fail 'Invalid Moshi pairing metadata; check moshi-hook status at the keyboard.'
  if [ "$paired" = false ]; then
    token="${MOSHI_PAIRING_TOKEN:-}"
    if [ -z "$token" ]; then
      printf 'Moshi token from Settings → Hooks (input hidden): ' >&2
      read -rs token || token=''
      printf '\n' >&2
    fi
    [ -n "$token" ] ||
      _fail 'Moshi is unpaired. Enter a pairing token at the keyboard or provide MOSHI_PAIRING_TOKEN, then re-run enrollment.'
    # Environment avoids exposing the token in process arguments. Pair output may contain secrets.
    MOSHI_PAIRING_TOKEN="$token" "$moshi" pair --name "$host_name" >/dev/null 2>&1 ||
      _fail 'Moshi pairing failed; check the token in Settings → Hooks and retry.'
    unset token
  fi
  # CLI-managed installation preserves user hooks. Missing agent configs are skipped.
  if jq -e '.hooks | any(.status == "stale")' <<< "$metadata" >/dev/null 2>&1; then
    "$moshi" install
  fi
  sudo loginctl enable-linger "$owner"
  if ! systemctl --user is-enabled --quiet moshi-hook.service ||
    ! systemctl --user is-active --quiet moshi-hook.service; then
    "$moshi" service install
  fi
}
