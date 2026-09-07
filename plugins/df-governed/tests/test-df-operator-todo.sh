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
OUT="$("$SCRIPT" --file "$F" add --id b1 --task "Rotate the key" --why "a credential only you hold" --do "gh auth refresh" 2>&1)"
contains "B: says async" "async" "$OUT"
OUT="$(cat "$F")"
contains "B: task text present" "Rotate the key" "$OUT"
contains "B: why present" "a credential only you hold" "$OUT"
contains "B: do present" "gh auth refresh" "$OUT"
contains "B: lands under the async heading" "Async — the loop continues" "$OUT"

echo "=== C: --blocking lands in the blocking section ==="
"$SCRIPT" --file "$F" add --id c1 --task "Decide the tier" --why "a decision you have not made" --do "reply T1 or T2" --blocking >/dev/null 2>&1
OUT="$(sed -n '/Blocking/,/## Async/p' "$F")"
contains "C: blocking item under the blocking heading" "Decide the tier" "$OUT"
absent   "C: async item NOT under blocking" "Rotate the key" "$OUT"

echo "=== D: re-adding an id UPDATES in place and MOVES section — never duplicates ==="
"$SCRIPT" --file "$F" add --id b1 --task "Rotate the key" --why "still yours" --do "gh auth refresh" --blocking >/dev/null 2>&1
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
"$SCRIPT" --file "$F" add --id g1 --task "Merge PR 7" --why "a merge you are blocked from" --do "gh pr merge 7" >/dev/null 2>&1
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
"$SCRIPT" --file "$F" add --id j1 --task "async thing" --why "a decision" --do "x" >/dev/null 2>&1
"$SCRIPT" --file "$F" add --id j2 --task "blocking thing" --why "a decision" --do "y" --blocking >/dev/null 2>&1
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
printf 'passed %s  failed %s\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
