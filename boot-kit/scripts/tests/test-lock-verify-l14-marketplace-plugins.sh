#!/usr/bin/env bash
# test-lock-verify-l14-marketplace-plugins.sh — L14: is each declared marketplace plugin
# present, ENABLED, and still the version install.sh recorded?
#
# WHY THIS EXISTS. `install.marketplacePlugins` is the one thing this kit installs that it
# cannot pin: `claude plugin install` was MEASURED 2026-09-08 to take no version argument at
# all, so every machine gets LATEST at whatever moment it ran. install.sh therefore records
# the RESOLVED version into `probed.marketplacePlugins`, and L14 is the half that makes the
# recording worth something. Without this layer the record is a number nobody reads back.
#
# ⚠️ THE THREE-WAY VERDICT AGAIN, AND FOR TWO DIFFERENT REASONS HERE. No `claude` on PATH is
# UNKNOWN, exactly as in L13 — nothing can see, and a silent pass would be a lie. But there is
# a SECOND unknown that L13 has no equivalent of: a plugin that is installed and enabled while
# `probed` holds no version for it. There is no baseline, so "moved" is not a question that
# has an answer yet; calling that ok would claim a comparison that never happened.
#
# ⚠️ INSTALLED IS NOT ENABLED. Measured on a real laptop: `plugin list --json` carries entries
# with "enabled": false — on disk, in installed_plugins.json, loading nothing. Case E is that
# machine, and a layer that only asked "is it installed" would call it healthy.
#
# `LOCK_VERIFY_CLAUDE_BIN` points at a stub `claude`, the same way L13's suite does and for the
# same reason: a suite that shelled out to the real CLI would depend on the network and on
# whatever this laptop happens to have installed today.
#
# Usage: bash boot-kit/scripts/tests/test-lock-verify-l14-marketplace-plugins.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
LV="${LOCK_VERIFY:-$SCRIPTS/lock-verify.sh}"
[ -f "$LV" ] || { echo "missing $LV"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkinst() { mkdir -p "$1/vendor"; : > "$1/install.sh"; }

l14_block() { printf '%s\n' "$1" | awk '/^\[L14\]/{p=1} p{print}'; }

# mkstub <path> <plugin-list-json> — a fake `claude` answering only what L14 asks it.
mkstub() {
  cat > "$1" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "plugin" ] && [ "\${2:-}" = "list" ]; then
  cat <<'JSON'
$2
JSON
  exit 0
fi
exit 0
EOF
  chmod +x "$1"
}

ID="playwright@claude-plugins-official"
ENTRY='{name:"playwright", marketplace:"claude-plugins-official"}'

echo "=== A: nothing declared -> PASS, not silence ==="
A="$TMP/a"; mkinst "$A"
jq -n '{vendorDir:"vendor", upstreams:{}}' > "$A/loom.lock.json"
outA="$(cd "$A" && bash "$LV" --lock=loom.lock.json 2>&1)"
contains "A: says there was nothing to check" "PASS  L14 no marketplace plugins declared" "$(l14_block "$outA")"

echo "=== B: declared, but no claude on PATH -> UNKNOWN, never a pass ==="
B="$TMP/b"; mkinst "$B"
jq -n --argjson e "$(jq -n "$ENTRY")" '{vendorDir:"vendor", upstreams:{}, install:{marketplacePlugins:[$e]}}' \
  > "$B/loom.lock.json"
outB="$(cd "$B" && LOCK_VERIFY_CLAUDE_BIN="$TMP/no-such-binary" bash "$LV" --lock=loom.lock.json 2>&1)"
lb="$(l14_block "$outB")"
contains "B: UNKNOWN, and it names the binary" "UNKNOWN L14 '$TMP/no-such-binary' is not on PATH" "$lb"
absent   "B: not reported as drift"            "DRIFT L14"                                        "$lb"

echo "=== C: installed, enabled, version matches probed -> PASS ==="
C="$TMP/c"; mkinst "$C"
jq -n --argjson e "$(jq -n "$ENTRY")" \
  '{vendorDir:"vendor", upstreams:{}, install:{marketplacePlugins:[$e]},
    probed:{marketplacePlugins:{"playwright@claude-plugins-official":{version:"85cce0381e78"}}}}' \
  > "$C/loom.lock.json"
mkstub "$TMP/claude-c" '[{"id":"playwright@claude-plugins-official","version":"85cce0381e78","enabled":true}]'
outC="$(cd "$C" && LOCK_VERIFY_CLAUDE_BIN="$TMP/claude-c" bash "$LV" --lock=loom.lock.json 2>&1)"
lc="$(l14_block "$outC")"
contains "C: PASS naming the version"  "PASS  L14 $ID: enabled, version 85cce0381e78" "$lc"
absent   "C: no drift"                 "DRIFT L14"                                    "$lc"

echo "=== D: declared but not installed -> DRIFT ==="
D="$TMP/d"; mkinst "$D"
jq -n --argjson e "$(jq -n "$ENTRY")" '{vendorDir:"vendor", upstreams:{}, install:{marketplacePlugins:[$e]}}' \
  > "$D/loom.lock.json"
mkstub "$TMP/claude-d" '[]'
outD="$(cd "$D" && LOCK_VERIFY_CLAUDE_BIN="$TMP/claude-d" bash "$LV" --lock=loom.lock.json 2>&1)"
contains "D: DRIFT says declared but NOT installed" "DRIFT L14 $ID: declared but NOT installed" "$(l14_block "$outD")"

echo "=== E: installed but DISABLED -> DRIFT, because it loads nothing ==="
E="$TMP/e"; mkinst "$E"
jq -n --argjson e "$(jq -n "$ENTRY")" \
  '{vendorDir:"vendor", upstreams:{}, install:{marketplacePlugins:[$e]},
    probed:{marketplacePlugins:{"playwright@claude-plugins-official":{version:"1.0.0"}}}}' \
  > "$E/loom.lock.json"
mkstub "$TMP/claude-e" '[{"id":"playwright@claude-plugins-official","version":"1.0.0","enabled":false}]'
outE="$(cd "$E" && LOCK_VERIFY_CLAUDE_BIN="$TMP/claude-e" bash "$LV" --lock=loom.lock.json 2>&1)"
le="$(l14_block "$outE")"
contains "E: DRIFT names the disabled state" "DRIFT L14 $ID: installed but DISABLED" "$le"
absent   "E: a matching version does not rescue it" "PASS  L14 $ID"                  "$le"

echo "=== F: version moved since install -> DRIFT, and says what that means ==="
F="$TMP/f"; mkinst "$F"
jq -n --argjson e "$(jq -n "$ENTRY")" \
  '{vendorDir:"vendor", upstreams:{}, install:{marketplacePlugins:[$e]},
    probed:{marketplacePlugins:{"playwright@claude-plugins-official":{version:"1.0.0"}}}}' \
  > "$F/loom.lock.json"
mkstub "$TMP/claude-f" '[{"id":"playwright@claude-plugins-official","version":"2.0.0","enabled":true}]'
outF="$(cd "$F" && LOCK_VERIFY_CLAUDE_BIN="$TMP/claude-f" bash "$LV" --lock=loom.lock.json 2>&1)"
lf="$(l14_block "$outF")"
contains "F: DRIFT names both versions" "DRIFT L14 $ID: version MOVED since install — recorded 1.0.0, now 2.0.0" "$lf"
contains "F: explains it is not a broken machine" "LATEST moved under you" "$lf"

echo "=== G: present and enabled, but nothing was ever recorded -> UNKNOWN ==="
# The distinction this case protects: L14 can see the plugin. It cannot see whether the
# version moved, because no baseline exists. That is UNKNOWN, and it is not ok.
G="$TMP/g"; mkinst "$G"
jq -n --argjson e "$(jq -n "$ENTRY")" '{vendorDir:"vendor", upstreams:{}, install:{marketplacePlugins:[$e]}}' \
  > "$G/loom.lock.json"
mkstub "$TMP/claude-g" '[{"id":"playwright@claude-plugins-official","version":"3.0.0","enabled":true}]'
outG="$(cd "$G" && LOCK_VERIFY_CLAUDE_BIN="$TMP/claude-g" bash "$LV" --lock=loom.lock.json 2>&1)"
lg="$(l14_block "$outG")"
contains "G: UNKNOWN, and it says how to clear it" "UNKNOWN L14 $ID: installed and enabled, but no recorded version" "$lg"
absent   "G: not a pass"  "PASS  L14 $ID"  "$lg"
absent   "G: not a drift" "DRIFT L14 $ID"  "$lg"

echo ""
printf 'lock-verify L14: %d ok, %d failed\n' "$PASS" "$FAIL"
# run-tests.sh treats a suite that exits 0 with no declared count as UNMEASURED, not a pass.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
