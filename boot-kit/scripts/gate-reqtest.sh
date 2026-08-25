#!/usr/bin/env bash
# gate-reqtest.sh — prove the gate catches every landmark CLASS the policy names.
#
# This is the other half of gate-selftest.sh, and the two must not be confused:
#
#   gate-selftest.sh   plants every canary landmarks.conf DEFINES  -> "is each pattern live?"
#   gate-reqtest.sh    plants a specimen of each class POLICY names -> "is each class covered?"
#
# A self-test draws its inputs from the same file as the thing under test, so it can only
# ever prove the patterns that already exist. A landmark class nobody wrote a pattern for
# has no canary either — it is invisible to the self-test, and the self-test goes green
# with the class wholly unprotected. That is not hypothetical: on 2026-08-24 all eleven
# canaries fired, the baseline was clean, the self-test PASSED — and a bare tracker board
# id, the private GitHub org name, a private repo name and the company's own name each
# went through the gate untouched. Every one of them is named as an absolute landmark by
# the publishing rules.
#
# So the inputs here come from OUTSIDE the config under test: gate-requirements.conf lists
# the classes the rules name, each with a real specimen. That file is gitignored for the
# same reason landmarks.conf is — it IS a list of the nouns that must not be published.
#
# Three verdicts, and the third is not a synonym for either other:
#   CAUGHT         planted, the gate FAILed on it — that class is covered
#   MISSED         planted, the gate stayed CLEAN — that class is NOT covered
#   INDETERMINATE  nothing could be measured. NOT a pass. Exit 2, never 0.
#
# Usage: bash boot-kit/scripts/gate-reqtest.sh [--show]
#          --show  print specimens unmasked (local operator use only)
# Exit:  0 = every class caught   1 = at least one MISSED
#        2 = indeterminate: plumbing failure, OR a class the policy names was UNPROBED
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/../.." && pwd)"
GATE="$SELF/publish-gate.sh"
PROBE="$REPO/docs/.gate-reqtest-probe.md"
SHOW=0
[ "${1:-}" = "--show" ] && SHOW=1

cleanup() { rm -f "$PROBE"; }
trap cleanup EXIT
mkdir -p "$(dirname "$PROBE")"

die() { printf '\n=== RESULT: %s ===\n' "$1"; exit 2; }

# ── where the requirement list comes from ─────────────────────────────────────
# Same shape as publish-gate's landmarks.conf / landmarks.example.conf pair, and for the
# same reason: the LOGIC is public, the LIST is local. The example holds placeholders, so
# running against it measures nothing — and says so rather than reporting a green.
REQS="$SELF/gate-requirements.conf"
REQS_SRC="gate-requirements.conf"
if [ ! -f "$REQS" ]; then
  REQS="$SELF/gate-requirements.example.conf"
  REQS_SRC="gate-requirements.example.conf (PLACEHOLDERS — copy to gate-requirements.conf and fill in)"
fi

echo "=== gate-reqtest: $REPO ==="
printf 'requirements: %s\n' "$REQS_SRC"

case "$REQS_SRC" in
  *example*)
    echo ""
    echo "No local requirement list. The example file names the classes but carries"
    echo "placeholder specimens, so nothing about this estate has been measured."
    die "INDETERMINATE — no real requirements file (this is not a pass)" ;;
esac
[ -f "$REQS" ] || die "INDETERMINATE — no requirement list found (this is not a pass)"
# shellcheck source=/dev/null
. "$REQS"
[ -n "${REQUIREMENTS:-}" ] || die "INDETERMINATE — REQUIREMENTS is empty in $REQS_SRC"

# ── the landmark config, resolved exactly the way publish-gate resolves it ─────
LANDMARKS="$SELF/landmarks.conf"; LANDMARKS_SRC="landmarks.conf"
if [ ! -f "$LANDMARKS" ]; then
  LANDMARKS="$SELF/landmarks.example.conf"; LANDMARKS_SRC="landmarks.example.conf (PLACEHOLDER PATTERNS)"
fi
[ -f "$LANDMARKS" ] || die "INDETERMINATE — no landmark config to test against"
# shellcheck source=/dev/null
. "$LANDMARKS"
printf 'landmarks:    %s\n\n' "$LANDMARKS_SRC"

mask() {
  [ "$SHOW" -eq 1 ] && { printf '%s' "$1"; return; }
  printf '%s…(%d chars)' "$(printf '%s' "$1" | cut -c1-2)" "${#1}"
}

# Run the gate with $1 planted (empty = nothing planted). Echoes "rc|fired-classes".
plant_and_run() {
  if [ -n "$1" ]; then printf 'probe: %s\n' "$1" > "$PROBE"; else rm -f "$PROBE"; fi
  local out rc fired
  out="$(bash "$GATE" 2>&1)"; rc=$?
  rm -f "$PROBE"
  fired="$(printf '%s\n' "$out" | sed -n 's/^FAIL  *\(P[1-9]\) .*/\1/p' | sort -u | paste -sd, -)"
  printf '%s|%s' "$rc" "$fired"
}

# ── control 1: the tree must be clean before anything is planted ──────────────
# Without this every row would read CAUGHT for a reason that has nothing to do with it.
IFS='|' read -r base_rc base_fired <<< "$(plant_and_run '')"
if [ "$base_rc" -ne 0 ]; then
  echo "The gate already reports findings on the untouched tree (classes: ${base_fired:-?})."
  echo "Nothing planted can be attributed. Clear those first, then re-run."
  die "ERROR — baseline is not clean"
fi

# ── control 2: the gate must be seen to FIRE before a CLEAN row is believed ────
# A gate that cannot fire produces a report in which every class reads MISSED — total
# absence of coverage and total absence of plumbing look identical on the page.
CONTROL="${P1_CANARY:-}"
[ -n "$CONTROL" ] || die "ERROR — no P1_CANARY in $LANDMARKS_SRC; the gate cannot be proven to fire"
IFS='|' read -r ctl_rc ctl_fired <<< "$(plant_and_run "$CONTROL")"
if [ "$ctl_rc" -eq 0 ]; then
  echo "The gate stayed CLEAN on a canary its own config says it must catch."
  echo "That is a broken gate, not an uncovered estate — every row below would be noise."
  die "ERROR — plumbing: the gate does not fire on its own canary"
fi
printf 'control:      gate FIREs on its own P1 canary (%s) — a CLEAN row below is meaningful\n\n' "$ctl_fired"

# ── the probes ────────────────────────────────────────────────────────────────
printf '%-32s %-8s %s\n' "landmark class (from policy)" "expects" "verdict"
MISSES=0; ROWS=0; EXEMPTS=0; SURPRISES=0; UNPROBED=0
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  name="${line%%|*}";  rest="${line#*|}"
  expect="${rest%%|*}"; rest2="${rest#*|}"
  # Optional 4th field: the REASON, required when expect is EXEMPT. An exemption with no
  # stated reason cannot be told apart from an oversight somebody wrote down.
  case "$rest2" in
    *\|*) spec="${rest2%%|*}"; reason="${rest2#*|}" ;;
    *)    spec="$rest2";        reason="" ;;
  esac
  # A row with no specimen is an UNKNOWN, and an unknown is not a pass. Until 2026-08-25
  # this `continue` fired BEFORE ROWS was incremented, so the row printed and then left no
  # trace in the arithmetic — it could not move the denominator, the miss count or the exit
  # code. The real config carried `client name |P1|` empty, and this instrument, whose one
  # job is to surface a landmark class nobody wrote a pattern for, printed
  # `RESULT: COVERED — 9/11 caught` and exited 0 while the client's own name sailed through
  # the gate. Counted separately from ROWS on purpose: folding it into the denominator
  # would report it as covered, and folding it into MISSES would claim a finding nobody
  # measured. Three verdicts, not two — the same rule df-preflight applies to `unknown`.
  [ -n "$spec" ] || { UNPROBED=$((UNPROBED+1)); printf '%-32s %-8s UNPROBED    no specimen — coverage UNKNOWN\n' "$name" "$expect"; continue; }
  ROWS=$((ROWS+1))
  IFS='|' read -r rc fired <<< "$(plant_and_run "$spec")"

  # EXEMPT means "policy says this class is deliberately NOT patterned". It exists because
  # a tool that reports a decision as a defect gets its bottom line ignored, and the real
  # gaps are ignored along with it. Two live cases here: the company's own name, where a
  # pattern would fire on our own LICENCE and NOTICE, and library names that are ordinary
  # English or widely-used OSS project names, where it would fire on ordinary prose.
  #
  # An exemption must never SWALLOW a firing. If an exempt specimen does fire, policy and
  # config disagree — either the note is stale or the pattern is broader than intended —
  # and that is exactly the kind of thing this instrument exists to surface.
  if [ "$expect" = "EXEMPT" ]; then
    if [ "$rc" -eq 0 ]; then
      EXEMPTS=$((EXEMPTS+1))
      printf '%-32s %-8s EXEMPT-BY-POLICY  %s  %s\n' "$name" "$expect" "$(mask "$spec")" "${reason:-NO REASON GIVEN}"
      [ -n "$reason" ] || SURPRISES=$((SURPRISES+1))
    else
      SURPRISES=$((SURPRISES+1))
      printf '%-32s %-8s EXEMPT BUT FIRES  by [%s]  %s  %s\n' "$name" "$expect" "$fired" "$(mask "$spec")" "${reason:-NO REASON GIVEN}"
    fi
    continue
  fi

  if [ "$rc" -ne 0 ]; then
    printf '%-32s %-8s CAUGHT      by [%s]  %s\n' "$name" "$expect" "$fired" "$(mask "$spec")"
  else
    printf '%-32s %-8s **MISSED**  nothing fired  %s\n' "$name" "$expect" "$(mask "$spec")"
    MISSES=$((MISSES+1))
  fi
done <<EOT
${REQUIREMENTS}
EOT

echo ""
if [ "$ROWS" -eq 0 ]; then
  die "INDETERMINATE — the requirement list has no usable rows"
fi
COVERED=$((ROWS - MISSES - EXEMPTS))
if [ "$SURPRISES" -gt 0 ]; then
  printf '=== RESULT: %d exempt class(es) disagree with the config — policy and patterns are out of step ===\n' "$SURPRISES"
  echo "An EXEMPT class that fires, or an exemption with no stated reason, is not a"
  echo "publish risk — it is a claim in the requirement list that the config contradicts."
  echo "Reconcile: widen the reason, narrow the pattern, or drop the exemption."
  [ "$MISSES" -eq 0 ] || printf 'Also: %d of %d classes are NOT caught.\n' "$MISSES" "$ROWS"
  [ "$UNPROBED" -eq 0 ] || printf 'Also: %d class(es) are UNPROBED — no specimen, coverage unknown.\n' "$UNPROBED"
  exit 1
fi
# The unprobed count belongs ON the verdict line. A row in a table above a green bottom
# line is the defect one indent deeper, and this repo has already learned that lesson once
# in gate-selftest, where `all 7 classes fire` sat over a table showing a sixth of the
# branches pinned. A reader who reads one line must see that coverage is UNKNOWN.
if [ "$MISSES" -eq 0 ] && [ "$UNPROBED" -gt 0 ]; then
  printf '=== RESULT: INCOMPLETE — %d/%d probed classes caught, but %d class(es) UNPROBED (no specimen) ===\n' \
    "$COVERED" "$ROWS" "$UNPROBED"
  echo "A landmark class the policy names and this harness never probed is an UNKNOWN, not"
  echo "a pass. Supply a real specimen for it in the requirement list, or mark it EXEMPT"
  echo "with a reason if it is deliberately not patterned. Coverage cannot be reported"
  echo "until every class the policy names has been measured one way or the other."
  exit 2
fi
if [ "$MISSES" -eq 0 ]; then
  if [ "$EXEMPTS" -gt 0 ]; then
    printf '=== RESULT: COVERED — %d/%d caught, %d exempt by policy ===\n' "$COVERED" "$ROWS" "$EXEMPTS"
  else
    printf '=== RESULT: COVERED — %d/%d landmark classes are caught ===\n' "$ROWS" "$ROWS"
  fi
  exit 0
fi
printf '=== RESULT: %d of %d landmark classes are NOT caught — the gate is incomplete ===\n' "$MISSES" "$ROWS"
# A definite gap outranks an unknown, so MISSES keeps exit 1 — but the unknown must still
# be reported, or fixing the misses would turn this line green over classes never measured.
[ "$UNPROBED" -eq 0 ] || printf '(%d further class(es) are UNPROBED — no specimen, coverage unknown.)\n' "$UNPROBED"
[ "$EXEMPTS" -eq 0 ] || printf '(%d further class(es) are exempt by policy and not counted as gaps.)\n' "$EXEMPTS"
echo "Add a branch to the matching P*_PATTERN in the landmark config, plus a matching"
echo "P*_CANARY so gate-selftest proves the new branch fires, then re-run both."
echo "If a class is deliberately unpatterned, mark it EXEMPT with a reason instead of"
echo "leaving it to read as a gap — see gate-requirements.example.conf."
exit 1
