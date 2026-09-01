#!/usr/bin/env bash
# test-preflight-self-curation.sh — a repo that is not cloned here must be curatable.
#
# WHY THIS EXISTS. A kit ships a repos.manifest.json naming the repos its ESTATE drives. A
# fresh machine has cloned none of them. So on a first install every one of those repos was
# drift, the supervisor refused to start on drift, and the kit's own worked example — the one
# step that proves the loop — was unreachable. Four outside installers, 24-27 Aug 2026: 4/4
# reached RESULT LOCKED, 3/4 could not start a mission. Two of them independently reached the
# same repair by hand, curate the manifest to your own lane, which is what made it the
# shipped default (operator decision 2026-09-01).
#
# The "not on this machine" finding previously carried NO proposal, so nothing could act on
# it — the operator's only options were to edit a committed file or stay blocked.
#
# ⚠️ THE VERDICT DELIBERATELY STAYS `drift`, AND THAT IS ASSERTED HERE. Zero worktrees found
# is a probe that RAN and returned a positive answer about the world. `unknown` is for a probe
# that could not run. Relabelling would also make it unappliable, because apply_report refuses
# unknown findings on principle — so the honest verdict and the useful one coincide. A future
# change that "helpfully" softens this to unknown breaks curation, and case A fails.
#
# ⚠️ THE APPEND OP IS THE POINT OF CASE C. scope.excludedRepos is a LIST. The pre-existing
# writer did `node[last] = value`, so confirming "exclude B" would have overwritten the list
# that already excluded A — the second curation silently un-curating the first, on a path
# whose entire purpose is to accumulate.
#
# Usage: bash boot-kit/scripts/tests/test-preflight-self-curation.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
PF="${DF_PREFLIGHT:-$SCRIPTS/df-preflight.py}"
[ -f "$PF" ] || { echo "missing $PF"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }
command -v git >/dev/null || { echo "git required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NOTEPAD="$TMP/notepad"; CODE="$TMP/code"
mkdir -p "$NOTEPAD" "$CODE"
jq -n '{repos:[{name:"ghost-repo", remote:"example-org/ghost-repo", branch:"main"}]}' \
  > "$NOTEPAD/repos.manifest.json"
LOCK="$TMP/loom.lock.json"
jq -n --arg cr "$CODE" '{codeRoot:$cr, codeLayout:{}, upstreams:{}, probed:{repos:{}}}' > "$LOCK"

report() { # -> $TMP/pf.json
  ( cd "$NOTEPAD" && LOOM_LOCK="$LOCK" python3 "$PF" --report --json "$TMP/pf.json" \
      >"$TMP/pf.txt" 2>&1 )
  return 0
}

echo "=== A: an uncloned repo is drift, and carries a curation proposal ==="
report
v="$(jq -r '.findings[]|select(.check=="repo" and .target=="ghost-repo")|.verdict' "$TMP/pf.json")"
[ "$v" = "drift" ] && ok "A: verdict is drift (a probe that ran, not one that could not)" \
                   || bad "A: verdict is drift" "got '$v'"
p="$(jq -r '.findings[]|select(.target=="ghost-repo")|.proposal.path // "none"' "$TMP/pf.json")"
[ "$p" = "scope.excludedRepos" ] && ok "A: proposes scope.excludedRepos" \
                                 || bad "A: proposes scope.excludedRepos" "got '$p'"
o="$(jq -r '.findings[]|select(.target=="ghost-repo")|.proposal.op // "none"' "$TMP/pf.json")"
[ "$o" = "append" ] && ok "A: the op is append, not assign" || bad "A: op is append" "got '$o'"
grep -q 'curate it out of scope' "$TMP/pf.txt" \
  && ok "A: the text tells the reader what to do" || bad "A: actionable text" "not present"

echo "=== B: --apply curates it, and the next run goes quiet ==="
jq '(.findings[]|select(.target=="ghost-repo")).confirmed = true' "$TMP/pf.json" > "$TMP/c.json"
LOOM_LOCK="$LOCK" python3 "$PF" --apply "$TMP/c.json" >"$TMP/apply.txt" 2>&1
got="$(jq -r '.scope.excludedRepos // [] | join(",")' "$LOCK")"
[ "$got" = "ghost-repo" ] && ok "B: lockfile now excludes it" || bad "B: lockfile excludes it" "got '$got'"
report
v2="$(jq -r '.findings[]|select(.check=="repo" and .target=="ghost-repo")|.verdict' "$TMP/pf.json")"
[ "$v2" = "ok" ] && ok "B: the repo row is now ok" || bad "B: row is ok after curation" "got '$v2'"
d2="$(jq -r '.summary.drift' "$TMP/pf.json")"
[ "$d2" = "0" ] && ok "B: drift is now zero — a first install can be quiet" \
                || bad "B: drift is zero" "got '$d2'"

echo "=== C: a second curation must not erase the first ==="
jq '.repos += [{name:"second-ghost", remote:"example-org/second-ghost", branch:"main"}]' \
  "$NOTEPAD/repos.manifest.json" > "$TMP/m.json" && mv "$TMP/m.json" "$NOTEPAD/repos.manifest.json"
report
jq '(.findings[]|select(.target=="second-ghost")).confirmed = true' "$TMP/pf.json" > "$TMP/c2.json"
LOOM_LOCK="$LOCK" python3 "$PF" --apply "$TMP/c2.json" >>"$TMP/apply.txt" 2>&1
both="$(jq -r '.scope.excludedRepos // [] | sort | join(",")' "$LOCK")"
[ "$both" = "ghost-repo,second-ghost" ] \
  && ok "C: BOTH are excluded — append did not clobber" \
  || bad "C: both excluded" "got '$both' (an assign would leave only the newest)"

echo "=== D: applying the same curation twice is a no-op, not a duplicate ==="
LOOM_LOCK="$LOCK" python3 "$PF" --apply "$TMP/c2.json" >"$TMP/apply2.txt" 2>&1
again="$(jq -r '.scope.excludedRepos // [] | sort | join(",")' "$LOCK")"
[ "$again" = "ghost-repo,second-ghost" ] && ok "D: no duplicate entry" \
                                        || bad "D: no duplicate entry" "got '$again'"
grep -q 'already present' "$TMP/apply2.txt" && ok "D: and it says so" \
                                            || bad "D: says already present" "silent"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
