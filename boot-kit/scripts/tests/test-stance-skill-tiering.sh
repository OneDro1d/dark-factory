#!/usr/bin/env bash
# test-stance-skill-tiering.sh — the operating stance is Tier 1; a memory-recall skill is not.
#
# WHY THIS EXISTS. On 2026-08-25 this repo cited `work-autonomously` four times — including
# as step 6 of its own build pipeline — while shipping no such skill. That was found, and
# the stance moved up: it is generic method, so it now lives here. Fixing it surfaced a
# FIFTH citation on the line directly above, `loom-recall`, step 1 of the same pipeline,
# naming a skill only an org repo ships. It had been invisible for exactly as long, because
# attention had been spent on the reference someone happened to notice.
#
# Both are content defects with no gate. `tier-check.py` detects `Skill(<name>)` and the
# legacy `](../<name>/SKILL.md)` path form; all five citations were bare backticks in prose,
# so it printed PASS over every one of them. Teaching `tier-check` to read prose is tracked
# separately and deliberately NOT done here — two detectors for one rule is how they drift.
# This suite instead pins the SPECIFIC invariants that fix established, so the six edited
# sites cannot silently revert while the general detector is still being built.
#
# Run:  bash boot-kit/scripts/tests/test-stance-skill-tiering.sh
# Exit: 0 all pass · 1 at least one failed. Prints a literal assertion count, because a
# suite that says "ok" without saying how many assertions ran cannot be told from one that
# ran none.
#
#   R1  `skills/work-autonomously/SKILL.md` is SHIPPED here. Every assertion below is a
#       statement about a file that must exist; if it does not, they are all vacuous.
#   R2  both pipeline lists cite the stance as a markdown link that RESOLVES on disk, not
#       as a bare backticked name. A link is checkable by `link-check.py`; a backtick is
#       checkable by nothing, which is how the original defect survived.
#   R3  no tracked file (vendor excluded) names `loom-recall`. It ships in exactly one org
#       repo. Tier 1 may describe the CAPABILITY; it may not name the binding. Exactly one
#       file is excluded — this one, because a guard that forbids a token must contain it.
#   R4  `vinculum-loop` does not declare the operating stance to be Tier-2 content, and
#       does link the stance. That sentence was the doctrine the other four defects were
#       downstream of — leaving it would contradict the direction rule in CONTENT-BOUNDARY.
#   R5  the rendered iteration prompt names the generic stance and NO lane. It previously
#       read "(`work-autonomously` on the OneDroid/PWW lane)", which is both a landmark and
#       a claim that stopped being true the moment the skill moved up.
#
# Every rule is exercised in BOTH directions, ONE AT A TIME. A batch of assertions added
# together and seen to fail together proves the batch, not each member — so each violation
# below is planted alone, into a scratch COPY of the tree, and the suite must fail for that
# reason and no other. Nothing is ever planted into the tracked tree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

STANCE_REL="skills/work-autonomously/SKILL.md"
LISTS=("skills/dark-factory-build/SKILL.md" "reference/dark-factory-build-orchestrator.md")
LOOP_REL="skills/vinculum-loop/SKILL.md"
PROMPT_REL="boot-kit/scripts/df-render-prompt.py"
SELF_REL="boot-kit/scripts/tests/test-stance-skill-tiering.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# Resolve a markdown link target relative to the file it appears in, and say whether it
# lands on a real file INSIDE the repo. Resolving outside the repo is a failure, not a
# pass: `../../DESIGN.md` "resolves" happily to a sibling checkout on the author's laptop.
resolves_inside() {
  local from_file="$1" target="$2" base abs
  base="$(cd "$ROOT/$(dirname "$from_file")" && pwd)"
  abs="$(cd "$base" && cd "$(dirname "$target")" 2>/dev/null && pwd)/$(basename "$target")" || return 1
  [ -f "$abs" ] || return 1
  case "$abs" in "$ROOT"/*) return 0 ;; *) return 1 ;; esac
}

run_suite() {
  local root="$1" label="$2"
  local p=0 f=0
  local _PASS=$PASS _FAIL=$FAIL
  PASS=0; FAIL=0
  local saved_root="$ROOT"; ROOT="$root"

  # ---- R1 the stance ships here -------------------------------------------------------
  if [ -f "$ROOT/$STANCE_REL" ]; then ok "R1 $STANCE_REL is shipped"
  else bad "R1 $STANCE_REL is MISSING — the stance is Tier-1 method and must ship here"; fi

  # ---- R2 both pipeline lists link it, and the link resolves ---------------------------
  for rel in "${LISTS[@]}"; do
    if [ ! -f "$ROOT/$rel" ]; then bad "R2 $rel does not exist"; continue; fi
    # every markdown link whose text is `work-autonomously`
    local targets
    targets="$(grep -oE '\[`work-autonomously`\]\([^)]+\)' "$ROOT/$rel" \
               | sed -E 's/.*\(([^)]+)\)/\1/' || true)"
    if [ -z "$targets" ]; then
      bad "R2 $rel cites the stance but not as a markdown link (a backtick is checkable by nothing)"
    else
      local n_ok=0 n_bad=0 t
      while IFS= read -r t; do
        [ -z "$t" ] && continue
        if resolves_inside "$rel" "$t"; then n_ok=$((n_ok+1)); else n_bad=$((n_bad+1)); fi
      done <<< "$targets"
      if [ "$n_bad" -eq 0 ] && [ "$n_ok" -ge 2 ]; then
        ok "R2 $rel links the stance ${n_ok}x, all resolving inside the repo"
      else
        bad "R2 $rel stance links: ${n_ok} resolve, ${n_bad} do not (expected >=2 and 0)"
      fi
    fi
    # and no BARE backticked citation may remain: every occurrence of the backticked name
    # must be the TEXT of a markdown link. Counted rather than pattern-matched with a
    # negative lookbehind, which POSIX grep does not have and BSD grep mis-parses.
    local n_tick n_link
    n_tick="$(grep -o '`work-autonomously`' "$ROOT/$rel" | wc -l | tr -d ' ')"
    n_link="$(grep -o '\[`work-autonomously`\](' "$ROOT/$rel" | wc -l | tr -d ' ')"
    if [ "$n_tick" -eq "$n_link" ]; then
      ok "R2 $rel: all ${n_tick} backticked stance citations are links"
    else
      bad "R2 $rel: ${n_tick} backticked stance citations but only ${n_link} are links"
    fi
  done

  # ---- R3 no org-only recall skill is named -------------------------------------------
  # THIS FILE IS THE ONE EXCLUSION, and it is not a loophole. A guard that forbids a token
  # has to contain the token; the alternative is building the string at runtime, which is
  # obfuscation inside a control and strictly worse. The exclusion is one named path, and
  # it is CHECKED below — an exclusion whose file no longer contains what it excuses is
  # silently protecting nothing and would mask a later file arriving at that path.
  #
  # Worth being precise about the class: the org-only recall skill is NOT a landmark. It
  # matches no pattern in the publish gate, and nothing here is a publication risk. What it
  # is, is a TIERING violation — Tier 1 citing a skill only a Tier-2 repo ships, which
  # breaks for the next consumer and for nobody who authored it.
  local recall_hits
  recall_hits="$(cd "$ROOT" && git grep -l -I -- 'loom-recall' -- . ':!vendor' ':!'"$SELF_REL" 2>/dev/null || true)"
  if [ -z "$recall_hits" ]; then
    ok "R3 no tracked file names the org-only recall skill (1 excluded: $SELF_REL)"
  else
    bad "R3 org-only recall skill named in: $(echo "$recall_hits" | tr '\n' ' ')"
  fi
  # NO STALENESS CHECK, and that is a considered omission rather than an oversight.
  # A suite whose exclusions are a LIST of other files must check that list — see the
  # sibling `boot-kit/scripts/tests/test-*-references.sh`, which does exactly that, and
  # for good reason: an entry can outlive the file it names and then silently excuse
  # whatever later lands at that path. This exclusion is one hardcoded path — THIS FILE — so it
  # cannot go stale — the guard necessarily contains the token it searches for, and if the
  # guard is deleted the rule is deleted with it, visibly. A staleness assertion here would
  # be tautological: it was written, planted against, and could not be made to fail. A
  # check that cannot fail is worse than no check, because it counts as one.

  # ---- R4 vinculum-loop does not file the stance as Tier-2 -----------------------------
  if [ -f "$ROOT/$LOOP_REL" ]; then
    if grep -q 'is Tier-2 content and is invoked by name' "$ROOT/$LOOP_REL"; then
      bad "R4 $LOOP_REL still declares the operating stance to be Tier-2 content"
    else
      ok "R4 $LOOP_REL does not file the stance as Tier-2"
    fi
    if grep -q '\[`work-autonomously`\](\.\./work-autonomously/SKILL\.md)' "$ROOT/$LOOP_REL"; then
      ok "R4 $LOOP_REL links the shipped stance"
    else
      bad "R4 $LOOP_REL does not link the shipped stance"
    fi
  else
    bad "R4 $LOOP_REL does not exist"
  fi

  # ---- R5 the rendered prompt names no lane -------------------------------------------
  if [ -f "$ROOT/$PROMPT_REL" ]; then
    if grep -q '`work-autonomously`' "$ROOT/$PROMPT_REL"; then
      ok "R5 $PROMPT_REL names the generic stance"
    else
      bad "R5 $PROMPT_REL does not name the generic stance in the read-from-disk fallback"
    fi
    # the specific defect: a citation qualified by which lane ships it
    if grep -nE 'work-autonomously.{0,40}(on the|lane)' "$ROOT/$PROMPT_REL" >/dev/null; then
      bad "R5 $PROMPT_REL qualifies the stance by lane — Tier 1 must not know whose lane it is"
    else
      ok "R5 $PROMPT_REL cites the stance unqualified by any lane"
    fi
  else
    bad "R5 $PROMPT_REL does not exist"
  fi

  p=$PASS; f=$FAIL
  ROOT="$saved_root"; PASS=$_PASS; FAIL=$_FAIL
  SUITE_PASS=$p; SUITE_FAIL=$f
  printf '%s: %d passed, %d failed\n' "$label" "$p" "$f"
}

echo "== forward pass: the tracked tree must satisfy every rule =="
run_suite "$ROOT" "tracked tree"
FWD_PASS=$SUITE_PASS; FWD_FAIL=$SUITE_FAIL

# Forward-only mode exists solely so the reverse pass can re-exec a planted COPY of this
# script without that copy planting violations of its own, forever.
if [ -n "${STANCE_TIER_FORWARD_ONLY:-}" ]; then
  [ "$FWD_FAIL" -eq 0 ] && exit 0 || exit 1
fi

# --------------------------------------------------------------------------------------
# Reverse pass. Each violation is planted ALONE into a scratch copy of the tracked tree,
# and the scratch copy's OWN script is re-executed there in forward-only mode.
#
# The re-exec is not stylistic. The first version ran the suite in-process against a
# different $ROOT and tracked which rules failed in shell variables; the bookkeeping leaked
# between plants and reported "caught by R2 R3 (3 assertions)" for a plant that in truth
# failed exactly ONE assertion, R3. A harness whose own accounting is wrong cannot be used
# to vouch for anything — so the child process is now the unit of isolation, and the parent
# reads only its printed counts and its FAIL lines.
#
# Each plant asserts BOTH that the suite failed AND that the rule it targets is among the
# rules that failed. "Something went red" is not evidence the intended check fired.
# --------------------------------------------------------------------------------------
echo
echo "== reverse pass: each rule must FAIL on the input it exists to catch =="
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/stance-tier.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

REV_OK=0
REV_BAD=0
plant() {
  local name="$1" want="$2"; shift 2
  local work="$SCRATCH/$name" out="$SCRATCH/$name.out"
  rm -rf "$work"; mkdir -p "$work"
  (cd "$ROOT" && git ls-files -z | tar -cf - --null -T -) | (cd "$work" && tar -xf -)
  ( cd "$work" \
    && git init -q . \
    && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm baseline ) >/dev/null 2>&1
  ( cd "$work" && "$@" ) >/dev/null 2>&1
  STANCE_TIER_FORWARD_ONLY=1 bash "$work/$SELF_REL" >"$out" 2>&1
  local rc=$? fails
  fails="$(grep -c '^  FAIL ' "$out" | tr -d ' ')"
  local hit_rules
  hit_rules="$(grep '^  FAIL ' "$out" | awk '{print $2}' | sort -u | tr '\n' ' ')"
  if [ "$rc" -ne 0 ] && printf '%s' " $hit_rules" | grep -q " $want "; then
    REV_OK=$((REV_OK+1))
    printf '  ok   %-26s caught by %s(%s assertion(s) failed)\n' "$name" "$hit_rules" "$fails"
  else
    REV_BAD=$((REV_BAD+1))
    printf '  FAIL %-26s wanted %s among failures, got: %s(rc=%s)\n' "$name" "$want" "${hit_rules:-none }" "$rc"
  fi
}

plant R1-stance-deleted      R1  rm -rf skills/work-autonomously
plant R2-link-downgraded     R2  sed -i.bak 's|\[`work-autonomously`\](\.\./work-autonomously/SKILL\.md)|`work-autonomously`|g' skills/dark-factory-build/SKILL.md
plant R3-recall-name-returns R3  sh -c 'printf "1. \`loom-recall\` — search memory first.\n" >> reference/dark-factory-build-orchestrator.md'
plant R4-tier2-sentence-back R4  sh -c 'printf "that stance is Tier-2 content and is invoked by name, never linked by path.\n" >> skills/vinculum-loop/SKILL.md'
plant R5-lane-qualifier-back R5  sed -i.bak 's|and `work-autonomously` —|and `work-autonomously` on the SomeCorp lane —|' boot-kit/scripts/df-render-prompt.py

echo
echo "=================================================================="
printf 'forward : %d assertions passed, %d failed\n' "$FWD_PASS" "$FWD_FAIL"
printf 'reverse : %d planted violations caught, %d NOT caught\n' "$REV_OK" "$REV_BAD"
echo "=================================================================="
if [ "$FWD_FAIL" -eq 0 ] && [ "$REV_BAD" -eq 0 ]; then
  echo "PASS"
  exit 0
fi
echo "FAIL"
exit 1
