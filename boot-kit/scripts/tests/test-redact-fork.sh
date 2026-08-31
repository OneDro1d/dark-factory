#!/usr/bin/env bash
# test-redact-fork.sh — the two copies of the hardened redactor must not drift apart.
#
# WHY THIS EXISTS. `lib/redact.sh` exists twice in this repo — once under
# `skills/agent-notepad/plugin/lib/` and once under `skills/handoff-auto/lib/`. Both are
# SOURCED by live code in their own skill, so neither can simply be deleted, and agent-notepad
# supersedes handoff-auto without removing it. Today they differ only in header comments.
#
# A redactor that drifts FAILS SILENTLY. It does not error and it does not log; it just stops
# masking one class of secret in one of the two paths, and the first evidence is the secret in
# a published handoff. `kits/agent-ops/kit.json` already records the risk in prose — "a
# redactor that drifts fails silently, and that is worth resolving before either is bundled
# again" — and prose is exactly what this repo has learned decays: a caveat written where no
# gate reads it decays like no caveat.
#
# WHAT IS COMPARED, AND WHY NOT THE WHOLE FILE. Header comments legitimately differ: each names
# its own skill and its own requirement ids. Comparing raw bytes would fail on the day it
# landed and be waived within the week, which is worse than no test. So the comparison is over
# the EXECUTABLE lines only — every line that is not blank and not a whole-line comment. Those
# are the lines that redact.
#
# R3 is a canary and it is not optional: a comparison test that can only pass proves nothing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

A="$ROOT/skills/agent-notepad/plugin/lib/redact.sh"
B="$ROOT/skills/handoff-auto/lib/redact.sh"

fail=0
n=0
ok()  { n=$((n + 1)); echo "  ok    $1"; }
bad() { n=$((n + 1)); echo "  FAIL  $1"; fail=1; }

# code_of <file> -> the executable lines: not blank, not a whole-line comment.
code_of() {
  sed -e 's/[[:space:]]*$//' "$1" | grep -vE '^[[:space:]]*(#|$)'
}

echo "=== redact.sh: two copies, one behaviour ==="
echo
echo "R1  both copies exist"
if [ -f "$A" ]; then ok "agent-notepad copy present"; else bad "agent-notepad copy MISSING"; fi
if [ -f "$B" ]; then ok "handoff-auto copy present"; else bad "handoff-auto copy MISSING"; fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "ASSERTIONS: $n"
  exit 1
fi

echo
echo "R2  their executable lines are identical"
TMP="$(mktemp -d)"
code_of "$A" > "$TMP/a.code"
code_of "$B" > "$TMP/b.code"
LINES="$(wc -l < "$TMP/a.code" | tr -d ' ')"

if [ ! -s "$TMP/a.code" ]; then
  bad "extracted zero executable lines — the extractor is broken, not the files"
elif cmp -s "$TMP/a.code" "$TMP/b.code"; then
  ok "executable lines identical ($LINES lines compared)"
else
  bad "THE TWO REDACTORS HAVE DRIFTED — a security-relevant divergence"
  diff "$TMP/a.code" "$TMP/b.code" | sed 's/^/        /' | head -40
fi

echo
echo "R3  canary: a one-line divergence IS detected"
cp "$TMP/a.code" "$TMP/c.code"
printf 'canary_extra_statement=1\n' >> "$TMP/c.code"
if cmp -s "$TMP/a.code" "$TMP/c.code"; then
  bad "canary: a modified copy compared EQUAL — this test cannot fail and proves nothing"
else
  ok "canary: a modified copy is detected as different"
fi

rm -rf "$TMP"

echo
echo "-----"
if [ "$fail" -eq 0 ]; then echo "passed: $n   failed: 0"; else echo "failed — see above"; fi
echo "ASSERTIONS: $n"
exit $fail
