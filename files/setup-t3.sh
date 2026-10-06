#!/usr/bin/env bash
# Shared user-owned T3 setup for Enrollment and the Provisioner (ADR 0011).
# Source and call setup_t3 <serve:true|false> <activate:1|0> [require-agent-env:true|false], or invoke this file directly.
# The caller sets Tailscale operator and enables linger before activation. Activation=0 skips
# only systemctl; it still installs T3 and renders settings/unit files (container smoke).
set -euo pipefail

# Mark setup_t3s local changed flag only when contents differ, keeping live turns running.
_t3_commit_file() {
  local source_file="$1" destination="$2" mode="$3"
  if [ -f "$destination" ] && cmp -s "$source_file" "$destination"; then
    rm -f "$source_file"
    chmod "$mode" "$destination"
    return 0
  fi
  chmod "$mode" "$source_file"
  mv "$source_file" "$destination"
  changed=1
}

setup_t3() {
  local serve="${1:?setup_t3 requires true or false for Serve}" activate="${2:-1}"
  case "$serve" in true|false) ;; *) echo "invalid T3 Serve setting" >&2; return 1 ;; esac
  case "$activate" in 0|1) ;; *) echo "invalid T3 activation setting" >&2; return 1 ;; esac
  local require_agent_env="${3:-false}"
  case "$require_agent_env" in true|false) ;; *) echo "invalid T3 agent-env requirement" >&2; return 1 ;; esac
  local binary changed=0
  binary="$(command -v t3 || true)"
  if [ -z "$binary" ] && [ -x "$HOME/.local/bin/t3" ]; then binary="$HOME/.local/bin/t3"; fi
  if [ -z "$binary" ]; then
    curl -fsSL https://t3.codes/install.sh | sh
    binary="$HOME/.local/bin/t3"
    changed=1
  fi
  [ -x "$binary" ] || { echo "T3 installer did not provide an executable" >&2; return 1; }
  # Keep the stable launcher, rather than a resolved version-specific runtime path.
  case "$binary" in /*) ;; *) binary="$PWD/$binary" ;; esac

  local t3_home="${T3CODE_HOME:-$HOME/.t3}" settings unit_dir launcher_dir temporary
  settings="$t3_home/userdata/settings.json"
  unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  launcher_dir="${XDG_CONFIG_HOME:-$HOME/.config}/t3code"
  install -d -m 0700 "$t3_home" "$t3_home/userdata" "$unit_dir" "$launcher_dir"
  temporary="$(mktemp "$t3_home/userdata/.settings.XXXXXX")"
  if [ -f "$settings" ]; then
    if ! jq -es 'if length == 1 and (.[0] | type == "object") then .[0] + {continueThreadsAfterServerUpdate: true} else error("expected one settings object") end' "$settings" > "$temporary"; then
      rm -f "$temporary"
      echo "T3 settings must be a valid JSON object; existing file preserved" >&2
      return 1
    fi
  else
    jq -n '{continueThreadsAfterServerUpdate: true}' > "$temporary"
  fi
  _t3_commit_file "$temporary" "$settings" 0600

  # Robot credentials are pushed post-boot as a shell file. Load them only inside the service
  # process; the installer and cloud-init never receive them. No pairing command runs here.
  temporary="$(mktemp "$launcher_dir/.start.XXXXXX")"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    # Always-on hosts retry startup until tailscaled is online. User units cannot order
    # themselves after the system tailscaled unit; Open-by-hand hosts need no Tailnet gate.
    cat <<'LAUNCHER'
if [ "${T3CODE_TAILSCALE_SERVE:-false}" = true ]; then
  if ! tailscale status --json | jq -e '.BackendState == "Running" and .Self.Online == true' >/dev/null; then
    echo "T3 is waiting for Tailscale" >&2
    exit 1
  fi
fi
LAUNCHER
    # shellcheck disable=SC2016
    printf '[ ! -f "$HOME/.robot-env" ] || source "$HOME/.robot-env"\n'
    if [ "$require_agent_env" = true ]; then
      cat <<'LAUNCHER'
if [ ! -f "$HOME/.robot-env" ] || [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -z "${GH_TOKEN:-}" ]; then
  echo "T3 is waiting for post-boot agent credentials" >&2
  exit 1
fi
LAUNCHER
    fi
    printf 'exec %q start --mode web --no-browser --host 127.0.0.1 --port 3773 --log-level warn\n' "$binary"
  } > "$temporary"
  _t3_commit_file "$temporary" "$launcher_dir/start.sh" 0700

  # Quote systemd paths and escape its percent specifiers. Paths remain stable across updates.
  local launcher="$launcher_dir/start.sh" escaped_home="$t3_home"
  launcher="${launcher//\\/\\\\}"; launcher="${launcher//\"/\\\"}"; launcher="${launcher//%/%%}"
  escaped_home="${escaped_home//\\/\\\\}"; escaped_home="${escaped_home//\"/\\\"}"; escaped_home="${escaped_home//%/%%}"
  temporary="$(mktemp "$unit_dir/.unit.XXXXXX")"
  cat > "$temporary" <<UNIT
[Unit]
Description=T3 Code agent host
After=network-online.target

[Service]
Type=simple
WorkingDirectory=%h
ExecStart=/bin/bash "$launcher"
Environment="PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin"
Environment="T3CODE_HOME=$escaped_home"
Environment=T3CODE_TRACE_MIN_LEVEL=Warn
Environment=T3CODE_AUTO_BOOTSTRAP_PROJECT_FROM_CWD=false
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  _t3_commit_file "$temporary" "$unit_dir/t3code.service" 0600
  install -d -m 0700 "$unit_dir/t3code.service.d"
  temporary="$(mktemp "$unit_dir/t3code.service.d/.tailnet.XXXXXX")"
  cat > "$temporary" <<UNIT
[Service]
Environment=T3CODE_TAILSCALE_SERVE=$serve
Environment=T3CODE_TAILSCALE_SERVE_PORT=443
UNIT
  _t3_commit_file "$temporary" "$unit_dir/t3code.service.d/10-tailnet.conf" 0600
  if [ "$activate" = 1 ]; then
    if [ "$changed" = 1 ]; then systemctl --user daemon-reload; fi
    if ! systemctl --user is-enabled --quiet t3code.service; then
      systemctl --user enable t3code.service
    fi
    if [ "$changed" = 1 ] || ! systemctl --user is-active --quiet t3code.service; then
      systemctl --user restart t3code.service
    fi
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then setup_t3 "$@"; fi
