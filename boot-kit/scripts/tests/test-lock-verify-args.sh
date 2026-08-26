#!/usr/bin/env bash
# test-lock-verify-args.sh — lock-verify must NAME the lockfile it was asked for, or refuse.
#
# WHY THIS EXISTS. `lock-verify.sh` parsed its arguments with a single positional line:
#
#     [ "${1:-}" = "--lock" ] && LOCK="${2:?--lock needs a path}"
#
# Only `$1`, only the space form, and no else-branch. Every other spelling was DROPPED —
# and dropping it was not an error. `--lock=instances/x/loom.lock.json` left LOCK at the
# root `loom.lock.json` and the script then PROCEEDED to print L1..L7 verdicts about a
# machine the operator had not asked about. That is worse than the sibling defect in
# `install.sh`: a wrong install is visible, a wrong PASS is the thing that stops the
# operator looking.
#
# The pairing was the hazard, because the estate's own docs teach both lines together:
#
#     bash install.sh      --lock=instances/{name}/loom.lock.json   # installs {name}
#     bash lock-verify.sh  --lock=instances/{name}/loom.lock.json   # verified the LAPTOP
#
# THE DECOY IS THE ASSERTION. Every case runs in a scratch tree that holds BOTH a root
# `loom.lock.json` and a target `instances/probe/loom.lock.json`, with DIFFERENT vendorDir
# values. So "it used the right lockfile" cannot be satisfied by the wrong one: the check
# is on the `lock   =` and `vendor =` header lines, never on the exit status. The overall
# verdict is deliberately not asserted — a scratch instance drifts on L3/L6 by design
# (nothing vendored), and a suite that keyed on exit 0 would be measuring that instead.
#
# ONE SPELLING IS NOT THE FLAG. The prior round proved `--lock` "is read rather than
# ignored" by passing a bogus path in the SPACE form and getting FATAL. True — of that
# spelling. Both forms are exercised here, separately, and so is the unknown-flag case.
#
# Usage: bash boot-kit/scripts/tests/test-lock-verify-args.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
LV="${LOCK_VERIFY:-$SCRIPTS/lock-verify.sh}"
[ -f "$LV" ] || { echo "missing $LV"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output" ;; *) ok "$1" ;; esac; }
eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lvargs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# The scratch tree. The two lockfiles differ ONLY in vendorDir, which is what makes
# the `vendor =` line a second, independent witness to which file was actually read.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/vendor-root" "$WORK/instances/probe/vendor-probe"
printf '%s\n' '{"vendorDir":"vendor-root","upstreams":{},"install":{"skills":[],"hooks":[]}}' \
  > "$WORK/loom.lock.json"
printf '%s\n' '{"vendorDir":"vendor-probe","upstreams":{},"install":{"skills":[],"hooks":[]}}' \
  > "$WORK/instances/probe/loom.lock.json"

TARGET="instances/probe/loom.lock.json"
BOGUS="instances/PROOF-NOT-REAL/loom.lock.json"

# run <args...> -> sets OUT (stdout+stderr) and RC. Always from $WORK, never the repo.
run() { OUT="$( cd "$WORK" && bash "$LV" "$@" 2>&1 )"; RC=$?; }

echo "=== controls — a broken harness must not read as a clean result ==="

# C1  the decoy is real and distinguishable. If these two ever became identical the
#     whole suite would pass vacuously.
C_ROOT="$(jq -r .vendorDir "$WORK/loom.lock.json")"
C_TGT="$(jq -r .vendorDir "$WORK/$TARGET")"
if [ "$C_ROOT" != "$C_TGT" ]; then ok "C1 decoy and target are distinguishable"
else bad "C1 decoy and target are distinguishable" "both vendorDir = $C_ROOT"; fi

# C2  the script under test parses at all.
if bash -n "$LV" 2>/dev/null; then ok "C2 lock-verify.sh parses"
else bad "C2 lock-verify.sh parses" "bash -n failed"; fi

# C3  the harness can observe a REFUSAL. Without this, every "it refused" below could be
#     the runner failing to run anything.
run --lock "$BOGUS"
contains "C3 harness can see a refusal (space form, bogus path)" "no lockfile at $BOGUS" "$OUT"

echo "=== assertions ==="

# A1  the = form must SELECT the named lockfile. This is the defect.
run "--lock=$TARGET"
contains "A1 --lock=PATH selects PATH"          "lock   = $TARGET" "$OUT"
absent   "A1b --lock=PATH does not fall back"   "lock   = loom.lock.json" "$OUT"
contains "A1c --lock=PATH derives PATH's vendor" "vendor-probe" "$OUT"

# A2  the space form must KEEP working. Both install.sh callers use it
#     (loom-storage:508, loom_storage-ESO:274); breaking it to fix A1 would trade a
#     hand-invocation hazard for an automated-path outage.
run --lock "$TARGET"
contains "A2 --lock PATH still selects PATH"    "lock   = $TARGET" "$OUT"
contains "A2b --lock PATH derives PATH's vendor" "vendor-probe" "$OUT"

# A3  an unrecognised flag is an ERROR, not a no-op. Silently ignoring it is how the
#     wrong-machine PASS was produced.
run --lcok=typo
eq       "A3 unknown flag exits 2" "2" "$RC"
contains "A3b unknown flag names itself" "--lcok=typo" "$OUT"
absent   "A3c unknown flag does not verify anything" "[L1]" "$OUT"

# A4  arguments AFTER the first are inspected too. The old line only ever read $1/$2,
#     so a trailing flag was invisible even when the leading pair was well-formed.
run --lock "$TARGET" --bogus
eq       "A4 trailing unknown flag exits 2" "2" "$RC"
contains "A4b trailing unknown flag names itself" "--bogus" "$OUT"

# A5  a bogus path in the = form must FATAL by NAME — not fall back and proceed.
run "--lock=$BOGUS"
contains "A5 --lock=BOGUS fatals on BOGUS" "no lockfile at $BOGUS" "$OUT"
absent   "A5b --lock=BOGUS does not verify the root" "[L1]" "$OUT"

# A6  bare invocation still means "the lockfile at the repo root". Documented behaviour;
#     the fix must not make the common case require a flag.
run
contains "A6 bare invocation uses the root lockfile" "lock   = loom.lock.json" "$OUT"
contains "A6b bare invocation derives the root vendor" "vendor-root" "$OUT"

# A7  --lock with no value is an error, not an empty path.
run --lock
if [ "$RC" -ne 0 ]; then ok "A7 --lock with no value is rejected"
else bad "A7 --lock with no value is rejected" "exit 0"; fi
absent "A7b --lock with no value does not verify anything" "[L1]" "$OUT"

# A8  `--lock=` with an EMPTY value is an error, not a request to verify "". Without a
#     guard the prefix strip yields "" and the FATAL line reads "no lockfile at " — a
#     message that names nothing and reads like a missing file rather than a bad argument.
run "--lock="
eq     "A8 --lock= with no value exits 2" "2" "$RC"
absent "A8b --lock= with no value does not verify anything" "[L1]" "$OUT"

echo ""
printf '%d passed, %d failed\n' "$PASS" "$FAIL"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
