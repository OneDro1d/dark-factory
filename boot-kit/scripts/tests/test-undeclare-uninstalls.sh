#!/usr/bin/env bash
# test-undeclare-uninstalls.sh — removing a skill from the lockfile must remove it from the machine.
#
# Enrolled by GLOB, per tests/README.md — "a suite is enrolled by existing".
#
# ⛔ WHAT IT PROTECTS, AND HOW IT WAS FOUND. handoff-auto was retired 2026-09-04: removed from
# Tier 1 and from every lockfile. Both reachable machines then reported `RESULT: DRIFT`, because
# `~/.claude/skills/handoff-auto` survived as a symlink into a directory that no longer existed.
# L10's words: "resolves INTO this instance but is declared by nothing here… installed by nothing,
# restored by nothing — and still loaded by the harness every session."
#
# ⚠️ THIS IS THE ESTATE'S DECLARED-vs-INSTALLED GAP POINTING THE OTHER WAY. The whole model rests
# on "content no lockfile declares does not exist", and the installer only ever ADDED. Declaring
# installed; un-declaring did nothing. Every person retiring a skill got a DRIFT verdict and a
# symlink to delete by hand — the kind of chore that teaches people to ignore a red result.
#
# THE THREE PROPERTIES, and the second is the one that keeps this from being destructive:
#   A  an undeclared link belonging to this instance is REMOVED
#   B  a link belonging to somebody ELSE is left alone       <- other instances, hand-made links
#   C  a REAL directory is NEVER removed                     <- it may be the only copy
# and a fourth, because the common case is the awkward one:
#   D  a DANGLING link is still pruned — the target went with the retirement, so "does it
#      resolve" cannot be the test; the LINK TEXT is.
#
# Usage: bash boot-kit/scripts/tests/test-undeclare-uninstalls.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
REHYDRATE="$SCRIPTS/rehydrate.sh"
[ -f "$REHYDRATE" ] || { echo "missing $REHYDRATE"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/undecl.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# an instance with a vendored upstream carrying two skills
mkdir -p "$W/inst/vendor/dark-factory/skills/kept"
mkdir -p "$W/inst/vendor/dark-factory/skills/retired"
printf 'x\n' > "$W/inst/vendor/dark-factory/skills/kept/SKILL.md"
printf 'x\n' > "$W/inst/vendor/dark-factory/skills/retired/SKILL.md"

# a SECOND instance on the same machine — its links must survive untouched
mkdir -p "$W/other/vendor/dark-factory/skills/theirs"
printf 'x\n' > "$W/other/vendor/dark-factory/skills/theirs/SKILL.md"

cat > "$W/inst/loom.lock.json" <<'JSON'
{
  "instance": "t",
  "vendorDir": "vendor",
  "upstreams": {},
  "install": {
    "skills": ["kept"],
    "skillSources": { "kept": "dark-factory/skills/kept" },
    "hooks": [], "hookSources": {}
  }
}
JSON

LIVE="$W/live"
mkdir -p "$LIVE/skills"

# the state a retirement leaves behind
ln -s "$W/inst/vendor/dark-factory/skills/kept"    "$LIVE/skills/kept"
ln -s "$W/inst/vendor/dark-factory/skills/retired" "$LIVE/skills/retired"     # undeclared, ours
ln -s "$W/other/vendor/dark-factory/skills/theirs" "$LIVE/skills/theirs"      # undeclared, NOT ours
mkdir -p "$LIVE/skills/handwritten"                                           # a REAL directory
printf 'precious\n' > "$LIVE/skills/handwritten/SKILL.md"
# and a DANGLING one — the target went with the retirement
ln -s "$W/inst/vendor/dark-factory/skills/vanished" "$LIVE/skills/vanished"

# ⚠️ rehydrate takes its instance from the CURRENT DIRECTORY: ROOT="$(pwd)" and LOCK is a
# RELATIVE filename. Invoking it with an absolute --lock from elsewhere resolves a different
# instance — which is what the first version of this test did, then reported the resulting
# no-op as the feature being broken.
OUT="$(cd "$W/inst" && LOOM_LIVE="$LIVE" bash "$REHYDRATE" 2>&1)" || true

echo "=== A: the declared skill survives ==="
if [ -L "$LIVE/skills/kept" ]; then ok "A kept is still linked"; else bad "A kept is still linked" "gone"; fi

echo "=== B: an undeclared link belonging to THIS instance is removed ==="
if [ ! -e "$LIVE/skills/retired" ] && [ ! -L "$LIVE/skills/retired" ]; then
  ok "B retired was unlinked"
else
  bad "B retired was unlinked" "still present — un-declaring did not uninstall"
fi
# and the content at the far end is untouched: a link removal must destroy nothing
if [ -f "$W/inst/vendor/dark-factory/skills/retired/SKILL.md" ]; then
  ok "B the content at the far end survived (a link was removed, not a skill)"
else
  bad "B the content at the far end survived" "the vendored copy was deleted"
fi

echo "=== C: a link belonging to ANOTHER instance is left alone ==="
# ⚠️ THE PROPERTY THAT KEEPS THIS FROM BEING DESTRUCTIVE. A machine carries several instances and
# a person's own hand-made links; an installer that removed every undeclared link would delete
# other people's work and call it tidying.
if [ -L "$LIVE/skills/theirs" ]; then ok "C another instance's link untouched"; else bad "C another instance's link untouched" "REMOVED — this installer deleted somebody else's work"; fi

echo "=== D: a REAL directory is never removed ==="
if [ -f "$LIVE/skills/handwritten/SKILL.md" ]; then
  ok "D a real directory survived"
else
  bad "D a real directory survived" "DELETED — it may have been the only copy"
fi

echo "=== E: a DANGLING link of ours is pruned too ==="
# The common case: the target was deleted with the retirement, so "does it resolve" cannot be
# the test — the link TEXT is.
if [ ! -L "$LIVE/skills/vanished" ]; then ok "E the dangling link was pruned"; else bad "E the dangling link was pruned" "still there"; fi

echo "=== F: it says what it did ==="
case "$OUT" in
  *UNLINKED*) ok "F reports each unlink" ;;
  *)          bad "F reports each unlink" "silent — an unexplained change is how the 24-27 Aug outside report described 'the right end state, invisibly reached'" ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
# ⚠️ REQUIRED BY run-tests.sh: a suite that exits 0 declaring no count is UNMEASURED, not PASS.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
