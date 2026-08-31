#!/usr/bin/env bash
# test-instance-ci.sh — a Tier-3 instance ships a runner and CI, and the runner sees the
# WHOLE instance rather than the corner it happens to live in.
#
# WHY THIS EXISTS. Tier 3 is the record of ONE machine and the last tier before a real
# environment. Measured 2026-08-31, it was the only tier in the estate with no runner and no
# `.github/` — Tier 1 fixed that for itself, Tier 2 got the same treatment, Tier 3 was left
# behind twice. Worse than absence: the reference instance in the estate this method came
# from SHIPS a suite under `boot-kit/tests/` with nothing to run it, so somebody wrote a
# check that never executes.
#
# ⚠️ THE ASSERTION THAT MATTERS IS D1, THE DEPTH ONE, and it is why this suite is not just
# "the file exists". The runner lives at `boot-kit/scripts/` — TWO levels down — while the
# Tier-2 copy it was seeded from lives at `scripts/` and computes `ROOT="$HERE/.."`. Carried
# over verbatim, ROOT lands on `boot-kit/` and discovery sweeps ONE suite instead of five,
# then prints `5 passed`-shaped output about a fraction of the repo. Nothing about that
# looks wrong: the run is green, the count is plausible, and four suites simply never ran.
# A file-exists check would pass throughout.
#
# Usage: bash starter-kit/tests/test-instance-ci.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = cannot run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T1="$(cd "$SELF/../.." && pwd)"
KIT="$T1/starter-kit/instance"
RUNNER="$KIT/boot-kit/scripts/run-tests.sh"
WF="$KIT/.github/workflows/gate.yml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/instci.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT

# Every nested call clears RUN_TESTS_ACTIVE. Tier 1's runner exports it and this one refuses
# to re-enter a tree containing itself — correct for recursion, wrong here, where the kit is
# a different (future) repo that merely lives inside Tier 1. Without this the suite passes
# standalone and fails only in CI, which is the worst place to learn it.
run_kit() { ( cd "$KIT" && env -u RUN_TESTS_ACTIVE bash boot-kit/scripts/run-tests.sh "$@" ) 2>&1; }

echo "=== A: the kit ships both halves ==="
[ -s "$RUNNER" ] && ok "A1 boot-kit/scripts/run-tests.sh is present" \
  || bad "A1 boot-kit/scripts/run-tests.sh is present" "absent — a minted instance gets no runner"
[ -s "$WF" ] && ok "A2 .github/workflows/gate.yml is present" \
  || bad "A2 .github/workflows/gate.yml is present" "absent — a minted instance gets no CI"
# `cp -R "$KIT" "$TARGET"` carries dotfiles because it copies the directory itself. A future
# `cp -R "$KIT"/* "$TARGET"` would silently drop `.github/`, and every instance minted after
# that would lose CI with nothing to say so — the exact defect C2b guards at Tier 2.
grep -q 'run-tests.sh' "$WF" 2>/dev/null && ok "A3 the workflow actually calls the runner" \
  || bad "A3 the workflow actually calls the runner" "gate.yml does not reference run-tests.sh"

echo "=== B: it runs, and reports assertions ==="
OUT="$(run_kit)"; RC=$?
[ "$RC" -eq 0 ] && ok "B1 the kit passes its own gate" || bad "B1 the kit passes its own gate" "rc=$RC"
case "$OUT" in *"assertions)"*) ok "B2 per-suite assertion counts are reported" ;;
              *) bad "B2 per-suite assertion counts are reported" "guarantee 4 is missing here" ;; esac

echo "=== C: enrolment is by existence ==="
case "$OUT" in *"discovered 5 suites"*) ok "C1 all five shipped suites are discovered" ;;
              *) bad "C1 all five shipped suites are discovered" "$(printf '%s' "$OUT" | head -1)" ;; esac

echo "=== D: DEPTH — the runner sees the instance, not just boot-kit ==="
# The whole point. `tests/` sits at the instance root; `boot-kit/tests/` sits beside the
# runner. A runner rooted one level too high finds ONLY the latter and still exits 0.
LIST="$(run_kit --list)"
case "$LIST" in *"tests/test-start-here-doc.sh"*) ok "D1 a ROOT-level suite is discovered" ;;
  *) bad "D1 a ROOT-level suite is discovered" "ROOT is too deep — discovery is confined to boot-kit/" ;; esac
case "$LIST" in *"boot-kit/tests/test-boot-kit.sh"*) ok "D2 a boot-kit suite is discovered too" ;;
  *) bad "D2 a boot-kit suite is discovered too" "not found" ;; esac
# ...and not too SHALLOW either, which is the opposite error: ROOT one level too high sweeps
# the whole of Tier 1 and reports a confident verdict about the wrong repo.
case "$LIST" in *"boot-kit/scripts/tests/"*)
    bad "D3 discovery does not escape the instance" "Tier 1's own suites were swept in" ;;
  *) ok "D3 discovery does not escape the instance" ;; esac

echo "=== E: and it can FAIL — a gate only ever seen passing is not known to work ==="
SCRATCH="$WORK/inst"; mkdir -p "$SCRATCH/boot-kit/scripts" "$SCRATCH/tests"
cp "$RUNNER" "$SCRATCH/boot-kit/scripts/run-tests.sh"
printf '#!/usr/bin/env bash\necho "ASSERTIONS: 2"\nexit 0\n' > "$SCRATCH/tests/test-good.sh"
printf '#!/usr/bin/env bash\nexit 4\n' > "$SCRATCH/tests/test-aaa-bad.sh"
OUT2="$( cd "$SCRATCH" && env -u RUN_TESTS_ACTIVE bash boot-kit/scripts/run-tests.sh 2>&1 )"; RC=$?
[ "$RC" -eq 1 ] && ok "E1 exits 1 when an EARLY suite fails and a later one passes" \
  || bad "E1 exits 1 on a failing suite" "rc=$RC — status taken from the last child?"
# guarantee 4, here rather than only in the Tier-2 suite: a silent suite must not pass.
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCRATCH/tests/test-aaa-bad.sh"
OUT3="$( cd "$SCRATCH" && env -u RUN_TESTS_ACTIVE bash boot-kit/scripts/run-tests.sh 2>&1 )"; RC=$?
[ "$RC" -eq 1 ] && ok "E2 a suite exiting 0 with no ASSERTIONS line is UNMEASURED, not passed" \
  || bad "E2 an unmeasured suite is a failure" "rc=$RC"
case "$OUT3" in *UNMEASURED*) ok "E3 it is named UNMEASURED" ;; *) bad "E3 it is named UNMEASURED" "not labelled" ;; esac
# CONTROL — with both suites well-formed it passes, so E1/E2 are not "fails on everything".
rm -f "$SCRATCH/tests/test-aaa-bad.sh"
( cd "$SCRATCH" && env -u RUN_TESTS_ACTIVE bash boot-kit/scripts/run-tests.sh >/dev/null 2>&1 )
[ $? -eq 0 ] && ok "E4 control: a well-formed instance still passes" \
  || bad "E4 control: a well-formed instance still passes" "the gate fails everything"

echo ""
printf 'instance-ci: %d ok, %d failed\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
