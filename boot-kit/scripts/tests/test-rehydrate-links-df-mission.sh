#!/usr/bin/env bash
# test-rehydrate-links-df-mission.sh — the engine must be REACHABLE, not merely materialised.
#
# ⛔ WHY THIS EXISTS. Measured 2026-09-05, per kit installer: the four personal kits link
# `df-mission` onto PATH in their own step 4; `<a sibling instance repo>` and `<a personal kit>` DO NOT. Both
# copy the whole engine and then never link the single CLI entry point — so on those two the
# engine is fully present and the command does not exist.
#
# ⚠️ INSTALLED-BUT-UNREACHABLE IS NOT INSTALLED, and it is worse than absent because every
# file-presence check passes on it. It surfaces much later and points at the wrong thing:
# "command not found", at the moment somebody first needs it.
#
# ⚠️ THE FIX BELONGS HERE, NOT IN THE TWO FORKED INSTALLERS. Patching those would fix two
# machines and leave the next fork to rediscover it. In rehydrate.sh, every kit inherits it by
# MOVING A PIN — the same shape as wire-settings.py (#84) and register-merge-drivers.sh (#109).
#
# THE ASSERTION IS THE LINK ON DISK AND WHERE IT POINTS, never the message. A step that printed
# "df-mission on PATH" and linked nothing would pass a message-only check and fail this one.
#
# Usage: bash boot-kit/scripts/tests/test-rehydrate-links-df-mission.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
RH="${REHYDRATE:-$SCRIPTS/rehydrate.sh}"
[ -f "$RH" ] || { echo "missing $RH"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rhbin.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A minimal kit. `--offline` so nothing is fetched.
kit() {
  K="$TMP/$1"
  mkdir -p "$K/live" "$K/vendor" "$K/bin"
  jq -n '{vendorDir:"vendor",upstreams:{},install:{skills:[],skillSources:{},hooks:[],hookSources:{}}}' \
    > "$K/loom.lock.json"
}
run() { ( cd "$TMP/$1" && LOOM_LIVE="$TMP/$1/live" LOOM_BIN="$TMP/$1/bin" \
           bash "$RH" --offline 2>&1 ); }

echo "=== A: df-mission is linked, and the link RESOLVES to the engine copy ==="
kit a
O="$(run a)"
if [ -L "$TMP/a/bin/df-mission" ]; then ok "A: a symlink was created"
else bad "A: a symlink was created" "df-mission is installed and unreachable"; fi
# ⚠️ Resolves — a link to a path that does not exist is the same failure wearing a symlink.
if [ -e "$TMP/a/bin/df-mission" ]; then ok "A: the link resolves"
else bad "A: the link resolves" "dangling"; fi
TARGET="$(readlink "$TMP/a/bin/df-mission" 2>/dev/null || true)"
case "$TARGET" in
  */df-mission) ok "A: it points at the engine's df-mission" ;;
  *) bad "A: it points at the engine's df-mission" "target=$TARGET" ;;
esac

echo "=== B: --dry-run writes NOTHING ==="
kit b
O="$( cd "$TMP/b" && LOOM_LIVE="$TMP/b/live" LOOM_BIN="$TMP/b/bin" bash "$RH" --offline --dry-run 2>&1 )"
contains "B: it says what it would do" "would link" "$O"
if [ -e "$TMP/b/bin/df-mission" ]; then bad "B: nothing is written" "a link was created"
else ok "B: nothing is written"; fi

echo "=== C: a real DIRECTORY in the way is REFUSED, not deleted and not nested into ==="
# ⚠️ rm-then-ln, never a bare `ln -sf`: if the existing name still RESOLVES TO A DIRECTORY,
# `ln -sf` creates the new link INSIDE it and leaves the original untouched, so the repoint
# silently does not take. This estate lost an afternoon to exactly that on ~/.claude/skills.
#
# ⛔ BUT THE ANSWER IS NOT `rm -rf`. This script cannot know what is inside a directory the
# operator put in their own ~/.local/bin, and destroying it to install a convenience symlink
# is a trade nobody agreed to. Refuse, say exactly what to do, carry on — and say it LOUDLY,
# because the consequence is that the command will not resolve.
kit c
mkdir -p "$TMP/c/bin/df-mission"          # the pathological case: a real DIRECTORY in the way
O="$(run c)"
if [ -d "$TMP/c/bin/df-mission" ] && [ ! -L "$TMP/c/bin/df-mission" ]; then
  ok "C: the operator's directory is left intact"
else bad "C: the operator's directory is left intact" "it was replaced or deleted"; fi
if [ -e "$TMP/c/bin/df-mission/df-mission" ]; then
  bad "C: no nested stray link" "a link was nested inside the old directory"
else ok "C: no nested stray link"; fi
contains "C: the refusal is reported" "refusing to delete it" "$O"
contains "C: and names the consequence" "will NOT resolve"     "$O"

echo "=== C2: the ordinary repeat run is idempotent ==="
kit c2
run c2 >/dev/null 2>&1
run c2 >/dev/null 2>&1
if [ -L "$TMP/c2/bin/df-mission" ] && [ -e "$TMP/c2/bin/df-mission" ]; then
  ok "C2: a second run leaves one valid link"
else bad "C2: a second run leaves one valid link" "the repeat run broke it"; fi

echo "=== D: an engine with no df-mission is REPORTED, never silently skipped ==="
# A kit pinned before df-mission existed is the pin doing its job, not a fault — but the
# reader must be able to see it, or "no CLI" looks like a broken install later.
kit d
FAKE="$TMP/fakeengine"; mkdir -p "$FAKE"
cp "$SCRIPTS/rehydrate.sh" "$FAKE/rehydrate.sh"      # engine dir WITHOUT df-mission beside it
O="$( cd "$TMP/d" && LOOM_LIVE="$TMP/d/live" LOOM_BIN="$TMP/d/bin" \
      bash "$FAKE/rehydrate.sh" --offline 2>&1 )"
contains "D: the absence is reported" "df-mission not in the pinned engine" "$O"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
