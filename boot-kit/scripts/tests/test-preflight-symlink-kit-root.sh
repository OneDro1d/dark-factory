#!/usr/bin/env bash
# test-preflight-symlink-kit-root.sh — df-preflight on PATH must still know which kit it is.
#
# WHY THIS EXISTS. The installers put the engine's CLIs on PATH as symlinks
# (~/.local/bin/df-preflight -> <kit>/boot-kit/scripts/df-preflight.py). The preflight
# derives KIT_ROOT — where the machine's lockfile lives — from its own file location. With
# os.path.abspath that location was the LINK's directory, so KIT_ROOT became ~/.. and
# find_lock() found nothing. The report still printed, with lockfile=null: a preflight that
# ran and described no machine. Measured 2026-09-05. df-mission never had the bug because it
# does `readlink -f "$0"`; this test holds the Python side to the same rule.
#
# Case A: invoked through a symlink from a notepad, kitRoot is the kit and the lockfile
#         resolves.
# Case B: invoked by path, same answers — the fix must not change the direct case.
# Case C: notepad discovery is unaffected: the notepad is the cwd's manifest dir, not the kit.
#
# Usage: bash boot-kit/scripts/tests/test-preflight-symlink-kit-root.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
PF="${DF_PREFLIGHT:-$SCRIPTS/df-preflight.py}"
[ -f "$PF" ] || { echo "missing $PF"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

# pwd -P: on macOS mktemp answers under /var, which is itself a symlink to /private/var.
# The script under test now canonicalises its own path, so the expectations must be
# canonical too, or this test would fail on the OS it was written on and pass on Linux.
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# A kit: the engine copied under boot-kit/scripts/, one lockfile at the root.
KIT="$TMP/kit"; mkdir -p "$KIT/boot-kit/scripts"
cp "$PF" "$KIT/boot-kit/scripts/df-preflight.py"
jq -n --arg cr "$TMP/code" '{codeRoot:$cr, codeLayout:{}, upstreams:{}, probed:{repos:{}}}' \
  > "$KIT/loom.lock.json"
# A notepad elsewhere, with an empty manifest, so nothing network-shaped is probed.
NP="$TMP/notepad"; mkdir -p "$NP" "$TMP/code"
printf '{"repos":[]}\n' > "$NP/repos.manifest.json"
# The PATH link, in a bin dir that is NOT under the kit.
BIN="$TMP/bin"; mkdir -p "$BIN"
ln -s "$KIT/boot-kit/scripts/df-preflight.py" "$BIN/df-preflight"

run() { # $1 = how, $2 = json out
  if [ "$1" = link ]; then
    ( cd "$NP" && PATH="$BIN:$PATH" df-preflight --report --json "$2" >"$TMP/out.txt" 2>&1 )
  else
    ( cd "$NP" && python3 "$KIT/boot-kit/scripts/df-preflight.py" --report --json "$2" >"$TMP/out.txt" 2>&1 )
  fi
  return 0
}

echo "=== A: through a PATH symlink, KIT_ROOT is the kit and the lockfile resolves ==="
run link "$TMP/a.json"
kr="$(jq -r '.kitRoot' "$TMP/a.json" 2>/dev/null)"
lk="$(jq -r '.lockfile' "$TMP/a.json" 2>/dev/null)"
[ "$kr" = "$KIT" ] && ok "A: kitRoot=$kr" || bad "A: kitRoot" "got '$kr', want $KIT"
[ "$lk" = "$KIT/loom.lock.json" ] && ok "A: lockfile resolved" || bad "A: lockfile" "got '$lk'"

echo "=== B: by path, the same answers ==="
run path "$TMP/b.json"
kr="$(jq -r '.kitRoot' "$TMP/b.json" 2>/dev/null)"
lk="$(jq -r '.lockfile' "$TMP/b.json" 2>/dev/null)"
[ "$kr" = "$KIT" ] && ok "B: kitRoot=$kr" || bad "B: kitRoot" "got '$kr'"
[ "$lk" = "$KIT/loom.lock.json" ] && ok "B: lockfile resolved" || bad "B: lockfile" "got '$lk'"

echo "=== C: the notepad is still discovered from cwd, not from the kit ==="
np="$(jq -r '.notepad' "$TMP/a.json" 2>/dev/null)"
src="$(jq -r '.notepadSource' "$TMP/a.json" 2>/dev/null)"
[ "$np" = "$NP" ] && ok "C: notepad=$np" || bad "C: notepad" "got '$np', want $NP"
[ "$src" = "discovered from cwd" ] && ok "C: source is cwd discovery" || bad "C: source" "got '$src'"

echo
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
