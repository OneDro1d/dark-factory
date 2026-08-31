#!/usr/bin/env bash
# df-ui-verify — per-scenario verdict from browser-surface evidence.
# Usage: verdict.sh <scenario_dir>   (expects network.json [+ console.txt])
# Echoes PASS | CONDITIONAL | FAIL on stdout; reason on stderr.
set -uo pipefail

dir="${1:?scenario dir}"
net="$dir/network.json"
con="$dir/console.txt"

[ -f "$net" ] || { echo "FAIL: no network.json (no evidence — a PASS is not earned)" >&2; echo "FAIL"; exit 0; }

bad="$(jq '[.[] | select(.status>=400)] | length' "$net" 2>/dev/null || echo 0)"
if [ "${bad:-0}" -gt 0 ]; then
  echo "FAIL: $bad request(s) >=400" >&2; echo "FAIL"; exit 0
fi

# console: ignore known-harmless telemetry 400s; any other line = blocking.
noise=0
if [ -f "$con" ] && [ -s "$con" ]; then
  any="$(grep -c -E '.' "$con" 2>/dev/null || echo 0)"
  other="$(grep -v -E 'clerk-telemetry\.com' "$con" 2>/dev/null | grep -c -E '.' 2>/dev/null || echo 0)"
  if [ "${any:-0}" -gt 0 ]; then noise=1; fi
  if [ "${other:-0}" -gt 0 ]; then
    echo "FAIL: blocking console error" >&2; echo "FAIL"; exit 0
  fi
fi

if [ "$noise" -gt 0 ]; then
  echo "CONDITIONAL: known-harmless console noise only" >&2; echo "CONDITIONAL"; exit 0
fi

echo "PASS" >&2; echo "PASS"
