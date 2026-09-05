#!/usr/bin/env bash
# test-rehydrate-plugins.sh — a kit that delegates to rehydrate.sh inherits install.plugins[]
# by MOVING A PIN. Same shape as test-rehydrate-links-df-mission.sh: the assertion is the
# directory on disk and what it contains, never the message.
#
# WHY. B15 put the plugin step into the two instance installers; the four personal kits install
# through THIS script. Declaring a plugin in such a kit would have made lock-verify L11 say "not
# installed" forever — honest and useless. The step belongs where every kit already runs.
#
# Rules:
#   A  declared plugin -> materialised as a REAL directory under $LIVE/skills/<name>, byte-equal
#      to the vendored source (diff -r empty); a second run converges (a stale extra file in the
#      dest is removed).
#   B  --dry-run writes nothing and says what it would do.
#   C  source not upstream:<path> -> REFUSED, nothing written.
#   D  dest outside ~/.claude/skills/ -> REFUSED, nothing written.
#   E  source without .claude-plugin/plugin.json -> REFUSED.
#   F  no plugins declared -> "none declared", nothing else changes.
#   G  the prune step (2b) leaves the materialised REAL directory alone.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
RH="${REHYDRATE:-$SCRIPTS/rehydrate.sh}"
[ -f "$RH" ] || { echo "missing $RH"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rhplug.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

DECL='[{"name":"probe-plug","source":"upstream:plugins/probe-plug","dest":"~/.claude/skills/probe-plug"}]'
kit() { # <name> <plugins-json>
  K="$TMP/$1"
  mkdir -p "$K/live/skills" "$K/vendor/dark-factory/plugins/probe-plug/.claude-plugin" "$K/vendor/dark-factory/plugins/probe-plug/hooks" "$K/bin"
  printf '{"name":"probe-plug"}\n' > "$K/vendor/dark-factory/plugins/probe-plug/.claude-plugin/plugin.json"
  printf 'echo hook\n' > "$K/vendor/dark-factory/plugins/probe-plug/hooks/h.sh"
  jq -n --argjson pl "$2" '{vendorDir:"vendor",upstreams:{"dark-factory":{commit:"0123456789abcdef0123456789abcdef01234567"}},install:{skills:[],skillSources:{},hooks:[],hookSources:{},plugins:$pl}}' > "$K/loom.lock.json"
}
run() { ( cd "$TMP/$1" && LOOM_LIVE="$TMP/$1/live" LOOM_BIN="$TMP/$1/bin" bash "$RH" --offline ${2:-} 2>&1 ); }

echo "=== A: declared plugin is materialised byte-equal, and re-runs converge ==="
kit a "$DECL"
O="$(run a)"
contains "A: says materialised" "plugin probe-plug: materialised from 01234567" "$O"
[ -d "$TMP/a/live/skills/probe-plug" ] && [ ! -L "$TMP/a/live/skills/probe-plug" ] && ok "A: a REAL directory exists" || bad "A: real directory" "missing or a symlink"
diff -r "$TMP/a/vendor/dark-factory/plugins/probe-plug" "$TMP/a/live/skills/probe-plug" >/dev/null 2>&1 && ok "A: byte-equal to the pin" || bad "A: byte-equal" "diff -r differs"
printf 'stale\n' > "$TMP/a/live/skills/probe-plug/stale.txt"
O="$(run a)"
[ -f "$TMP/a/live/skills/probe-plug/stale.txt" ] && bad "A: second run removes a stale extra" "still there" || ok "A: second run converges (stale extra removed)"

echo "=== B: --dry-run writes nothing ==="
kit b "$DECL"
O="$(run b --dry-run)"
contains "B: says what it would do" "would  materialise plugin probe-plug" "$O"
[ -e "$TMP/b/live/skills/probe-plug" ] && bad "B: nothing written" "dest exists" || ok "B: nothing written"

echo "=== C: source not upstream: -> REFUSED ==="
kit c '[{"name":"probe-plug","source":"local:plugins/probe-plug","dest":"~/.claude/skills/probe-plug"}]'
O="$(run c)"
contains "C: refused" "REFUSED plugin probe-plug: source" "$O"
[ -e "$TMP/c/live/skills/probe-plug" ] && bad "C: nothing written" "dest exists" || ok "C: nothing written"

echo "=== D: dest outside ~/.claude/skills/ -> REFUSED ==="
kit d '[{"name":"probe-plug","source":"upstream:plugins/probe-plug","dest":"~/.claude/hooks/probe-plug"}]'
O="$(run d)"
contains "D: refused" "REFUSED plugin probe-plug: dest" "$O"
[ -e "$TMP/d/live/hooks/probe-plug" ] && bad "D: nothing written" "dest exists" || ok "D: nothing written"

echo "=== E: source without plugin.json -> REFUSED ==="
kit e "$DECL"
rm "$TMP/e/vendor/dark-factory/plugins/probe-plug/.claude-plugin/plugin.json"
O="$(run e)"
contains "E: refused" "no .claude-plugin/plugin.json" "$O"

echo "=== F: none declared -> stated, not silent ==="
kit f '[]'
O="$(run f)"
contains "F: says none declared" "plugins: none declared" "$O"

echo "=== G: the prune step leaves the materialised real directory alone ==="
kit g "$DECL"
O="$(run g)"
O="$(run g)"
[ -d "$TMP/g/live/skills/probe-plug" ] && ok "G: still present after a second full run" || bad "G: pruned" "directory gone"

echo
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
