#!/usr/bin/env bash
# test-org-layer-ci.sh — every org layer minted from the Tier 2 template ships a working
# gate, and the generator does not damage it on the way out.
#
# WHY THIS EXISTS. `providentiaww/dark-factory-onedroid` — the OneDroid Tier 2 org layer,
# the register that decides what every minted Tier 3 instance installs — had NO `.github/`
# directory at all. Fixing that one repo leaves the generator producing CI-less org layers
# forever, so the template gained the gate too. This suite is the other half: it pins the
# claim "a minted layer has CI that works", which is otherwise maintained by whoever last
# remembered to check.
#
# THE DEFECT THIS SUITE WAS WRITTEN AROUND, measured 2026-08-26. `new-org-layer.sh`
# substitutes placeholders with `find "$TARGET" -type f | sed -i` — over EVERY file it
# copies, which now includes the template's own test suite. The first version of that suite
# compared the pin against the LITERAL placeholder token, so on a minted layer sed rewrote
# the comparison string to the minted SHA, the test compared the pin against itself, took
# the template branch, and reported "16 passed, 0 failed" with its pin assertion inert.
# The generator rewrites the test that guards it. C3 below is the assertion that catches
# that class: the minted copies must be BYTE-IDENTICAL to the template.
#
# Usage: bash starter-kit/tests/test-org-layer-ci.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = cannot run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T1="$(cd "$SELF/../.." && pwd)"
T2T="$T1/starter-kit/templates/tier2-org"
GEN="$T1/starter-kit/new-org-layer.sh"
[ -f "$GEN" ] || { echo "missing $GEN"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/orgci.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT

CI_FILES="scripts/run-tests.sh scripts/tests/test-repo-shape.sh .github/workflows/gate.yml"

# --- C1  the template ships all three ------------------------------------------------
for rel in $CI_FILES; do
  if [ -s "$T2T/$rel" ]; then pass "C1 template ships $rel"
  else fail "C1 template is missing $rel"; fi
done

# --- mint one layer ------------------------------------------------------------------
# `new-org-layer.sh` resolves the Tier 1 pin with `git ls-remote` and falls back to the
# BRANCH NAME when it cannot reach GitHub. Every assertion below that depends on the pin
# normalises it first, so this suite behaves identically online and offline.
MINTDIR="$WORK/mint"; mkdir -p "$MINTDIR"
GENOUT="$WORK/gen.out"
if bash "$GEN" dark-factory-citest citest/dark-factory-citest "$MINTDIR" "CI Test" >"$GENOUT" 2>&1; then
  pass "C2a new-org-layer.sh minted a layer"
else
  fail "C2a new-org-layer.sh failed — see $GENOUT"
  echo; echo "=== test-org-layer-ci: $PASS passed, $FAIL failed ==="
  # Declared here too, because this early exit is a FAILURE. A suite that exits without
  # an ASSERTIONS line is reported UNMEASURED instead, and UNMEASURED and FAIL have
  # different repairs -- naming the wrong one costs more than naming none.
  echo "ASSERTIONS: $((PASS + FAIL))"
  exit 1
fi
LAYER="$MINTDIR/dark-factory-citest"

# --- C2  the three files ARRIVED -----------------------------------------------------
# `cp -R "$TEMPLATE" "$TARGET"` carries dotfiles because it copies the directory itself.
# A future `cp -R "$TEMPLATE"/* "$TARGET"` would silently drop `.github/` and every gate
# would vanish from every layer minted afterwards, with nothing to say so.
for rel in $CI_FILES; do
  if [ -s "$LAYER/$rel" ]; then pass "C2b minted layer has $rel"
  else fail "C2b minted layer is MISSING $rel — did the copy stop carrying dotfiles?"; fi
done

# --- C3  and arrived UNDAMAGED -------------------------------------------------------
for rel in $CI_FILES; do
  if [ ! -f "$T2T/$rel" ] || [ ! -f "$LAYER/$rel" ]; then
    # C2b already reported the absence. Saying "MODIFIED" here as well would name the
    # wrong defect, and a wrong diagnosis costs more than a missing one.
    fail "C3 cannot compare $rel — it is absent on one side (see C1/C2b)"
  elif diff -q "$T2T/$rel" "$LAYER/$rel" >/dev/null 2>&1; then
    pass "C3 minted $rel is byte-identical to the template"
  else
    fail "C3 the generator MODIFIED $rel — a placeholder token in it was substituted; a test whose own comparison string is rewritten judges nothing"
  fi
done

# `env -u RUN_TESTS_ACTIVE` on every nested call below. Tier 1's runner exports that
# variable and the minted runner refuses to re-enter a tree that CONTAINS it — correct for
# recursion, wrong here, because the minted layer is a DIFFERENT repo that merely happens
# to be running underneath. Without this the assertions pass standalone and fail only in
# CI, which is the worst possible place to learn it.
run_minted() { ( cd "$1" && env -u RUN_TESTS_ACTIVE bash scripts/run-tests.sh ) >"$2" 2>&1; }

pin() { jq --arg v "$2" '.upstreams["dark-factory"].commit=$v' "$1/org.lock.json" > "$1/.l" && mv "$1/.l" "$1/org.lock.json"; }

# --- C4  a well-formed minted layer PASSES its own gate ------------------------------
pin "$LAYER" 0123456789abcdef0123456789abcdef01234567
run_minted "$LAYER" "$WORK/c4.out"; rc=$?
if [ "$rc" -eq 0 ]; then pass "C4a minted gate exits 0 on a well-formed layer"
else fail "C4a minted gate exited $rc on a well-formed layer — $(tail -3 "$WORK/c4.out" | tr '\n' ' ')"; fi
if grep -qE 'discovered [1-9][0-9]* suites' "$WORK/c4.out"; then pass "C4b minted gate discovered at least one suite"
else fail "C4b minted gate discovered no suites — $(head -2 "$WORK/c4.out" | tr '\n' ' ')"; fi

# --- C5  and FAILS on a defect. A gate only ever seen passing is not known to work. ---
pin "$LAYER" main
run_minted "$LAYER" "$WORK/c5.out"; rc=$?
if [ "$rc" -ne 0 ]; then pass "C5a minted gate exits non-zero when the Tier 1 pin is a branch name (rc=$rc)"
else fail "C5a minted gate exited 0 on an UNRESOLVED pin — the seed suite is inert"; fi
if grep -q 'A3' "$WORK/c5.out" || grep -q 'test-repo-shape' "$WORK/c5.out"; then
  pass "C5b the failure is reported by name"
else fail "C5b the gate failed without naming the suite"; fi
pin "$LAYER" 0123456789abcdef0123456789abcdef01234567

# --- C6  zero suites discovered is a HARD FAILURE, not a pass ------------------------
SCRATCH="$WORK/empty"; mkdir -p "$SCRATCH/scripts"
cp "$T2T/scripts/run-tests.sh" "$SCRATCH/scripts/run-tests.sh"
( cd "$SCRATCH" && env -u RUN_TESTS_ACTIVE bash scripts/run-tests.sh ) >"$WORK/c6.out" 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "C6 runner exits 2 when it discovers no suites"
else fail "C6 runner exited $rc with no suites present — a glob matching nothing must not be a pass"; fi

# --- C7  the exit status comes from the TALLY, never from the last child -------------
# A failing suite sorting BEFORE a passing one is the case a naive loop gets wrong.
TALLY="$WORK/tally"; mkdir -p "$TALLY/scripts/tests"
cp "$T2T/scripts/run-tests.sh" "$TALLY/scripts/run-tests.sh"
printf '#!/usr/bin/env bash\nexit 3\n' > "$TALLY/scripts/tests/test-aaa-fails.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TALLY/scripts/tests/test-zzz-passes.sh"
( cd "$TALLY" && env -u RUN_TESTS_ACTIVE bash scripts/run-tests.sh ) >"$WORK/c7.out" 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then pass "C7a runner exits 1 when an EARLY suite fails and a later one passes"
else fail "C7a runner exited $rc — the status was taken from the last child, not the tally"; fi
if grep -q 'test-aaa-fails.sh (rc=3)' "$WORK/c7.out"; then pass "C7b the failing suite is named with its rc"
else fail "C7b the failing suite was not named"; fi

echo
echo "=== test-org-layer-ci: $PASS passed, $FAIL failed ==="

# The assertion-count contract read by run-tests.sh (see its header). Exit status alone
# cannot tell "asserted every case above" from "asserted nothing" -- both exit 0 -- so the
# count is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
