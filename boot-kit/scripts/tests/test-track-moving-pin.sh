#!/usr/bin/env bash
# test-track-moving-pin.sh — an upstream may declare `track`: follow a moving ref, install what
# it resolves to, and REWRITE the record's own commit so the pin never stops existing.
#
# ⛔ WHAT IT PROTECTS. The whole tier model rests on a record naming exactly what is on a
# machine. "Always install latest" would throw that away: two machines installing on different
# days would differ with nothing able to say how. So `track` does not make the pin optional --
# it automates MOVING it, and writes the resolved sha back. Everything downstream (lock-verify
# L3's pin match, L6's reachability, a validate report naming a version) keeps working unchanged
# because it still reads a real 40-char sha.
#
# Real local remotes, no network: a bare repo with a branch and a movable tag.
#
# Usage: bash boot-kit/scripts/tests/test-track-moving-pin.sh
# Exit:  0 every case behaves · 1 at least one does not · 2 the harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
RH="${REHYDRATE:-$SCRIPTS/rehydrate.sh}"
[ -f "$RH" ] || { echo "missing $RH"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
GIT="$(command -v git)" || { echo "git required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# Normalised: a trailing-slash or symlinked TMPDIR otherwise compares a path the script printed
# against one the harness built. Same trap as test-df-start.sh.
T="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/track.XXXXXX")" && pwd)"
trap 'rm -rf "$T"' EXIT
GC=(-c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main)

# ── a real upstream: three commits on main, with `stable` parked on the FIRST ────────────────
UP="$T/upstream"; "$GIT" "${GC[@]}" init -q "$UP"
mk() { printf '%s\n' "$1" > "$UP/f"; "$GIT" "${GC[@]}" -C "$UP" add -A; "$GIT" "${GC[@]}" -C "$UP" commit -q -m "$1"; "$GIT" -C "$UP" rev-parse HEAD; }
C1="$(mk one)"; C2="$(mk two)"; C3="$(mk three)"
"$GIT" "${GC[@]}" -C "$UP" tag -f stable "$C1" >/dev/null 2>&1
BARE="$T/origin.git"; "$GIT" clone -q --bare "$UP" "$BARE"

inst() {  # inst <dir> <pinned-commit> [track]
  local d="$T/$1"; mkdir -p "$d"
  "$GIT" clone -q "$BARE" "$d/vendor/layer" 2>/dev/null
  # Build the record, THEN add track with a second jq call. Splicing the track clause into the
  # expression string left the braces unbalanced and every jq call failed — which reads as 19
  # broken assertions rather than one broken fixture.
  jq -n --arg c "$2" '{vendorDir:"vendor",
                       upstreams:{layer:{repo:"acme/layer",commit:$c}},
                       install:{skills:[],skillSources:{},hooks:[],hookSources:{}},
                       plugins:[]}' > "$d/loom.lock.json"
  if [ -n "${3:-}" ]; then
    jq --arg t "$3" '.upstreams.layer.track = $t' "$d/loom.lock.json" > "$d/.tmp" \
      && mv "$d/.tmp" "$d/loom.lock.json"
  fi
  : > "$d/install.sh"
}
run() { ( cd "$T/$1" && shift; env -u LOOM_LOCK -u LOOM_FROZEN LOOM_LIVE="$T/live" LOOM_BIN="$T/bin" \
            bash "$RH" "$@" 2>&1 ); }
pin() { jq -r '.upstreams.layer.commit' "$T/$1/loom.lock.json"; }
head_() { "$GIT" -C "$T/$1/vendor/layer" rev-parse HEAD; }

echo "== A) no track: today's behaviour, byte for byte"
inst a "$C1"
OUT="$(run a)"
check "A the record is untouched" '[ "$(pin a)" = "$C1" ]' "$(pin a)"
check "A the tree sits at the pin" '[ "$(head_ a)" = "$C1" ]'
check "A no track line for the upstream" '! printf "%s" "$OUT" | grep -qE "(track|frozen|would  resolve)  *layer"'

echo "== B) track a TAG: resolves, installs it, and rewrites the record"
inst b "$C3" stable
OUT="$(run b)"
check "B the record now names the tag's commit" '[ "$(pin b)" = "$C1" ]' "$(pin b) wanted $C1"
check "B the tree sits at the tag's commit" '[ "$(head_ b)" = "$C1" ]'
check "B the move is REPORTED, both shas" 'printf "%s" "$OUT" | grep -q "track  layer .stable.: ${C3:0:8} -> ${C1:0:8}"' "$OUT"
check "B it says the record was rewritten" 'printf "%s" "$OUT" | grep -q "rewritten"'
check "B the record still names a REAL 40-char sha" '[ "$(pin b | wc -c | tr -d " ")" = 41 ]'

echo "== C) the tag MOVES: a second run follows it"
"$GIT" "${GC[@]}" -C "$UP" tag -f stable "$C2" >/dev/null 2>&1
"$GIT" -C "$UP" push -q --force --tags "$BARE" 2>/dev/null
OUT="$(run b)"
check "C the record follows the tag" '[ "$(pin b)" = "$C2" ]' "$(pin b) wanted $C2"
check "C the tree follows too" '[ "$(head_ b)" = "$C2" ]'

echo "== D) unchanged is SAID, not silent — and nothing is rewritten"
OUT="$(run b)"
check "D reports unchanged" 'printf "%s" "$OUT" | grep -q "(unchanged)"' "$OUT"
check "D does not claim a rewrite" '! printf "%s" "$OUT" | grep -q "rewritten"'
check "D the record is stable at the same sha" '[ "$(pin b)" = "$C2" ]'

echo "== E) track a BRANCH head"
inst e "$C1" main
OUT="$(run e)"
check "E follows the branch to its head" '[ "$(pin e)" = "$C3" ]' "$(pin e) wanted $C3"

echo "== F) --frozen ignores track entirely: this is how a machine is REPRODUCED"
inst f "$C3" stable
OUT="$(run f --frozen)"
check "F the record is NOT rewritten" '[ "$(pin f)" = "$C3" ]' "$(pin f)"
check "F the recorded pin is what got installed" '[ "$(head_ f)" = "$C3" ]'
check "F it says the track was ignored" 'printf "%s" "$OUT" | grep -q "frozen layer tracks .stable. — ignored"' "$OUT"
inst f2 "$C3" stable
OUT="$(LOOM_FROZEN=1 bash -c "cd '$T/f2' && env -u LOOM_LOCK LOOM_LIVE='$T/live' LOOM_BIN='$T/bin' bash '$RH' 2>&1")"
check "F LOOM_FROZEN=1 does the same" '[ "$(pin f2)" = "$C3" ]' "$(pin f2)"

echo "== G) a track that resolves to NOTHING must not silently install a stale pin"
inst g "$C3" no-such-ref
OUT="$(run g)"
check "G warns, naming the ref" 'printf "%s" "$OUT" | grep -q "tracks .no-such-ref. — no such tag or branch"' "$OUT"
check "G the record is left alone" '[ "$(pin g)" = "$C3" ]'
check "G the recorded pin is still installed" '[ "$(head_ g)" = "$C3" ]'

echo "== H) --dry-run changes nothing, and says what it would do"
inst h "$C3" stable
OUT="$(run h --dry-run)"
check "H the record is untouched" '[ "$(pin h)" = "$C3" ]' "$(pin h)"
check "H it says it would resolve and rewrite" 'printf "%s" "$OUT" | grep -q "would  resolve layer .stable."' "$OUT"

echo "== I) --offline never reaches the network, so track cannot move a pin"
inst i "$C3" stable
OUT="$(run i --offline)"
check "I the record is untouched" '[ "$(pin i)" = "$C3" ]' "$(pin i)"
check "I no track line at all" '! printf "%s" "$OUT" | grep -q "track  layer"'

echo
printf 'track moving pin: %d ok, %d failed\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
