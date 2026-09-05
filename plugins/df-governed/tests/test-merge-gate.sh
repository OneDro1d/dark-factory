#!/usr/bin/env bash
# test-merge-gate.sh — covers BOTH halves of the merge-gate feature:
#
#   PART A  boot-kit/scripts/publish-gate.sh's additive record writer: a CLEAN run against
#           the real landmarks.conf writes <git-common-dir>/publish-gate.ok; anything else
#           (placeholder conf, FINDINGS) deletes any record that was there.
#   PART B  plugins/df-governed/hooks/merge-gate.py: refuses `gh pr merge` / `gh api
#           .../pulls/<n>/merge` unless that record exists, is real, is clean, and matches
#           the PR's head sha.
#
# DESIGN CHOICE for Part A: run the REAL boot-kit/scripts/publish-gate.sh, copied into a
# scratch git repo, exactly the way test-publish-gate-empty-exclusions.sh already does for
# the same script (mk_repo / write_conf / run_gate). Extracting the record-writer into a
# separately-sourceable function was the other option offered in the ticket; this file does
# NOT do that, because a sourceable copy could pass while the shipped tail (the exit-code
# threading the ticket's additive change relies on) silently diverges from it. Running the
# real script means these assertions can only pass against what actually ships.
#
# Style follows boot-kit/scripts/tests/test-identify.sh: ok()/bad() counters, one assertion
# per behaviour, exit non-zero on any failure.
#
# Part B runs against SCRATCH git repos under $TMPDIR, with a stub `gh` on PATH so no
# network call and no real GitHub state is involved. The stub only answers `gh pr view`
# (the one call merge-gate.py makes); anything else it refuses loudly so a test that
# accidentally depends on an unstubbed call fails clearly instead of hanging.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SELF/../hooks/merge-gate.py"
GATE_SRC="$SELF/../../../boot-kit/scripts/publish-gate.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output: $3" ;; esac; }
not_contains() { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output: $3" ;; *) ok "$1" ;; esac; }
equals()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2' got '$3'"; fi; }

[ -f "$HOOK" ] || { echo "FAIL  merge-gate.py does not exist at $HOOK"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mergegate.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ── a stub `gh` on PATH ─────────────────────────────────────────────────────────────
# Only `gh pr view <n> --repo <r> --json headRefOid -q .headRefOid` is stubbed -- that is
# the one call merge-gate.py makes. It answers with $STUB_HEAD_SHA (an env var, so each
# test case can pick its own value) and refuses everything else, loudly, so an accidental
# dependency on an unstubbed gh call fails visibly instead of hanging or silently passing.
GHDIR="$T/bin"
mkdir -p "$GHDIR"
cat > "$GHDIR/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '%s\n' "${STUB_HEAD_SHA:?STUB_HEAD_SHA not set}"
  exit 0
fi
echo "gh-stub: unstubbed invocation: $*" >&2
exit 1
EOF
chmod +x "$GHDIR/gh"
PATH="$GHDIR:$PATH"
export PATH

STUB_SHA="abc1234deadbeefabc1234deadbeefabc1234de"
export STUB_HEAD_SHA="$STUB_SHA"

# ── scratch repo builders ───────────────────────────────────────────────────────────
# The origin remote is a synthetic RFC-2606 `.example`-adjacent placeholder, never a real
# host or org -- this test file ships in a PUBLIC repo. See test-identify.sh's own note on
# the same discipline: realism here is the defect, not the goal.
ORIGIN_URL="https://example.com/test-owner/test-repo.git"
ORIGIN_REPO="test-owner/test-repo"

mk_repo() {  # mk_repo <with_gate:0|1>; prints the repo path
  local d with_gate="$1"
  d="$(mktemp -d "${TMPDIR:-/tmp}/mgrepo.XXXXXX")"
  git init -q -b main "$d" >/dev/null
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name test
  git -C "$d" remote add origin "$ORIGIN_URL"
  if [ "$with_gate" = "1" ]; then
    mkdir -p "$d/boot-kit/scripts"
    echo stub-gate > "$d/boot-kit/scripts/publish-gate.sh"
  fi
  echo x > "$d/f.txt"
  git -C "$d" add -A >/dev/null
  git -C "$d" commit -qm base >/dev/null
  printf '%s' "$d"
}

write_record() {  # write_record <repo> <commit> <dirty:true|false> <conf>
  local d="$1"
  printf '{"commit":"%s","dirty":%s,"conf":"%s","ts":"2026-09-05T00:00:00Z"}\n' \
    "$2" "$3" "$4" > "$d/.git/publish-gate.ok"
}

# ── per-user registry ────────────────────────────────────────────────────────────────
# A scratch directory, never the real ~/.claude/df-governed/publish-gate -- exported so
# every run_hook call below (and publish-gate.sh itself, in Part A) reads/writes here.
REG="$T/registry"
mkdir -p "$REG"
DF_PUBLISH_GATE_REGISTRY="$REG"
export DF_PUBLISH_GATE_REGISTRY

write_registry() {  # write_registry <owner/repo slug> <commit> <dirty:true|false> <conf>
  printf '{"commit":"%s","dirty":%s,"conf":"%s","ts":"2026-09-05T00:00:00Z"}\n' \
    "$2" "$3" "$4" > "$REG/${1//\//__}.json"
}

run_hook() {  # run_hook <cwd> <command> -- builds the event JSON with python (so paths and
  # commands need no manual shell/JSON escaping), pipes it to the hook, prints the hook's
  # stdout, and returns the hook's own exit code.
  python3 -c '
import json, subprocess, sys
cwd, cmd, hook = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.dumps({"hook_event_name": "PreToolUse", "cwd": cwd,
                       "tool_name": "Bash", "tool_input": {"command": cmd}})
p = subprocess.run([sys.executable, hook], input=payload, capture_output=True, text=True)
sys.stdout.write(p.stdout)
sys.stderr.write(p.stderr)
sys.exit(p.returncode)
' "$1" "$2" "$HOOK"
}

echo "=== A: the hook exists and answers a merge command with a well-formed decision ==="
# The exact probe from the ticket: a merge command against a repo/PR that cannot be
# verified (no matching local checkout, no registry entry) must still come back as a
# well-formed decision -- never a crash, never unparseable output.
#
# It is NOT a permissionDecision key specifically: x/y has no local checkout AND no
# registry entry, which used to be denied outright ("run the merge from inside the
# checkout") without the record ever being consulted -- the MEASURED DEFECT this ticket
# fixes. The correct answer now is an abstain-with-systemMessage (see test I), since a
# repo the hook has never heard of may simply not be gated at all.
O="$(printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"gh pr merge 1 --repo x/y"}}' "$T" | python3 "$HOOK")"; rc=$?
case "$O" in
  *permissionDecision*|*systemMessage*) ok "A: answers with a permissionDecision or a systemMessage" ;;
  *) bad "A: answers with a permissionDecision or a systemMessage" "neither key in output: $O" ;;
esac
equals   "A: always exits 0 (decision is in the JSON, not the exit code)" "0" "$rc"

echo "=== B: a non-merge Bash command is not this hook's business ==="
REPO_GATED="$(mk_repo 1)"
write_record "$REPO_GATED" "$STUB_SHA" false real
O="$(run_hook "$REPO_GATED" "ls -la")"
equals "B: a non-merge command allows with {}" "{}" "$O"

echo "=== C: a repo that does not ship a publish gate is not this hook's business ==="
REPO_NOGATE="$(mk_repo 0)"
O="$(run_hook "$REPO_NOGATE" "gh pr merge 1 --repo $ORIGIN_REPO")"
equals "C: repo without publish-gate.sh allows with {}" "{}" "$O"

echo "=== D: no record at all -- deny ==="
REPO_NOREC="$(mk_repo 1)"
O="$(run_hook "$REPO_NOREC" "gh pr merge 1 --repo $ORIGIN_REPO")"
contains "D: denies" "permissionDecision" "$O"
contains "D: reason names the missing record" "no record" "$O"

echo "=== E: a record with dirty:true -- deny ==="
REPO_DIRTY="$(mk_repo 1)"
write_record "$REPO_DIRTY" "$STUB_SHA" true real
O="$(run_hook "$REPO_DIRTY" "gh pr merge 1 --repo $ORIGIN_REPO")"
contains "E: denies" "permissionDecision" "$O"
contains "E: reason names the dirty tree" "dirty" "$O"

echo "=== F: a record whose conf is placeholder, not real -- deny ==="
REPO_PLACEHOLDER="$(mk_repo 1)"
write_record "$REPO_PLACEHOLDER" "$STUB_SHA" false placeholder
O="$(run_hook "$REPO_PLACEHOLDER" "gh pr merge 1 --repo $ORIGIN_REPO")"
contains "F: denies" "permissionDecision" "$O"
contains "F: reason names the placeholder conf" "placeholder conf" "$O"

echo "=== G: a record whose commit does not match the PR head -- deny, both shas shown ==="
REPO_MISMATCH="$(mk_repo 1)"
OTHER_SHA="1111111deadbeef1111111deadbeef11111111"
write_record "$REPO_MISMATCH" "$OTHER_SHA" false real
O="$(run_hook "$REPO_MISMATCH" "gh pr merge 1 --repo $ORIGIN_REPO")"
contains "G: denies" "permissionDecision" "$O"
contains "G: reason names the mismatch" "commit mismatch" "$O"
contains "G: shows the record's sha (7 chars)" "${OTHER_SHA:0:7}" "$O"
contains "G: shows the PR head's sha (7 chars)" "${STUB_SHA:0:7}" "$O"

echo "=== H: a record that matches -- allow ==="
REPO_MATCH="$(mk_repo 1)"
write_record "$REPO_MATCH" "$STUB_SHA" false real
O="$(run_hook "$REPO_MATCH" "gh pr merge 1 --repo $ORIGIN_REPO")"
equals "H: a matching record allows with {}" "{}" "$O"

echo "=== H2: the SAME record satisfies gh api .../pulls/<n>/merge too ==="
O="$(run_hook "$REPO_MATCH" "gh api -X PUT repos/$ORIGIN_REPO/pulls/1/merge")"
equals "H2: gh api merge form is recognised and allowed" "{}" "$O"

echo "=== W: F-MG1 -- wrapper spellings must be SEEN (measured bypass: env --chdir=<repo> gh pr merge) ==="
# Measured 2026-09-05 on a Linux instance during the interactive validation: the bare form was
# denied, `env --chdir=<tier1> gh pr merge 999999` reached GitHub. Detection keyed on tokens[0]
# being `gh`; a wrapper puts gh anywhere else. Every spelling below carries the mismatching
# record from case G and must be DENIED with the mismatch reason -- {} would mean unseen.
REPO_W="$(mk_repo 1)"
write_record "$REPO_W" "$OTHER_SHA" false real
for CMD in \
  "env --chdir=$REPO_W gh pr merge 1" \
  "env -C $REPO_W gh pr merge 1" \
  "nice -n 5 gh pr merge 1 --repo $ORIGIN_REPO" \
  "timeout 60 gh pr merge 1 -R $ORIGIN_REPO" \
  "/usr/local/bin/gh pr merge 1 --repo $ORIGIN_REPO" \
  "bash -c 'gh pr merge 1 --repo $ORIGIN_REPO'" \
  "bash -lc 'cd $REPO_W && gh pr merge 1'" \
  "eval 'gh pr merge 1 --repo $ORIGIN_REPO'" \
  "cd $REPO_W && gh pr merge 1" \
  "env FOO=bar gh api -X PUT repos/$ORIGIN_REPO/pulls/1/merge"; do
  O="$(run_hook "$REPO_W" "$CMD")"
  contains "W: seen and denied: $CMD" "commit mismatch" "$O"
done
echo "=== W2: wrapped NON-merges stay {} ==="
O="$(run_hook "$T" "env --chdir=$REPO_W gh pr view 1")"
equals "W2: env-wrapped gh pr view is not a merge" "{}" "$O"
O="$(run_hook "$T" "nice gh pr list --repo $ORIGIN_REPO")"
equals "W2: nice-wrapped gh pr list is not a merge" "{}" "$O"

echo "=== I: cwd not inside any checkout, no registry entry -- abstain, not deny ==="
# MEASURED DEFECT this covers: cwd outside the checkout used to be an automatic deny
# ("run the merge from inside the checkout"), and the registry/checkout record was never
# even consulted. Now cwd being elsewhere is not itself a reason to deny -- with nothing
# recorded anywhere for this repo, the hook cannot tell "never gated" from "gated, never
# run here", so it abstains and says so, rather than assuming either way.
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/mgoutside.XXXXXX")"
O="$(run_hook "$OUTSIDE" "gh pr merge 1 --repo $ORIGIN_REPO")"
contains     "I: surfaces a systemMessage" "systemMessage" "$O"
not_contains "I: does not deny merely for being outside the checkout" "permissionDecision" "$O"
contains     "I: names the target repo it found no record for" "$ORIGIN_REPO" "$O"

echo "=== I2: registry entry matches the PR head, cwd OUTSIDE the checkout -- allow ==="
write_registry "$ORIGIN_REPO" "$STUB_SHA" false real
O="$(run_hook "$OUTSIDE" "gh pr merge 1 --repo $ORIGIN_REPO")"
equals "I2: a matching registry entry allows with {} even though cwd is outside" "{}" "$O"

echo "=== I3: registry entry's commit mismatches the PR head, cwd OUTSIDE -- deny, both shas ==="
OTHER_SHA2="2222222deadbeef2222222deadbeef22222222"
write_registry "$ORIGIN_REPO" "$OTHER_SHA2" false real
O="$(run_hook "$OUTSIDE" "gh pr merge 1 --repo $ORIGIN_REPO")"
contains "I3: denies" "permissionDecision" "$O"
contains "I3: reason names the mismatch" "commit mismatch" "$O"
contains "I3: shows the registry's sha (7 chars)" "${OTHER_SHA2:0:7}" "$O"
contains "I3: shows the PR head's sha (7 chars)" "${STUB_SHA:0:7}" "$O"

echo "=== I4: registry entry is dirty, cwd OUTSIDE the checkout -- deny ==="
write_registry "$ORIGIN_REPO" "$STUB_SHA" true real
O="$(run_hook "$OUTSIDE" "gh pr merge 1 --repo $ORIGIN_REPO")"
contains "I4: denies" "permissionDecision" "$O"
contains "I4: reason names the dirty tree" "dirty" "$O"
rm -f "$REG/${ORIGIN_REPO//\//__}.json"

echo "=== J: malformed stdin -- deny, internal error, never a crash ==="
O="$(printf 'not json at all' | python3 "$HOOK")"; rc=$?
contains "J: denies" "permissionDecision" "$O"
contains "J: reason says internal error" "internal error" "$O"
equals   "J: still exits 0" "0" "$rc"

echo ""
echo "########################################################################"
echo "# PART A -- boot-kit/scripts/publish-gate.sh's additive record writer"
echo "########################################################################"

[ -f "$GATE_SRC" ] || { echo "FAIL  publish-gate.sh does not exist at $GATE_SRC"; FAIL=$((FAIL+1)); }

# A scratch repo carrying only the gate script and one content file. No landmarks config is
# written here -- each case below writes exactly the config(s) it needs, so it is explicit
# from the test which branch (real vs. placeholder) is under exercise.
mk_gate_repo() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/gaterec.XXXXXX")"
  git init -q -b main "$d" >/dev/null
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name test
  mkdir -p "$d/boot-kit/scripts" "$d/docs"
  cp "$GATE_SRC" "$d/boot-kit/scripts/publish-gate.sh"
  echo clean > "$d/docs/f.md"
  git -C "$d" add -A >/dev/null
  git -C "$d" commit -qm base >/dev/null
  printf '%s' "$d"
}

# Nonsense patterns, matching nothing in the scratch tree by construction (same technique
# as test-publish-gate-empty-exclusions.sh's conf_body) -- what is under test is the RECORD,
# not the scan.
gate_conf_body() {
  cat <<'CONF'
P1_PATTERN='zzqxalfa'
P2_PATTERN='zzqxbravo'
P3_PATTERN='zzqxcharlie'
P4_PATTERN='zzqxdelta'
P5_PATTERN='zzqxfoxtrot'
P6_PATTERN='zzqxgolf'
P7_PATTERN='zzqxhotel'
CONF
}

RECORD_TIMESTAMP='{"commit":"deadbeef","dirty":false,"conf":"real","ts":"stale"}'

echo "=== A1: CLEAN + real landmarks.conf -- writes a record matching HEAD, not dirty ==="
D="$(mk_gate_repo)"
gate_conf_body > "$D/boot-kit/scripts/landmarks.conf"
git -C "$D" add -A >/dev/null
git -C "$D" commit -qm "add real landmarks" >/dev/null
HEAD_A1="$(git -C "$D" rev-parse HEAD)"
OUT="$(cd "$D" && bash boot-kit/scripts/publish-gate.sh 2>&1)"; RC=$?
equals   "A1: gate itself still exits 0 on CLEAN" "0" "$RC"
contains "A1: result line unchanged" "RESULT: CLEAN" "$OUT"
if [ -f "$D/.git/publish-gate.ok" ]; then
  ok "A1: publish-gate.ok was written"
  equals "A1: record.commit is HEAD"  "$HEAD_A1" "$(jq -r .commit "$D/.git/publish-gate.ok")"
  equals "A1: record.dirty is false"  "false"    "$(jq -r .dirty  "$D/.git/publish-gate.ok")"
  equals "A1: record.conf is real"    "real"     "$(jq -r .conf   "$D/.git/publish-gate.ok")"
else
  bad "A1: publish-gate.ok was written" "no record file at $D/.git/publish-gate.ok"
fi

echo "=== A2: CLEAN but PLACEHOLDER conf -- no record, and a stale one is deleted ==="
D="$(mk_gate_repo)"
gate_conf_body > "$D/boot-kit/scripts/landmarks.example.conf"
git -C "$D" add -A >/dev/null
git -C "$D" commit -qm "add placeholder landmarks" >/dev/null
printf '%s' "$RECORD_TIMESTAMP" > "$D/.git/publish-gate.ok"
OUT="$(cd "$D" && bash boot-kit/scripts/publish-gate.sh 2>&1)"; RC=$?
equals   "A2: gate itself still exits 0 on CLEAN" "0" "$RC"
contains "A2: first line names the placeholder file" "landmarks.example.conf" "$OUT"
contains "A2: result line unchanged" "RESULT: CLEAN" "$OUT"
if [ -f "$D/.git/publish-gate.ok" ]; then
  bad "A2: no record is written on a placeholder-conf run" "publish-gate.ok still exists"
else
  ok "A2: no record is written on a placeholder-conf run (stale one deleted)"
fi

echo "=== A3: FINDINGS (real conf, planted canary) -- exit 1 unchanged, stale record deleted ==="
D="$(mk_gate_repo)"
gate_conf_body > "$D/boot-kit/scripts/landmarks.conf"
echo 'zzqxalfa in a sentence' > "$D/docs/canary.md"
git -C "$D" add -A >/dev/null
git -C "$D" commit -qm "add real landmarks + canary" >/dev/null
printf '%s' "$RECORD_TIMESTAMP" > "$D/.git/publish-gate.ok"
OUT="$(cd "$D" && bash boot-kit/scripts/publish-gate.sh 2>&1)"; RC=$?
equals   "A3: gate itself still exits 1 on FINDINGS (exit code unchanged)" "1" "$RC"
contains "A3: result line unchanged" "RESULT: FINDINGS" "$OUT"
if [ -f "$D/.git/publish-gate.ok" ]; then
  bad "A3: a stale record is deleted on FINDINGS" "publish-gate.ok still exists"
else
  ok "A3: a stale record is deleted on FINDINGS"
fi

echo "=== A4: CLEAN + real conf + a DIRTY tree -- record is written with dirty:true ==="
D="$(mk_gate_repo)"
gate_conf_body > "$D/boot-kit/scripts/landmarks.conf"
git -C "$D" add -A >/dev/null
git -C "$D" commit -qm "add real landmarks" >/dev/null
HEAD_A4="$(git -C "$D" rev-parse HEAD)"
echo 'more clean content' >> "$D/docs/f.md"   # uncommitted -- tree is now dirty
OUT="$(cd "$D" && bash boot-kit/scripts/publish-gate.sh 2>&1)"; RC=$?
equals   "A4: gate itself still exits 0 on CLEAN" "0" "$RC"
contains "A4: result line unchanged" "RESULT: CLEAN" "$OUT"
if [ -f "$D/.git/publish-gate.ok" ]; then
  ok "A4: publish-gate.ok was written despite the dirty tree"
  equals "A4: record.commit is still HEAD (the dirty change is uncommitted)" "$HEAD_A4" "$(jq -r .commit "$D/.git/publish-gate.ok")"
  equals "A4: record.dirty is true"                                          "true"    "$(jq -r .dirty  "$D/.git/publish-gate.ok")"
else
  bad "A4: publish-gate.ok was written despite the dirty tree" "no record file"
fi

echo "=== A5: CLEAN + real conf + a real-shaped origin -- writes the registry; FINDINGS deletes it ==="
# DF_PUBLISH_GATE_REGISTRY points at ITS OWN scratch dir here, separate from $REG above --
# proving the override works standalone, not just because $REG happens to be exported for
# the whole file.
D="$(mk_gate_repo)"
gate_conf_body > "$D/boot-kit/scripts/landmarks.conf"
git -C "$D" remote add origin "https://example.com/reg-owner/reg-repo.git"
git -C "$D" add -A >/dev/null
git -C "$D" commit -qm "add real landmarks + origin" >/dev/null
HEAD_A5="$(git -C "$D" rev-parse HEAD)"
REGDIR_A5="$T/a5-registry"
REGFILE_A5="$REGDIR_A5/reg-owner__reg-repo.json"
OUT="$(cd "$D" && DF_PUBLISH_GATE_REGISTRY="$REGDIR_A5" bash boot-kit/scripts/publish-gate.sh 2>&1)"; RC=$?
equals "A5: gate itself still exits 0 on CLEAN" "0" "$RC"
if [ -f "$REGFILE_A5" ]; then
  ok "A5: registry file was written"
  equals "A5: registry record.commit is HEAD" "$HEAD_A5" "$(jq -r .commit "$REGFILE_A5")"
  equals "A5: registry record.dirty is false" "false"    "$(jq -r .dirty  "$REGFILE_A5")"
  equals "A5: registry record.conf is real"   "real"     "$(jq -r .conf   "$REGFILE_A5")"
  # The two records are additive copies of the SAME run -- they must agree, not merely
  # both exist.
  equals "A5: registry record matches the git-common-dir record" \
    "$(jq -Sc . "$D/.git/publish-gate.ok")" "$(jq -Sc . "$REGFILE_A5")"
else
  bad "A5: registry file was written" "no file at $REGFILE_A5"
fi

echo 'zzqxalfa in a sentence' > "$D/docs/canary2.md"
git -C "$D" add -A >/dev/null
git -C "$D" commit -qm "add canary" >/dev/null
OUT="$(cd "$D" && DF_PUBLISH_GATE_REGISTRY="$REGDIR_A5" bash boot-kit/scripts/publish-gate.sh 2>&1)"; RC=$?
equals "A5: gate itself exits 1 on FINDINGS" "1" "$RC"
if [ -f "$REGFILE_A5" ]; then
  bad "A5: registry file is deleted on FINDINGS" "$REGFILE_A5 still exists"
else
  ok "A5: registry file is deleted on FINDINGS (git-common-dir record deleted too, per A3)"
fi

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
