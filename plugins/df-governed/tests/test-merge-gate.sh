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

echo "=== A: the hook exists and answers a merge command with a permission decision ==="
# The exact probe from the ticket: a merge command against a repo/PR that cannot be
# verified (no matching local checkout) must still come back as a well-formed decision.
O="$(printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"gh pr merge 1 --repo x/y"}}' "$T" | python3 "$HOOK")"; rc=$?
contains "A: answers with a permissionDecision key" "permissionDecision" "$O"
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

echo "=== I: cwd not inside a matching checkout -- deny ==="
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/mgoutside.XXXXXX")"
O="$(run_hook "$OUTSIDE" "gh pr merge 1 --repo $ORIGIN_REPO")"
contains "I: denies" "permissionDecision" "$O"
contains "I: reason says run it from inside the checkout" "checkout" "$O"

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

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
