#!/usr/bin/env bash
# test-df-record-new.sh — a new machine record inherits DECLARATIONS and never MEASUREMENTS.
#
# ⚠️ THE ASSERTIONS THAT MATTER ARE THE ABSENCES. This script's whole job is that a value
# present in the source is GONE from the output, and an absence assertion passes on a broken
# tool that produces nothing — so every "X is gone" here is paired with a control proving the
# output is a real record that kept the things it should keep.
#
# The fixture is a source record carrying one of each hazard, taken from the shape that
# actually bit a Coder workspace on 2026-09-08: a sibling's mcp block, a sibling's codeRoot,
# a sibling's machine identity, and a populated probed map.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SELF/../df-record-new.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
T="$(mktemp -d "${TMPDIR:-/tmp}/recnew.XXXXXX")"
trap 'rm -rf "$T"' EXIT

SRC="$T/src.json"
cat > "$SRC" <<'JSON'
{
  "instance": "coder-sibling--loom-a",
  "lanes": ["canonical", "onedroid"],
  "vendorDir": "vendor",
  "machine": { "$comment": "doc line", "platform": "Linux", "home": "/home/coder",
               "hostname": "sibling-box" },
  "codeRoot": "/home/coder/code",
  "codeLayout": { "onedroid": "providentiaww", "optima": "Optima" },
  "upstreams": { "dark-factory": { "repo": "OneDro1d/dark-factory", "commit": "deadbeef" } },
  "install": { "skills": ["vinculum-loop"], "skillSources": { "vinculum-loop": "dark-factory/skills/vinculum-loop" },
               "hooks": [], "hookSources": {} },
  "mcp": { "profiles": { "onedroid": { "kind": "hubs", "servers": ["onedroid", "onedroid-dev"] } } },
  "scope": { "excluded": ["some-lane"] },
  "probed": { "repos": { "thing": { "path": "/home/coder/code/thing" } }, "checkedAt": "2026-01-01" },
  "notRestorable": { "gh auth login": "credentials cannot live in a lockfile" }
}
JSON

OUT="$T/out.json"
ERR="$(python3 "$SCRIPT" --from "$SRC" --instance coder-new--loom-b --out "$OUT" 2>&1)"; rc=$?
eq "A1 exits 0" "$rc" "0"
[ -f "$OUT" ] && ok "A2 wrote the file" || bad "A2 wrote the file" "no $OUT"
jq -e . "$OUT" >/dev/null 2>&1 && ok "A3 output is valid JSON" || bad "A3 output is valid JSON" "parse failed"

echo "=== KEPT: declarations are inherited, which is the point ==="
eq "B1 the Tier-1 pin survives"      "$(jq -r '.upstreams["dark-factory"].commit' "$OUT")" "deadbeef"
eq "B2 the skill list survives"      "$(jq -r '.install.skills[0]' "$OUT")" "vinculum-loop"
eq "B3 lanes survive"                "$(jq -r '.lanes[1]' "$OUT")" "onedroid"
eq "B4 scope survives (a policy, not a measurement)" "$(jq -r '.scope.excluded[0]' "$OUT")" "some-lane"
eq "B5 notRestorable survives"       "$(jq -r '.notRestorable | keys[0]' "$OUT")" "gh auth login"

echo "=== RESET: every measurement of the SOURCE machine is gone ==="
eq "C1 instance is the new name"     "$(jq -r '.instance' "$OUT")" "coder-new--loom-b"
absent "C2 the sibling's hostname is gone" "sibling-box" "$(cat "$OUT")"
absent "C3 the sibling's codeRoot is gone" "/home/coder/code\"" "$(cat "$OUT")"
eq "C4 codeRoot is a loud placeholder" "$(jq -r '.codeRoot' "$OUT")" "__MEASURE_ME__"
eq "C5 machine values are placeholders" "$(jq -r '.machine.platform' "$OUT")" "__MEASURE_ME__"
eq "C6 machine documentation is KEPT"  "$(jq -r '.machine["$comment"]' "$OUT")" "doc line"
eq "C7 codeLayout has no inherited lane" "$(jq -r '[.codeLayout | keys[] | select(startswith("$")|not)] | length' "$OUT")" "0"
eq "C8 mcp is REMOVED, not blanked"  "$(jq -r 'has("mcp")' "$OUT")" "false"
eq "C9 probed.repos is empty"        "$(jq -r '.probed.repos | length' "$OUT")" "0"

echo "=== the reset is EXPLAINED, not silent ==="
contains "D1 stderr lists what was reset"   "RESET"  "$ERR"
contains "D2 stderr names mcp specifically" "mcp"    "$ERR"
contains "D3 stderr names the vendor symlink step" "vendor" "$ERR"
contains "D4 the file itself carries a reset note"  "RESET by df-record-new.py" "$(cat "$OUT")"

echo "=== refusals ==="
OUT2="$(python3 "$SCRIPT" --from "$SRC" --instance x --out "$OUT" 2>&1)"; rc=$?
eq "E1 refuses to overwrite without --force" "$rc" "1"
contains "E2 and says why" "refusing to overwrite" "$OUT2"
python3 "$SCRIPT" --from "$SRC" --instance x --out "$OUT" --force >/dev/null 2>&1
eq "E3 --force overwrites" "$?" "0"
OUT3="$(python3 "$SCRIPT" --from "$T/nope.json" --instance x 2>&1)"; rc=$?
eq "E4 a missing source exits non-zero" "$rc" "1"
contains "E5 and names the file" "nope.json" "$OUT3"

echo
printf 'passed %s  failed %s\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
