#!/usr/bin/env bash
# test-plugin-skill-forks.sh — three skills exist twice in this repo; their INSTRUCTIONS must
# not drift apart.
#
# WHY THIS EXISTS. `handoff`, `scope-init` and `scope-retire` each live at `skills/<name>/` AND
# at `skills/agent-notepad/plugin/skills/<name>/`. The plugin bundle needs its own copies to be
# self-contained; the lockfile installs the TOP-LEVEL ones. Neither can simply be deleted.
#
# ⚠️ THE COST, MEASURED 2026-08-31, NOT HYPOTHESISED. `handoff` had drifted by fourteen lines,
# and the divergence was a live defect in the copy that installs: the top-level file documented
#     "${CLAUDE_PLUGIN_ROOT}/lib/publish-handoff.sh"
# with no fallback. `CLAUDE_PLUGIN_ROOT` is set only under PLUGIN mode; under `install.sh` it is
# empty and that path collapses to `/lib/publish-handoff.sh`, which does not exist. The correct
# line — a `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/hooks/agent-notepad}` fallback — already existed
# in the plugin twin that nothing installs. **The estate shipped the broken half and kept the fix
# where no machine would read it**, and no gate noticed for months.
#
# WHAT IS COMPARED, AND WHY NOT THE WHOLE FILE. Prose legitimately differs: each copy resolves
# relative links from its own depth, and each header describes its own side of the pair. A
# byte-for-byte test would have failed on the day it landed and been waived within the week,
# which is worse than no test. So the comparison is over the FENCED CODE BLOCKS with comment
# lines stripped — the lines a reader actually executes.
#
# R3 is a canary and it is not optional: a comparison test that can only pass proves nothing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TOP="$ROOT/skills"
PLUG="$ROOT/skills/agent-notepad/plugin/skills"
SKILLS="handoff scope-init scope-retire"

fail=0
n=0
ok()  { n=$((n + 1)); echo "  ok    $1"; }
bad() { n=$((n + 1)); echo "  FAIL  $1"; fail=1; }

# code_of <skill.md> -> executable lines inside ``` fences, comments and blanks removed
code_of() {
  awk '/^```/ { inb = !inb; next } inb' "$1" \
    | sed -e 's/[[:space:]]*$//' \
    | grep -vE '^[[:space:]]*(#|$)'
}

echo "=== plugin-bundled skills: two copies, one set of instructions ==="
echo
echo "R1  both copies of each skill exist"
for s in $SKILLS; do
  if [ -f "$TOP/$s/SKILL.md" ] && [ -f "$PLUG/$s/SKILL.md" ]; then
    ok "$s present in both trees"
  else
    bad "$s MISSING from one tree"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "ASSERTIONS: $n"
  exit 1
fi

echo
echo "R2  their fenced code blocks are identical once comments are stripped"
TMP="$(mktemp -d)"
for s in $SKILLS; do
  code_of "$TOP/$s/SKILL.md"  > "$TMP/$s.top"
  code_of "$PLUG/$s/SKILL.md" > "$TMP/$s.plug"
  lines="$(wc -l < "$TMP/$s.top" | tr -d ' ')"
  if cmp -s "$TMP/$s.top" "$TMP/$s.plug"; then
    ok "$s code identical ($lines line(s) compared)"
  else
    bad "$s HAS DRIFTED — the installed copy and the bundled copy disagree"
    diff "$TMP/$s.top" "$TMP/$s.plug" | sed 's/^/        /' | head -20
  fi
done

echo
echo "R3  canary: a one-line divergence IS detected"
cp "$TMP/handoff.top" "$TMP/canary"
printf 'canary_divergent_line=1\n' >> "$TMP/canary"
if cmp -s "$TMP/handoff.top" "$TMP/canary"; then
  bad "canary: a modified copy compared EQUAL — this test cannot fail and proves nothing"
else
  ok "canary: a modified copy is detected as different"
fi

echo
echo "R5  their CAVEAT lines are identical too"
# ⚠️ ADDED 2026-08-31 BECAUSE R2 MISSED A LIVE ONE. `scope-init` had contradictory DIGEST.md
# instructions, and the correction was written into the PLUGIN copy — the one nothing
# installs — exactly as `handoff`'s fix had been. R2 compares fenced code and saw nothing,
# because in an instructions skill the instructions ARE the prose.
#
# WHY CAVEATS AND NOT ALL PROSE. The header above is right that a whole-file compare fails on
# day one and gets waived: relative links resolve from each copy's own depth and each header
# describes its own side. A ⚠️ line is the exception — this repo's own rule is that a caveat is
# never compressed away, and a caveat is about the SKILL, not about which tree the copy sits
# in. If one ever must differ per copy, the right repair is to word it identically, not to
# widen this comparison.
#
# Measured before landing: all three pairs already match (7 / 1 / 0 lines), so this does not
# ship a red gate.
caveats_of() { grep '⚠️' "$1" 2>/dev/null; }
for s in $SKILLS; do
  caveats_of "$TOP/$s/SKILL.md"  > "$TMP/$s.top.cav"
  caveats_of "$PLUG/$s/SKILL.md" > "$TMP/$s.plug.cav"
  c="$(wc -l < "$TMP/$s.top.cav" | tr -d ' ')"
  if cmp -s "$TMP/$s.top.cav" "$TMP/$s.plug.cav"; then
    # The count is printed even when it is 0. "Both copies have no caveats" and "the
    # extractor found nothing" render identically otherwise, and only one of them is a fact
    # about the files.
    ok "$s caveats identical ($c line(s) compared)"
  else
    bad "$s CAVEATS HAVE DRIFTED — one copy carries a warning the other does not"
    diff "$TMP/$s.top.cav" "$TMP/$s.plug.cav" | sed 's/^/        /' | head -20
  fi
done

echo
echo "R6  canary: a dropped caveat IS detected"
cp "$TMP/scope-init.top.cav" "$TMP/cav-canary"
sed -i.bak '1d' "$TMP/cav-canary" && rm -f "$TMP/cav-canary.bak"
if cmp -s "$TMP/scope-init.top.cav" "$TMP/cav-canary"; then
  bad "canary: a caveat set with a line REMOVED compared equal — this check cannot fail"
else
  ok "canary: a removed caveat line is detected"
fi

echo
echo "R4  canary: the extractor actually extracts something"
# A test whose extractor silently returns nothing would report every pair identical.
if [ -s "$TMP/handoff.top" ]; then
  ok "extractor returned $(wc -l < "$TMP/handoff.top" | tr -d ' ') code line(s) for handoff"
else
  bad "extractor returned ZERO lines — every comparison above is vacuous"
fi

rm -rf "$TMP"

echo
echo "-----"
if [ "$fail" -eq 0 ]; then echo "passed: $n   failed: 0"; else echo "failed — see above"; fi
echo "ASSERTIONS: $n"
exit $fail
