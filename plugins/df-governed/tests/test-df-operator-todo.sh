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
OUT="$("$SCRIPT" --file "$F" add --id b1 --category credential --task "Rotate the key" --why "a credential only you hold" --context "A throwaway item written by a test, so the page has something on it to check." --step "Open a terminal and run the command below" --do "gh auth refresh" 2>&1)"
contains "B: says async" "async" "$OUT"
OUT="$(cat "$F")"
contains "B: task text present" "Rotate the key" "$OUT"
contains "B: why present" "a credential only you hold" "$OUT"
contains "B: do present" "gh auth refresh" "$OUT"
contains "B: lands under the async heading" "Async — the loop continues" "$OUT"

echo "=== C: --blocking lands in the blocking section ==="
"$SCRIPT" --file "$F" add --id c1 --category decision --task "Decide the tier" --why "a decision you have not made" --context "A throwaway item written by a test, so the page has something on it to check." --do "reply T1 or T2" --option "T1: every org gets it" --option "T2: only this estate gets it" --recommend "T1, because it is generic" --blocking >/dev/null 2>&1
OUT="$(sed -n '/Blocking/,/## Async/p' "$F")"
contains "C: blocking item under the blocking heading" "Decide the tier" "$OUT"
absent   "C: async item NOT under blocking" "Rotate the key" "$OUT"

echo "=== D: re-adding an id UPDATES in place and MOVES section — never duplicates ==="
"$SCRIPT" --file "$F" add --id b1 --category credential --task "Rotate the key" --why "still yours" --context "A throwaway item written by a test, so the page has something on it to check." --step "Open a terminal and run the command below" --do "gh auth refresh" --blocking >/dev/null 2>&1
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
"$SCRIPT" --file "$F" add --id g1 --category irreversible --task "Merge PR 7" --why "a merge you are blocked from" --context "A throwaway item written by a test, so the page has something on it to check." --step "Open https://github.com/o/r/pull/7 and click Merge" --do "gh pr merge 7" >/dev/null 2>&1
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
"$SCRIPT" --file "$F" add --id j1 --category decision --task "async thing" --why "a decision" --context "A throwaway item written by a test, so the page has something on it to check." --do "x" --option "A: one way" --option "B: the other" --recommend "A" >/dev/null 2>&1
"$SCRIPT" --file "$F" add --id j2 --category decision --task "blocking thing" --why "a decision" --context "A throwaway item written by a test, so the page has something on it to check." --do "y" --option "A: one way" --option "B: the other" --recommend "A" --blocking >/dev/null 2>&1
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
OUT="$("$SCRIPT" --file "$FN" add --id n1 --task "FYI the box was slow" --why "thought you'd like to know" --context "A throwaway item written by a test, so the page has something on it to check." --do "nothing" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "N1 add without --category is refused" \
  || bad "N1 add without --category is refused" "rc=$RC: $OUT"
[ ! -f "$FN" ] && ok "N1 and nothing was written" || bad "N1 and nothing was written" "file exists"
OUT="$("$SCRIPT" --file "$FN" add --id n2 --category fyi --task "x" --why "y" --context "A throwaway item written by a test, so the page has something on it to check." --do "z" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "N2 an invented category is refused" \
  || bad "N2 an invented category is refused" "rc=$RC: $OUT"
case "$OUT" in
  *credential*decision*|*decision*credential*) ok "N2 the refusal lists the closed set" ;;
  *) bad "N2 the refusal lists the closed set" "$OUT" ;;
esac
"$SCRIPT" --file "$FN" add --id n3 --category credential --task "Sign in on the box" \
  --why "an interactive login only you can complete" --context "A throwaway item written by a test, so the page has something on it to check." --step "Run claude and follow the sign-in link" --do "run claude and sign in" >/dev/null 2>&1
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
"$SCRIPT" --file "$FO/operator-todo.md" add --id o3 --category decision --task "keep me" --why "w" --context "A throwaway item written by a test, so the page has something on it to check." --do "d" --option "A: a" --option "B: b" --recommend "A" >/dev/null 2>&1
BEFORE="$(cat "$FO/operator-todo.md")"
OUT="$("$SCRIPT" --file "$FO/operator-todo.md" init 2>&1)"
contains "O3 a second init says already present" "already present" "$OUT"
eq "O3 and leaves an existing page byte-identical" "$(cat "$FO/operator-todo.md")" "$BEFORE"

echo "== P: a DECISION carries its options, what each one means, and a recommendation"
# Operator ruling 2026-09-22: "When decisions are needed, the ask should be in plain English, with
# options, implications, consequences of each choice and recommendation." A decision without them
# hands the operator the analysis as well as the choice.
FP="$T/dec.md"
OUT="$("$SCRIPT" --file "$FP" add --id p1 --category decision --task "Pick one" --why "w" --context "A throwaway item written by a test, so the page has something on it to check." --do "say A or B" 2>&1)"; RC=$?
eq "P1 a decision with no options is refused (rc 2)" "$RC" "2"
contains "P1 the refusal says what is missing" "--option" "$OUT"
[ ! -f "$FP" ] && ok "P1 and nothing was written" || bad "P1 nothing written" "file exists"
OUT="$("$SCRIPT" --file "$FP" add --id p2 --category decision --task "Pick one" --why "w" --context "A throwaway item written by a test, so the page has something on it to check." --do "say A or B" --option "A: x" --recommend "A" 2>&1)"; RC=$?
eq "P2 ONE option is not a choice (rc 2)" "$RC" "2"
OUT="$("$SCRIPT" --file "$FP" add --id p3 --category decision --task "Pick one" --why "w" --context "A throwaway item written by a test, so the page has something on it to check." --do "say A or B" --option "A: x" --option "B: y" 2>&1)"; RC=$?
eq "P3 options without a recommendation are refused (rc 2)" "$RC" "2"
"$SCRIPT" --file "$FP" add --id p4 --category decision --task "Keep the gate on the laptop?" \
  --why "a risk only you can accept" --context "A throwaway item written by a test, so the page has something on it to check." --do "say A or B" \
  --option "A — copy the list here: I can gate and merge alone; the list now lives on two machines" \
  --option "B — leave it: every merge waits for the laptop" \
  --recommend "A, because merges stop waiting on a second machine" >/dev/null 2>&1
BODY="$(cat "$FP")"
contains "P4 option A is on the page" "copy the list here" "$BODY"
contains "P4 option B is on the page" "every merge waits for the laptop" "$BODY"
contains "P4 the recommendation is labelled" "**Recommendation:** A, because" "$BODY"
OUT="$("$SCRIPT" --file "$FP" list 2>&1)"
contains "P5 list round-trips the options" "every merge waits for the laptop" "$OUT"
"$SCRIPT" --file "$FP" add --id p6 --category credential --task "other" --why "w" --context "A throwaway item written by a test, so the page has something on it to check." --step "s" --do "d" >/dev/null 2>&1
contains "P6 a later add keeps the decision's option lines" "copy the list here" "$(cat "$FP")"

echo "== Q: an item is an ask, not an essay — every field has a cap"
FQ="$T/cap.md"
LONG="$(printf 'x%.0s' $(seq 1 900))"
OUT="$("$SCRIPT" --file "$FQ" add --id q1 --category credential --task "t" --why "w" --context "A throwaway item written by a test, so the page has something on it to check." --step "s" --do "$LONG" 2>&1)"; RC=$?
eq "Q1 an over-long --do is refused (rc 2)" "$RC" "2"
contains "Q1 and it names the field" "--do" "$OUT"
[ ! -f "$FQ" ] && ok "Q1 nothing was written" || bad "Q1 nothing written" "file exists"

echo "== R: re-adding keeps the FIRST raised date — no dated trail of rewrites"
FR="$T/raised.md"
printf '# Operator TODO\n\n## ⛔ Blocking — the loop is stopped until you do these\n\n_Nothing blocking. The loop is not waiting on you._\n\n## Async — the loop continues without these\n\n- [ ] `r1` — **old** · _yours because:_ **credential** — w · _do:_ d · _raised 2026-01-02_\n' > "$FR"
"$SCRIPT" --file "$FR" add --id r1 --category credential --task "new wording" --why "w" --context "A throwaway item written by a test, so the page has something on it to check." --step "s" --do "d" >/dev/null 2>&1
BODY="$(cat "$FR")"
contains "R1 the original date survives" "_raised 2026-01-02_" "$BODY"
N="$(grep -o '_raised [0-9-]*_' "$FR" | grep -c .)"
eq "R1 and there is exactly one date" "$N" "1"

echo "== S: lint — only OPEN items, no narration, no history"
FS="$T/lint.md"
"$SCRIPT" --file "$FS" add --id s0 --category credential --task "Sign in" --why "only you can" --context "A throwaway item written by a test, so the page has something on it to check." --step "Run: claude auth login" --do "claude auth login" >/dev/null 2>&1
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
OUT="$("$SCRIPT" --file "$FU" add --id u1 --category credential --task "Create a GitHub token" --why "only you can" --context "A throwaway item written by a test, so the page has something on it to check." --do "make a token" 2>&1)"; RC=$?
eq "U1 an action with no --step is refused (rc 2)" "$RC" "2"
contains "U1 the refusal asks for the steps" "--step" "$OUT"
[ ! -f "$FU" ] && ok "U1 and nothing was written" || bad "U1 nothing written" "file exists"
"$SCRIPT" --file "$FU" add --id u2 --category credential --task "Create a GitHub token for the gate" --why "only you can" --context "A throwaway item written by a test, so the page has something on it to check." \
  --step "Open https://github.com/settings/tokens?type=beta and click Generate new token" \
  --step "Name it publish-gate, repository access: only OneDro1d/dark-factory, permission Commit statuses: read and write" \
  --step "Click Generate, then run: gh auth login --with-token and paste it" >/dev/null 2>&1
BODY="$(cat "$FU")"
contains "U2 step 1 is numbered on the page" "  1. Open https://github.com/settings/tokens" "$BODY"
contains "U2 step 3 is numbered on the page" "  3. Click Generate" "$BODY"
OUT="$("$SCRIPT" --file "$FU" lint 2>&1)"; RC=$?
eq "U3 an action with steps lints clean" "$RC" "0"
"$SCRIPT" --file "$FU" add --id u4 --category approval --task "other" --why "w" --context "A throwaway item written by a test, so the page has something on it to check." --step "Say 'go'" >/dev/null 2>&1
contains "U4 a later add keeps the earlier item's steps" "  2. Name it publish-gate" "$(cat "$FU")"
printf -- '- [ ] `u5` — **Hand-written** · _yours because:_ **access** — w · _do:_ do the thing · _raised 2026-09-22_\n' >> "$FU"
OUT="$("$SCRIPT" --file "$FU" lint 2>&1)"; RC=$?
eq "U5 a hand-written action with no steps fails lint (rc 1)" "$RC" "1"
contains "U5 and names what is missing" "numbered steps" "$OUT"

echo "== V: every item carries CONTEXT in plain English (operator ruling 2026-10-21)"
# "I want to make sure that any question I'm asked and decisions I have to make are presented to
# me with context in plain English, always." The page already carried WHAT is asked and WHY it is
# his; none of that says what the thing IS. Measured the day before the ruling: an item reading
# `t1-230-credit-line` with a gate code and a PR number, which he had to decode before he could
# reach the question. Both directions are asserted, because a required field nobody checks gets
# filled with the same jargon.
FV="$T/context.md"
GOODCTX="A line in the new kit credits you by name, and the leak checker treats a first name as something it must not publish."

OUT="$("$SCRIPT" --file "$FV" add --id v1 --category decision --task "Pick one" --why "w" \
  --do "say A or B" --option "A: x" --option "B: y" --recommend "A" 2>&1)"; RC=$?
eq "V1 an item with no --context at all is refused (rc 2)" "$RC" "2"
contains "V1 and the refusal names the missing field" "--context" "$OUT"
[ ! -f "$FV" ] && ok "V1 and nothing was written" || bad "V1 nothing written" "file exists"

OUT="$("$SCRIPT" --file "$FV" add --id v2 --category decision --task "Pick one" --why "w" \
  --context "FAIL P6 at builder-tester-pair/README.md:96 blocks publish-gate/real on ee6571ff" \
  --do "say A or B" --option "A: x" --option "B: y" --recommend "A" 2>&1)"; RC=$?
eq "V2 an identifier dump is NOT plain English (rc 2)" "$RC" "2"
contains "V2 and the refusal says so in words" "plain English" "$OUT"

OUT="$("$SCRIPT" --file "$FV" add --id v3 --category decision \
  --task "Pick the wording of a credit line" --why "it is your name" --context "$GOODCTX" \
  --do "say A or B" --option "A: use the surname only" --option "B: drop the name" \
  --recommend "A, it keeps the credit" 2>&1)"; RC=$?
eq "V3 an ordinary sentence is accepted (rc 0)" "$RC" "0"
BODY="$(cat "$FV")"
contains "V3 the context is on the page, labelled" "**Context:** A line in the new kit" "$BODY"

# Order matters: he reads top to bottom, so the subject must arrive before the choices.
CTXLINE="$(grep -n '\*\*Context:\*\*' "$FV" | head -1 | cut -d: -f1)"
OPTLINE="$(grep -n '\*\*Option:\*\*' "$FV" | head -1 | cut -d: -f1)"
[ -n "$CTXLINE" ] && [ -n "$OPTLINE" ] && [ "$CTXLINE" -lt "$OPTLINE" ] \
  && ok "V4 context is rendered BEFORE the options" \
  || bad "V4 context before options" "context=$CTXLINE option=$OPTLINE"

OUT="$("$SCRIPT" --file "$FV" lint 2>&1)"; RC=$?
eq "V5 a page whose items carry context lints clean" "$RC" "0"

# CONTROL. A check that cannot fail is not a check: strip the one line and lint MUST turn red.
grep -v '\*\*Context:\*\*' "$FV" > "$T/context-stripped.md"
OUT="$("$SCRIPT" --file "$T/context-stripped.md" lint 2>&1)"; RC=$?
eq "V6 CONTROL: with the context line removed, lint fails (rc 1)" "$RC" "1"
contains "V6 and names what is missing" "no Context line" "$OUT"

# The parser must round-trip it, or the next add on a real page would silently drop it.
"$SCRIPT" --file "$FV" add --id v7 --category approval --task "something else" --why "w" \
  --context "An unrelated item, added so the first one has to survive a rewrite of the page." \
  --step "Say go" >/dev/null 2>&1
contains "V7 a later add keeps the earlier item's context" "**Context:** A line in the new kit" "$(cat "$FV")"

echo "== T: a missing page lints as MISSING, never as clean"
OUT="$("$SCRIPT" --file "$T/absent.md" lint 2>&1)"; RC=$?
eq "T1 rc is 2 on a missing page" "$RC" "2"


# The page is published to Engram; what that is and how a machine reaches it:
# [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
echo "== W: publish — the ONE page the operator actually reads (ruling 2026-10-30)"
# He reads an HTML page at a pinned link, not a markdown file in a private repo on a machine he is
# not at. Everything here is about the two ways that promise breaks in practice: a SECOND object
# (his link stops tracking reality while every report says "updated"), and a page that is simply
# never re-published after the queue moves.
mkdir -p "$T/w"
FW="$T/w/operator-todo.md"
NS="ns-under-test"
BASE="https://engram.example.invalid/l/lib/ns"
export DF_AGENT_ID="agent-under-test"
"$SCRIPT" --file "$FW" init >/dev/null 2>&1
"$SCRIPT" --file "$FW" add --id w-dec --category decision --task "Pick the tier for the guard" \
  --why "a new risk you accept or not" \
  --context "The guard stops the agent printing a token into a transcript. Putting it in Tier 1 gives it to every estate at once." \
  --do "Reply A or B" --option "A: Tier 1, every estate gets it" --option "B: this estate only" \
  --recommend "A, because the hazard is generic" >/dev/null 2>&1
"$SCRIPT" --file "$FW" add --id w-act --category access --task "Run one install on the far box" \
  --why "that machine is not reachable from here" --blocking \
  --context "A machine keeps running whatever it last installed, so until this runs it has the old tool." \
  --ref "https://example.invalid/pull/1" \
  --step "Open the workspace and click Terminal" \
  --step "Run: cd /home/coder/code/loom-storage" \
  --step "Run: bash install.sh --lock=instances/far/loom.lock.json" >/dev/null 2>&1

OUT="$("$SCRIPT" --file "$FW" publish --dry-run --out "$T/w/page.html" 2>&1)"; RC=$?
eq       "W1 dry-run needs no configuration (rc 0)" "$RC" "0"
contains "W1 reports the size" "bytes" "$OUT"
contains "W1 counts both kinds" "1 decision(s), 1 action(s)" "$OUT"
H="$(cat "$T/w/page.html")"
contains "W2 the decision is labelled D1" 'id="D1"' "$H"
contains "W2 the action is labelled A1" 'id="A1"' "$H"
contains "W2 context is rendered" "printing a token into a transcript" "$H"
contains "W2 the recommended option is marked" '<li class="rec">' "$H"
contains "W2 steps are an ordered list" "<ol>" "$H"
contains "W2 a full path survives" "/home/coder/code/loom-storage" "$H"
contains "W2 the command is monospaced" "<code>bash install.sh" "$H"
contains "W2 the ref becomes a link" '<a href="https://example.invalid/pull/1">' "$H"
contains "W2 blocking is called out" "Blocking" "$H"
contains "W2 the title names the agent and the operator" "agent-under-test: what I need from" "$H"

# ⛔ A PUBLIC PAGE RENDERS WHATEVER THE QUEUE SAYS. Escaping is not cosmetic here.
"$SCRIPT" --file "$FW" add --id w-esc --category approval --task "Approve the thing" \
  --why "yours to approve" \
  --context "A plain sentence followed by a tag that must never reach the browser as markup: <script>alert(1)</script>" \
  --step "Click approve" >/dev/null 2>&1
"$SCRIPT" --file "$FW" publish --dry-run --out "$T/w/esc.html" >/dev/null 2>&1
H="$(cat "$T/w/esc.html")"
contains "W3 a script tag is escaped" "&lt;script&gt;" "$H"
absent   "W3 and never emitted as markup" "<script>" "$H"
"$SCRIPT" --file "$FW" done --id w-esc --by-operator >/dev/null 2>&1

OUT="$("$SCRIPT" --file "$FW" publish --check 2>&1)"; RC=$?
eq       "W4 unconfigured --check PASSES (a notepad that never opted in is not gated)" "$RC" "0"
contains "W4 and says why" "not configured" "$OUT"

OUT="$(DF_ENGRAM_PAGES_NS="$NS" DF_ENGRAM_PAGES_URL="$BASE" "$SCRIPT" --file "$FW" publish --check 2>&1)"; RC=$?
eq       "W5 configured but never published is a DEFECT (rc 1)" "$RC" "1"
contains "W5 and names the fix" "df-operator-todo publish" "$OUT"

# A stub transport: df-engram's documented test seam. No network, and it RECORDS which hub tool
# was called, which is the only way to prove a second page was never written.
export DF_ENGRAM_TOOLLOG="$T/w/tools.log"
STUB="$T/w/transport.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$DF_ENGRAM_TOOLLOG"
if [ "${DF_STUB_LIST_BROKEN:-0}" = "1" ]; then
  case "$1" in *engram_list) printf '{}\n'; exit 0 ;; esac
fi
case "$1" in
  *engram_list)             printf '{"objects":[]}\n' ;;
  *engram_write)            printf '{"id":"11111111-2222-3333-4444-555555555555"}\n' ;;
  *engram_update)           printf '{"object_id":"11111111-2222-3333-4444-555555555555"}\n' ;;
  *set_object_visibility)   printf '{"object_id":"11111111-2222-3333-4444-555555555555","visibility":"public"}\n' ;;
  *)                        printf '{}\n' ;;
esac
STUBEOF
chmod +x "$STUB"

# ⛔ THE LIST MUST ANSWER BEFORE A FIRST WRITE IS ALLOWED. A store that could not answer is not an
# absence, and treating it as one is exactly how an operator ends up with two pinned links.
: > "$DF_ENGRAM_TOOLLOG"
OUT="$(DF_STUB_LIST_BROKEN=1 DF_ENGRAM_TRANSPORT="$STUB" DF_ENGRAM_PAGES_NS="$NS" \
       DF_ENGRAM_PAGES_URL="$BASE" "$SCRIPT" --file "$FW" publish 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "W6 an unlistable store REFUSES a first publish" \
  || bad "W6 unlistable store refuses" "rc was 0"
N="$(grep -c 'engram_write' "$DF_ENGRAM_TOOLLOG" || true)"
eq "W6 CONTROL: and wrote NOTHING" "$N" "0"
[ -f "$T/w/.df/operator-page.json" ] && bad "W6 no state recorded" "state file exists" \
  || ok "W6 no state recorded either"

: > "$DF_ENGRAM_TOOLLOG"
OUT="$(DF_ENGRAM_TRANSPORT="$STUB" DF_ENGRAM_PAGES_NS="$NS" DF_ENGRAM_PAGES_URL="$BASE" \
       "$SCRIPT" --file "$FW" publish 2>&1)"; RC=$?
eq       "W7 a first publish succeeds" "$RC" "0"
contains "W7 and prints the link" "$BASE/11111111-2222-3333-4444-555555555555" "$OUT"
contains "W7 asked the object store first" "engram_list" "$(cat "$DF_ENGRAM_TOOLLOG")"
contains "W7 then wrote the page" "engram_write" "$(cat "$DF_ENGRAM_TOOLLOG")"
contains "W7 and set it public" "set_object_visibility" "$(cat "$DF_ENGRAM_TOOLLOG")"
contains "W7 state records the id" "11111111-2222-3333-4444-555555555555" "$(cat "$T/w/.df/operator-page.json")"

OUT="$(DF_ENGRAM_PAGES_NS="$NS" DF_ENGRAM_PAGES_URL="$BASE" "$SCRIPT" --file "$FW" publish --check 2>&1)"; RC=$?
eq       "W8 --check passes immediately after a publish" "$RC" "0"
contains "W8 and says so" "is current" "$OUT"

# THE RED CONTROL for the whole mechanism: move the queue, and the page he can read is stale.
"$SCRIPT" --file "$FW" add --id w-new --category approval --task "One more thing" --why "yours" \
  --context "An item added after the page was published, so the page he is looking at is behind." \
  --step "Say go" >/dev/null 2>&1
OUT="$(DF_ENGRAM_PAGES_NS="$NS" DF_ENGRAM_PAGES_URL="$BASE" "$SCRIPT" --file "$FW" publish --check 2>&1)"; RC=$?
eq       "W9 CONTROL: a changed queue makes the published page STALE (rc 1)" "$RC" "1"
contains "W9 and says what he is reading is out of date" "OUT OF DATE" "$OUT"

# ⛔ THE SECOND PUBLISH MUST UPDATE IN PLACE. A new object means a new URL, and his pin is dead.
: > "$DF_ENGRAM_TOOLLOG"
OUT="$(DF_ENGRAM_TRANSPORT="$STUB" DF_ENGRAM_PAGES_NS="$NS" DF_ENGRAM_PAGES_URL="$BASE" \
       "$SCRIPT" --file "$FW" publish 2>&1)"; RC=$?
eq       "W10 a later publish succeeds" "$RC" "0"
contains "W10 and says it UPDATED rather than published" "updated" "$OUT"
LOG="$(cat "$DF_ENGRAM_TOOLLOG")"
contains "W10 it updated in place" "engram_update" "$LOG"
N="$(grep -c 'engram_write' "$DF_ENGRAM_TOOLLOG" || true)"
eq       "W10 and NEVER wrote a second object" "$N" "0"
N="$(grep -c 'set_object_visibility' "$DF_ENGRAM_TOOLLOG" || true)"
eq       "W10 nor silently re-set visibility (an unpublish is a decision)" "$N" "0"
contains "W10 the link is unchanged" "$BASE/11111111-2222-3333-4444-555555555555" "$OUT"

# A page out of shape must not be published: the HTML is rendered FROM it, to a public URL.
printf 'a stray line of narration\n' >> "$FW"
OUT="$(DF_ENGRAM_TRANSPORT="$STUB" DF_ENGRAM_PAGES_NS="$NS" DF_ENGRAM_PAGES_URL="$BASE" \
       "$SCRIPT" --file "$FW" publish 2>&1)"; RC=$?
eq       "W11 a page that fails lint REFUSES to publish (rc 2)" "$RC" "2"
contains "W11 and says the defect would be published" "public URL" "$OUT"

echo "== X: 25 KB is a ceiling the route enforces silently, so the tool enforces it loudly"
mkdir -p "$T/x"
FX="$T/x/operator-todo.md"
"$SCRIPT" --file "$FX" init >/dev/null 2>&1
SENT='A sentence of plain English that is long enough to be realistic for an operator item. '
WHY="${SENT}${SENT}${SENT}"      # 3 x 86 = 258, inside the 400 cap
CTX="${SENT}${SENT}${SENT}${SENT}${SENT}${SENT}"   # 6 x 86 = 516, inside the 600 cap
i=1
while [ "$i" -le 30 ]; do
  "$SCRIPT" --file "$FX" add --id "x$i" --category approval --task "Approve item number $i of a page built to exceed the published size ceiling" \
    --why "$WHY" --context "$CTX" \
    --step "Open the page and read it" --step "Click the button" --step "Tell me when you have clicked it" >/dev/null 2>&1
  i=$((i+1))
done
N="$(grep -c '^- \[ \] ' "$FX" || true)"
eq       "X0 CONTROL: the oversized fixture really has 30 items" "$N" "30"
OUT="$("$SCRIPT" --file "$FX" publish --dry-run 2>&1)"; RC=$?
eq       "X1 an oversized page REFUSES (rc 2)" "$RC" "2"
contains "X1 and names the ceiling" "25000" "$OUT"
contains "X1 and names the hazard" "truncates" "$OUT"
contains "X1 and names the biggest items" "Biggest items:" "$OUT"
unset DF_AGENT_ID DF_ENGRAM_TOOLLOG

printf 'passed %s  failed %s\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
