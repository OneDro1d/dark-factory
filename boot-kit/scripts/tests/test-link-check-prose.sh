#!/usr/bin/env bash
# test-link-check-prose.sh — prove link-check sees a reference written as backticked prose.
#
# The defect this exists for: `patterns/richardson-rules.md` shipped four references to
# files that do not exist in this repo, on public main, and link-check PASSED — because
# all four were written as `_meta/PWW_AXIOMS.md` rather than as [x](_meta/PWW_AXIOMS.md).
# Rewriting one of them to markdown-link syntax, changing nothing else, turned the same
# run FAIL. The checker was blind to the FORM, not ignorant of the FACT.
#
# The opposite failure is just as real and constrains the fix: a checker that flags every
# backticked *.md token flags 213 of them here, almost all correct prose (`NOTES.md` is
# the NAME OF A KIND OF FILE, not a link). A gate that fires 200 times is one people learn
# to override. So the PROSE-REF class is deliberately narrow — it requires a directory
# component, and it resolves against every ancestor directory up to the repo root, because
# a doc inside a template addresses its siblings from the template root, not from itself.
#
# Each case is asserted SEPARATELY, and each case that PASSES is paired with something
# that must FAIL — a batch that goes green together proves the batch, not the member, and
# "nothing is detected at all" makes every PASS-case vacuously true. Case 1 is the control
# for detection; case 4b is the control for case 4. Recorded honestly: 2, 3, 6 and 7 held
# BEFORE this feature and are regression guards, not evidence of it; 1, 4/4b and 5 are the
# new behaviour and all three went red on the pre-feature run.
#
# Runs entirely in a scratch tree under $TMPDIR — never against the real repo.
#
# Usage: bash boot-kit/scripts/tests/test-link-check-prose.sh
# Exit:  0 = all cases behave   1 = at least one does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$(cd "$SELF/.." && pwd)/link-check.py"
[ -f "$CHECK" ] || { echo "link-check.py not found at $CHECK"; exit 2; }

FAIL=0
PASSED=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcprose.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# assert <case-name> <expected-rc> <must-contain|-> — runs link-check on $WORK/tree
assert() {
  local name="$1" want_rc="$2" want_txt="$3" out rc
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
  echo "ok    $name"
  PASSED=$((PASSED+1))
}

fresh() { rm -rf "$WORK/tree"; mkdir -p "$WORK/tree"; }

# --- 1 (NEW) a real dangling prose reference must FAIL and be named PROSE-REF ----------
fresh
printf '# doc\n\nSee `_meta/AXIOMS.md` (source of truth).\n' > "$WORK/tree/a.md"
assert "1 dangling prose ref FAILs" 1 "PROSE-REF"

# --- 2 (REGRESSION) the same token inside a fenced block must still PASS ---------------
fresh
printf '# doc\n\n```\nSee `_meta/AXIOMS.md` here.\n```\n' > "$WORK/tree/a.md"
assert "2 fenced prose ref PASSes" 0 "-"

# --- 3 (REGRESSION) a bare filename with no directory is out of scope by design --------
fresh
printf '# doc\n\nWrite your working memory to `NOTES.md` as you go.\n' > "$WORK/tree/a.md"
assert "3 bare filename PASSes" 0 "-"

# --- 4 (NEW) a token that resolves from an ANCESTOR directory must PASS ----------------
fresh
mkdir -p "$WORK/tree/tpl/agents" "$WORK/tree/tpl/context"
printf 'x\n' > "$WORK/tree/tpl/agents/README.md"
printf '# doc\n\nDispatch per `agents/README.md`.\n' > "$WORK/tree/tpl/context/GUIDE.md"
assert "4 ancestor-resolved prose ref PASSes" 0 "-"

# --- 4b (NEW, control for 4) remove the ancestor target: the SAME ref must now FAIL ----
rm "$WORK/tree/tpl/agents/README.md"
assert "4b same ref FAILs once the ancestor target is gone" 1 "PROSE-REF"

# --- 4c (NEW) a ref that resolves OUTSIDE the repo is not a resolution ----------------
# `../../DESIGN.md` from skills/scope-init/ finds a sibling checkout on the machine that
# wrote it and nothing anywhere else. Two such refs were live on main.
fresh
mkdir -p "$WORK/tree/skills/scope-init"
printf 'x\n' > "$WORK/OUTSIDE.md"
printf '# doc\n\nSee `../../../OUTSIDE.md`.\n' > "$WORK/tree/skills/scope-init/SKILL.md"
assert "4c ref resolving outside the repo still FAILs" 1 "PROSE-REF"

# --- 5 (NEW) .linkcheckignore suppresses it, and says so out loud ----------------------
fresh
printf '# doc\n\nSee `_meta/AXIOMS.md` (source of truth).\n' > "$WORK/tree/a.md"
printf 'a.md -> _meta/AXIOMS.md # output path the build creates downstream\n' \
  > "$WORK/tree/.linkcheckignore"
assert "5 suppressed prose ref PASSes and is counted" 0 "suppressed by .linkcheckignore"

# --- 6 (REGRESSION) a broken markdown link still FAILs --------------------------------
fresh
printf '# doc\n\nSee [axioms](_meta/AXIOMS.md).\n' > "$WORK/tree/a.md"
assert "6 broken markdown link still FAILs" 1 "IN-REPO"

# --- 7 (REGRESSION) a suppression without a reason is still a hard error --------------
fresh
printf '# doc\n\nSee `_meta/AXIOMS.md`.\n' > "$WORK/tree/a.md"
printf 'a.md -> _meta/AXIOMS.md\n' > "$WORK/tree/.linkcheckignore"
assert "7 unjustified suppression is a hard error" 2 "no \`# reason\`"

echo
if [ "$FAIL" = 0 ]; then
  echo "RESULT: PASS — 9/9 cases behave ($PASSED asserted)"
else
  echo "RESULT: FAIL — $PASSED/9 cases behave"
fi

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASSED + FAIL))"
exit "$FAIL"
