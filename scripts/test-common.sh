#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_common.sh

# Pure-bash unit tests for the injectable helpers in _common.sh. No box, no network, no container:
# the probe and _ip are the seams, so we substitute fakes. See ADR 0006 (the interface is the test
# surface).

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

echo "==> _wait_until"

# Ready immediately -> returns 0.
_always() { return 0; }
if _wait_until "ready-now" 0 "$(( $(date +%s) + 10 ))" _always >/dev/null; then
  ok "succeeds when probe is already ready"
else bad "should succeed when probe is ready"; fi

# Ready after N failures -> returns 0 (proves it polls, not one-shot).
_n=0; _after_three() { _n=$((_n+1)); [ "$_n" -ge 3 ]; }
if _wait_until "ready-soon" 0 "$(( $(date +%s) + 10 ))" _after_three >/dev/null && [ "$_n" -ge 3 ]; then
  ok "polls until the probe flips ready"
else bad "should poll until ready (n=$_n)"; fi

# Never ready + past deadline -> returns 1 (timeout), does not hang.
_never() { return 1; }
if _wait_until "never" 0 "$(( $(date +%s) - 1 ))" _never >/dev/null; then
  bad "should time out on a past deadline"
else ok "times out on a past deadline"; fi

echo "==> _require_ip"

# _ip present -> prints it, returns 0. (Invoked indirectly by _require_ip.)
# shellcheck disable=SC2329
_ip() { printf '100.64.0.9\n'; }
if out="$(_require_ip)" && [ "$out" = "100.64.0.9" ]; then
  ok "returns the ip when on the tailnet"
else bad "should return the ip (got '${out:-}')"; fi

# _ip empty -> returns 1, prints nothing to stdout.
_ip() { printf ''; }
if out="$(_require_ip 2>/dev/null)"; then
  bad "should fail when not on the tailnet"
elif [ -n "$out" ]; then
  bad "leaked stdout: '$out'"
else
  ok "fails (rc=1) and prints no ip when off the tailnet"
fi

echo
if [ "$fail" -eq 0 ]; then echo "common tests OK"; else echo "common tests FAILED"; exit 1; fi
