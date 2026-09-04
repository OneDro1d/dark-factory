#!/usr/bin/env bash
# test-validate-ships.sh — the post-install validation must REACH the machine, and say to RUN things.
#
# Enrolled by GLOB, per tests/README.md — "a suite is enrolled by existing".
#
# ⚠️ WHAT IT PROTECTS. VALIDATE-INSTALL.md exists because every check that looks for a FILE passes
# on a broken install: a hook command that does not exist FAILS OPEN, and a hook wired nowhere is
# inert. Both are invisible to a presence check.
#
# ⛔ AND A VALIDATION GUIDE THAT NOTHING POINTS AT IS THE SAME DEFECT ONE LEVEL UP — present,
# correct, reached by nobody. So this suite asserts the JOIN, not the file: bootstrap copies it
# into the minted instance, and install.sh names it at the end. That is the same class of gap as
# `kits/` being unreachable from an install until 2026-09-04.
#
# ⚠️ It also asserts the document still tells people to EXERCISE things. A validation prompt that
# decays into a file checklist is worse than none: it would pass on exactly the installs this
# method keeps shipping broken.
#
# Usage: bash boot-kit/scripts/tests/test-validate-ships.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF/../../.." && pwd)"
DOC="$ROOT/starter-kit/instance/VALIDATE-INSTALL.md"
BOOTSTRAP="$ROOT/starter-kit/instance/bootstrap.sh"
INSTALL="$ROOT/starter-kit/instance/install.sh"
for f in "$DOC" "$BOOTSTRAP" "$INSTALL"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
has() { grep -q "$2" "$1" 2>/dev/null; }
# ⚠️ PHRASES WRAP; grep is line-oriented. "feed it two different inputs" spans a line break in the
# document, so a line-by-line search reported the guide as decayed when it was not. Collapse all
# whitespace to single spaces before matching a PHRASE. A grep over wrapped prose tests the line
# breaks, not the content.
phrase() { tr '\n' ' ' < "$1" | tr -s '[:space:]' ' ' | grep -qF "$2"; }

echo "=== A: it reaches the machine ==="
if has "$BOOTSTRAP" 'VALIDATE-INSTALL.md'; then
  ok "A bootstrap copies it into the minted instance"
else
  bad "A bootstrap copies it" "it would exist only in the public repo, never on the machine"
fi
if has "$INSTALL" 'VALIDATE-INSTALL.md'; then
  ok "A install.sh names it"
else
  bad "A install.sh names it" "a validation guide nobody is told about is the defect it describes"
fi

echo "=== B: the installer says it even when the install FAILED ==="
# ⚠️ An install ending in drift is precisely when someone most needs telling that files-in-place
# is not working. A pointer suppressed on failure hides in the only case that matters.
if awk '/VALIDATE-INSTALL.md/{found=NR} /exit "\$RC"/{ if (found && NR>found) print "after" }' "$INSTALL" | grep -q after; then
  ok "B the pointer precedes the exit (not gated behind success)"
else
  bad "B the pointer precedes the exit" "it may be unreachable on a failing install"
fi

echo "=== C: it assumes nothing about layout ==="
# Paths differ per estate and per person; at least one kit here names its lockfile something other
# than loom.lock.json, and a sweep that globbed for that name missed it for three weeks.
if phrase "$DOC" 'walk up'; then ok "C it discovers the kit root rather than hardcoding one"; else bad "C it discovers the kit root" "no discovery step"; fi
if phrase "$DOC" 'not on PATH'; then ok "C it treats a missing operator CLI as possibly correct"; else bad "C missing CLI handled" "it would report a deliberate estate choice as a fault"; fi

echo "=== D: it EXERCISES rather than inventories ==="
# The whole point. Each of these is a task that runs something and reads the output.
for probe in 'disagree on purpose' 'two different inputs' 'NO MCP IN WORKER' '/clear'; do
  if phrase "$DOC" "$probe"; then
    ok "D covers: $probe"
  else
    bad "D covers: $probe" "the guide has decayed toward a file checklist"
  fi
done

echo "=== E: it keeps unknown separate from broken ==="
# ⚠️ Collapsing `unknown` into `drift` is how a failed probe becomes a recorded fact about the
# world — and an unprobed item promoted to PASS is the failure the whole document exists to stop.
if phrase "$DOC" 'UNKNOWN'; then ok "E UNKNOWN is a first-class verdict"; else bad "E UNKNOWN is a verdict" "only pass/fail — a failed probe would read as a result"; fi
if phrase "$DOC" 'must not be empty'; then ok "E it forces an explicit could-not-determine section"; else bad "E could-not-determine is forced" "silence would read as completeness"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
# ⚠️ REQUIRED BY run-tests.sh: a suite that exits 0 declaring no count is UNMEASURED, not PASS.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
