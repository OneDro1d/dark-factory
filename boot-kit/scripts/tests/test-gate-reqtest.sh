#!/usr/bin/env bash
# test-gate-reqtest.sh — prove gate-reqtest.sh answers the question gate-selftest cannot.
#
# gate-selftest.sh plants every canary the landmark config DEFINES and asserts each fires.
# That proves the patterns present are live. It cannot, even in principle, discover a
# pattern that is ABSENT: its inputs come from the same file as the thing under test, so a
# landmark class nobody ever wrote a pattern for has no canary either, and the self-test
# goes green with the class completely unprotected. That is exactly what happened on
# 2026-08-24 — 11 canaries green while the tracker board id, the private org name, the
# private repo name and the company name all sailed through the gate untouched.
#
# gate-reqtest.sh starts from the POLICY side instead: the list of landmark CLASSES the
# publishing rules name, each with a real specimen supplied out-of-band. This suite proves
# that instrument behaves — above all that it can be SEEN TO FAIL, and that it refuses to
# report coverage when it cannot actually measure any.
#
# Everything runs in a SCRATCH repo under $TMPDIR with a synthetic landmark config. A test
# that proved this by planting a real landmark in the real repo would create the very
# condition the gate exists to detect.
#
# Usage: bash boot-kit/scripts/tests/test-gate-reqtest.sh
# Exit:  0 = all rules hold   1 = at least one does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
GATE_SRC="$SCRIPTS/publish-gate.sh"
REQ_SRC="$SCRIPTS/gate-reqtest.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

[ -f "$REQ_SRC" ] || { echo "FAIL  gate-reqtest.sh does not exist at $REQ_SRC"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reqtest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A synthetic landmark config. Fictional nouns only — this file is written by a committed
# test, so a real one here would be published by the act of testing.
mk_repo() {
  local d="$WORK/repo"
  rm -rf "$d"; mkdir -p "$d/boot-kit/scripts/tests" "$d/docs"
  git init -q -b main "$d"
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name test
  cp "$GATE_SRC" "$d/boot-kit/scripts/publish-gate.sh"
  cp "$REQ_SRC"  "$d/boot-kit/scripts/gate-reqtest.sh"
  # Neutral nonsense tokens, one per class. An EARLIER version of this file used
  # realistic canaries copied out of landmarks.example.conf — a cloud-key-shaped string, a
  # clinical column name, a home-directory path, a tracker board URL — and the REAL
  # landmark config matched four of them, so adding this test made
  # publish-gate FAIL on the repo. A committed test that carries landmark-SHAPED strings
  # is a landmark; the harness under test only needs "pattern X matches canary X", and
  # nonsense tokens satisfy that while matching nobody's real pattern, now or later.
  cat > "$d/boot-kit/scripts/landmarks.conf" <<'CONF'
P1_PATTERN='zzqxalfa|zzqxbravo'
P2_PATTERN='zzqxcharlie'
P3_PATTERN='zzqxdelta'
P4_PATTERN='zzqxecho'
P5_PATTERN='zzqxfoxtrot'
P6_PATTERN='zzqxgolf'
P7_PATTERN='zzqxhotel'
P1_CANARY='zzqxalfa in a sentence'
P2_CANARY='zzqxcharlie in a sentence'
P3_CANARY='zzqxdelta in a sentence'
P4_CANARY='zzqxecho in a sentence'
P5_CANARY='zzqxfoxtrot in a sentence'
P6_CANARY='zzqxgolf in a sentence'
P7_CANARY='zzqxhotel in a sentence'
CONF
  # The real repo gitignores the requirement list because it holds real landmarks; the
  # scratch repo must do the same or the gate reads the specimens out of the list itself
  # and every baseline is dirty for a reason that has nothing to do with the probe.
  printf 'boot-kit/scripts/gate-requirements.conf\n' > "$d/.gitignore"
  echo clean > "$d/docs/readme.md"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm base
  printf '%s' "$d"
}

write_reqs() { printf 'REQUIREMENTS="\n%s\n"\n' "$1" > "$2/boot-kit/scripts/gate-requirements.conf"; }
run_req()    { ( cd "$1" && bash boot-kit/scripts/gate-reqtest.sh "${@:2}" 2>&1 ); }

echo "=== test-gate-reqtest ==="
echo ""

# ── R1  a specimen the config DOES match is reported CAUGHT, exit 0 ────────────
D="$(mk_repo)"
write_reqs 'covered class|P1|zzqxbravo' "$D"
OUT="$(run_req "$D")"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'CAUGHT' \
  && ok "R1 a covered class reports CAUGHT and exits 0" \
  || bad "R1 a covered class reports CAUGHT and exits 0" "rc=$RC out=$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"

# ── R2  a specimen the config does NOT match is reported MISSED, exit 1 ────────
# The whole point of the instrument. If it cannot be seen to fail, a clean run means
# nothing — this repo has shipped a validator that reported CLEAN on a planted violation.
write_reqs 'uncovered class|P7|zzqxuncovered' "$D"
OUT="$(run_req "$D")"; RC=$?
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'MISSED' \
  && ok "R2 an UNCOVERED class reports MISSED and exits 1 (seen to fail)" \
  || bad "R2 an UNCOVERED class reports MISSED and exits 1 (seen to fail)" "rc=$RC out=$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"

# ── R3  no requirements file is INDETERMINATE, never a pass ───────────────────
# Absence of a measurement must not read as a clean measurement. Every gate failure in
# this repo's history was some form of "could not check" rendered as "nothing found".
rm -f "$D/boot-kit/scripts/gate-requirements.conf"
OUT="$(run_req "$D")"; RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'INDETERMINATE' \
  && ok "R3 a missing requirements file is INDETERMINATE (exit 2), not a pass" \
  || bad "R3 a missing requirements file is INDETERMINATE (exit 2), not a pass" "rc=$RC out=$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"

# ── R4  the shipped example file is placeholders, and is also INDETERMINATE ────
cp "$SCRIPTS/gate-requirements.example.conf" "$D/boot-kit/scripts/gate-requirements.example.conf" 2>/dev/null
OUT="$(run_req "$D")"; RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'INDETERMINATE' \
  && ok "R4 the placeholder example config is INDETERMINATE, not a green demo" \
  || bad "R4 the placeholder example config is INDETERMINATE, not a green demo" "rc=$RC out=$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"

# ── R5  specimens are masked by default, shown only on --show ─────────────────
# The requirements file is a list of the exact nouns that must not be published. A report
# that echoes them turns the instrument into the leak.
write_reqs 'covered class|P1|zzqxbravo' "$D"
OUT="$(run_req "$D")"
printf '%s' "$OUT" | grep -q 'zzqxbravo' \
  && bad "R5 specimens are masked by default" "the full specimen appeared in the report" \
  || ok "R5 specimens are masked by default"
OUT="$(run_req "$D" --show)"
printf '%s' "$OUT" | grep -q 'zzqxbravo' \
  && ok "R5b --show unmasks for local operator use" \
  || bad "R5b --show unmasks for local operator use"

# ── R6  no probe file is left behind ──────────────────────────────────────────
DIRTY="$(git -C "$D" status --porcelain --untracked-files=all | grep -v 'gate-requirements' || true)"
[ -z "$DIRTY" ] \
  && ok "R6 the probe file is removed — the tree is clean afterwards" \
  || bad "R6 the probe file is removed — the tree is clean afterwards" "$DIRTY"

# ── R7  a gate that cannot fire is ERROR, not a coverage report ────────────────
# If publish-gate is broken or misconfigured, every row would read MISSED and the report
# would look like total absence of coverage. That is a plumbing failure wearing the
# costume of a finding, and it must be distinguishable.
printf '#!/usr/bin/env bash\necho "=== RESULT: CLEAN — safe to publish ==="\nexit 0\n' \
  > "$D/boot-kit/scripts/publish-gate.sh"
OUT="$(run_req "$D")"; RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qE 'ERROR|plumbing' \
  && ok "R7 a gate that cannot fire is ERROR (exit 2), not 'everything missed'" \
  || bad "R7 a gate that cannot fire is ERROR (exit 2), not 'everything missed'" "rc=$RC out=$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"

# R7 breaks the scratch gate on purpose to prove the ERROR path, and leaves it broken.
# Without this rebuild the rules below fail with a plumbing ERROR and never reach the
# code they exist to test — a red for the wrong reason is worth no more than a green for
# the wrong reason.
D="$(mk_repo)"

# ── R9  a class marked EXEMPT that does NOT fire is an exemption, not a miss ───
# A deliberate non-pattern must not be reported as a gap. A tool that calls a decision a
# defect gets its bottom line ignored, and then the real gaps go with it.
write_reqs 'policy exempt class|EXEMPT|zzqxnotpatterned|would match our own LICENCE' "$D"
OUT="$(run_req "$D")"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'EXEMPT-BY-POLICY' \
  && ok "R9 an EXEMPT class that does not fire reports EXEMPT-BY-POLICY and exits 0" \
  || bad "R9 an EXEMPT class that does not fire reports EXEMPT-BY-POLICY and exits 0" "rc=$RC out=$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"

# ── R10  the REASON is printed, so the exemption can be argued with ────────────
# An exemption with no stated reason is indistinguishable from an oversight someone wrote
# down. The reason is the whole difference between a decision and a gap.
printf '%s' "$OUT" | grep -q 'would match our own LICENCE' \
  && ok "R10 the exemption prints its reason" \
  || bad "R10 the exemption prints its reason" "$(printf '%s' "$OUT" | grep -i exempt | tr '\n' ' ')"

# ── R11  an EXEMPT specimen that DOES fire is reported, not swallowed ──────────
# The direction that matters. An exemption that absorbs a real firing is a silencer, and
# this repo has shipped enough checks that reported clean over a live finding.
write_reqs 'policy exempt but covered|EXEMPT|zzqxbravo|believed unpatterned' "$D"
OUT="$(run_req "$D")"; RC=$?
printf '%s' "$OUT" | grep -qi 'EXEMPT.*FIRES\|FIRES.*EXEMPT' \
  && ok "R11 an EXEMPT class that DOES fire is surfaced, not swallowed" \
  || bad "R11 an EXEMPT class that DOES fire is surfaced, not swallowed" "rc=$RC out=$(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"

# ── R12  a row with NO specimen must not be swallowed by a COVERED verdict ─────
# The row prints SPECIMEN-MISSING and then vanishes from the arithmetic: it was excluded
# from ROWS, so it could not move the denominator, the miss count or the exit code. The
# real config carried `client name |P1|` with an empty specimen for a day, and the
# instrument whose entire purpose is to surface an unpatterned class printed
# `RESULT: COVERED — 9/11 caught` and exited 0 over it. A class nobody probed is an
# UNKNOWN, and an unknown rendered as a pass is the false-assurance shape this whole
# suite exists to stop. (Same doctrine as df-preflight: `unknown` is not a fact about
# the world, and collapsing it into a verdict is how a blind spot gets written down as
# a clean result.)
write_reqs 'covered class|P1|zzqxbravo
unprobed class|P1|' "$D"
OUT="$(run_req "$D")"; RC=$?
[ "$RC" -ne 0 ] && ! printf '%s' "$OUT" | grep -q '=== RESULT: COVERED' \
  && ok "R12 an unprobed class blocks a COVERED verdict and a zero exit" \
  || bad "R12 an unprobed class blocks a COVERED verdict and a zero exit" "rc=$RC verdict=$(printf '%s' "$OUT" | grep '=== RESULT' | tr -d '\n')"

# ── R13  the unprobed count appears on the VERDICT line, not only in the table ──
# A per-row note nobody scrolls to is the same defect one indent deeper — the identical
# lesson gate-selftest learned when `all 7 classes fire` sat above a table showing a sixth
# of the branches pinned. A reader who reads one line must see that coverage is unknown.
printf '%s' "$OUT" | grep -E '=== RESULT' | grep -qE 'unprobed|not probed|UNPROBED|INCOMPLETE' \
  && ok "R13 the verdict line itself names the unprobed class(es)" \
  || bad "R13 the verdict line itself names the unprobed class(es)" "verdict=$(printf '%s' "$OUT" | grep '=== RESULT' | tr -d '\n')"

# ── R14  an unprobed class is not counted as caught ────────────────────────────
# The opposite over-correction is just as wrong: adding the row to ROWS without excluding
# it from COVERED would report it as covered, which is the original bug with extra steps.
# Assert the NUMBERS, not a string shape. The first draft of this rule grepped for the
# literal '2/2 caught' and would have passed straight through the over-correction it
# exists to catch, because that path prints '2/2 probed classes caught' — different words,
# same defect. One caught class and one unprobed class must report exactly 1 caught out
# of exactly 1 probed; any other pair means the unprobed row leaked into the denominator.
R14_NUMS="$(printf '%s' "$OUT" | grep -E '=== RESULT' | grep -oE '[0-9]+/[0-9]+' | head -1)"
[ "$R14_NUMS" = "1/1" ] \
  && ok "R14 an unprobed class is not counted among the caught (reported $R14_NUMS)" \
  || bad "R14 an unprobed class is not counted among the caught" "reported '$R14_NUMS', expected '1/1' — the unprobed row leaked into the denominator"

echo ""
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
