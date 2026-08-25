#!/usr/bin/env bash
# test-tier-check-prose.sh — prove tier-check sees a skill reference written as backticked prose.
#
# The defect this exists for: on 2026-08-25 this repo cited a memory-recall skill it does
# not ship FOUR times — as STEP 1 of the engine's own pipeline, in two separate lists —
# while `tier-check` printed PASS. It ships in exactly one org repo and nowhere here. The
# checker was blind to the FORM, not ignorant of the FACT: rewriting one of those four as
# `Skill(<name>)`, changing nothing else, turned the same run FAIL. The name itself is not
# repeated here: it is a Tier-2 binding, and the fixtures below use `absent-skill` instead.
#
# The opposite failure constrains the fix, and this is where the rule was CHOSEN rather
# than guessed. On the tree that carried the defect:
#
#   873  backticked tokens in prose                                       (unusable)
#   164  hyphenated, bare, not shipped here                              (unusable)
#    10  ...that also sit in a block naming a component this repo SHIPS   <- the rule
#     4  of those 10 were the defect — i.e. ALL FOUR known defects
#
# The plausible alternative — "the same LINE also carries a Skill() call or a SKILL.md
# link" — scored 0 of 4. Every defect line was bare prose among bare prose; the confirmed
# reference was elsewhere in the list. A rule that reads well and catches nothing is the
# shape this repo has been wrong in before (link-check's first-path-segment rule scored
# 0/4 the same way). MEASURE A CANDIDATE AGAINST THE KNOWN DEFECTS BEFORE ADOPTING IT.
#
# Each case is asserted SEPARATELY. Every case that must PASS is paired with something
# that must FAIL, because "nothing is detected at all" makes every PASS-case vacuously
# true: 1 is the control for detection, 4b for 4, 6b for 6. And each planted violation
# asserts the INTENDED class is what caught it (PROSE-REF vs the pre-existing forms) —
# asserting only "it went red" proves the batch, not the member.
#
# Runs entirely in a scratch tree under $TMPDIR — never against the real repo.
#
# Usage: bash boot-kit/scripts/tests/test-tier-check-prose.sh
# Exit:  0 = all cases behave   1 = at least one does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$(cd "$SELF/.." && pwd)/tier-check.py"
[ -f "$CHECK" ] || { echo "tier-check.py not found at $CHECK"; exit 2; }

FAIL=0
PASSED=0
CASES=12
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tcprose.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# assert <case-name> <expected-rc> <must-contain|-> [must-NOT-contain]
assert() {
  local name="$1" want_rc="$2" want_txt="$3" not_txt="${4:-}" out rc
  out="$(python3 "$CHECK" "$WORK/tree" 2>&1)"; rc=$?
  if [ "$rc" != "$want_rc" ]; then
    echo "FAIL  $name: expected exit $want_rc, got $rc"
    echo "$out" | sed 's/^/        /'
    FAIL=1; return
  fi
  if [ "$want_txt" != "-" ] && ! printf '%s' "$out" | grep -qF "$want_txt"; then
    echo "FAIL  $name: exit $rc as expected but output lacks: $want_txt"
    echo "$out" | sed 's/^/        /'
    FAIL=1; return
  fi
  if [ -n "$not_txt" ] && printf '%s' "$out" | grep -qF "$not_txt"; then
    echo "FAIL  $name: output must NOT contain: $not_txt"
    echo "$out" | sed 's/^/        /'
    FAIL=1; return
  fi
  echo "ok    $name"
  PASSED=$((PASSED+1))
}

# A tree that ships ONE skill, so every block below has a legitimate shipped sibling to
# anchor on. `df-qa` is the anchor; the token under test is the second one in the block.
fresh() {
  rm -rf "$WORK/tree"
  mkdir -p "$WORK/tree/skills/df-qa"
  printf '# df-qa\n' > "$WORK/tree/skills/df-qa/SKILL.md"
}

# --- 1 (NEW) a prose skill ref in a block with a shipped sibling must FAIL as PROSE-REF --
fresh
printf '# doc\n\n1. `absent-skill` — runs first.\n2. `df-qa` — the gate.\n' \
  > "$WORK/tree/a.md"
assert "1 prose ref beside a shipped sibling FAILs as PROSE-REF" 1 "PROSE-REF"

# --- 2 (NEW, control for 1) the SAME token with no shipped sibling in the block PASSes ---
# This is the whole discriminator. Without it the gate fires 164 times on this repo.
fresh
printf '# doc\n\n1. `absent-skill` — runs first.\n2. `something-else` — no.\n' \
  > "$WORK/tree/a.md"
assert "2 same token with no shipped sibling PASSes" 0 "-" "absent-skill"

# --- 3 (NEW) the sibling must be in the SAME block — a blank line breaks the anchor ------
fresh
printf '# doc\n\n1. `absent-skill` — runs first.\n\n2. `df-qa` — the gate.\n' \
  > "$WORK/tree/a.md"
assert "3 sibling in a different block does not anchor" 0 "-" "absent-skill"

# --- 4 (NEW) an inline enumeration on ONE line is a block too ----------------------------
fresh
printf '# doc\n\nSuggested next: `df-qa`, `absent-skill`, `another-absent`.\n' \
  > "$WORK/tree/a.md"
assert "4 inline enumeration FAILs as PROSE-REF" 1 "PROSE-REF"

# --- 4b (NEW, control for 4) ship the named skill and the SAME line must PASS ------------
mkdir -p "$WORK/tree/skills/absent-skill" "$WORK/tree/skills/another-absent"
printf '# x\n' > "$WORK/tree/skills/absent-skill/SKILL.md"
printf '# x\n' > "$WORK/tree/skills/another-absent/SKILL.md"
assert "4b same line PASSes once both are shipped" 0 "-"

# --- 5 (NEW) a skill shipped at DEPTH counts as shipped ----------------------------------
# `context-management` and `contract-check` ship only inside df-context-store's substrate
# template. The content travels with the repo, so a consumer resolves it; calling that a
# tier violation is a false positive, and there were 6 of them.
fresh
mkdir -p "$WORK/tree/skills/df-context-store/substrate-template/dotclaude/skills/commit-sync"
printf '# x\n' > "$WORK/tree/skills/df-context-store/substrate-template/dotclaude/skills/commit-sync/SKILL.md"
printf '# doc\n\nRecord it, then `df-qa`, then `commit-sync`.\n' > "$WORK/tree/a.md"
assert "5 skill shipped at depth is not a violation" 0 "-" "commit-sync"

# --- 6 (NEW) an AGENT this repo ships counts as provided, for the prose class ------------
fresh
mkdir -p "$WORK/tree/agents"
printf '# x\n' > "$WORK/tree/agents/knowledge-keeper.md"
printf '# doc\n\nA finding recorded via `knowledge-keeper` then `df-qa`.\n' > "$WORK/tree/a.md"
assert "6 shipped agent is not a violation in prose" 0 "-" "knowledge-keeper"

# --- 6b (NEW, control for 6) a shipped AGENT does NOT license the Skill() form -----------
# Skill(x) asserts x is an invocable skill. An agent is not one. Widening `shipped` for
# prose must not quietly widen it for the form that already worked.
fresh
mkdir -p "$WORK/tree/agents"
printf '# x\n' > "$WORK/tree/agents/knowledge-keeper.md"
printf '# doc\n\nRun `Skill(knowledge-keeper)` next.\n' > "$WORK/tree/a.md"
assert "6b shipped agent does not license Skill(agent)" 1 "knowledge-keeper"

# --- 7 (NEW) .tiercheckignore suppresses it, and says so out loud ------------------------
fresh
printf '# doc\n\n1. `proj-arbbot` — an example.\n2. `df-qa` — the gate.\n' > "$WORK/tree/a.md"
printf 'a.md -> proj-arbbot # an example notepad directory, not a component\n' \
  > "$WORK/tree/.tiercheckignore"
assert "7 suppressed prose ref PASSes and is counted" 0 "suppressed by .tiercheckignore"

# --- 8 (NEW) a suppression without a reason is a hard error ------------------------------
fresh
printf '# doc\n\n1. `proj-arbbot` — an example.\n2. `df-qa` — the gate.\n' > "$WORK/tree/a.md"
printf 'a.md -> proj-arbbot\n' > "$WORK/tree/.tiercheckignore"
assert "8 unjustified suppression is a hard error" 2 "no \`# reason\`"

# --- 9 (REGRESSION) fenced blocks are still skipped for the prose class ------------------
fresh
printf '# doc\n\n```\n1. `absent-skill` — runs first.\n2. `df-qa` — the gate.\n```\n' \
  > "$WORK/tree/a.md"
assert "9 fenced prose ref PASSes" 0 "-" "absent-skill"

# --- 10 (REGRESSION) Skill() still FAILs, and is NOT reported as PROSE-REF ---------------
fresh
printf '# doc\n\nRun `Skill(absent-skill)` first.\n' > "$WORK/tree/a.md"
assert "10 Skill() form still FAILs, class unchanged" 1 "absent-skill" "PROSE-REF"

# --- 11 (REGRESSION) --allow silences the prose class too --------------------------------
fresh
printf '# doc\n\n1. `absent-skill` — runs first.\n2. `df-qa` — the gate.\n' > "$WORK/tree/a.md"
out="$(python3 "$CHECK" "$WORK/tree" --allow absent-skill 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then echo "ok    11 --allow silences the prose class"; PASSED=$((PASSED+1));
else echo "FAIL  11 --allow did not silence the prose class (rc=$rc)"; echo "$out" | sed 's/^/        /'; FAIL=1; fi

# --- 12 (NEW) a token with no hyphen is out of scope by design ---------------------------
# `authority`, `effect`, `pure`, `origin` are 157 of the 873 backticked tokens here and
# none is a component name. Requiring a hyphen is what makes the class usable.
fresh
printf '# doc\n\n1. `authority` — the owning node.\n2. `df-qa` — the gate.\n' > "$WORK/tree/a.md"
assert "12 unhyphenated token is out of scope" 0 "-" "authority"

echo
if [ "$FAIL" = 0 ]; then
  echo "RESULT: PASS — $CASES/$CASES cases behave ($PASSED asserted)"
else
  echo "RESULT: FAIL — $PASSED/$CASES cases behave"
fi
exit "$FAIL"
