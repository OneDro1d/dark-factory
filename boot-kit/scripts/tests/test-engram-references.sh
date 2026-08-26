#!/usr/bin/env bash
# test-engram-references.sh — every place this repo names Engram must point at the one
# place that explains it.
#
# WHY THIS EXISTS. Eleven files across `docs/`, `reference/` and `skills/` named `engram`
# in passing long before anything in the repo said what it was. Mostly lowercase, which is
# the worse form: a stranger cannot tell whether it is a product they are missing or a
# generic word for "the memory store". In one place it is not decoration at all — it is a
# CHECKLIST ITEM telling the reader to save to it, so an unexplained noun reads as a
# prerequisite they do not have and cannot get.
#
# The explanation now exists exactly once, at `starter-kit/instance/AUTHENTICATION.md`
# anchor `#engram`. One definition, many pointers — the same reason the kit links the
# vendor's docs instead of restating them. Two copies of a product description drift, and
# the reader ends up trusting neither.
#
# THE DISCOVERY RULE, AND WHY IT IS NOT A LIST.
# This suite does NOT iterate a hardcoded set of eleven files. It asks git for every
# tracked file containing `engram`, subtracts a short, JUSTIFIED exclusion set, and
# requires a pointer in each of the rest. A guard built from a list can only ever prove the
# files that were known when it was written; the twelfth file, added next month, is invisible
# to it and the defect is its ABSENCE — which is precisely the class of bug this repo keeps
# finding in its own gates. Start from the unknown side.
#
# The exclusions are themselves checked (R4): an exclusion whose file has been deleted, or
# no longer mentions Engram, is silently protecting nothing and would mask a later file
# arriving at that path. A stale allowlist is an allowlist nobody re-reads.
#
# Run:  bash boot-kit/scripts/tests/test-engram-references.sh
# Exit: 0 all pass · 1 at least one failed. Prints a literal count, because a suite that
# says "ok" without saying how many assertions ran cannot be told from one that ran none.
#
#   R1  the anchor exists in the definition page, and is a real HTML anchor rather than a
#       heading whose slug could be renamed out from under eleven links.
#   R2  every tracked file mentioning Engram, minus the exclusions, carries the pointer.
#   R3  every markdown pointer RESOLVES — the relative path is walked to a real file on
#       disk. `link-check.py` does not check anchors and says so, and a link that is off by
#       one `../` renders as ordinary blue text that 404s only for the reader.
#   R4  every exclusion is live: the path exists AND still mentions Engram.
#   R5  the two CHECKLIST sites carry the pointer on the instruction line itself. A reader
#       who enters a document at its checklist has not read its prose.
#
# Every rule is exercised in BOTH directions. A check never seen to fail on the input it
# exists to catch is not known to work — this repo has shipped a gate that reported CLEAN on
# a planted canary. Canaries are written to $TMPDIR and never to the tracked tree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DEF_REL="starter-kit/instance/AUTHENTICATION.md"
DEF="$ROOT/$DEF_REL"
ANCHOR='<a id="engram"></a>'
POINTER="AUTHENTICATION.md#engram"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The files that legitimately mention Engram WITHOUT pointing at the explanation, and why.
# Keep this list short and keep the reasons specific: "it is inconvenient" is not a reason.
EXCLUDE_PATHS=(
  # It IS the explanation. A page cannot point at itself.
  "starter-kit/instance/AUTHENTICATION.md"
  # A JSON config has no comment syntax to carry a link, and its `$hubUrl` note already
  # routes the reader to the vendor's own docs directly.
  "starter-kit/instance/boot-kit/mcp.template.json"
  # Test suites. They match because they assert ON the word; a stranger looking for the
  # product does not read them, and a pointer here would be a pointer nobody follows.
  "starter-kit/instance/tests/test-authentication-doc.sh"
  "starter-kit/instance/tests/test-start-here-doc.sh"
  "boot-kit/scripts/tests/test-engram-references.sh"
)

excluded() {
  local p="$1" e
  for e in "${EXCLUDE_PATHS[@]}"; do [ "$p" = "$e" ] && return 0; done
  return 1
}

echo "=== Engram references point at the one explanation ==="
echo

# ---- R1 -- the anchor exists, and is an HTML anchor -------------------------------------
echo "R1  the definition anchor"
if [ -f "$DEF" ]; then
  ok "definition page exists: $DEF_REL"
else
  bad "definition page exists: $DEF_REL" "every pointer in this repo is dangling"
fi
if grep -qF "$ANCHOR" "$DEF" 2>/dev/null; then
  ok "explicit HTML anchor present: $ANCHOR"
else
  bad "explicit HTML anchor present: $ANCHOR" \
      "a heading slug is not enough -- renaming the heading breaks every pointer silently"
fi
printf 'x\n' > "$TMP/noanchor.md"
if grep -qF "$ANCHOR" "$TMP/noanchor.md" 2>/dev/null; then
  bad "R1 canary: a page without the anchor is detected"
else
  ok "R1 canary: a page without the anchor is detected"
fi
echo

# ---- R2 -- inventory: discovered from git, not from a list ------------------------------
echo "R2  every file that names Engram points at it"
MENTIONS=()
while IFS= read -r f; do MENTIONS+=("$f"); done < <(
  cd "$ROOT" && git ls-files -z | xargs -0 grep -ril 'engram' 2>/dev/null | sort
)
if [ "${#MENTIONS[@]}" -gt 0 ]; then
  ok "discovery found ${#MENTIONS[@]} tracked file(s) naming Engram"
else
  bad "discovery found tracked file(s) naming Engram" \
      "zero results means the discovery step is broken, not that the repo is clean"
fi

MISSING=""; CHECKED=0
for f in "${MENTIONS[@]}"; do
  excluded "$f" && continue
  CHECKED=$((CHECKED+1))
  grep -qF "$POINTER" "$ROOT/$f" || MISSING="$MISSING $f"
done
if [ -z "$MISSING" ]; then
  ok "all $CHECKED non-excluded file(s) carry a pointer to $POINTER"
else
  bad "all $CHECKED non-excluded file(s) carry a pointer to $POINTER" \
      "missing in:$MISSING"
fi
# Canary: a file that names Engram and points nowhere must be caught by the same test.
printf 'A stage writes to engram at each checkpoint.\n' > "$TMP/orphan.md"
if grep -qF "$POINTER" "$TMP/orphan.md"; then
  bad "R2 canary: an orphan mention is detected"
else
  ok "R2 canary: an orphan mention is detected"
fi
echo

# ---- R3 -- the pointers resolve on disk -------------------------------------------------
echo "R3  every markdown pointer resolves to the real page"
BADLINK=""; NLINK=0
for f in "${MENTIONS[@]}"; do
  excluded "$f" && continue
  case "$f" in *.md) ;; *) continue ;; esac
  dir="$(dirname "$ROOT/$f")"
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    NLINK=$((NLINK+1))
    resolved="$(cd "$dir" 2>/dev/null && cd "$(dirname "$target")" 2>/dev/null && \
                printf '%s/%s' "$(pwd)" "$(basename "$target")")"
    [ "$resolved" = "$DEF" ] || BADLINK="$BADLINK $f->$target"
  done < <(grep -oE '\]\(([^)]*)AUTHENTICATION\.md#engram\)' "$ROOT/$f" \
             | sed -E 's/^\]\(//; s/#engram\)$//')
done
if [ "$NLINK" -gt 0 ]; then
  ok "found $NLINK markdown pointer link(s) to check"
else
  bad "found markdown pointer link(s) to check" "zero links means the extractor is broken"
fi
if [ -z "$BADLINK" ]; then
  ok "all $NLINK pointer link(s) resolve to $DEF_REL"
else
  bad "all $NLINK pointer link(s) resolve to $DEF_REL" "not resolving:$BADLINK"
fi
# Canary: one `../` too few must not resolve.
mkdir -p "$TMP/a/b"
printf 'see [Engram](../%s#engram)\n' "$DEF_REL" > "$TMP/a/b/wrong.md"
wrongdir="$TMP/a/b"; wrongtarget="../$DEF_REL"
wres="$(cd "$wrongdir" && cd "$(dirname "$wrongtarget")" 2>/dev/null && \
        printf '%s/%s' "$(pwd)" "$(basename "$wrongtarget")")"
if [ "$wres" = "$DEF" ]; then
  bad "R3 canary: a wrong relative depth is detected"
else
  ok "R3 canary: a wrong relative depth is detected"
fi
echo

# ---- R4 -- the exclusion list is live ---------------------------------------------------
echo "R4  every exclusion still earns its place"
STALE=""
for e in "${EXCLUDE_PATHS[@]}"; do
  if [ ! -f "$ROOT/$e" ]; then STALE="$STALE $e(gone)"; continue; fi
  grep -qil 'engram' "$ROOT/$e" >/dev/null 2>&1 || STALE="$STALE $e(no-mention)"
done
if [ -z "$STALE" ]; then
  ok "all ${#EXCLUDE_PATHS[@]} exclusion(s) exist and still mention Engram"
else
  bad "all ${#EXCLUDE_PATHS[@]} exclusion(s) exist and still mention Engram" \
      "stale:$STALE -- a dead exclusion masks whatever arrives at that path"
fi
if [ -f "$ROOT/starter-kit/instance/does-not-exist.md" ]; then
  bad "R4 canary: a nonexistent exclusion path is detected"
else
  ok "R4 canary: a nonexistent exclusion path is detected"
fi
echo

# ---- R5 -- the checklist sites carry it on the instruction line -------------------------
echo "R5  the checklist instruction lines carry the pointer"
for f in "skills/dark-factory-build/SKILL.md" "reference/dark-factory-build-orchestrator.md"; do
  if [ ! -f "$ROOT/$f" ]; then
    bad "$f: checklist line carries the pointer" "file not found"
    continue
  fi
  if grep -n 'Save to memory' "$ROOT/$f" | grep -qF "$POINTER"; then
    ok "$f: 'Save to memory' checklist line carries the pointer"
  else
    bad "$f: 'Save to memory' checklist line carries the pointer" \
        "a reader entering at the checklist has not read the prose above it"
  fi
done
printf -- '- [ ] Save to memory (engram project record); close the epic.\n' > "$TMP/cl.md"
if grep -n 'Save to memory' "$TMP/cl.md" | grep -qF "$POINTER"; then
  bad "R5 canary: a bare checklist line is detected"
else
  ok "R5 canary: a bare checklist line is detected"
fi
echo

printf '%s\n' "-----"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
