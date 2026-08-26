#!/usr/bin/env bash
# test-run-tests.sh — the runner enrols by existence, and CANNOT report a green pass it
# has not earned.
#
# WHY THIS EXISTS. `run-tests.sh` replaces a hand-written list of suites in CI with a
# glob. That trade is only worth making if the runner itself cannot lie, and the two ways
# a runner lies are both easy to write by accident:
#
#   * `for f in …; do bash "$f"; done` exits with the LAST child's status, so a failure
#     followed by a pass exits 0. A6 orders the scratch tree so the FAILING suite sorts
#     first and a passing one sorts last — a runner with this defect exits 0 and A4 fires.
#   * A glob that matches nothing loops zero times and exits 0. A7/A8 assert that
#     discovering no suites is a hard failure, because "the directory moved" must not be
#     indistinguishable from "everything passed".
#
# Every fake suite TOUCHES A MARKER FILE when it runs. Exit status alone cannot tell
# "ran and passed" from "never ran", so the markers are the assertion and the exit status
# is only ever a second signal. A9's vendor decoy is the sharpest case: it exits 1, so if
# the prune failed the run would go red — but C3 proves the decoy is capable of running at
# all, without which A9 would pass on a decoy that was simply broken.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RUNNER="$ROOT/boot-kit/scripts/run-tests.sh"

PASSED=0; FAILED=0
ok()   { PASSED=$((PASSED+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAILED=$((FAILED+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-run-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Write a fake suite at $1 that touches a marker named after itself and exits $2.
# $3 is what it DECLARES on stdout: a number emits `ASSERTIONS: <n>`; the literal word
# `silent` emits no count line at all. Default 1 — a fake suite that declared nothing
# would be UNMEASURED under the contract, and every A-assertion below would then be
# exercising the unmeasured path rather than the path it names.
mksuite() {
  mkdir -p "$(dirname "$1")"
  decl="${3:-1}"
  cat > "$1" <<SUITE
#!/usr/bin/env bash
touch "\$MARKDIR/\$(basename "\$0")"
SUITE
  case "$decl" in
    silent) : ;;
    *)      printf 'echo "ASSERTIONS: %s"\n' "$decl" >> "$1" ;;
  esac
  printf 'exit %s\n' "$2" >> "$1"
  chmod +x "$1"
}

run_runner() {  # run_runner <marker-dir> <args...>  -> sets OUT, RC
  MARKDIR="$WORK/$1"; export MARKDIR
  rm -rf "$MARKDIR"; mkdir -p "$MARKDIR"
  OUT="$(bash "$RUNNER" "${@:2}" 2>&1)"; RC=$?
  return 0
}
ran() { [ -e "$WORK/$1/$2" ] && echo yes || echo no; }

# ---------------------------------------------------------------- controls
[ -r "$RUNNER" ] && ok "C1 runner is present and readable" \
                 || bad "C1 runner is present and readable" "no file at $RUNNER"

# ---------------------------------------------------------------- ALLPASS tree
A="$WORK/allpass"
mksuite "$A/test-one.sh" 0
mksuite "$A/deep/test-two.sh" 0
mksuite "$A/deep/deeper/test-three.sh" 0          # depth-independent discovery

run_runner m1 --root "$A"
check "A1  all-pass tree exits 0"                        "$RC"  "0"
check "A2a top-level suite ran"                          "$(ran m1 test-one.sh)"   "yes"
check "A2b nested suite ran"                             "$(ran m1 test-two.sh)"   "yes"
check "A12 depth-3 suite ran (glob is not depth-capped)" "$(ran m1 test-three.sh)" "yes"
case "$OUT" in *"discovered 3 suites"*) ok "A3  reports the discovered count" ;;
               *) bad "A3  reports the discovered count" "output: $OUT" ;; esac
check "A2c the runner reports one PASS line per suite" \
      "$(printf '%s' "$OUT" | grep -c '^PASS')" "3"

# ---------------------------------------------------------------- FAILFIRST tree
# `test-a-fails` sorts BEFORE `test-z-passes`, so a runner that returns the last child's
# status exits 0 here. That is the whole point of the ordering.
F="$WORK/failfirst"
mksuite "$F/test-a-fails.sh" 1
mksuite "$F/test-z-passes.sh" 0

run_runner m2 --root "$F"
check "A4  a failure followed by a pass still exits 1" "$RC" "1"
check "A5  the suite AFTER the failure still ran"  "$(ran m2 test-z-passes.sh)" "yes"
check "A5b the failing suite itself ran"           "$(ran m2 test-a-fails.sh)"  "yes"
case "$OUT" in *test-a-fails.sh*) ok "A6  the failing suite is named in the output" ;;
               *) bad "A6  the failing suite is named in the output" "output: $OUT" ;; esac

# ---------------------------------------------------------------- EMPTY tree
E="$WORK/empty"; mkdir -p "$E/nothing/here"
run_runner m3 --root "$E"
[ "$RC" -ne 0 ] && ok "A7  discovering zero suites is NOT a pass" \
                || bad "A7  discovering zero suites is NOT a pass" "rc=$RC"
check "A8  zero discovery exits 2 — an environment fault, not a test failure" "$RC" "2"

# ---------------------------------------------------------------- VENDOR prune
# A COPY of a suite inside vendor/ must not be run: it reports on the cache, not the repo.
V="$WORK/vendored"
mksuite "$V/test-real.sh" 0
mksuite "$V/vendor/dark-factory/test-decoy.sh" 1
run_runner m4 --root "$V"
check "A9  a suite inside vendor/ is pruned"  "$(ran m4 test-decoy.sh)" "no"
check "A10 pruning leaves the run green"      "$RC" "0"
# C3 — the decoy is CAPABLE of running. Without this, A9 passes on a decoy that is simply
# broken, and the prune would be unproven.
run_runner m5 --root "$V/vendor/dark-factory"
check "C3  the vendor decoy DOES run when it is the root" "$(ran m5 test-decoy.sh)" "yes"

# ---------------------------------------------------------------- enrolment by existence
# The property the whole change buys: a suite is enrolled by being committed, with no
# edit to the runner and no edit to CI.
mksuite "$A/test-brand-new.sh" 0
run_runner m6 --root "$A"
check "A11 a newly added suite runs with NO edit to the runner" \
      "$(ran m6 test-brand-new.sh)" "yes"
case "$OUT" in *"discovered 4 suites"*) ok "A11b the count follows the directory" ;;
               *) bad "A11b the count follows the directory" "output: $OUT" ;; esac

# ---------------------------------------------------------------- flag forms
run_runner m7 --root="$F"
# A13 and A13b only pin the behaviour AS A PAIR. Delete the `--root=*)` case and the
# argument falls to the catch-all, exiting 2 — which is also "not zero", so a looser A13
# would pass on a runner that never read the flag at all.
check "A13 --root=DIR runs DIR and reports its failure (rc 1, not the usage 2)" "$RC" "1"
check "A13b --root=DIR ran DIR's suites, not the repo's" "$(ran m7 test-a-fails.sh)" "yes"
run_runner m8 --root "$F"
check "A14 --root DIR selects DIR" "$(ran m8 test-a-fails.sh)" "yes"

# A15 asserts the MESSAGE as well as the code, and runs against the empty tree. Without
# both halves this passes for the wrong reason: a runner that ignores the flag and then
# discovers nothing also exits 2. Without --root it is worse than wrong — an ignored flag
# makes discovery fall back to the repo root, which contains THIS file, which invokes the
# runner again. The assertion would hang instead of failing.
run_runner m9 --frobnicate --root "$E"
check "A15  an unknown argument exits 2"              "$RC" "2"
case "$OUT" in *"unknown argument"*) ok "A15b …and says so, rather than exiting 2 for some other reason" ;;
               *) bad "A15b …and says so, rather than exiting 2 for some other reason" "output: $OUT" ;; esac

# A19 guards the hazard A15 describes, at the runner rather than at the call sites. A
# static sweep for unguarded call sites cannot work here — this file invokes the runner
# through a helper, so the flag and the invocation are never on the same line. The runner
# refuses instead: nesting is fine, nesting onto a tree that contains the runner is not.
OUT="$(RUN_TESTS_ACTIVE=1 bash "$RUNNER" --list --root "$ROOT" 2>&1)"; RC=$?
check "A19  a nested run over a tree containing the runner is refused" "$RC" "2"
case "$OUT" in *"refusing to re-enter"*) ok "A19b …and says why" ;;
               *) bad "A19b …and says why" "output: $OUT" ;; esac
# A19c — the guard fires only when NESTED. An unnested run over the real repo must still
# work, or the guard has replaced an infinite loop with a runner that cannot run.
OUT="$(env -u RUN_TESTS_ACTIVE bash "$RUNNER" --list --root "$ROOT" 2>&1)"; RC=$?
check "A19c an UNNESTED run over the real repo is allowed" "$RC" "0"
case "$OUT" in *test-run-tests.sh*) ok "A19d …and discovers this very suite" ;;
               *) bad "A19d …and discovers this very suite" "output: $OUT" ;; esac
run_runner m10 --root
check "A16 --root with no value exits 2, does not fall back to the repo root" "$RC" "2"
check "A16b …and runs nothing" "$(ls "$WORK/m10" | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------- --list
run_runner m11 --list --root "$A"
check "A17 --list runs no suite"        "$(ls "$WORK/m11" | wc -l | tr -d ' ')" "0"
check "A18 --list exits 0"              "$RC" "0"
case "$OUT" in *test-brand-new.sh*) ok "A17b --list names the suites" ;;
               *) bad "A17b --list names the suites" "output: $OUT" ;; esac

# ------------------------------------------------- the assertion-count contract (B*)
# The defect these guard: `bash "$suite" >/dev/null 2>&1; rc=$?` cannot tell "asserted 44
# things" from "asserted nothing". Both exit 0 and both rendered as `PASS 0s`. Exit
# status is a proxy for having-been-checked, and a proxy is exactly what decays silently
# — a suite whose glob stops matching, whose fixture directory moves, or whose assertions
# get commented out during a debug session keeps reporting PASS forever.
#
# The contract is DECLARED, not parsed. The suites on main print their totals in SIX
# different formats (`N passed, 0 failed`, `=== N passed …`, `forward : N assertions …`,
# `RESULT: PASS — 9/9 cases behave (9 asserted)`, `passed: 14   failed: 0`, `4/4 classes
# behave`), so a runner that greps for a count is a hand-written list of formats — the
# same rot this runner's glob exists to avoid, one level down. Each suite emits
# `ASSERTIONS: <n>` and the runner reads that or refuses to call it a pass.
B="$WORK/counts"
mksuite "$B/test-counts.sh"  0 5

run_runner m12 --root "$B"
# B1 is a CONTROL, and it passes against the OLD runner too: a suite that exits 0 has
# always exited 0. It is here so that a B-block gone entirely red is distinguishable from
# one that broke the happy path.
check "B1  a suite that declares a positive count still exits 0"  "$RC" "0"
# Matched against the PASS LINE, not against $OUT. A `case "$OUT" in *"5 assertions"*`
# here is satisfied by the SUMMARY line — it stayed green through an ablation that
# stripped the count from the per-suite line entirely, which is the thing it names.
check "B2  the per-suite PASS line carries the declared count" \
      "$(printf '%s\n' "$OUT" | grep -c '^PASS.*5 assertions')" "1"

# B3/B4 — the defect itself. A suite that exits 0 having asserted nothing is the exact
# input the ticket demonstrated, and the old runner printed `PASS 0s` for it.
S="$WORK/silent"
mksuite "$S/test-says-nothing.sh" 0 silent
run_runner m13 --root "$S"
check "B3  a suite that declares NO count is not a pass"          "$RC" "1"
check "B3b …and it did run — this is not 'the suite was skipped'" "$(ran m13 test-says-nothing.sh)" "yes"
case "$OUT" in *UNMEASURED*) ok "B4  …and the runner says UNMEASURED" ;;
               *) bad "B4  …and the runner says UNMEASURED" "output: $OUT" ;; esac

# B5/B6 — declaring zero is honest and still not a pass. Kept distinct from B3 because
# the two have different repairs: UNMEASURED means the suite has not adopted the
# contract, VACUOUS means its assertions stopped executing.
Z="$WORK/zero"
mksuite "$Z/test-asserts-zero.sh" 0 0
run_runner m14 --root "$Z"
check "B5  a suite that declares ZERO assertions is not a pass"   "$RC" "1"
case "$OUT" in *VACUOUS*) ok "B6  …and the runner says VACUOUS, distinct from UNMEASURED" ;;
               *) bad "B6  …and the runner says VACUOUS, distinct from UNMEASURED" "output: $OUT" ;; esac

# B7 — the total is the number a reader actually uses to notice a drop.
T2="$WORK/total"
mksuite "$T2/test-a.sh" 0 4
mksuite "$T2/test-b.sh" 0 7
run_runner m15 --root "$T2"
check "B7a two declaring suites exit 0" "$RC" "0"
case "$OUT" in *"11 assertions"*) ok "B7b the summary reports the TOTAL declared assertions (11)" ;;
               *) bad "B7b the summary reports the TOTAL declared assertions (11)" "output: $OUT" ;; esac

# B8 — a CONTROL in the other direction. A non-zero exit is still a failure however many
# assertions the suite declares; the count must not be able to rescue a red suite.
X="$WORK/countfail"
mksuite "$X/test-red.sh" 1 9
run_runner m16 --root "$X"
check "B8  a declared count does NOT rescue a suite that exited non-zero" "$RC" "1"

# B9 — a suite that drives sub-suites prints several count lines. The LAST one is its own
# total; taking the first would report a sub-suite's count as the whole suite's.
M="$WORK/multi"
mkdir -p "$M"
cat > "$M/test-multi.sh" <<'MULTI'
#!/usr/bin/env bash
touch "$MARKDIR/$(basename "$0")"
echo "ASSERTIONS: 2"
echo "ASSERTIONS: 6"
exit 0
MULTI
chmod +x "$M/test-multi.sh"
run_runner m17 --root "$M"
check "B9a several count lines is not an error" "$RC" "0"
case "$OUT" in *"6 assertions"*) ok "B9b the LAST declared count wins" ;;
               *) bad "B9b the LAST declared count wins" "output: $OUT" ;; esac

# B10 — the conversion itself, guarded statically so it cannot rot back. Running the real
# runner over the real repo from here would re-enter it (A19), so this greps instead:
# every discovered suite in this repo must carry an emitter. It checks the FILE, not a
# run, and is honest about that — a suite could carry the string in a comment. It exists
# to catch a NEW suite committed without the line, which is how the conversion decays.
missing=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qE 'ASSERTIONS:' "$f" || { missing=$((missing+1)); echo "     no emitter: ${f#$ROOT/}"; }
done <<REPO
$(find "$ROOT" \( -name .git -o -name vendor -o -name node_modules \) -prune \
   -o -type f -name 'test-*.sh' -print | LC_ALL=C sort)
REPO
check "B10 every test-*.sh in this repo declares an assertion count" "$missing" "0"

# This suite must obey its own contract.
echo "ASSERTIONS: $((PASSED + FAILED))"

echo
echo "=== $PASSED passed, $FAILED failed ==="
[ "$FAILED" -eq 0 ] || exit 1
