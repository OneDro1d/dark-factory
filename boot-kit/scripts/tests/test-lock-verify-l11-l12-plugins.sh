#!/usr/bin/env bash
# test-lock-verify-l11-l12-plugins.sh — a materialised plugin can drift silently, and a
# plugin's own invariants can go unrun silently. Two different layers, because they fail
# differently.
#
# WHY THIS EXISTS. Personal skills-directory plugins (M-KITV2 B15) are installed as a COPY,
# not a symlink — the personal skills-directory loader only scans ~/.claude/skills/, so
# nothing about $LIVE redirection can make a symlink into the vendor cache load there instead.
# A copy can drift from its source the instant anyone edits the live copy by hand, and L5's
# `phys()` symlink-resolution check (built for skills, which ARE symlinks) cannot see that —
# it was never asked to compare file contents. L11 is that comparison. L12 is a second,
# independent question a byte-for-byte diff cannot answer: does the plugin's OWN self-check
# (tests/test-plugin-invariants.sh, if it ships one) still pass? kitv2/b4 measured a concrete
# reason this matters — a plugin's settings.json carrying "agent" hijacks the main thread of a
# HEADLESS run too, silently, exit 0 — the kind of property a byte-diff would call "PASS" right
# up until the pin itself regressed it.
#
# THE CONTRACT UNDER TEST IS THAT BOTH LAYERS CAN FAIL, and that "absent" is reported
# differently from "checked and clean" in both — an `unknown` that reads like a `pass` is a
# gate nobody can trust the second time it is quiet. Every case is paired the same way
# test-lock-verify-l10-skills.sh pairs its own: a fixture that must drift/unknown and a
# control that must not, on the same machinery.
#
# Usage: bash boot-kit/scripts/tests/test-lock-verify-l11-l12-plugins.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
LV="${LOCK_VERIFY:-$SCRIPTS/lock-verify.sh}"
[ -f "$LV" ] || { echo "missing $LV"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in block" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in block" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lvl11l12.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# mk <case> <install-json> — an isolated instance: its own vendor/dark-factory (standing in
# for the pinned Tier 1) and its own private $LIVE.
mk() {
  mkdir -p "$WORK/$1/live/skills" "$WORK/$1/vendor/dark-factory"
  jq -n --argjson inst "$2" '{vendorDir:"vendor",upstreams:{},install:$inst}' \
    > "$WORK/$1/loom.lock.json"
}
# plugin_pin <case> <path-under-plugins> <file> <content> — content at the PIN
plugin_pin() {
  mkdir -p "$(dirname "$WORK/$1/vendor/dark-factory/$2/$3")"
  printf '%s\n' "$4" > "$WORK/$1/vendor/dark-factory/$2/$3"
}
# plugin_dest <case> <name> <file> <content> — content actually MATERIALISED into $LIVE
plugin_dest() {
  mkdir -p "$(dirname "$WORK/$1/live/skills/$2/$3")"
  printf '%s\n' "$4" > "$WORK/$1/live/skills/$2/$3"
}

# run <case> — full lock-verify output
run() { ( cd "$WORK/$1" && LOOM_LIVE="$WORK/$1/live" bash "$LV" --lock=loom.lock.json 2>&1 ); }
# blk <output> <label> — just that layer's block, same convention test-lock-verify-l10-skills.sh uses
blk() { printf '%s\n' "$1" | sed -n "/^\[$2\]/,/^\$/p"; }

DECL_OK='{"plugins":[{"name":"df-governed","source":"upstream:plugins/df-governed","dest":"~/.claude/skills/df-governed"}]}'

echo "=== L11-A: the materialised copy matches the pin exactly ==="
mk a1 "$DECL_OK"
plugin_pin  a1 plugins/df-governed .claude-plugin/plugin.json '{"name":"df-governed"}'
plugin_pin  a1 plugins/df-governed hooks/probe.sh 'echo hook'
plugin_dest a1 df-governed .claude-plugin/plugin.json '{"name":"df-governed"}'
plugin_dest a1 df-governed hooks/probe.sh 'echo hook'
O="$(run a1)"; B="$(blk "$O" L11)"
contains "A1 clean copy passes"           "PASS"                          "$B"
contains "A1 names the plugin"            "df-governed"                   "$B"
absent   "A1 no drift reported"           "DRIFT"                         "$B"

echo "=== L11-B: the materialised copy has been hand-edited — DRIFT, and named ==="
mk b1 "$DECL_OK"
plugin_pin  b1 plugins/df-governed .claude-plugin/plugin.json '{"name":"df-governed"}'
plugin_pin  b1 plugins/df-governed hooks/probe.sh 'echo hook'
plugin_dest b1 df-governed .claude-plugin/plugin.json '{"name":"df-governed"}'
plugin_dest b1 df-governed hooks/probe.sh 'echo TAMPERED'
O="$(run b1)"; B="$(blk "$O" L11)"
contains "B1 a modified file is DRIFT"        "DRIFT"                     "$B"
contains "B1 the mismatch names the file"     "hooks/probe.sh"            "$B"
contains "B1 explains the copy does not match" "does NOT match the pin"   "$B"

echo "=== L11-C: dest was never installed — DRIFT, 'not installed' ==="
mk c1 "$DECL_OK"
plugin_pin c1 plugins/df-governed .claude-plugin/plugin.json '{"name":"df-governed"}'
O="$(run c1)"; B="$(blk "$O" L11)"
contains "C1 missing dest is DRIFT"       "DRIFT"                         "$B"
contains "C1 named as not installed"      "not installed"                 "$B"

echo "=== L11-D: source is not upstream:<path> — DRIFT, cannot verify ==="
mk d1 '{"plugins":[{"name":"bad","source":"local:plugins/df-governed","dest":"~/.claude/skills/bad"}]}'
O="$(run d1)"; B="$(blk "$O" L11)"
contains "D1 non-upstream source is DRIFT" "DRIFT"                        "$B"
contains "D1 names why"                    "not upstream:<path>"          "$B"

echo "=== L11-E: dest outside ~/.claude/skills/ — DRIFT, cannot verify ==="
mk e1 '{"plugins":[{"name":"bad2","source":"upstream:plugins/df-governed","dest":"/etc/passwd"}]}'
O="$(run e1)"; B="$(blk "$O" L11)"
contains "E1 dest outside the prefix is DRIFT" "DRIFT"                    "$B"
contains "E1 names why"                        "outside ~/.claude/skills/" "$B"

echo "=== L11-F: no plugins declared — a stated pass, not silence ==="
mk f1 '{}'
O="$(run f1)"; B="$(blk "$O" L11)"
contains "F1 no plugins is PASS"          "PASS"                          "$B"
contains "F1 says nothing to check"       "no plugins declared"           "$B"
absent   "F1 not DRIFT"                   "DRIFT"                         "$B"

echo "=== L12-A: the plugin ships an invariants suite, and it passes ==="
mk g1 "$DECL_OK"
plugin_pin  g1 plugins/df-governed .claude-plugin/plugin.json '{"name":"df-governed"}'
plugin_dest g1 df-governed .claude-plugin/plugin.json '{"name":"df-governed"}'
mkdir -p "$WORK/g1/live/skills/df-governed/tests"
cat > "$WORK/g1/live/skills/df-governed/tests/test-plugin-invariants.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/g1/live/skills/df-governed/tests/test-plugin-invariants.sh"
O="$(run g1)"; B="$(blk "$O" L12)"
contains "G1 a passing suite is PASS"     "PASS"                          "$B"
absent   "G1 not DRIFT"                   "DRIFT"                         "$B"
absent   "G1 not reported as skipped"     "skipped"                       "$B"

echo "=== L12-B: the plugin ships an invariants suite, and it FAILS ==="
mk h1 "$DECL_OK"
plugin_pin  h1 plugins/df-governed .claude-plugin/plugin.json '{"name":"df-governed"}'
plugin_dest h1 df-governed .claude-plugin/plugin.json '{"name":"df-governed"}'
mkdir -p "$WORK/h1/live/skills/df-governed/tests"
cat > "$WORK/h1/live/skills/df-governed/tests/test-plugin-invariants.sh" <<'EOF'
#!/usr/bin/env bash
echo "settings.json MUST NOT carry agent"
echo "line two"
echo "INVARIANT VIOLATED: agent key present"
exit 1
EOF
chmod +x "$WORK/h1/live/skills/df-governed/tests/test-plugin-invariants.sh"
O="$(run h1)"; B="$(blk "$O" L12)"
contains "H1 a failing suite is DRIFT"        "DRIFT"                     "$B"
contains "H1 names the exit code"             "exit 1"                    "$B"
contains "H1 carries the suite's own tail"    "INVARIANT VIOLATED"        "$B"

echo "=== L12-C: the plugin ships no invariants suite — visible, not a pass ==="
mk i1 "$DECL_OK"
plugin_pin  i1 plugins/df-governed .claude-plugin/plugin.json '{"name":"df-governed"}'
plugin_dest i1 df-governed .claude-plugin/plugin.json '{"name":"df-governed"}'
O="$(run i1)"; B="$(blk "$O" L12)"
contains "I1 absent suite is reported"    "UNKNOWN"                      "$B"
contains "I1 says why"                    "ships no invariants suite"    "$B"
absent   "I1 NOT reported as PASS"        "PASS"                         "$B"

echo "=== L12-D: no plugins declared — unknown, not a pass ==="
mk j1 '{}'
O="$(run j1)"; B="$(blk "$O" L12)"
contains "J1 no plugins is UNKNOWN, not PASS" "UNKNOWN"                   "$B"
absent   "J1 not reported as PASS"            "PASS"                     "$B"

echo ""
printf 'L11/L12 plugins: %d ok, %d failed\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
