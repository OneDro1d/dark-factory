#!/usr/bin/env bash
# test-p8-reachability.sh — prove P8 tells PUBLISHED from PENDING from LOCAL-ONLY.
#
# P8 used to scan `git rev-list --all` and call the result "history". That set is every
# commit in THIS CLONE, not what the world can fetch, so a stale local branch — reviewed,
# merged upstream, its remote ref long since pruned — read as a published leak. The gate
# then prescribed "rebuild from a fresh git init": an irreversible remedy for a condition
# that does not exist upstream. A gate that fires on something the maintainer cannot fix
# is one people learn to override, and that is how the next real finding gets waved through.
#
# Splitting one fatal class into three is only safe if each class is proven to fire on its
# own input, so this plants a committed canary in each reachability class and asserts the
# verdict. It runs entirely in a SCRATCH repo under $TMPDIR: a test that proved P8 by
# committing a landmark into the real repo would create the exact condition P8 exists to
# detect, and no later scan could undo it.
#
# Usage: bash boot-kit/scripts/tests/test-p8-reachability.sh
# Exit:  0 = all four cases behave   1 = at least one does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
GATE_SRC="$SCRIPTS/publish-gate.sh"

# The canary comes from the SAME local config as the patterns, never hardcoded here —
# hardcoding a real landmark in a committed test would publish the very noun the patterns
# exist to hide. (gate-selftest.sh's first version did exactly that.)
LANDMARKS="$SCRIPTS/landmarks.conf"
LANDMARKS_SRC=landmarks.conf
[ -f "$LANDMARKS" ] || { LANDMARKS="$SCRIPTS/landmarks.example.conf"; LANDMARKS_SRC=landmarks.example.conf; }
[ -f "$LANDMARKS" ] || { echo "no landmark config found"; exit 2; }
# shellcheck source=/dev/null
. "$LANDMARKS"
CANARY_TEXT="${P1_CANARY:-}"
[ -n "$CANARY_TEXT" ] || { echo "P1_CANARY unset in $LANDMARKS — cannot prove P8 fires"; exit 2; }

FAIL=0
# A tally, distinct from the FAIL flag: the contract needs how many classes were
# actually probed, and the "4/4" in the summary below is a literal, not a measurement.
CHECKS=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/p8test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Build a repo whose ONLY landmark sits in the class named by $1, with a bare "remote"
# so refs/remotes/* is populated exactly the way a real clone's is.
#   published   the canary commit is on the branch that was pushed
#   pending     pushed a clean commit, then committed the canary on top (unpushed)
#   local-only  the canary lives on a side branch; HEAD and the remote are clean
#   no-remote   same as local-only but the remote is never added at all
build() {
  local kind="$1" d="$WORK/$kind" bare="$WORK/$kind.git"
  rm -rf "$d" "$bare"; mkdir -p "$d"
  git init -q -b main "$d"
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name  test
  mkdir -p "$d/boot-kit/scripts"
  cp "$GATE_SRC" "$d/boot-kit/scripts/publish-gate.sh"
  cp "$LANDMARKS" "$d/boot-kit/scripts/$LANDMARKS_SRC"
  echo clean > "$d/docs.md"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm base

  case "$kind" in
    published)
      printf '%s\n' "$CANARY_TEXT" > "$d/leak.md"
      git -C "$d" add -A >/dev/null; git -C "$d" commit -qm leak
      git -C "$d" rm -q leak.md >/dev/null; git -C "$d" commit -qm "remove leak"
      ;;
    pending)
      printf '%s\n' "$CANARY_TEXT" > "$d/leak.md"
      ;;
    local-only|no-remote)
      git -C "$d" checkout -qb side
      printf '%s\n' "$CANARY_TEXT" > "$d/leak.md"
      git -C "$d" add -A >/dev/null; git -C "$d" commit -qm leak
      git -C "$d" checkout -q main
      ;;
  esac

  if [ "$kind" != "no-remote" ]; then
    git init -q --bare "$bare"
    git -C "$d" remote add origin "$bare"
    # `pending` must push BEFORE the canary is committed, so the canary is HEAD-only.
    git -C "$d" push -q origin main
    git -C "$d" fetch -q origin
  fi

  # `pending`'s canary is committed only after the push, so it is reachable from HEAD
  # and from no remote ref — which is the whole point of the class.
  if [ "$kind" = "pending" ]; then
    git -C "$d" add -A >/dev/null; git -C "$d" commit -qm leak
  fi
  printf '%s\n' "$d"
}

check() {  # check <kind> <expected-p8-verdict-regex> <expected-overall>
  local kind="$1" want="$2" want_result="$3" d out p8 result
  d="$(build "$kind")"
  out="$(bash "$d/boot-kit/scripts/publish-gate.sh" --history 2>&1)"
  p8="$(printf '%s\n' "$out" | grep -E '^(PASS|FAIL|WARN) +P8 ' | head -3 | tr '\n' ';')"
  result="$(printf '%s\n' "$out" | grep -E '^=== RESULT:' || true)"
  if printf '%s' "$p8" | grep -qE "$want" && printf '%s' "$result" | grep -q "$want_result"; then
    CHECKS=$((CHECKS + 1))
    printf 'ok    %-11s %s\n' "$kind" "$p8"
  else
    printf 'FAIL  %-11s got: %s | %s\n' "$kind" "$p8" "$result"
    FAIL=1
  fi
}

echo "=== P8 reachability classes (landmarks: $LANDMARKS_SRC) ==="
echo ""
# A landmark already fetchable by anyone: fatal, and honestly unfixable by patching.
check published  'FAIL +P8 landmark is ALREADY PUBLISHED'        'FINDINGS'
# On HEAD but never pushed: still fatal — the next push publishes it — but fixable here.
check pending    'FAIL +P8 landmark is on HEAD and NOT yet'      'FINDINGS'
# In this clone and nowhere else: a fact about the working copy, not a publish blocker.
check local-only 'WARN +P8 landmark in LOCAL-ONLY'               'CLEAN'
# No remote-tracking refs means published-vs-local is UNKNOWN, and an unknown must never
# be recorded as an ok — so this falls back to scanning everything and failing hard.
check no-remote  'FAIL +P8 landmark found in git HISTORY'        'FINDINGS'

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "=== P8 REACHABILITY TEST PASSED — 4/4 classes behave ==="
else
  echo "=== P8 REACHABILITY TEST FAILED — do NOT trust P8's verdict ==="
fi

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $CHECKS"
exit "$FAIL"
