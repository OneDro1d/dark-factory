#!/usr/bin/env bash
# test-df-operator-todo.sh — the operator's single page of owed work.
# Style follows test-mission-tick.sh: PASS/FAIL counters, ok/bad/contains/absent helpers,
# mktemp fixtures, non-zero exit on failure.
#
# ⚠️ THE REFUSAL PATHS ARE THE POINT OF THIS SUITE, not an afterthought. This tool's whole
# value is that a task cannot silently leave the operator's queue while still undone, and the
# only mechanism enforcing that is `done` refusing without evidence. A suite that exercised
# only the happy path would go green over a tool that closes anything you name.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$SELF/.." && pwd)"
SCRIPT="$PLUGIN/bin/df-operator-todo"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/optodo.XXXXXX")"
trap 'rm -rf "$T"' EXIT
F="$T/operator-todo.md"

echo "=== A: executable and self-describing ==="
[ -x "$SCRIPT" ] && ok "A: bin/df-operator-todo is executable" || bad "A: executable" "not +x"
OUT="$("$SCRIPT" --help 2>&1)"; contains "A: --help mentions the file" "operator-todo" "$OUT"

echo "=== B: add records an async item by default ==="
OUT="$("$SCRIPT" --file "$F" add --id b1 --category credential --task "Rotate the key" --why "a credential only you hold" --step "Open a terminal and run the command below" --do "gh auth refresh" 2>&1)"
contains "B: says async" "async" "$OUT"
OUT="$(cat "$F")"
contains "B: task text present" "Rotate the key" "$OUT"
contains "B: why present" "a credential only you hold" "$OUT"
contains "B: do present" "gh auth refresh" "$OUT"
contains "B: lands under the async heading" "Async — the loop continues" "$OUT"

echo "=== C: --blocking lands in the blocking section ==="
"$SCRIPT" --file "$F" add --id c1 --category decision --task "Decide the tier" --why "a decision you have not made" --do "reply T1 or T2" --option "T1: every org gets it" --option "T2: only this estate gets it" --recommend "T1, because it is generic" --blocking >/dev/null 2>&1
OUT="$(sed -n '/Blocking/,/## Async/p' "$F")"
contains "C: blocking item under the blocking heading" "Decide the tier" "$OUT"
absent   "C: async item NOT under blocking" "Rotate the key" "$OUT"

echo "=== D: re-adding an id UPDATES in place and MOVES section — never duplicates ==="
"$SCRIPT" --file "$F" add --id b1 --category credential --task "Rotate the key" --why "still yours" --step "Open a terminal and run the command below" --do "gh auth refresh" --blocking >/dev/null 2>&1
N="$(grep -c '`b1`' "$F")"
eq "D: exactly one entry for the id" "$N" "1"
OUT="$(sed -n '/Blocking/,/## Async/p' "$F")"
contains "D: moved into blocking" "Rotate the key" "$OUT"

echo "=== E: done WITHOUT evidence REFUSES (rc=2) and removes nothing ==="
OUT="$("$SCRIPT" --file "$F" done --id c1 2>&1)"; rc=$?
eq "E: rc is 2" "$rc" "2"
contains "E: says it is refusing" "refusing to close" "$OUT"
contains "E: names the hazard" "while still undone" "$OUT"
contains "E: the item survived the refusal" "Decide the tier" "$(cat "$F")"

echo "=== F: done --by-operator removes it, and leaves NO history in the file ==="
OUT="$("$SCRIPT" --file "$F" done --id c1 --by-operator 2>&1)"; rc=$?
eq "F: rc is 0" "$rc" "0"
absent "F: entry gone from the file" "Decide the tier" "$(cat "$F")"
# ⚠️ This assertion first read `absent ... "Done"` and FAILED — on the file's own header, which
# contains the sentence "never moved to a 'Done' section". The bare word was never the thing
# being tested; a grown section is a HEADING and a survived item is a STRIKETHROUGH. Matching
# the loosest possible string is how a test reports a defect that is not there, and the fix is
# to assert the real shape rather than to weaken the check.
absent "F: no Done section heading grew" "## Done" "$(cat "$F")"
absent "F: nothing struck through" "~~" "$(cat "$F")"
contains "F: tells the reader where history IS" "History is in git" "$OUT"

echo "=== G: done --verified <evidence> also removes ==="
"$SCRIPT" --file "$F" add --id g1 --category irreversible --task "Merge PR 7" --why "a merge you are blocked from" --step "Open https://github.com/o/r/pull/7 and click Merge" --do "gh pr merge 7" >/dev/null 2>&1
OUT="$("$SCRIPT" --file "$F" done --id g1 --verified "gh pr view 7 --json state -> MERGED" 2>&1)"; rc=$?
eq "G: rc is 0" "$rc" "0"
contains "G: echoes the evidence" "MERGED" "$OUT"
absent "G: entry removed" "Merge PR 7" "$(cat "$F")"

echo "=== H: done on an unknown id reports and does not rewrite (rc=1) ==="
BEFORE="$(cat "$F")"
OUT="$("$SCRIPT" --file "$F" done --id nosuch --by-operator 2>&1)"; rc=$?
eq "H: rc is 1" "$rc" "1"
contains "H: names the missing id" "nosuch" "$OUT"
eq "H: file byte-identical" "$(cat "$F")" "$BEFORE"

echo "=== I: an empty queue says so rather than printing nothing ==="
"$SCRIPT" --file "$F" done --id b1 --by-operator >/dev/null 2>&1
OUT="$("$SCRIPT" --file "$F" list 2>&1)"
contains "I: empty queue is stated" "empty" "$OUT"
contains "I: file still says nothing blocking" "Nothing blocking" "$(cat "$F")"

echo "=== J: --blocking-only filters ==="
"$SCRIPT" --file "$F" add --id j1 --category decision --task "async thing" --why "a decision" --do "x" --option "A: one way" --option "B: the other" --recommend "A" >/dev/null 2>&1
"$SCRIPT" --file "$F" add --id j2 --category decision --task "blocking thing" --why "a decision" --do "y" --option "A: one way" --option "B: the other" --recommend "A" --blocking >/dev/null 2>&1
OUT="$("$SCRIPT" --file "$F" list --blocking-only 2>&1)"
contains "J: blocking shown" "blocking thing" "$OUT"
absent   "J: async hidden" "async thing" "$OUT"

echo "=== K: with no notepad above cwd it REFUSES rather than writing somewhere arbitrary ==="
ND="$T/nowhere"; mkdir -p "$ND"
OUT="$(cd "$ND" && DF_NOTEPAD="$ND" "$SCRIPT" list 2>&1)"; rc=$?
eq "K: rc is 2" "$rc" "2"
contains "K: explains the notepad marker" "NOTES.md" "$OUT"

echo "=== L: resolves to the notepad root, not cwd, from a subdirectory ==="
NP="$T/np"; mkdir -p "$NP/deep/deeper"; : > "$NP/NOTES.md"
# ⚠️ Compare against the PHYSICAL path. On macOS mktemp hands back /var/... which is a symlink
# to /private/var/..., and the tool resolves through it via getcwd(). The first version of this
# assertion compared the logical path and failed on a correct tool — a test asserting the
# platform's symlink layout rather than the behaviour under test.
NP_REAL="$(cd "$NP" && pwd -P)"
OUT="$(cd "$NP/deep/deeper" && "$SCRIPT" path 2>&1)"
eq "L: path is <notepad>/operator-todo.md" "$OUT" "$NP_REAL/operator-todo.md"

echo
echo "== N: --category is the admission test (operator ruling 2026-09-09)"
# The file already DELETED finished items; nothing stopped a NON-ACTION being admitted at all.
# The set is closed on purpose: it is the same list work-autonomously uses for what stays the
# operator's, so an item fitting none of them is one the agent should have done itself.
FN="$T/cat.md"
OUT="$("$SCRIPT" --file "$FN" add --id n1 --task "FYI the box was slow" --why "thought you'd like to know" --do "nothing" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "N1 add without --category is refused" \
  || bad "N1 add without --category is refused" "rc=$RC: $OUT"
[ ! -f "$FN" ] && ok "N1 and nothing was written" || bad "N1 and nothing was written" "file exists"
OUT="$("$SCRIPT" --file "$FN" add --id n2 --category fyi --task "x" --why "y" --do "z" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "N2 an invented category is refused" \
  || bad "N2 an invented category is refused" "rc=$RC: $OUT"
case "$OUT" in
  *credential*decision*|*decision*credential*) ok "N2 the refusal lists the closed set" ;;
  *) bad "N2 the refusal lists the closed set" "$OUT" ;;
esac
"$SCRIPT" --file "$FN" add --id n3 --category credential --task "Sign in on the box" \
  --why "an interactive login only you can complete" --step "Run claude and follow the sign-in link" --do "run claude and sign in" >/dev/null 2>&1
BODY="$(cat "$FN")"
case "$BODY" in
  *"_yours because:_ **credential**"*) ok "N3 the category is rendered on the line, auditable at a glance" ;;
  *) bad "N3 the category is rendered on the line" "$BODY" ;;
esac
case "$BODY" in
  *"EVERY LINE HERE IS AN ACTION WAITING ON YOU"*) ok "N4 the header states the admission rule" ;;
  *) bad "N4 the header states the admission rule" "no rule line in header" ;;
esac


echo "== O: init creates the empty page when absent, and never touches an existing one"
# Operator ruling 2026-09-10: every Dark Factory notepad keeps this page. Measured that day:
# nothing created it except the first `add`, so a mission that raised nothing had no page and
# a reader could not tell "nothing is waiting on you" from "this estate never set one up".
FO="$T/init-np"; mkdir -p "$FO"; : > "$FO/NOTES.md"
OUT="$("$SCRIPT" --file "$FO/operator-todo.md" init 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "O1 init exits 0" || bad "O1 init exits 0" "rc=$RC: $OUT"
contains "O1 it says it created the page" "created" "$OUT"
BODY="$(cat "$FO/operator-todo.md" 2>/dev/null)"
contains "O2 the page carries the admission rule" "EVERY LINE HERE IS AN ACTION WAITING ON YOU" "$BODY"
contains "O2 and states the queue is empty" "Nothing blocking" "$BODY"
"$SCRIPT" --file "$FO/operator-todo.md" add --id o3 --category decision --task "keep me" --why "w" --do "d" --option "A: a" --option "B: b" --recommend "A" >/dev/null 2>&1
BEFORE="$(cat "$FO/operator-todo.md")"
OUT="$("$SCRIPT" --file "$FO/operator-todo.md" init 2>&1)"
contains "O3 a second init says already present" "already present" "$OUT"
eq "O3 and leaves an existing page byte-identical" "$(cat "$FO/operator-todo.md")" "$BEFORE"

echo "== P: a DECISION carries its options, what each one means, and a recommendation"
# Operator ruling 2026-09-22: "When decisions are needed, the ask should be in plain English, with
# options, implications, consequences of each choice and recommendation." A decision without them
# hands the operator the analysis as well as the choice.
FP="$T/dec.md"
OUT="$("$SCRIPT" --file "$FP" add --id p1 --category decision --task "Pick one" --why "w" --do "say A or B" 2>&1)"; RC=$?
eq "P1 a decision with no options is refused (rc 2)" "$RC" "2"
contains "P1 the refusal says what is missing" "--option" "$OUT"
[ ! -f "$FP" ] && ok "P1 and nothing was written" || bad "P1 nothing written" "file exists"
OUT="$("$SCRIPT" --file "$FP" add --id p2 --category decision --task "Pick one" --why "w" --do "say A or B" --option "A: x" --recommend "A" 2>&1)"; RC=$?
eq "P2 ONE option is not a choice (rc 2)" "$RC" "2"
OUT="$("$SCRIPT" --file "$FP" add --id p3 --category decision --task "Pick one" --why "w" --do "say A or B" --option "A: x" --option "B: y" 2>&1)"; RC=$?
eq "P3 options without a recommendation are refused (rc 2)" "$RC" "2"
"$SCRIPT" --file "$FP" add --id p4 --category decision --task "Keep the gate on the laptop?" \
  --why "a risk only you can accept" --do "say A or B" \
  --option "A — copy the list here: I can gate and merge alone; the list now lives on two machines" \
  --option "B — leave it: every merge waits for the laptop" \
  --recommend "A, because merges stop waiting on a second machine" >/dev/null 2>&1
BODY="$(cat "$FP")"
contains "P4 option A is on the page" "copy the list here" "$BODY"
contains "P4 option B is on the page" "every merge waits for the laptop" "$BODY"
contains "P4 the recommendation is labelled" "**Recommendation:** A, because" "$BODY"
OUT="$("$SCRIPT" --file "$FP" list 2>&1)"
contains "P5 list round-trips the options" "every merge waits for the laptop" "$OUT"
"$SCRIPT" --file "$FP" add --id p6 --category credential --task "other" --why "w" --step "s" --do "d" >/dev/null 2>&1
contains "P6 a later add keeps the decision's option lines" "copy the list here" "$(cat "$FP")"

echo "== Q: an item is an ask, not an essay — every field has a cap"
FQ="$T/cap.md"
LONG="$(printf 'x%.0s' $(seq 1 900))"
OUT="$("$SCRIPT" --file "$FQ" add --id q1 --category credential --task "t" --why "w" --step "s" --do "$LONG" 2>&1)"; RC=$?
eq "Q1 an over-long --do is refused (rc 2)" "$RC" "2"
contains "Q1 and it names the field" "--do" "$OUT"
[ ! -f "$FQ" ] && ok "Q1 nothing was written" || bad "Q1 nothing written" "file exists"

echo "== R: re-adding keeps the FIRST raised date — no dated trail of rewrites"
FR="$T/raised.md"
printf '# Operator TODO\n\n## ⛔ Blocking — the loop is stopped until you do these\n\n_Nothing blocking. The loop is not waiting on you._\n\n## Async — the loop continues without these\n\n- [ ] `r1` — **old** · _yours because:_ **credential** — w · _do:_ d · _raised 2026-01-02_\n' > "$FR"
"$SCRIPT" --file "$FR" add --id r1 --category credential --task "new wording" --why "w" --step "s" --do "d" >/dev/null 2>&1
BODY="$(cat "$FR")"
contains "R1 the original date survives" "_raised 2026-01-02_" "$BODY"
N="$(grep -o '_raised [0-9-]*_' "$FR" | grep -c .)"
eq "R1 and there is exactly one date" "$N" "1"

echo "== S: lint — only OPEN items, no narration, no history"
FS="$T/lint.md"
"$SCRIPT" --file "$FS" add --id s0 --category credential --task "Sign in" --why "only you can" --step "Run: claude auth login" --do "claude auth login" >/dev/null 2>&1
OUT="$("$SCRIPT" --file "$FS" lint 2>&1)"; RC=$?
eq "S0 a page written by the tool is clean (rc 0)" "$RC" "0"
cp "$FS" "$FS.bak"
printf '\nSome narration a session appended about what it did.\n' >> "$FS"
OUT="$("$SCRIPT" --file "$FS" lint 2>&1)"; RC=$?
eq "S1 stray text outside an item fails (rc 1)" "$RC" "1"
contains "S1 and says it is outside any item" "outside any item" "$OUT"
cp "$FS.bak" "$FS"
printf -- '- [x] `s2` — **finished thing** · _yours because:_ **approval** — w · _do:_ d\n' >> "$FS"
OUT="$("$SCRIPT" --file "$FS" lint 2>&1)"; RC=$?
eq "S2 a ticked item fails (rc 1)" "$RC" "1"
contains "S2 and says closed items are deleted" "closed" "$OUT"
cp "$FS.bak" "$FS"
sed -i.x 's/_do:_ claude auth login/_do:_ claude auth login ✅ RE-CHECKED 2026-09-18, still true/' "$FS"
OUT="$("$SCRIPT" --file "$FS" lint 2>&1)"; RC=$?
eq "S3 a history trail inside an item fails (rc 1)" "$RC" "1"
contains "S3 and names the item" "s0" "$OUT"
cp "$FS.bak" "$FS"
printf -- '- [ ] `s4` — **Pick** · _yours because:_ **decision** — w · _do:_ say A or B · _raised 2026-09-22_\n' >> "$FS"
OUT="$("$SCRIPT" --file "$FS" lint 2>&1)"; RC=$?
eq "S4 a hand-written decision with no options fails (rc 1)" "$RC" "1"
contains "S4 and says what a decision needs" "options" "$OUT"
cp "$FS.bak" "$FS"
BIG="$(printf 'y%.0s' $(seq 1 1600))"
printf -- '- [ ] `s5` — **%s** · _yours because:_ **access** — w · _do:_ d\n' "$BIG" >> "$FS"
OUT="$("$SCRIPT" --file "$FS" lint 2>&1)"; RC=$?
eq "S5 an over-long item fails (rc 1)" "$RC" "1"
# ⛔ CONTROL, run against a case that MUST hit: a real pre-ruling page, full of re-check trails.
FC="$T/control.md"
cat > "$FC" <<'CTRL'
# Operator TODO

## ⛔ Blocking — the loop is stopped until you do these

- [ ] `merge-all-scope` — **two PRs** · _yours because:_ x · _do:_ y
  ✅ **#212, #213, #214 and #215 ARE MERGED** — the clause that used to sit here is gone. · _raised 2026-09-20, extended same day, stack closed 2026-09-21_

## Async — the loop continues without these

_Nothing queued._
CTRL
OUT="$("$SCRIPT" --file "$FC" lint 2>&1)"; RC=$?
eq "S6 CONTROL: a real pre-ruling page fails lint" "$RC" "1"

echo "== U: an operator ACTION carries step-by-step instructions (operator ruling 2026-09-22)"
# "If I need to create a github token, I want to see a brief step by step instruction: click
# here, run this command, etc." A --do sentence says WHAT; the steps say HOW.
FU="$T/steps.md"
OUT="$("$SCRIPT" --file "$FU" add --id u1 --category credential --task "Create a GitHub token" --why "only you can" --do "make a token" 2>&1)"; RC=$?
eq "U1 an action with no --step is refused (rc 2)" "$RC" "2"
contains "U1 the refusal asks for the steps" "--step" "$OUT"
[ ! -f "$FU" ] && ok "U1 and nothing was written" || bad "U1 nothing written" "file exists"
"$SCRIPT" --file "$FU" add --id u2 --category credential --task "Create a GitHub token for the gate" --why "only you can" \
  --step "Open https://github.com/settings/tokens?type=beta and click Generate new token" \
  --step "Name it publish-gate, repository access: only OneDro1d/dark-factory, permission Commit statuses: read and write" \
  --step "Click Generate, then run: gh auth login --with-token and paste it" >/dev/null 2>&1
BODY="$(cat "$FU")"
contains "U2 step 1 is numbered on the page" "  1. Open https://github.com/settings/tokens" "$BODY"
contains "U2 step 3 is numbered on the page" "  3. Click Generate" "$BODY"
OUT="$("$SCRIPT" --file "$FU" lint 2>&1)"; RC=$?
eq "U3 an action with steps lints clean" "$RC" "0"
"$SCRIPT" --file "$FU" add --id u4 --category approval --task "other" --why "w" --step "Say 'go'" >/dev/null 2>&1
contains "U4 a later add keeps the earlier item's steps" "  2. Name it publish-gate" "$(cat "$FU")"
printf -- '- [ ] `u5` — **Hand-written** · _yours because:_ **access** — w · _do:_ do the thing · _raised 2026-09-22_\n' >> "$FU"
OUT="$("$SCRIPT" --file "$FU" lint 2>&1)"; RC=$?
eq "U5 a hand-written action with no steps fails lint (rc 1)" "$RC" "1"
contains "U5 and names what is missing" "numbered steps" "$OUT"

echo "== T: a missing page lints as MISSING, never as clean"
OUT="$("$SCRIPT" --file "$T/absent.md" lint 2>&1)"; RC=$?
eq "T1 rc is 2 on a missing page" "$RC" "2"

printf 'passed %s  failed %s\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
