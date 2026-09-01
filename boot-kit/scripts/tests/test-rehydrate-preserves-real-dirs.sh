#!/usr/bin/env bash
# test-rehydrate-preserves-real-dirs.sh — rehydrate must not destroy the only copy of a skill.
#
# WHY THIS EXISTS. Installing a skill is `rm -rf "$LIVE/skills/$s"` then `ln -s`. That covers
# two cases with very different consequences:
#
#   the entry is a SYMLINK to somewhere else -> deleting it destroys nothing. The bytes are
#     at the other end of the link; re-linking undoes it completely.
#   the entry is a REAL DIRECTORY -> deleting it destroys the only copy. Anyone who had
#     edited a skill in place loses that work with no backup and no trace.
#
# Both printed the same OVERRIDE line, so the unrecoverable case looked exactly like the
# harmless one. Outside-installer feedback (24-27 Aug 2026, finding 09) reported it on two
# machines: "the right end state, invisibly reached", and on the second machine eight skills
# changed owner silently and it took a `readlink` to notice.
#
# ⚠️ HALF OF THAT REPORT WAS ALREADY FIXED AND THE DATE IS THE POINT. The OVERRIDE counter
# landed 2026-08-31 in 2474db0 — AFTER their install window — so they ran a rehydrate that
# said nothing at all. What remained is that a printed line is not enough when the operation
# is unrecoverable. Content nobody can get back is MOVED, not described.
#
# THE ASSERTION IS THE FILE, NOT THE MESSAGE. Case A writes a known byte string into the
# pre-existing skill and then demands to read it back from the preserve directory. A change
# that printed a stern warning and still called `rm -rf` would pass a message-only check and
# fail this one.
#
# Usage: bash boot-kit/scripts/tests/test-rehydrate-preserves-real-dirs.sh
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
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A scratch instance: a lockfile declaring one skill that resolves via `local:` into the
# instance itself, so --offline needs no network and no vendor fetch.
mkinstance() { # $1 = instance dir
  local I="$1"
  mkdir -p "$I/my-skills/widget"
  echo "canonical source" > "$I/my-skills/widget/SKILL.md"
  jq -n '{
    vendorDir: "vendor",
    upstreams: {},
    install: { skills: ["widget"], skillSources: { widget: "local:my-skills/widget" }, hooks: [] }
  }' > "$I/loom.lock.json"
  mkdir -p "$I/vendor"
}

run_rehydrate() { # $1 = instance dir, $2 = live dir, rest = flags
  local I="$1" L="$2"; shift 2
  ( cd "$I" && LOOM_LIVE="$L" bash "$RH" --offline "$@" 2>&1 )
}

echo "=== A: a REAL directory is preserved, not deleted ==="
IA="$TMP/a/inst"; LA="$TMP/a/live"
mkinstance "$IA"; mkdir -p "$LA/skills/widget"
echo "MY-LOCAL-EDIT-42" > "$LA/skills/widget/SKILL.md"
outA="$(run_rehydrate "$IA" "$LA")"
contains "A: says the directory is real"      "is a REAL directory" "$outA"
contains "A: names the preserve destination"  ".skills-replaced/" "$outA"
found="$(find "$LA/.skills-replaced" -name SKILL.md 2>/dev/null | head -1)"
if [ -n "$found" ] && grep -q 'MY-LOCAL-EDIT-42' "$found"; then
  ok "A: THE BYTES SURVIVED — local edit readable at $found"
else
  bad "A: THE BYTES SURVIVED" "local edit not recoverable under $LA/.skills-replaced"
fi
if [ -L "$LA/skills/widget" ]; then ok "A: skills/widget is now a symlink"
else bad "A: skills/widget is now a symlink" "not a link"; fi
if [ "$(cat "$LA/skills/widget/SKILL.md" 2>/dev/null)" = "canonical source" ]; then
  ok "A: the link resolves to the declared source"
else bad "A: the link resolves to the declared source" "unexpected content"; fi
# The preserve dir must not sit inside skills/, where the loader would read it as a skill.
if [ -e "$LA/skills/.skills-replaced" ]; then
  bad "A: preserve dir is outside skills/" "it was created inside skills/"
else ok "A: preserve dir is outside skills/"; fi

echo "=== B: a symlink is repointed, and NOT hoarded ==="
IB="$TMP/b/inst"; LB="$TMP/b/live"
mkinstance "$IB"; mkdir -p "$LB/skills" "$TMP/b/elsewhere"
echo "other" > "$TMP/b/elsewhere/SKILL.md"
ln -s "$TMP/b/elsewhere" "$LB/skills/widget"
outB="$(run_rehydrate "$IB" "$LB")"
contains "B: reports a reversible repoint" "repoints a symlink" "$outB"
absent   "B: does not claim a real directory" "is a REAL directory" "$outB"
if [ -d "$LB/.skills-replaced" ]; then
  bad "B: nothing preserved for a symlink" "created a preserve dir for a link"
else ok "B: nothing preserved for a symlink"; fi
if [ "$(cat "$LB/skills/widget/SKILL.md" 2>/dev/null)" = "canonical source" ]; then
  ok "B: the link was repointed"
else bad "B: the link was repointed" "unexpected content"; fi

echo "=== C: --dry-run destroys and moves nothing ==="
IC="$TMP/c/inst"; LC="$TMP/c/live"
mkinstance "$IC"; mkdir -p "$LC/skills/widget"
echo "STILL-HERE-99" > "$LC/skills/widget/SKILL.md"
outC="$(run_rehydrate "$IC" "$LC" --dry-run)"
if [ "$(cat "$LC/skills/widget/SKILL.md" 2>/dev/null)" = "STILL-HERE-99" ]; then
  ok "C: the original is untouched"
else bad "C: the original is untouched" "dry-run modified the tree"; fi
if [ -d "$LC/.skills-replaced" ]; then
  bad "C: dry-run created no preserve dir" "it created one"
else ok "C: dry-run created no preserve dir"; fi
contains "C: still PREDICTS the preserve" "is a REAL directory" "$outC"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
