#!/usr/bin/env bash
# test-binding-invokes-generics.sh — a binding must INVOKE the method, not just ship beside it.
#
# WHY THIS EXISTS, and it is one link past the failure everyone already knows.
#
# "Content on disk that no lockfile declares is installed by nothing and reported by nothing"
# is well understood here. Its sibling has the same shape and none of the visibility:
# DECLARED, INSTALLED, AND NEVER INVOKED. The file is right there on disk, so every check that
# looks for a file passes, and the skill still never reaches a session.
#
# Measured 2026-09-01 across all three estate bindings in the reference estate:
#
#     capability            onedroid  optima  catalyst
#     work-autonomously        --       --       --      <-- the escalation gate, in NONE
#     critical-thinking        --       --       --
#     df-preflight            yes      yes       --
#     promise theory          yes      yes       --
#     sizes (lines)           301      294      124
#
# `work-autonomously` carries the rule that decides whether a question is really the
# operator's before their attention is spent on it. It shipped in Tier 1, was open source, was
# fetchable by every kit, and reached nobody, because no binding named it. The 124-line
# outlier had also quietly lost the preflight and Promise Theory — three estates hand-rolling
# a binding with no template drifted that far apart.
#
# ⚠️ THE ASSERTION IS THE INVOCATION, NOT THE FILE. Checking that Tier 1 contains
# skills/work-autonomously/ would have passed on every single day this bug was live. This
# suite reads the BINDINGS and asks whether each one names the generic.
#
# ⚠️ BY NAME, NEVER BY PATH — and case D is why. Two bindings in this estate's history linked
# into `Dark-Factory-Process`, archived 2026-08-06. Both links resolved to nothing, the
# contract was never loaded, and nothing said so. A path that resolves on the authoring
# machine is not an invocation anywhere else.
#
# Usage: bash starter-kit/tests/test-binding-invokes-generics.sh [--binding <SKILL.md> ...]
#        BINDINGS="a/SKILL.md b/SKILL.md" bash ...
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T1="$(cd "$SELF/../.." && pwd)"
TEMPLATE_DIR="$T1/starter-kit/templates/tier2-org/bindings"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

# The six. Each must be NAMED by every binding. Kept as a flat list rather than derived from
# the template, so a mistake in the template cannot silently empty the requirement.
REQUIRED="work-autonomously critical-thinking vinculum-loop vinculum-map df-dispatch-subagents df-adversary-gate"

echo "=== A: the template itself names all six ==="
TPL="$TEMPLATE_DIR/SKILL.md.template"
if [ ! -f "$TPL" ]; then
  bad "A: the binding template exists" "no $TPL — an estate has nothing to copy, which is how three bindings drifted to 301/294/124 lines"
else
  ok "A: the binding template exists"
  tpl="$(cat "$TPL")"
  for r in $REQUIRED; do
    case "$tpl" in *"$r"*) ok "A: template names $r" ;;
      *) bad "A: template names $r" "missing from the template every estate copies" ;; esac
  done
fi

echo "=== B: the README states WHY, not just what ==="
RDM="$TEMPLATE_DIR/README.md"
if [ ! -f "$RDM" ]; then
  bad "B: bindings/README.md exists" "no $RDM"
else
  rdm="$(cat "$RDM")"
  case "$rdm" in *"never invoked"*|*"never reached"*) ok "B: names the declared-but-never-invoked failure" ;;
    *) bad "B: names the declared-but-never-invoked failure" "a rule with no incident behind it is one people talk themselves out of" ;; esac
  case "$rdm" in *"by NAME, never by path"*|*"by name, never by path"*) ok "B: states the name-not-path rule" ;;
    *) bad "B: states the name-not-path rule" "not stated" ;; esac
fi

echo "=== C: Tier 1 actually ships every skill the template demands ==="
# A template naming a skill that does not exist is worse than naming none: it reads as a
# working reference and resolves to nothing, which is the archived-repo failure again.
for r in $REQUIRED; do
  if [ -f "$T1/skills/$r/SKILL.md" ]; then ok "C: T1 ships $r"
  else bad "C: T1 ships $r" "the template demands a skill Tier 1 does not have"; fi
done

echo "=== D: real bindings, if any were named ==="
# Bindings live in the ESTATE layers, which are private and not present in a Tier-1 checkout.
# So this section is opt-in rather than skipped-with-a-pass: say plainly that it did not run.
CANDIDATES="${BINDINGS:-}"
while [ $# -gt 0 ]; do
  case "$1" in --binding) CANDIDATES="$CANDIDATES $2"; shift 2 ;; *) shift ;; esac
done
if [ -z "$CANDIDATES" ]; then
  echo "  n/a  no binding named — estate layers are private and absent from a T1 checkout."
  echo "       This suite pinned the TEMPLATE and Tier 1 above; it did NOT verify any real"
  echo "       binding. Run an estate's own CI with:  BINDINGS=bindings/*/SKILL.md bash \$0"
else
  for b in $CANDIDATES; do
    if [ ! -f "$b" ]; then bad "D: $b exists" "no such file"; continue; fi
    body="$(cat "$b")"
    label="$(basename "$(dirname "$b")")"
    for r in $REQUIRED; do
      case "$body" in *"$r"*) ok "D: $label invokes $r" ;;
        *) bad "D: $label invokes $r" "the binding never names it, so it never loads" ;; esac
    done
    # A path into another repo is the archived-link failure. Names resolve; paths rot.
    #
    # ⚠️ MATCH A LINK, NOT A MENTION — and this caught itself on its first run. The first
    # version grepped for the bare string and failed the OneDroid binding, whose only hit is
    # the sentence WARNING future readers not to link there. Flagging the warning as the bug
    # is the same defect `install.sh`'s placeholder check already fixed: "walk the JSON, do not
    # grep the file... the prose EXPLAINS the convention, so a text scan reports the
    # documentation as unfilled data -- a warning that is wrong on every correct file, which is
    # the fastest way to teach someone to skip reading warnings."
    #
    # So: only a markdown link TARGET counts — `](...Dark-Factory-Process...)`. Prose may name
    # the archived repo freely, which is exactly what a binding should do to warn the next
    # person.
    if printf '%s' "$body" | grep -qE '\]\([^)]*Dark-Factory-Process'; then
      bad "D: $label has no LINK into the archived repo" "Dark-Factory-Process was archived 2026-08-06; that link resolves to nothing"
    else
      ok "D: $label has no LINK into the archived repo (prose mentions are fine, and are a good warning)"
    fi
  done
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
