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

# B11 — the runner pins LOOM_BIN and LOOM_LIVE away from the real home for every suite.
# MEASURED 2026-09-09: a full run from a worktree left ~/.local/bin/df-mission pointing into
# that worktree; removing the worktree dangled the link and every df-worker dispatch on the
# machine refused. A fake suite prints what it sees; both must be under a scratch dir, never
# under $HOME/.local/bin or $HOME/.claude, and a value the caller pre-set must be honoured.
H="$WORK/hermetic"
mkdir -p "$H"
cat > "$H/test-env.sh" <<'HERM'
#!/usr/bin/env bash
touch "$MARKDIR/$(basename "$0")"
echo "BIN=${LOOM_BIN:-unset}"
echo "LIVE=${LOOM_LIVE:-unset}"
echo "ASSERTIONS: 1"
exit 1
HERM
chmod +x "$H/test-env.sh"
# exit 1 on purpose: the runner prints a failing suite's tail, which is how we read the values.
( unset LOOM_BIN LOOM_LIVE; run_runner m18 --root "$H"; printf '%s\n' "$OUT" > "$WORK/b11.out" )
B11="$(cat "$WORK/b11.out")"
case "$B11" in *"BIN=$HOME/.local/bin"*|*"BIN=unset"*) bad "B11a LOOM_BIN is pinned away from ~/.local/bin" "output: $B11" ;;
                *"BIN="*) ok "B11a LOOM_BIN is pinned away from ~/.local/bin" ;;
                *) bad "B11a LOOM_BIN is pinned away from ~/.local/bin" "no BIN= line: $B11" ;; esac
case "$B11" in *"LIVE=$HOME/.claude"*|*"LIVE=unset"*) bad "B11b LOOM_LIVE is pinned away from ~/.claude" "output: $B11" ;;
                *"LIVE="*) ok "B11b LOOM_LIVE is pinned away from ~/.claude" ;;
                *) bad "B11b LOOM_LIVE is pinned away from ~/.claude" "no LIVE= line: $B11" ;; esac
( LOOM_BIN="$WORK/mybin" run_runner m19 --root "$H"; printf '%s\n' "$OUT" > "$WORK/b11c.out" )
case "$(cat "$WORK/b11c.out")" in *"BIN=$WORK/mybin"*) ok "B11c a caller's LOOM_BIN is honoured, not overridden" ;;
                                   *) bad "B11c a caller's LOOM_BIN is honoured" "output: $(cat "$WORK/b11c.out")" ;; esac

# This suite must obey its own contract.
# ------------------------------------------------- instance record must not leak into a suite
# MEASURED 2026-09-09 on the Poland Coder: a kit suite drove the real install.sh over scratch
# fixtures, install.sh reads ${LOOM_LOCK:-loom.lock.json}, and the Coder exports LOOM_LOCK from
# ~/.bashrc -- so every fixture was replaced by the machine's live record and the suite measured
# the wrong subject. It passed on the laptop only because LOOM_LOCK is unset there.
E="$WORK/envleak"
mkdir -p "$E"
# ⚠️ The probe WRITES what it saw; it does not print it. run-tests.sh captures a suite's
# stdout and prints it only when the suite FAILS, so a passing probe that printed its finding
# would leave the assertion below matching an empty string -- green for the wrong reason.
cat > "$E/test-envleak.sh" <<'SUITE'
#!/usr/bin/env bash
touch "$MARKDIR/$(basename "$0")"
{
  printf 'SAW_LOOM_LOCK=[%s]\n'  "${LOOM_LOCK-<unset>}"
  printf 'SAW_DF_PROFILE=[%s]\n' "${DF_PROFILE-<unset>}"
} > "$MARKDIR/saw.txt"
echo "ASSERTIONS: 1"
exit 0
SUITE
chmod +x "$E/test-envleak.sh"
MARKDIR="$WORK/menv"; export MARKDIR
rm -rf "$MARKDIR"; mkdir -p "$MARKDIR"
OUT="$(LOOM_LOCK=/nowhere/the-machines-own-record.json DF_PROFILE=someprofile bash "$RUNNER" --root "$E" 2>&1)"
SAW="$(cat "$MARKDIR/saw.txt" 2>/dev/null || echo '<probe never ran>')"
case "$SAW" in
  *'SAW_LOOM_LOCK=[<unset>]'*)  ok   "E1  LOOM_LOCK is unset for the suite, even when the caller exports it" ;;
  *) bad "E1  LOOM_LOCK is unset for the suite, even when the caller exports it" "$SAW" ;;
esac
case "$SAW" in
  *'SAW_DF_PROFILE=[<unset>]'*) ok   "E2  DF_PROFILE is unset too (the sibling path to the same sink)" ;;
  *) bad "E2  DF_PROFILE is unset too (the sibling path to the same sink)" "$SAW" ;;
esac
# and the scratch redirection above still holds -- unsetting must not have replaced it
case "$SAW$OUT" in
  *'the-machines-own-record'*) bad "E3  the machine's record never reaches the suite" "leaked" ;;
  *) ok "E3  the machine's record never reaches the suite" ;;
esac

# ---------------------------------------------------------------- F: a suite that reads stdin
# ⛔ MEASURED IN CI 2026-10-05, AND IT BLAMED THE WRONG FILE. The runner's loop is fed by a
# here-doc, and until this was fixed a child INHERITED that as its own stdin. A suite whose
# child reads stdin therefore consumed bytes the loop had not read yet, and the next iteration
# began mid-line: two suite paths arrived missing their leading bytes ("unner/work/…",
# "home/runner/…") and failed rc=127 "No such file or directory". The suites were fine. The
# gate reported a defect in them.
#
# ffmpeg is the canonical offender — it polls stdin for keyboard interaction unless given
# `-nostdin` — which is why this surfaced the moment the gate began installing it.
#
# ⚠️ TWO DISTINCT SEVERITIES, and the quieter one is worse. A greedy child (`cat`) eats the
# WHOLE list, so the run is mysteriously short and nothing says why. A polling child eats a few
# bytes, so you get a corrupt path that NAMES A FILE — and a name sends the reader to the wrong
# place. The eater here is greedy because it is deterministic; the fix closes both.
F="$WORK/stdineater"
# ⚠️ WRITTEN BY HAND, NOT VIA mksuite, AND THAT IS THE POINT. mksuite ends the file with
# `exit <n>`, so appending the stdin-eating line afterwards puts it AFTER the exit, where it
# never runs. The first version of this block did exactly that: all seven F assertions passed
# against a deliberately UN-fixed runner, because the eater never ate anything. An ablation
# run is what exposed it. A regression test that passes against the defect is decoration.
mkdir -p "$F"
cat > "$F/test-a-eats-stdin.sh" <<'EATER'
#!/usr/bin/env bash
touch "$MARKDIR/$(basename "$0")"
cat >/dev/null          # consume the runner's stdin, the way a stdin-polling tool does
echo "ASSERTIONS: 1"
exit 0
EATER
chmod +x "$F/test-a-eats-stdin.sh"
mksuite "$F/test-b-after.sh" 0
mksuite "$F/test-c-after.sh" 0
mksuite "$F/test-d-after.sh" 0
run_runner m_stdin --root "$F"
check "F1  a suite that eats stdin does not stop the run"        "$RC" "0"
check "F2  the eater itself ran"           "$(ran m_stdin test-a-eats-stdin.sh)" "yes"
check "F3  the suite AFTER the eater still ran"  "$(ran m_stdin test-b-after.sh)" "yes"
check "F4  …and the one after that"              "$(ran m_stdin test-c-after.sh)" "yes"
check "F5  …and the last one"                    "$(ran m_stdin test-d-after.sh)" "yes"
case "$OUT" in
  *'4 passed'*) ok "F6  all four suites are accounted for, none swallowed" ;;
  *) bad "F6  all four suites are accounted for, none swallowed" "$OUT" ;;
esac

# ---------------------------------------------------------------- G: a PARTIAL stdin reader
# ⛔ THIS IS THE EXACT CI SYMPTOM, REPRODUCED. The F fixture above is GREEDY: it eats the whole
# list, so the run goes short and no path is ever corrupted. A tool that merely POLLS stdin
# eats a few bytes and leaves the rest of a line behind — and then the next `read` returns a
# path missing its leading characters, which the runner dutifully reports as a missing FILE.
# That is what CI printed: "unner/work/…" (minus "/home/r") and "home/runner/…" (minus "/").
# ⚠️ Without this block, the "no corrupted path" assertion could not fail — a greedy eater
# never produces one. Two fixtures, because the two severities have different signatures and
# the quieter one is the one that misdirects the reader.
G="$WORK/stdinnibbler"
mkdir -p "$G"
cat > "$G/test-a-nibbles-stdin.sh" <<'NIBBLER'
#!/usr/bin/env bash
touch "$MARKDIR/$(basename "$0")"
head -c 7 >/dev/null    # eat SEVEN BYTES, leaving the rest of the next path behind
echo "ASSERTIONS: 1"
exit 0
NIBBLER
chmod +x "$G/test-a-nibbles-stdin.sh"
mksuite "$G/test-b-after.sh" 0
mksuite "$G/test-c-after.sh" 0
mksuite "$G/test-d-after.sh" 0
run_runner m_nibble --root "$G"
check "G1  a suite that nibbles stdin does not corrupt the run" "$RC" "0"
case "$OUT" in
  *'No such file or directory'*) bad "G2  no suite path arrives missing its leading bytes" "$OUT" ;;
  *) ok "G2  no suite path arrives missing its leading bytes" ;;
esac
check "G3  the suite after the nibbler ran"  "$(ran m_nibble test-b-after.sh)" "yes"
# ⚠️ G4 is a SANITY COMPANION, not a regression guard, and the difference is worth stating: a
# 7-byte nibble corrupts only the IMMEDIATELY following path, so this one still passes against
# the unfixed runner. G1/G2/G3/G5 are the discriminating assertions here (verified by ablation:
# they go red with `</dev/null` removed, this does not).
check "G4  …and a later one too (sanity, not a guard)" "$(ran m_nibble test-d-after.sh)" "yes"
case "$OUT" in
  *'4 passed'*) ok "G5  all four ran — the list survived intact" ;;
  *) bad "G5  all four ran — the list survived intact" "$OUT" ;;
esac

echo "ASSERTIONS: $((PASSED + FAILED))"

echo
echo "=== $PASSED passed, $FAILED failed ==="
[ "$FAILED" -eq 0 ] || exit 1
