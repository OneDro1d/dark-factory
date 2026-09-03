#!/usr/bin/env bash
# test-kit-bootstrap.sh — `kits/` must be REACHABLE FROM AN INSTALL, not merely valid.
#
# Enrolled by GLOB, per tests/README.md — "a suite is enrolled by existing".
#
# WHAT IT PROTECTS, and why kit-check.sh does not already cover it.
#
# kit-check.py proves every kit RESOLVES: no kit names a skill this repo lacks. It has always
# passed. What nothing asked was whether any kit could be INSTALLED — and until kit-resolve.py
# and `bootstrap.sh --kit`, none could: measured, no path under starter-kit/ mentioned kits/,
# bootstrap.sh had no skill selection, and every bootstrapped instance shipped `"skills": []`
# with a skillSources map holding only a comment.
#
# ⚠️ THAT IS THIS REPO'S SIGNATURE DEFECT, one level up from where it usually appears: a thing
# DECLARED, shipped, correct, and wired to nothing. Every check that looks at the artefact
# passes. The gap is only visible to a check that looks at the JOIN — which is this one.
#
# Usage: bash boot-kit/scripts/tests/test-kit-bootstrap.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
ROOT="$(cd "$SCRIPTS/../.." && pwd)"
RESOLVER="$SCRIPTS/kit-resolve.py"
BOOTSTRAP="$ROOT/starter-kit/instance/bootstrap.sh"
[ -f "$RESOLVER" ]  || { echo "missing $RESOLVER"; exit 2; }
[ -f "$BOOTSTRAP" ] || { echo "missing $BOOTSTRAP"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }
command -v jq >/dev/null      || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kitboot.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- A. the resolver can fail ------------------------------------------------
# A gate that cannot fail is worse than none: it suppresses the caution its absence would
# prompt. This repo shipped one once — publish-gate.sh reported CLEAN over a planted canary
# with three bugs behind it.
OUT="$(python3 "$RESOLVER" --self-test 2>&1)"; RC=$?
contains "A self-test names its cases" "all pass" "$OUT"
if [ "$RC" -eq 0 ]; then ok "A self-test exits 0"; else bad "A self-test exits 0" "got $RC"; fi

OUT="$(python3 "$RESOLVER" definitely-not-a-kit --root "$ROOT" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then ok "A an absent kit is a non-zero exit"; else bad "A an absent kit is a non-zero exit" "got 0"; fi

# ---- B. extends pulls the floor in, in order --------------------------------
# kits/README.md says method-core is "the floor" and that the others "assume it is installed
# alongside". That was a dependency recorded in prose and enforced by nobody.
J="$(python3 "$RESOLVER" dev --root "$ROOT" 2>/dev/null)"
FIRST="$(printf '%s' "$J" | jq -r '.resolvedFrom[0]')"
if [ "$FIRST" = "method-core" ]; then ok "B the floor resolves FIRST"; else bad "B the floor resolves FIRST" "got $FIRST"; fi
N="$(printf '%s' "$J" | jq -r '.skills | length')"
if [ "$N" -gt 5 ]; then ok "B dev carries more than its own 5 skills ($N)"; else bad "B dev carries more than its own 5" "got $N"; fi

# ⚠️ A kit WITHOUT extends must be left alone. A resolver that helpfully injected the floor
# everywhere would make `extends` unfalsifiable and would silently overrule a kit that
# deliberately stands alone.
CH="$(python3 "$RESOLVER" method-core --root "$ROOT" 2>/dev/null | jq -r '.resolvedFrom | join(",")')"
if [ "$CH" = "method-core" ]; then ok "B a kit without extends is untouched"; else bad "B a kit without extends is untouched" "chain=$CH"; fi

# ---- C. every name comes with a source --------------------------------------
# The installer requires the pairing: a name with no entry in its *Sources map is a declaration
# it cannot resolve, and it fails at install time on the user's machine rather than here.
# array difference: the names, minus the names that have a source, must be empty
UNPAIRED="$(printf '%s' "$J" | jq -r '(.skills - (.skillSources | keys)) | length')"
TOTAL="$(printf '%s' "$J" | jq -r '.skills | length')"
if [ "$UNPAIRED" = "0" ]; then ok "C every skill has a source (0 unpaired of $TOTAL)"; else bad "C every skill has a source" "$UNPAIRED unpaired"; fi

# ---- D. bootstrap --kit writes them into the LOCKFILE ------------------------
# ⚠️ Asserted against the written file, never the console output. A bootstrap that prints
# "kits resolved: dev" and writes an empty list is precisely the false success this suite exists
# to catch.
bash "$BOOTSTRAP" t-dev "$WORK/t-dev" --kit dev >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then ok "D bootstrap --kit exits 0"; else bad "D bootstrap --kit exits 0" "got $RC"; fi
LOCK="$WORK/t-dev/loom.lock.json"
if [ -f "$LOCK" ]; then
  SK="$(jq -r '.install.skills | length' "$LOCK")"
  if [ "$SK" -gt 0 ]; then ok "D the lockfile declares $SK skills"; else bad "D the lockfile declares skills" "0"; fi
  BAD="$(jq -r '(.install.skills - (.install.skillSources | keys)) | length' "$LOCK")"
  if [ "$BAD" = "0" ]; then ok "D every declared skill has a source"; else bad "D every declared skill has a source" "$BAD unpaired"; fi
  BADH="$(jq -r '(.install.hooks - (.install.hookSources | keys)) | length' "$LOCK")"
  if [ "$BADH" = "0" ]; then ok "D every declared hook has a source"; else bad "D every declared hook has a source" "$BADH unpaired"; fi
  # the template's own hook must SURVIVE the merge -- the kit's lists are unioned onto the
  # template's, not substituted for them
  if jq -e '.install.hooks | index("df-instance-start.sh")' "$LOCK" >/dev/null; then
    ok "D the template's own hook survived the merge"
  else
    bad "D the template's own hook survived the merge" "df-instance-start.sh gone"
  fi
  if jq -e '.install["$kitResolution"]' "$LOCK" >/dev/null; then
    ok "D provenance recorded (which bundle these names came from)"
  else
    bad "D provenance recorded" "no \$kitResolution"
  fi
else
  bad "D lockfile written" "no $LOCK"
fi

# ---- E. a bad kit leaves NO half-built instance ------------------------------
# ⚠️ A half-built instance is WORSE than none: it exists, so the next run refuses to overwrite
# it, and the user is left with a directory that looks finished. Hence resolve-before-create.
bash "$BOOTSTRAP" t-ghost "$WORK/t-ghost" --kit ghost >/dev/null 2>&1; RC=$?
if [ "$RC" -ne 0 ]; then ok "E an unknown kit fails"; else bad "E an unknown kit fails" "exit 0"; fi
if [ ! -e "$WORK/t-ghost" ]; then ok "E and leaves no directory behind"; else bad "E and leaves no directory behind" "$WORK/t-ghost exists"; fi

# ---- F. --kit is OPTIONAL, and its absence stays honest ---------------------
# An empty skill list is a valid, honest starting state. A default set nobody chose is the thing
# this repo refuses to ship elsewhere (see kits/README.md and scope-init on docs-map defaults).
bash "$BOOTSTRAP" t-bare "$WORK/t-bare" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then ok "F bootstrap without --kit still works"; else bad "F bootstrap without --kit still works" "got $RC"; fi
if [ -f "$WORK/t-bare/loom.lock.json" ]; then
  SK="$(jq -r '.install.skills | length' "$WORK/t-bare/loom.lock.json")"
  if [ "$SK" = "0" ]; then ok "F and ships an empty skill list, not a guessed default"; else bad "F ships an empty skill list" "got $SK"; fi
fi

# ---- G. both kits this repo advertises as installable actually are -----------
for K in dev knowledge-worker; do
  if python3 "$RESOLVER" "$K" --root "$ROOT" >/dev/null 2>&1; then
    ok "G kits/$K resolves"
  else
    bad "G kits/$K resolves" "resolver failed"
  fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
# ⚠️ REQUIRED BY run-tests.sh. A suite that exits 0 while declaring no count is reported
# UNMEASURED, not PASS — because "it ran and said nothing" and "it ran and asserted nothing" are
# indistinguishable from outside, and the second is a suite that cannot fail. test-run-tests.sh
# B10 asserts that every test-*.sh in this repo emits this line, and it is what caught this file
# on its first run — the meta-gate working exactly as designed, on the suite added to test a gap.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
