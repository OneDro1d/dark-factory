#!/usr/bin/env bash
# test-infrastructure-vocabulary.sh — the stage guides must describe shared infrastructure
# by CAPABILITY, and every lesson they teach about it must survive that description.
#
# WHY THIS EXISTS. Thirty-five lines across `docs/`, `reference/`, `skills/` and five `stages/`
# named six proper nouns that are, from a reader's side, unreachable: they are repositories in
# a private organisation with no public documentation of any kind. A stranger following
# "fork the skeleton, <library> init comes free" cannot fork anything, and — worse — cannot
# tell whether they are missing a product or reading a house word for "the message bus".
# The kit's own reference layer already had the right vocabulary: Pattern 7 states the boot
# sequence as `init, metrics server, broker connect, queue bind`, with no product in it.
# Only the stage guides drifted into naming the implementation.
#
# THE TWO WAYS THIS GOES WRONG, AND WHY EACH SITE IS ONE ASSERTION.
# Genericising can fail in opposite directions, and a test that checks only one of them is
# a test that permits the other:
#   1. the noun comes BACK, silently, in the next edit;
#   2. the noun goes and the LESSON goes with it — "genericise" degrades into "delete",
#      which reads as a clean diff and loses the thing the line was for.
# So every site below is asserted as a SINGLE LINE that must match BOTH an anchor (the
# lesson) AND the capability vocabulary. Per-file matching was rejected deliberately: this
# repo has already shipped an assertion that passed on a neighbouring line that was not its
# subject, so the subject here is the line, not the file.
#
# WHAT THIS TEST DELIBERATELY DOES NOT DO.
# It does not carry the banned nouns. `landmarks.example.conf` states the rule this repo
# learned the hard way — *the LOGIC is public and the LIST is local* — because a list of
# nouns you do not want published is itself the thing you do not want published. Detecting
# a REINTRODUCED noun is `publish-gate.sh`'s job, against the gitignored `landmarks.conf`.
# This suite proves the positive property, which is publishable: the guidance stands on
# capability, and it still teaches what it taught.
#
# Run:  bash boot-kit/scripts/tests/test-infrastructure-vocabulary.sh
# Exit: 0 all pass · 1 at least one failed. Prints a literal count, because a suite that
# says "ok" without saying how many assertions ran cannot be told from one that ran none.
#
#   R1  the reference layer still states the boot sequence by capability — it is the source
#       every stage guide below is made to agree with, so if it drifts the rest are moot.
#   R2  each of the 35 sites: the line that carries the lesson also carries the vocabulary.
#   R3  the discovered site count matches the inventory, so a site cannot be quietly dropped
#       from the table and the suite still report all-green on a smaller world.
#
# Both directions are exercised. A check never seen to fail on the input it exists to catch
# is not known to work; canaries are written to $TMPDIR and never to the tracked tree.
#
# TWO THINGS THE SECOND WAVE OF SITES ADDED, BOTH ABOUT THE *MUST* COLUMN.
#   * A MUST must require something the DEFECTIVE text does not have. Seven of the sites
#     below already said `holdout` before they were fixed -- the product name sat in a
#     parenthetical beside it -- so a MUST of `holdout` would have been GREEN on the very
#     line it exists to change. Each of those asks for `held-back acceptance suite`, a
#     phrase the unfixed line does not contain. Check this by running the assertion
#     BEFORE the edit and watching it fail; a lone GREEN in a RED batch is the signal.
#   * An ANCHOR that matches several lines lets a neighbour answer for the subject. Every
#     anchor below was checked to match exactly one line in its file at the time it was
#     written; two candidates were tightened after matching two. Re-check when you add a row.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# path | label | ANCHOR (identifies the one line) | MUST (capability vocabulary on that line)
#
# The separator is `|`, so no field may contain one -- a literal pipe is eaten by the split
# and the surviving regex quietly matches nothing. That is how the last row below first
# passed while still naming the products: the T1 evidence row ALREADY said "immutable audit
# ledger" and carried the product names in a parenthetical after it, so requiring the phrase
# alone was satisfied by the very text it existed to replace. Its MUST therefore requires the
# phrase NOT to be followed by an opening parenthesis.
SITES=(
"stages/3-Developer/00-developer-guide.md|fork-the-skeleton: what comes free|comes free|messaging library"
"stages/3-Developer/00-developer-guide.md|failure mode: custom AMQP|[Cc]ustom AMQP|messaging library"
"stages/3-Developer/00-developer-guide.md|failure mode: Log.Error panics|Log\\.Error|messaging library"
"stages/3-Developer/02-tdd-implementation-guide.md|fork-the-skeleton: what comes free|for free|messaging library"
"stages/3-Developer/02-tdd-implementation-guide.md|GREEN discipline: Log.Warn never Log.Error|never .Log\\.Error|messaging library"
"stages/3-Developer/02-tdd-implementation-guide.md|anti-pattern: testing the framework/bus|test \\*your\\* logic|messaging library"
"stages/3-Developer/01-adversary-developer.md|grep for anti-patterns: custom AMQP|custom AMQP \(not|messaging library"
"stages/3-Developer/templates/per-service-build-spec-template.md|anatomy row: language|^. Language|messaging library"
"stages/3-Developer/sample/medstream-ambulance-ai.md|anatomy row: language|^. Language|messaging library"
"skills/df-tdd-developer/SKILL.md|GREEN discipline: Log.Warn not Log.Error|Log\\.Warn|messaging library"
"docs/DARK-FACTORY-PRIMING.md|GREEN discipline: language gotchas|language gotchas|messaging library"
"stages/4-Infrastructure-Architect/templates/deployment-infrastructure-spec-template.md|observability row: traces|^. Traces|messaging library"
"stages/4-Infrastructure-Architect/templates/deployment-infrastructure-spec-template.md|compliance: safety-grade audit|safety-grade|immutable"
"stages/4-Infrastructure-Architect/sample/medstream-ambulance-ai.md|compliance: ML recommendation audit|ML recommendation|immutable"
"stages/2-Solution-Architect/templates/data-model-template.md|PHI/PII: audit sink|audit sink|immutable"
"stages/6-Operations/sample/medstream-ambulance-ai.md|on-call note: inspect actions are logged|inspect action|immutable"
"reference/operating-agents-promise-theory.md|T1 evidence: the audit ledger|T1 — mechanical|immutable audit ledger [^(]"
"reference/operating-agents-promise-theory.md|attribution: where a Merkle root is anchored|Merkle root|immutable"
"skills/df-qa/SKILL.md|holdout ownership: what QA holds and never hands over|Never hand the holdout|held-back acceptance suite"
"skills/df-qa/SKILL.md|pyramid order: the last rung|Run the pyramid in order|held-back acceptance suite"
"skills/df-tdd-developer/SKILL.md|blind synthesis: the evidence withheld from the builder|lookup-degeneration|held-back acceptance suite"
"stages/3-Developer/02-tdd-implementation-guide.md|pyramid: QA owns E2E and the holdout|Do not rebuild E2E here|held-back acceptance suite"
"stages/3-Developer/02-tdd-implementation-guide.md|blind synthesis: do not ask for the holdout|Blind synthesis|held-back acceptance suite"
"stages/5-QA/00-qa-guide.md|test assets: the holdout is a named deliverable|regression suite|[Hh]eld-back acceptance suite"
"stages/5-QA/00-qa-guide.md|pyramid order: the last rung|Run the pyramid in order|held-back acceptance suite"
"stages/4-Infrastructure-Architect/00-infrastructure-architect-guide.md|dashboards as code: where they live|provision sinks|checked in beside the service"
"stages/3-Developer/00-developer-guide.md|priming bar: a working service CLAUDE.md|restates the architecture|own CLAUDE\\.md is the bar"
"stages/3-Developer/sample/medstream-ambulance-ai.md|anatomy row: DLQ replay is a command someone runs|single-requeue|medstream-ctl"
"stages/4-Infrastructure-Architect/sample/medstream-ambulance-ai.md|knob: stop the intake API|settings\\.yaml intake\\.rate|medstream-ctl pause intake"
"stages/4-Infrastructure-Architect/sample/medstream-ambulance-ai.md|knob: stop the summary builder|HPA max cap|medstream-ctl pause"
"stages/6-Operations/sample/medstream-ambulance-ai.md|knob: stop the classifier consumer|pause classifier consumer|medstream-ctl pause vitals-classifier"
"stages/6-Operations/sample/medstream-ambulance-ai.md|knob: redirect the handoff|route handoff to backup|medstream-ctl route handoff"
"stages/6-Operations/sample/medstream-ambulance-ai.md|knob: inspect by replaying the DLQ|replay summary DLQ|medstream-ctl dlq-replay"
"stages/6-Operations/templates/operations-runbook-template.md|knob: slow is a config change, not a CLI action|rate-limit ingestion|control CLI"
"skills/agent-notepad/DESIGN.md|non-goals: signed provenance is a v2 layer|provenance journals|signed-provenance substrate"
)

echo "=== shared infrastructure is described by capability, and the lessons survive ==="
echo

# ---- R1 -- the reference layer, which every site below is made to agree with ------------
echo "R1  the reference layer states the boot sequence by capability"
P7="$ROOT/reference/8-implementation-patterns.md"
# The statement wraps across lines in the source, so squash whitespace before matching --
# a regex that only works on an unwrapped line is a regex that fails on the next reflow.
squash() { tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '; }
if [ -f "$P7" ] && squash "$P7" | grep -qE 'init, metrics server, broker connect, queue bind'; then
  ok "Pattern 7 states the boot sequence as capabilities"
else
  bad "Pattern 7 states the boot sequence as capabilities" \
      "the stage guides are made to agree with this line; if it moves they agree with nothing"
fi
printf 'Statement: every service shares one\nboot sequence.\n' > "$TMP/p7.md"
if squash "$TMP/p7.md" | grep -qE 'init, metrics server, broker connect, queue bind'; then
  bad "R1 canary: a Pattern 7 without the capability list is detected"
else
  ok "R1 canary: a Pattern 7 without the capability list is detected"
fi
echo

# ---- R2 -- every site: the lesson line also carries the vocabulary ----------------------
echo "R2  each site keeps its lesson AND states it by capability"
CHECKED=0
for row in "${SITES[@]}"; do
  IFS='|' read -r path label anchor must <<< "$row"
  CHECKED=$((CHECKED+1))
  f="$ROOT/$path"
  if [ ! -f "$f" ]; then
    bad "$path -- $label" "file not found"
    continue
  fi
  # The SUBJECT is the line. A file-wide match would let a neighbouring line satisfy this.
  if grep -E "$anchor" "$f" 2>/dev/null | grep -qE "$must"; then
    ok "$path -- $label"
  else
    hits="$(grep -cE "$anchor" "$f" 2>/dev/null || true)"
    bad "$path -- $label" \
        "anchor '$anchor' matched ${hits:-0} line(s), none carrying '$must' -- either the lesson was deleted or the product name is back"
  fi
done
echo

# canary A: the lesson present, the vocabulary absent (the noun came back).
printf -- '- `Log.Error` (panics in SomeProduct) instead of `Log.Warn`.\n' > "$TMP/back.md"
if grep -E 'Log\.Error' "$TMP/back.md" | grep -qE 'messaging library'; then
  bad "R2 canary A: a re-introduced product name is detected"
else
  ok "R2 canary A: a re-introduced product name is detected"
fi
# canary B: the vocabulary present somewhere in the file, the lesson line gone.
# This is the "genericise degraded into delete" failure, and it is the one a per-FILE
# matcher would wave through.
printf 'Use the shared messaging library.\n- latest image tags are an anti-pattern.\n' > "$TMP/gone.md"
if grep -E 'Log\.Error' "$TMP/gone.md" | grep -qE 'messaging library'; then
  bad "R2 canary B: a deleted lesson is detected even though the vocabulary is in the file"
else
  ok "R2 canary B: a deleted lesson is detected even though the vocabulary is in the file"
fi
# canary C: both present but on DIFFERENT lines -- must still fail.
printf -- '- `Log.Error` panics.\n- Use the shared messaging library.\n' > "$TMP/split.md"
if grep -E 'Log\.Error' "$TMP/split.md" | grep -qE 'messaging library'; then
  bad "R2 canary C: lesson and vocabulary on different lines is detected"
else
  ok "R2 canary C: lesson and vocabulary on different lines is detected"
fi
echo

# ---- R3 -- the inventory is the size it claims to be ------------------------------------
echo "R3  the site table still covers the whole inventory"
EXPECTED=35
if [ "$CHECKED" -eq "$EXPECTED" ]; then
  ok "checked $CHECKED site(s), the full inventory"
else
  bad "checked $CHECKED site(s), expected $EXPECTED" \
      "a site removed from the table is a site nothing protects; update the count deliberately or put it back"
fi
echo

printf '%s\n' "-----"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
