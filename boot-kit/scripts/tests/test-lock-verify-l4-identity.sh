#!/usr/bin/env bash
# test-lock-verify-l4-identity.sh — L4 must not report "no identity needed" as drift.
#
# WHY THIS EXISTS. L4 wrapped its ENTIRE body in `command -v gh`:
#
#     if command -v gh >/dev/null 2>&1; then
#         ...compute which accounts the lock requires, check them...
#     else
#         drift "L4 gh not installed — cannot verify identities"
#     fi
#
# The set of REQUIRED accounts was computed inside the `if`, so a machine without `gh` was
# marked DRIFT before anything had asked whether an identity was needed at all. The public
# starter lockfile declares NO account. `gh` appears nowhere in START-HERE, and install.sh's
# own comments say the public method must install with git alone. So the public kit could
# not reach exit 0 with its own four documented prerequisites: installing `gh` and nothing
# else was the only thing between a correct install and success. Found cold, on a clean
# Debian container, first try — outside-installer feedback 24-27 Aug 2026, finding 03.
#
# ⚠️ THE SAME BUG WAS ALREADY FIXED ONE LEVEL IN. The `// empty` jq filter exists because an
# upstream with no `account` rendered as the string "null" and was checked as though it were
# an account by that name. Same failure — "no identity required" reported as a missing
# identity — at a different depth. Fixing the inner one and not the outer one is why a
# stranger found this instead of us, and it is why case A below asserts the ABSENCE of any
# gh consultation rather than merely a passing verdict.
#
# THE DECOY IS THE ASSERTION. Case C keeps a REAL missing identity in the same scratch tree
# and demands DRIFT for it. A fix that simply stopped reporting L4 problems would pass A and
# B and fail C. Cases assert on the L4 LINE, never on the overall exit status — a scratch
# instance drifts on L3/L6 by design (nothing is vendored) and a suite keyed on exit 0 would
# be measuring that instead.
#
# Usage: bash boot-kit/scripts/tests/test-lock-verify-l4-identity.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
LV="${LOCK_VERIFY:-$SCRIPTS/lock-verify.sh}"
[ -f "$LV" ] || { echo "missing $LV"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A PATH with every tool lock-verify needs EXCEPT gh. Symlinking rather than filtering the
# real PATH, so "gh is absent" is a property of the harness and not of the developer laptop
# that happens to run it.
NOGH="$TMP/nogh-bin"; mkdir -p "$NOGH"
for t in bash sh env jq git awk grep sed sort uniq cat printf readlink dirname basename \
         mktemp rm mkdir ls find head tail tr wc cut date python3 stat cmp diff; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOGH/$t"
done
command -v gh >/dev/null 2>&1 && HOST_HAS_GH=1 || HOST_HAS_GH=0
[ -x "$NOGH/jq" ] || { echo "harness could not stage jq"; exit 2; }
[ -e "$NOGH/gh" ] && { echo "harness leaked gh into the no-gh PATH"; exit 2; }

mklock() { # $1 = dir, $2 = jq-expression building .upstreams
  mkdir -p "$1"
  jq -n "$2" > "$1/loom.lock.json"
  # lock-verify walks up for install.sh to find the repo root; give it one.
  : > "$1/install.sh"
}

run_nogh() { PATH="$NOGH" "$NOGH/bash" "$LV" --lock "$1" 2>&1; }
run_hostpath() { bash "$LV" --lock "$1" 2>&1; }

echo "=== L4: no account declared, gh absent (the public kit) ==="
A="$TMP/a"
mklock "$A" '{vendorDir:"vendor",upstreams:{"dark-factory":{repo:"OneDro1d/dark-factory",commit:"0000000000000000000000000000000000000000"}}}'
outA="$(run_nogh "$A/loom.lock.json")"
contains "A: L4 passes with no gh" "L4 no upstream declares an account" "$outA"
absent   "A: L4 does not report drift" "DRIFT L4" "$outA"
absent   "A: gh install not demanded" "gh not installed" "$outA"

echo "=== L4: account declared, gh absent (unknown, NOT drift) ==="
B="$TMP/b"
mklock "$B" '{vendorDir:"vendor",upstreams:{"layer":{repo:"acme/layer",commit:"1111111111111111111111111111111111111111",account:"some-user"}}}'
outB="$(run_nogh "$B/loom.lock.json")"
contains "B: L4 is UNKNOWN"        "UNKNOWN L4" "$outB"
contains "B: says it is not drift" "unknown, not drift" "$outB"
contains "B: names the account"    "some-user" "$outB"
absent   "B: L4 does not report drift" "DRIFT L4" "$outB"

# ⚠️ KNOWN GAP, STATED RATHER THAN QUIETLY DROPPED. This suite does NOT cover the RESULT
# line's rendering of an unknown ("LOCKED (locally) — N check(s) UNKNOWN"). Reaching that
# branch needs DRIFT=0, and a scratch instance necessarily drifts on L3/L6 because nothing
# is vendored into it. An earlier draft of this file asserted that string here and failed —
# not because the code was wrong, but because the RESULT line correctly said DRIFT about
# L3/L6. Asserting it here would have measured the scratch tree, not the change.
# Covering it properly needs a fully-vendored fixture instance. Until that exists, the
# rendering is verified by reading, and this comment is the record that it is not tested.
echo "  gap  B: RESULT-line rendering of UNKNOWN is NOT covered (needs a clean fixture; see comment)"

echo "=== L4: account declared and gh present — a real gap must still be DRIFT ==="
if [ "$HOST_HAS_GH" -eq 1 ]; then
  C="$TMP/c"
  mklock "$C" '{vendorDir:"vendor",upstreams:{"layer":{repo:"acme/layer",commit:"2222222222222222222222222222222222222222",account:"definitely-not-a-logged-in-account-xyz"}}}'
  outC="$(run_hostpath "$C/loom.lock.json")"
  contains "C: missing identity still drifts" "DRIFT L4 not logged in as" "$outC"
  contains "C: names the missing account" "definitely-not-a-logged-in-account-xyz" "$outC"
else
  echo "  skip C: gh not installed on this host, cannot exercise the present-gh path"
  echo "  (this is the UNKNOWN case the change is about — the suite refuses to call it a pass)"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
# run-tests.sh requires this line and calls a suite without one UNMEASURED — a suite that
# exits 0 having asserted nothing is indistinguishable from one that ran. It caught this
# file on its first run, which is the runner doing exactly its job.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
