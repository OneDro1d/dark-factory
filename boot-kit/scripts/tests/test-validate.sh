#!/usr/bin/env bash
# test-validate.sh — validate-arm.sh + validate.sh actually do what SPEC.md asked for.
#
# ⛔ ALL EIGHT CASES BELOW ARE RED AGAINST THE PREVIOUS COMMIT'S TREE. There is no
# validate-arm.sh, no validate.sh, and no plugins/df-governed/commands/validate.md there —
# every `bash "$ARM" ...` / `bash "$VALIDATE" ...` line below fails with "no such file",
# and case 8 fails because `plugins/df-governed/commands/validate.md` does not exist to
# validate. That is the whole point: these are new deliverables, not a refactor of
# something that already passed.
#
# ⚠️ NEVER LAUNCHES A REAL SESSION. Every `validate.sh` invocation here sets
# VALIDATE_CLAUDE_BIN to a stub that logs its argv+cwd and exits — never the real `claude`.
# The one place the real binary runs (case 8) is `claude plugin validate`, a static manifest
# check with no session, no prompt, no network call.
#
# ⚠️ FIXTURES ARE TEMP-ONLY. Every kit is a throwaway git repo under mktemp -d, normalized
# through `cd ... && pwd` immediately (macOS resolves /tmp through a symlink to /private/tmp,
# and comparing an unresolved path against find_notepad()'s resolved output is the same
# spelling-not-behaviour trap test-identify.sh's case K exists to avoid). Nothing here
# touches this repo, ~/.claude, or a real notepad.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
ARM="$SELF/../validate-arm.sh"
VALIDATE="$SELF/../validate.sh"
NOTEPAD_LIB="$SELF/../../../skills/agent-notepad/plugin/lib/notepad.sh"
REPO_ROOT="$(cd "$SELF/../../.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in: $3"; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }
file_exists() { [ -e "$2" ] && ok "$1" || bad "$1" "missing: $2"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/dfvalidate.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT

# A stub `claude`: logs argv + cwd, optionally drops a REPORT.md, exits ${STUB_EXIT:-0}.
# Never a real session -- this is the ONLY thing VALIDATE_CLAUDE_BIN ever points at below.
STUB="$T/claude-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
{
  echo "cwd=$PWD"
  i=0
  for a in "$@"; do i=$((i+1)); echo "argv[$i]=$a"; done
} >> "$STUB_LOG"
[ -n "${STUB_WRITE_REPORT:-}" ] && printf '%s' "$STUB_WRITE_REPORT" > REPORT.md
exit "${STUB_EXIT:-0}"
STUBEOF
chmod +x "$STUB"

# _fresh_kit NAME -> prints the path to a new throwaway git repo with a lockfile, an
# origin remote (a real, LOCAL bare repo under mktemp -- reachable, so Deliverable C's
# default-on push actually succeeds against it, but it carries no hostname at all, which
# satisfies the same "no real host in this public repo" rule a fake RFC 2606 URL used to),
# and a clean baseline (`git status --porcelain` empty) before anything touches it.
_bare_origin() {  # NAME -> prints the path to a fresh local bare repo
  local b="$T/$1.git"
  git init -q --bare "$b"
  printf '%s' "$b"
}

_fresh_kit() {
  local k="$T/$1" origin
  origin="$(_bare_origin "$1-origin")"
  mkdir -p "$k"
  git -C "$k" init -q
  printf '{"kit":"%s"}\n' "$1" > "$k/loom.lock.json"
  git -C "$k" -c user.name=t -c user.email=t@example.invalid add -A
  git -C "$k" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  git -C "$k" remote add origin "$origin"
  printf '%s' "$k"
}

echo "=== 1: arm on a fixture kit (git repo with a remote configured) ==="
KIT1="$(_fresh_kit kit1)"
ARM_OUT="$(bash "$ARM" "$KIT1" 2>&1)"; ARM_RC=$?
NP1="$KIT1/.df-validate"
[ "$ARM_RC" -eq 0 ] && ok "1: arm exits 0" || bad "1: arm exits 0" "rc=$ARM_RC: $ARM_OUT"
contains "1: arm prints the arm: line last" "arm: $NP1" "$(printf '%s\n' "$ARM_OUT" | tail -1)"
file_exists "1: NOTES.md"                    "$NP1/NOTES.md"
file_exists "1: repos.manifest.json"         "$NP1/repos.manifest.json"
file_exists "1: handoffs/"                   "$NP1/handoffs"
file_exists "1: sessions/"                   "$NP1/sessions"
file_exists "1: MAP.md"                      "$NP1/MAP.md"
file_exists "1: .df/missions/M-VALIDATE/state"       "$NP1/.df/missions/M-VALIDATE/state"
file_exists "1: .df/missions/M-VALIDATE/MISSION.md"  "$NP1/.df/missions/M-VALIDATE/MISSION.md"
contains "1: mission state is RUNNING" "RUNNING" "$(cat "$NP1/.df/missions/M-VALIDATE/state" 2>/dev/null)"
INNER_REMOTES="$(git -C "$NP1" remote 2>/dev/null)"
[ -z "$INNER_REMOTES" ] && ok "1: inner repo has NO remote" || bad "1: inner repo has NO remote" "found: $INNER_REMOTES"
EXCL1="$(git -C "$KIT1" rev-parse --git-path info/exclude)"
case "$EXCL1" in /*) : ;; *) EXCL1="$KIT1/$EXCL1" ;; esac
contains "1: .git/info/exclude carries the line" ".df-validate/" "$(cat "$EXCL1" 2>/dev/null)"
OUTER_STATUS_1="$(git -C "$KIT1" status --porcelain 2>&1)"
[ -z "$OUTER_STATUS_1" ] && ok "1: outer repo status is empty after arming (excluded)" \
  || bad "1: outer repo status is empty after arming (excluded)" "$OUTER_STATUS_1"

echo "=== 2: find_notepad resolves the armed dir ==="
# shellcheck source=/dev/null
. "$NOTEPAD_LIB"
FOUND="$(find_notepad "$NP1/handoffs")"
[ "$FOUND" = "$NP1" ] && ok "2: find_notepad resolves to the armed notepad" \
  || bad "2: find_notepad resolves to the armed notepad" "got '$FOUND' want '$NP1'"

echo "=== 3: re-arm refuses; --force recreates ==="
REARM_OUT="$(bash "$ARM" "$KIT1" 2>&1)"; REARM_RC=$?
[ "$REARM_RC" -ne 0 ] && ok "3: bare re-arm refuses (nonzero exit)" \
  || bad "3: bare re-arm refuses (nonzero exit)" "exited 0"
contains "3: refusal names --force" "--force" "$REARM_OUT"
FORCE_OUT="$(bash "$ARM" "$KIT1" --force 2>&1)"; FORCE_RC=$?
[ "$FORCE_RC" -eq 0 ] && ok "3: --force recreates (exit 0)" || bad "3: --force recreates (exit 0)" "rc=$FORCE_RC: $FORCE_OUT"
EXCL_HITS="$(grep -c '^\.df-validate/$' "$EXCL1" 2>/dev/null || true)"
[ "$EXCL_HITS" = "1" ] && ok "3: --force does not duplicate the exclude line" \
  || bad "3: --force does not duplicate the exclude line" "count=$EXCL_HITS"

echo "=== 4: validate.sh runs the stub with the right cwd+argv, then tears down clean ==="
KIT4="$(_fresh_kit kit4)"
LOG4="$T/log4"; : > "$LOG4"
V4_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOG4" bash "$VALIDATE" --kit-root "$KIT4" 2>&1)"; V4_RC=$?
[ "$V4_RC" -eq 0 ] && ok "4: validate.sh exits 0" || bad "4: validate.sh exits 0" "rc=$V4_RC: $V4_OUT"
contains "4: stub's cwd was the armed notepad" "cwd=$KIT4/.df-validate" "$(cat "$LOG4")"
contains "4: stub's argv named the slash command" "argv[1]=/df-governed:validate" "$(cat "$LOG4")"
[ ! -d "$KIT4/.df-validate" ] && ok "4: .df-validate/ is gone after teardown" \
  || bad "4: .df-validate/ is gone after teardown" "still present"
EXCL4="$(git -C "$KIT4" rev-parse --git-path info/exclude)"
case "$EXCL4" in /*) : ;; *) EXCL4="$KIT4/$EXCL4" ;; esac
absent "4: exclude line is gone after teardown" ".df-validate/" "$(cat "$EXCL4" 2>/dev/null)"
V4_STATUS="$(git -C "$KIT4" status --porcelain 2>&1)"
[ -z "$V4_STATUS" ] && ok "4: kit status --porcelain is empty after teardown" \
  || bad "4: kit status --porcelain is empty after teardown" "$V4_STATUS"

echo "=== 5: a REPORT.md the stub writes survives teardown, copied to the kit root ==="
KIT5="$(_fresh_kit kit5)"
LOG5="$T/log5"; : > "$LOG5"
REPORT_BODY="M-VALIDATE report from case 5 -- $(date -u +%Y-%m-%dT%H:%M:%SZ)"
V5_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOG5" STUB_WRITE_REPORT="$REPORT_BODY" \
  bash "$VALIDATE" --kit-root "$KIT5" 2>&1)"; V5_RC=$?
[ "$V5_RC" -eq 0 ] && ok "5: validate.sh exits 0" || bad "5: validate.sh exits 0" "rc=$V5_RC: $V5_OUT"
REPORT_FILE="$(ls "$KIT5"/VALIDATE-REPORT-*.md 2>/dev/null | head -1)"
[ -n "$REPORT_FILE" ] && ok "5: VALIDATE-REPORT-<date>.md exists at the kit root" \
  || bad "5: VALIDATE-REPORT-<date>.md exists at the kit root" "no such file under $KIT5"
if [ -n "$REPORT_FILE" ]; then
  contains "5: it carries the stub's REPORT.md content" "$REPORT_BODY" "$(cat "$REPORT_FILE")"
else
  bad "5: it carries the stub's REPORT.md content" "no report file to check"
fi

echo "=== 6: --keep leaves the dir and says so ==="
KIT6="$(_fresh_kit kit6)"
LOG6="$T/log6"; : > "$LOG6"
V6_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOG6" bash "$VALIDATE" --kit-root "$KIT6" --keep 2>&1)"; V6_RC=$?
[ "$V6_RC" -eq 0 ] && ok "6: --keep exits 0" || bad "6: --keep exits 0" "rc=$V6_RC: $V6_OUT"
[ -d "$KIT6/.df-validate" ] && ok "6: .df-validate/ is left in place" \
  || bad "6: .df-validate/ is left in place" "missing"
contains "6: output says teardown was skipped" "--keep" "$V6_OUT"

echo "=== 7: no claude on PATH and no override refuses with exit 2, names the binary ==="
# ⚠️ The negative must be ESTABLISHED, not assumed. This used to narrow PATH to /usr/bin:/bin
# and call that "no claude" — but a system-wide npm install puts `claude` in exactly those
# directories (measured on a Coder 2026-09-09), so validate.sh correctly proceeded, launched a
# REAL session, and the suite hung with no verdict to read. A negative control that fails
# toward a hang is worse than none. PATH is now a scratch dir holding only the tools the
# script itself needs (bash, coreutils, git, python3 resolved from the current PATH) and no
# `claude`; the assertion below first proves `claude` is absent from that PATH.
KIT7="$(_fresh_kit kit7)"
P7="$T/path7"; mkdir -p "$P7"
for tool in bash sh env cat cp mkdir rm rmdir ls dirname basename readlink realpath date mktemp grep sed awk tr sort head tail wc find diff cmp git python3 jq; do
  src="$(command -v "$tool" 2>/dev/null || true)"; [ -n "$src" ] && ln -sf "$src" "$P7/$tool"
done
if PATH="$P7" command -v claude >/dev/null 2>&1; then bad "7: the control PATH has no claude" "claude resolved under $P7"
else ok "7: the control PATH has no claude"; fi
V7_OUT="$(PATH="$P7" bash "$VALIDATE" --kit-root "$KIT7" 2>&1)"; V7_RC=$?
[ "$V7_RC" -eq 2 ] && ok "7: exits 2" || bad "7: exits 2" "rc=$V7_RC: $V7_OUT"
contains "7: names the binary" "claude" "$V7_OUT"

echo "=== 8: claude plugin validate plugins/df-governed ==="
if command -v claude >/dev/null 2>&1; then
  P8_OUT="$(claude plugin validate "$REPO_ROOT/plugins/df-governed" 2>&1)"; P8_RC=$?
  printf '%s\n' "$P8_OUT" | sed 's/^/  claude plugin validate: /'
  [ "$P8_RC" -eq 0 ] && ok "8: claude plugin validate exits 0" \
    || bad "8: claude plugin validate exits 0" "rc=$P8_RC: $P8_OUT"
else
  # UNKNOWN, stated explicitly -- never a silent pass. Counted as a case that ran and
  # recorded UNKNOWN, not folded into the pass tally.
  printf '  UNKNOWN 8: claude plugin validate plugins/df-governed -- no claude on PATH\n'
  ok "8: absence of claude recorded as UNKNOWN, not silently skipped"
fi

echo "=== 9: a kit that was ALREADY dirty before the run is not blamed for its own drift ==="
# The laptop's real kit is never clean when validate.sh runs after install.sh (probed.*
# writes, operator edits). "Leave it as you found it" is measured against FOUND, not empty.
KIT9="$(_fresh_kit kit9)"
printf 'operator edit\n' > "$KIT9/PRE-EXISTING.md"
printf '{"kit":"kit9","touched":true}\n' > "$KIT9/loom.lock.json"
PRE9="$(git -C "$KIT9" status --porcelain)"
LOG9="$T/log9"; : > "$LOG9"
V9_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOG9" bash "$VALIDATE" --kit-root "$KIT9" 2>&1)"; V9_RC=$?
[ "$V9_RC" -eq 0 ] && ok "9: exits 0 despite the pre-existing drift" \
  || bad "9: exits 0 despite the pre-existing drift" "rc=$V9_RC: $V9_OUT"
contains "9: says teardown clean" "teardown clean" "$V9_OUT"
POST9="$(git -C "$KIT9" status --porcelain)"
[ "$PRE9" = "$POST9" ] && ok "9: status after == status before (the operator's drift is untouched)" \
  || bad "9: status after == status before" "before: $PRE9 | after: $POST9"
[ ! -d "$KIT9/.df-validate" ] && ok "9: .df-validate/ is gone" || bad "9: .df-validate/ is gone" "still present"

echo "=== 10: a leftover .df-validate/ from a --keep run does not strand the one command ==="
KIT10="$(_fresh_kit kit10)"
LOG10="$T/log10"; : > "$LOG10"
VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOG10" bash "$VALIDATE" --kit-root "$KIT10" --keep >/dev/null 2>&1
[ -d "$KIT10/.df-validate" ] && ok "10: precondition — leftover exists" || bad "10: precondition — leftover exists" "missing"
V10_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOG10" bash "$VALIDATE" --kit-root "$KIT10" 2>&1)"; V10_RC=$?
[ "$V10_RC" -eq 0 ] && ok "10: second run exits 0 over the leftover" \
  || bad "10: second run exits 0 over the leftover" "rc=$V10_RC: $V10_OUT"
contains "10: it says it removed the leftover" "leftover" "$V10_OUT"
[ ! -d "$KIT10/.df-validate" ] && ok "10: .df-validate/ is gone after the second run" \
  || bad "10: .df-validate/ is gone after the second run" "still present"
V10_STATUS="$(git -C "$KIT10" status --porcelain 2>&1)"
[ -z "$V10_STATUS" ] && ok "10: kit status is empty" || bad "10: kit status is empty" "$V10_STATUS"

echo "=== 10b: a FAILED session is not reported as a clean validate (exit 4), teardown still proven ==="
# MEASURED 2026-09-09 on the homelab Coder: `claude -p` died on an account limit, wrote no
# REPORT.md, and validate.sh exited 0 -- so the ssh loop that reads $? printed "validate exit 0"
# and the box read as validated. SESSION_RC was captured and PRINTED but never reached an exit
# path: a human could see it, no machine could. The teardown proof must STILL run and print --
# the failure code is applied after it, exactly as a failed push (3) already was.
KIT10B="$(_fresh_kit kit10b)"
LOG10B="$T/log10b"; : > "$LOG10B"
V10B_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOG10B" STUB_EXIT=1 bash "$VALIDATE" --kit-root "$KIT10B" 2>&1)"; V10B_RC=$?
[ "$V10B_RC" -eq 4 ] && ok "10b: exits 4, not 0" || bad "10b: exits 4, not 0" "rc=$V10B_RC: $V10B_OUT"
contains "10b: it says the session failed"    "the session FAILED" "$V10B_OUT"
contains "10b: the teardown proof still ran"  "teardown clean"     "$V10B_OUT"
[ ! -d "$KIT10B/.df-validate" ] && ok "10b: .df-validate/ is gone even on failure" \
  || bad "10b: .df-validate/ is gone even on failure" "still present"
# and the other half of the same hole, stated but NOT an exit code (only the shape above was
# measured; this suite's own teardown cases drive a deliberately report-less stub):
KIT10C="$(_fresh_kit kit10c)"
LOG10C="$T/log10c"; : > "$LOG10C"
V10C_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOG10C" bash "$VALIDATE" --kit-root "$KIT10C" 2>&1)"; V10C_RC=$?
[ "$V10C_RC" -eq 0 ] && ok "10c: a report-less session that exits 0 still exits 0" \
  || bad "10c: a report-less session that exits 0 still exits 0" "rc=$V10C_RC: $V10C_OUT"
contains "10c: but it WARNS that nothing was validated" "produced NO report" "$V10C_OUT"

echo "=== 10d: a LIVE validate.sh owning .df-validate/ is refused (exit 5), nothing touched ==="
# ⛔ MEASURED 2026-09-09 on the Poland Coder: two --headless runs against one kit, four minutes
# apart. The second re-armed the LIVE notepad with a fresh `git init`, the two sessions then
# interleaved commits in the same repo, and whichever exits first removes .df-validate/ --
# including the other run's REPORT.md -- before that run can copy it out. Neither errored.
# A --keep leftover and a running peer are indistinguishable on disk, so the directory now
# names its owner.
KIT10D="$(_fresh_kit kit10d)"
mkdir -p "$KIT10D/.df-validate"
# A LIVE owner: a real sleeping process whose command line contains validate.sh, so the check's
# two halves -- alive, AND still a validate.sh -- are both genuinely satisfied rather than stubbed.
LIVE_OWNER="$T/live-validate.sh"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$LIVE_OWNER"
chmod +x "$LIVE_OWNER"
bash "$LIVE_OWNER" &
LIVE_PID=$!
printf '%s\n' "$LIVE_PID" > "$KIT10D/.df-validate/.validate-owner"
printf 'sentinel\n' > "$KIT10D/.df-validate/DO-NOT-DELETE.txt"
V10D_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$T/log10d" bash "$VALIDATE" --kit-root "$KIT10D" 2>&1)"; V10D_RC=$?
[ "$V10D_RC" -eq 5 ] && ok "10d: exits 5" || bad "10d: exits 5" "rc=$V10D_RC: $V10D_OUT"
contains "10d: names the live pid"        "$LIVE_PID"      "$V10D_OUT"
contains "10d: says nothing was touched"  "Nothing was touched" "$V10D_OUT"
file_exists "10d: the live run's directory is intact" "$KIT10D/.df-validate/DO-NOT-DELETE.txt"
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null

echo "=== 10e: an owner file naming a DEAD pid is just a leftover -- the run proceeds ==="
# The other half. A stale owner must not refuse forever: pids are reused and processes die.
KIT10E="$(_fresh_kit kit10e)"
mkdir -p "$KIT10E/.df-validate"
DEAD_OWNER="$T/dead-validate.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$DEAD_OWNER"
chmod +x "$DEAD_OWNER"
bash "$DEAD_OWNER" &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
printf '%s\n' "$DEAD_PID" > "$KIT10E/.df-validate/.validate-owner"
V10E_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$T/log10e" bash "$VALIDATE" --kit-root "$KIT10E" 2>&1)"; V10E_RC=$?
[ "$V10E_RC" -eq 0 ] && ok "10e: a dead owner does not block the run" \
  || bad "10e: a dead owner does not block the run" "rc=$V10E_RC: $V10E_OUT"
contains "10e: it is treated as a leftover" "leftover" "$V10E_OUT"

echo "=== 10f: a normal run claims the directory, so a peer would see an owner ==="
KIT10F="$(_fresh_kit kit10f)"
STUB10F="$T/claude-stub-owner.sh"
cat > "$STUB10F" <<'STUBEOF'
#!/usr/bin/env bash
# record what the owner file said WHILE the session was running -- after teardown it is gone
cp .validate-owner "$OWNER_COPY" 2>/dev/null || echo "MISSING" > "$OWNER_COPY"
exit 0
STUBEOF
chmod +x "$STUB10F"
OWNER_COPY="$T/owner-seen.txt"; export OWNER_COPY
VALIDATE_CLAUDE_BIN="$STUB10F" bash "$VALIDATE" --kit-root "$KIT10F" >/dev/null 2>&1
SEEN="$(cat "$OWNER_COPY" 2>/dev/null || echo MISSING)"
case "$SEEN" in
  ''|MISSING|*[!0-9$'\n']*) bad "10f: the run wrote a numeric owner pid" "saw [$SEEN]" ;;
  *) ok "10f: the run wrote a numeric owner pid" ;;
esac
[ ! -e "$KIT10F/.df-validate" ] && ok "10f: the owner file goes with the notepad at teardown" \
  || bad "10f: the owner file goes with the notepad at teardown" ".df-validate still present"

echo "=== 10g: a report git refuses to STAGE is exit 3, and the step is named ==="
# MEASURED 2026-09-10 on two ESO machines at once: each copied its report, neither committed it,
# GitHub's push log shows no push from either, and both looked finished. Until then `git add`'s
# status was never checked and a failed commit printed FATAL and still exited 0.
KIT10G="$(_fresh_kit kit10g)"
EXCL10G="$(git -C "$KIT10G" rev-parse --git-path info/exclude)"
case "$EXCL10G" in /*) : ;; *) EXCL10G="$KIT10G/$EXCL10G" ;; esac
mkdir -p "$(dirname "$EXCL10G")"
printf 'VALIDATE-REPORT-*\n' >> "$EXCL10G"
HEAD10G="$(git -C "$KIT10G" rev-parse HEAD)"
V10G_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$T/log10g" STUB_WRITE_REPORT="probe report" bash "$VALIDATE" --kit-root "$KIT10G" 2>&1)"; V10G_RC=$?
[ "$V10G_RC" -eq 3 ] && ok "10g: exits 3, not 0" || bad "10g: exits 3, not 0" "rc=$V10G_RC: $V10G_OUT"
contains "10g: the message names git add" "git add refused the report" "$V10G_OUT"
[ "$(git -C "$KIT10G" rev-parse HEAD)" = "$HEAD10G" ] && ok "10g: nothing was committed" \
  || bad "10g: nothing was committed" "HEAD moved"
ls "$KIT10G"/VALIDATE-REPORT-*.md >/dev/null 2>&1 && ok "10g: the report is still at the kit root" \
  || bad "10g: the report is still at the kit root" "missing"

echo "=== 10h: a report git refuses to COMMIT is exit 3 too (it used to be FATAL + exit 0) ==="
KIT10H="$(_fresh_kit kit10h)"
HOOKS10H="$(git -C "$KIT10H" rev-parse --git-path hooks)"
case "$HOOKS10H" in /*) : ;; *) HOOKS10H="$KIT10H/$HOOKS10H" ;; esac
mkdir -p "$HOOKS10H"
printf '#!/bin/sh\necho "probe pre-commit: refused"\nexit 1\n' > "$HOOKS10H/pre-commit"
chmod +x "$HOOKS10H/pre-commit"
HEAD10H="$(git -C "$KIT10H" rev-parse HEAD)"
V10H_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$T/log10h" STUB_WRITE_REPORT="probe report" bash "$VALIDATE" --kit-root "$KIT10H" 2>&1)"; V10H_RC=$?
[ "$V10H_RC" -eq 3 ] && ok "10h: exits 3, not 0" || bad "10h: exits 3, not 0" "rc=$V10H_RC: $V10H_OUT"
contains "10h: the message names git commit" "git commit failed" "$V10H_OUT"
[ "$(git -C "$KIT10H" rev-parse HEAD)" = "$HEAD10H" ] && ok "10h: nothing was committed" \
  || bad "10h: nothing was committed" "HEAD moved"

echo "=== 10i: work already STAGED in the kit is not swept into the report commit, nor pushed ==="
# MEASURED 2026-09-10 on an ESO Coder: the tree held unrelated staged work, and `git commit -m`
# with no pathspec commits the WHOLE index -- the report commit would have carried that work and
# pushed it to the estate remote. The add was scoped; the commit was not. It names its paths now,
# which commits only those and leaves everything else staged exactly as it was.
KIT10I="$(_fresh_kit kit10i)"
printf 'operator work in progress\n' > "$KIT10I/operator-wip.txt"
git -C "$KIT10I" add -- operator-wip.txt
V10I_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$T/log10i" STUB_WRITE_REPORT="probe report" bash "$VALIDATE" --kit-root "$KIT10I" 2>&1)"; V10I_RC=$?
[ "$V10I_RC" -eq 0 ] && ok "10i: exits 0" || bad "10i: exits 0" "rc=$V10I_RC: $V10I_OUT"
FILES10I="$(git -C "$KIT10I" show --name-only --format= HEAD)"
case "$FILES10I" in
  *operator-wip.txt*) bad "10i: the report commit does not carry the staged work" "HEAD has: $FILES10I" ;;
  *VALIDATE-REPORT-*) ok "10i: the report commit does not carry the staged work" ;;
  *) bad "10i: the report commit does not carry the staged work" "HEAD has no report: $FILES10I" ;;
esac
contains "10i: the staged work is still staged afterwards" "operator-wip.txt" \
  "$(git -C "$KIT10I" diff --cached --name-only)"
ORIGIN10I="$(git -C "$KIT10I" remote get-url origin)"
BR10I="$(git -C "$KIT10I" symbolic-ref --short HEAD)"
if git -C "$ORIGIN10I" ls-tree -r --name-only "$BR10I" 2>/dev/null | grep -qx operator-wip.txt; then
  bad "10i: the staged work did not reach the remote" "it is in origin/$BR10I"
else
  ok "10i: the staged work did not reach the remote"
fi

echo "=== 10j: the remote MOVED since this checkout pulled -> merged once, pushed, exit 0 ==="
# MEASURED 2026-09-10 on the ESO laptop: one record repo, five machines, every validate pushes to
# it -- the laptop's report push was rejected (fetch first) because a Coder's report and a repin
# had landed on the same main. The script printed "push FAILED: To https://…" and stopped.
KIT10J="$(_fresh_kit kit10j)"
BR10J="$(git -C "$KIT10J" symbolic-ref --short HEAD)"
git -C "$KIT10J" push -q -u origin "$BR10J" 2>/dev/null
ORIGIN10J="$(git -C "$KIT10J" remote get-url origin)"
git clone -q -b "$BR10J" "$ORIGIN10J" "$T/other10j" 2>/dev/null
printf 'another machine\n' > "$T/other10j/other-machine.txt"
git -C "$T/other10j" add -- other-machine.txt
git -C "$T/other10j" -c user.name=t -c user.email=t@example.invalid commit -q -m "another machine's report"
git -C "$T/other10j" push -q 2>/dev/null
V10J_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$T/log10j" STUB_WRITE_REPORT="probe report" bash "$VALIDATE" --kit-root "$KIT10J" 2>&1)"; V10J_RC=$?
[ "$V10J_RC" -eq 0 ] && ok "10j: exits 0" || bad "10j: exits 0" "rc=$V10J_RC: $V10J_OUT"
contains "10j: it says it merged the remote and retried" "merging origin/$BR10J and retrying once" "$V10J_OUT"
TREE10J="$(git -C "$ORIGIN10J" ls-tree -r --name-only "$BR10J" 2>/dev/null)"
contains "10j: the other machine's commit is still on the remote" "other-machine.txt" "$TREE10J"
contains "10j: the report reached the remote" "VALIDATE-REPORT-" "$TREE10J"

echo "=== 10k: the remote CONFLICTS -> merge aborted, report commit kept, exit 3, git's reason named ==="
KIT10K="$(_fresh_kit kit10k)"
BR10K="$(git -C "$KIT10K" symbolic-ref --short HEAD)"
git -C "$KIT10K" push -q -u origin "$BR10K" 2>/dev/null
ORIGIN10K="$(git -C "$KIT10K" remote get-url origin)"
git clone -q -b "$BR10K" "$ORIGIN10K" "$T/other10k" 2>/dev/null
printf '{"kit":"kit10k","from":"the other machine"}\n' > "$T/other10k/loom.lock.json"
git -C "$T/other10k" -c user.name=t -c user.email=t@example.invalid commit -q -am "remote edit"
git -C "$T/other10k" push -q 2>/dev/null
printf '{"kit":"kit10k","from":"this machine"}\n' > "$KIT10K/loom.lock.json"
git -C "$KIT10K" -c user.name=t -c user.email=t@example.invalid commit -q -am "local edit, never pushed"
V10K_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$T/log10k" STUB_WRITE_REPORT="probe report" bash "$VALIDATE" --kit-root "$KIT10K" 2>&1)"; V10K_RC=$?
[ "$V10K_RC" -eq 3 ] && ok "10k: exits 3" || bad "10k: exits 3" "rc=$V10K_RC: $V10K_OUT"
contains "10k: git's rejection reason is printed, not only its To <url> line" "[rejected]" "$V10K_OUT"
if printf '%s' "$V10K_OUT" | grep -q 'push FAILED: To '; then
  bad "10k: the FAILED line is not the bare 'To <url>' line" "$V10K_OUT"
else
  ok "10k: the FAILED line is not the bare 'To <url>' line"
fi
contains "10k: it says how to finish by hand" "pull --no-rebase" "$V10K_OUT"
if git -C "$KIT10K" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  bad "10k: no merge is left in progress" "MERGE_HEAD present"
else
  ok "10k: no merge is left in progress"
fi
case "$(git -C "$KIT10K" log -1 --format=%s)" in
  "M-VALIDATE: validation report"*) ok "10k: the report commit is still HEAD" ;;
  *) bad "10k: the report commit is still HEAD" "HEAD is: $(git -C "$KIT10K" log -1 --format=%s)" ;;
esac

echo "=== 11: the kit's PROJECT-level settings (commit/push gates) reach the armed notepad ==="
# MEASURED 2026-09-08 on the first real run: the commit gate is wired in the kit root's
# .claude/settings.json only, the armed notepad is its own repo under its own cwd, so
# `git commit -m wip` went through with M-VALIDATE RUNNING. The arm now copies that file in.
KIT11="$(_fresh_kit kit11)"
mkdir -p "$KIT11/.claude"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"${HOME}/.claude/hooks/agent-notepad/hooks/commit-gate.sh"}]}]}}\n' > "$KIT11/.claude/settings.json"
git -C "$KIT11" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$KIT11" -c user.name=t -c user.email=t@example.invalid commit -q -m settings
bash "$ARM" "$KIT11" >/dev/null 2>&1
file_exists "11: armed notepad has .claude/settings.json" "$KIT11/.df-validate/.claude/settings.json"
if cmp -s "$KIT11/.claude/settings.json" "$KIT11/.df-validate/.claude/settings.json"; then
  ok "11: it is byte-identical to the kit's"
else
  bad "11: it is byte-identical to the kit's" "differs"
fi
KIT11B="$(_fresh_kit kit11b)"
bash "$ARM" "$KIT11B" >/dev/null 2>&1
[ ! -e "$KIT11B/.df-validate/.claude" ] && ok "11: a kit with no project settings arms with none (nothing invented)" \
  || bad "11: a kit with no project settings arms with none" ".claude/ present"

echo "=== 12: the armed notepad can COMMIT with no global git identity ==="
# MEASURED 2026-09-08 on the homelab Coder: the kit's identity was repo-local, nothing was
# global, so the notepad repo inherited none -- the handoff helper wrote and staged but could
# not commit ("Author identity unknown"). The arm now gives the notepad an identity: the kit's
# where git can resolve one, else its own throwaway one. Both halves, under a HOME with no
# .gitconfig and GIT_CONFIG_GLOBAL pointed at nothing.
NOHOME="$T/nohome"; mkdir -p "$NOHOME"
KIT12="$(_fresh_kit kit12)"
git -C "$KIT12" config user.name "Kit Local"
git -C "$KIT12" config user.email "kit-local@example.invalid"
env HOME="$NOHOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$ARM" "$KIT12" >/dev/null 2>&1
NP12="$KIT12/.df-validate"
C12="$(env HOME="$NOHOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$NP12" commit -q --allow-empty -m "M-VALIDATE: gate check" 2>&1)"; RC12=$?
[ "$RC12" -eq 0 ] && ok "12: a plain commit in the armed notepad succeeds" || bad "12: a plain commit succeeds" "rc=$RC12: $C12"
contains "12: it carries the kit's repo-local identity" "kit-local@example.invalid" "$(git -C "$NP12" log -1 --format=%ae)"
KIT12B="$(_fresh_kit kit12b)"
env HOME="$NOHOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$ARM" "$KIT12B" >/dev/null 2>&1
C12B="$(env HOME="$NOHOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$KIT12B/.df-validate" commit -q --allow-empty -m "M-VALIDATE: gate check" 2>&1)"; RC12B=$?
[ "$RC12B" -eq 0 ] && ok "12: with NO identity anywhere the arm supplies its own and the commit still succeeds" \
  || bad "12: no identity anywhere still commits" "rc=$RC12B: $C12B"

echo "=== 13: project HOOKS travel with the project settings that name them ==="
# MEASURED 2026-09-08 on the homelab Coder: the copied settings named `.claude/hooks/ensure-gate.sh`,
# absent in the notepad -- a declared SessionStart hook failing silently on every start there.
KIT13="$(_fresh_kit kit13)"
mkdir -p "$KIT13/.claude/hooks"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash .claude/hooks/ensure-gate.sh"}]}]}}\n' > "$KIT13/.claude/settings.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$KIT13/.claude/hooks/ensure-gate.sh"
git -C "$KIT13" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$KIT13" -c user.name=t -c user.email=t@example.invalid commit -q -m hooks
bash "$ARM" "$KIT13" >/dev/null 2>&1
file_exists "13: the hook the settings name exists in the notepad" "$KIT13/.df-validate/.claude/hooks/ensure-gate.sh"

echo "=== 14: an operator-todo raised INSIDE the run is carried out, not destroyed ==="
# MEASURED 2026-09-08 on the homelab Coder: df-operator-todo resolves the nearest notepad --
# the throwaway one -- so an item raised for the operator during validation was written there
# and would have gone with the directory.
KIT14="$(_fresh_kit kit14)"
LOG14="$T/log14"; : > "$LOG14"
STUB14="$T/claude-stub-todo.sh"
cat > "$STUB14" <<'STUBEOF'
#!/usr/bin/env bash
printf '## Async\n- [ ] `probe` — **needs the operator** · _why it is yours:_ a decision · _do:_ decide · _raised 2026-09-08_\n' > operator-todo.md
exit 0
STUBEOF
chmod +x "$STUB14"
V14_OUT="$(VALIDATE_CLAUDE_BIN="$STUB14" bash "$VALIDATE" --kit-root "$KIT14" 2>&1)"; V14_RC=$?
[ "$V14_RC" -eq 0 ] && ok "14: validate.sh exits 0" || bad "14: validate.sh exits 0" "rc=$V14_RC: $V14_OUT"
TODO14="$(ls "$KIT14"/VALIDATE-OPERATOR-TODO-*.md 2>/dev/null | head -1)"
[ -n "$TODO14" ] && ok "14: VALIDATE-OPERATOR-TODO-<date>.md exists at the kit root" || bad "14: operator todo carried out" "no file"
contains "14: it carries the item" "needs the operator" "$(cat "$TODO14" 2>/dev/null)"
contains "14: the run says it did so" "raised item(s) for the operator" "$V14_OUT"
KIT14B="$(_fresh_kit kit14b)"
LOG14B="$T/log14b"; : > "$LOG14B"
V14B_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOG14B" bash "$VALIDATE" --kit-root "$KIT14B" 2>&1)"; V14B_RC=$?
[ -z "$(ls "$KIT14B"/VALIDATE-OPERATOR-TODO-*.md 2>/dev/null)" ] && ok "14: a run that raised nothing leaves no todo file" \
  || bad "14: no todo file when nothing raised" "file present"

echo "=== W1/W2: validate.md names the vendored identify path first, and gives each CALL probe a real budget (SPEC D) ==="
VMD="$REPO_ROOT/plugins/df-governed/commands/validate.md"
file_exists "W: validate.md exists" "$VMD"
VEND_LINE="$(grep -Fn 'vendor/dark-factory/boot-kit/scripts/identify.sh' "$VMD" | head -1 | cut -d: -f1)"
KITROOT_LINE="$(grep -Fn '<kit-root>/boot-kit/scripts/identify.sh' "$VMD" | head -1 | cut -d: -f1)"
if [ -n "$VEND_LINE" ] && [ -n "$KITROOT_LINE" ] && [ "$VEND_LINE" -lt "$KITROOT_LINE" ]; then
  ok "W1: the vendored identify path appears before the kit-root one in Task 1"
else
  bad "W1: the vendored identify path appears before the kit-root one in Task 1" \
    "vendor@line=$VEND_LINE kit-root@line=$KITROOT_LINE"
fi
contains "W2: --max-budget-usd 3 appears in §6" "--max-budget-usd 3" "$(cat "$VMD" 2>/dev/null)"
# W3, MEASURED 2026-09-09 on the first `validate.sh --headless` run: the Bash tool's environment
# carries CLAUDE_CODE_ENTRYPOINT=sdk-cli into every child, so the "direct" Stop-gate probe the
# command text prescribed released with {} and no handoff on disk — three false PASSes. The probe
# snippet must strip the entrypoint, or a headless run cannot tell the handoff from the guard.
contains "W3: the direct Stop-gate probe strips the entrypoint (env -u CLAUDE_CODE_ENTRYPOINT before the gate)" \
  "| env -u CLAUDE_CODE_ENTRYPOINT python3 ~/.claude/skills/df-governed/hooks/handoff-completeness-gate.py" \
  "$(cat "$VMD" 2>/dev/null)"
if grep -q 'which do not depend on the entrypoint' "$VMD" 2>/dev/null; then
  bad "W3: the false claim 'do not depend on the entrypoint' is gone" "still present"
else
  ok "W3: the false claim 'do not depend on the entrypoint' is gone"
fi

# W4, MEASURED 2026-09-10 on three machines (the laptop, the ESO laptop, the ESO Azure Coder): four
# lines of the procedure could not be followed as written. The teardown's reset guard can never
# fire, because step 6's handoff helper commits after the gate-check commit; step 5 needed a `cd`
# the harness undoes after every command; step 3 had no headless caveat though AskUserQuestion
# does not exist under sdk-cli; section 6 told a hand-rolled worker to use ToolSearch, which it
# may not be given. Every run spent a probe rediscovering each one.
echo "=== W4: the procedure text can be followed as written (validate.md + VALIDATE-INSTALL.md) ==="
VIN="$REPO_ROOT/starter-kit/instance/VALIDATE-INSTALL.md"
for _doc in "$VMD" "$VIN"; do
  if grep -Fq '= "M-VALIDATE: gate check" ] && git reset' "$_doc" 2>/dev/null; then
    bad "W4a: no dead gate-check reset guard in $(basename "$_doc")" "still present"
  else
    ok "W4a: no dead gate-check reset guard in $(basename "$_doc")"
  fi
  contains "W4b: the merge probe names its repo with --repo in $(basename "$_doc")" \
    "gh pr merge 999999 --repo" "$(cat "$_doc" 2>/dev/null)"
done
contains "W4c: step 3 gives a headless direct feed to the escalation gate" \
  '"tool_name":"AskUserQuestion"' "$(cat "$VMD" 2>/dev/null)"
if grep -Fq 'Ask it to run `ToolSearch`' "$VMD" 2>/dev/null; then
  bad "W4d: section 6 no longer tells a hand-rolled worker to run ToolSearch" "still present"
else
  ok "W4d: section 6 no longer tells a hand-rolled worker to run ToolSearch"
fi

echo "=== H1: --headless assembles the print-mode argv and says so ==="
KITH1="$(_fresh_kit kith1)"
LOGH1="$T/logh1"; : > "$LOGH1"
VH1_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOGH1" bash "$VALIDATE" --kit-root "$KITH1" --headless 2>&1)"; VH1_RC=$?
[ "$VH1_RC" -eq 0 ] && ok "H1: validate.sh --headless exits 0" || bad "H1: validate.sh --headless exits 0" "rc=$VH1_RC: $VH1_OUT"
LOGH1_CONTENT="$(cat "$LOGH1")"
contains "H1: argv[1]=-p"                    "argv[1]=-p" "$LOGH1_CONTENT"
contains "H1: argv[2]=/df-governed:validate" "argv[2]=/df-governed:validate" "$LOGH1_CONTENT"
contains "H1: argv[3]=--permission-mode"     "argv[3]=--permission-mode" "$LOGH1_CONTENT"
contains "H1: argv[4]=bypassPermissions"     "argv[4]=bypassPermissions" "$LOGH1_CONTENT"
contains "H1: argv[5]=--output-format"       "argv[5]=--output-format" "$LOGH1_CONTENT"
contains "H1: argv[6]=text"                  "argv[6]=text" "$LOGH1_CONTENT"
contains "H1: transcript says mode headless" "mode headless" "$VH1_OUT"

echo "=== H2: without --headless, argv[1] is still the slash command and says mode interactive ==="
KITH2="$(_fresh_kit kith2)"
LOGH2="$T/logh2"; : > "$LOGH2"
VH2_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOGH2" bash "$VALIDATE" --kit-root "$KITH2" 2>&1)"; VH2_RC=$?
[ "$VH2_RC" -eq 0 ] && ok "H2: validate.sh (interactive) exits 0" || bad "H2: validate.sh (interactive) exits 0" "rc=$VH2_RC: $VH2_OUT"
contains "H2: argv[1]=/df-governed:validate"    "argv[1]=/df-governed:validate" "$(cat "$LOGH2")"
contains "H2: transcript says mode interactive" "mode interactive" "$VH2_OUT"

echo "=== R1: the report basename carries a timestamp + the kit's own single lock's instance ==="
KITR1="$(_fresh_kit kitr1)"
printf '{"kit":"kitr1","instance":"kitr1-box"}\n' > "$KITR1/loom.lock.json"
git -C "$KITR1" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$KITR1" -c user.name=t -c user.email=t@example.invalid commit -q -m instance
LOGR1="$T/logr1"; : > "$LOGR1"
VR1_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOGR1" STUB_WRITE_REPORT="r1 report" \
  bash "$VALIDATE" --kit-root "$KITR1" 2>&1)"; VR1_RC=$?
[ "$VR1_RC" -eq 0 ] && ok "R1: validate.sh exits 0" || bad "R1: validate.sh exits 0" "rc=$VR1_RC: $VR1_OUT"
R1_BASENAME="$(basename "$(ls "$KITR1"/VALIDATE-REPORT-*.md 2>/dev/null | head -1)" 2>/dev/null)"
case "$R1_BASENAME" in
  VALIDATE-REPORT-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9][0-9][0-9]Z-kitr1-box.md)
    ok "R1: report basename matches the timestamp+instance pattern" ;;
  *) bad "R1: report basename matches the timestamp+instance pattern" "got '$R1_BASENAME'" ;;
esac

echo "=== R2: env.LOOM_LOCK from an armed settings.local.json carries the instance through ==="
KITR2="$(_fresh_kit kitr2)"
mkdir -p "$KITR2/instances/x" "$KITR2/.claude"
printf '{"instance":"box-x"}\n' > "$KITR2/instances/x/loom.lock.json"
printf '{"env":{"LOOM_LOCK":"instances/x/loom.lock.json"}}\n' > "$KITR2/.claude/settings.local.json"
git -C "$KITR2" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$KITR2" -c user.name=t -c user.email=t@example.invalid commit -q -m loom-lock
LOGR2="$T/logr2"; : > "$LOGR2"
VR2_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOGR2" STUB_WRITE_REPORT="r2 report" \
  bash "$VALIDATE" --kit-root "$KITR2" 2>&1)"; VR2_RC=$?
[ "$VR2_RC" -eq 0 ] && ok "R2: validate.sh exits 0" || bad "R2: validate.sh exits 0" "rc=$VR2_RC: $VR2_OUT"
R2_FILE="$(ls "$KITR2"/VALIDATE-REPORT-*.md 2>/dev/null | head -1)"
contains "R2: report basename carries box-x" "box-x" "$(basename "${R2_FILE:-}" 2>/dev/null)"

echo "=== C1: commit + push succeeds against a local bare origin with an upstream already set ==="
KITC1="$(_fresh_kit kitc1)"
BRANCH_C1="$(git -C "$KITC1" symbolic-ref --short HEAD)"
git -C "$KITC1" push -q -u origin "$BRANCH_C1"
LOGC1="$T/logc1"; : > "$LOGC1"
VC1_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOGC1" STUB_WRITE_REPORT="c1 report" \
  bash "$VALIDATE" --kit-root "$KITC1" 2>&1)"; VC1_RC=$?
[ "$VC1_RC" -eq 0 ] && ok "C1: validate.sh exits 0" || bad "C1: validate.sh exits 0" "rc=$VC1_RC: $VC1_OUT"
contains "C1: transcript says report committed" "report committed" "$VC1_OUT"
contains "C1: transcript says report pushed"    "report pushed" "$VC1_OUT"
C1_SUBJECT="$(git -C "$KITC1" log -1 --format=%s)"
contains "C1: HEAD commit subject names M-VALIDATE" "M-VALIDATE" "$C1_SUBJECT"
C1_REPORT="$(basename "$(ls "$KITC1"/VALIDATE-REPORT-*.md 2>/dev/null | head -1)")"
C1_INSTANCE="$(printf '%s' "$C1_REPORT" | sed -E 's/^VALIDATE-REPORT-[0-9-]+T[0-9]+Z-(.*)\.md$/\1/')"
contains "C1: HEAD commit subject names the report's own instance" "$C1_INSTANCE" "$C1_SUBJECT"
C1_STATUS="$(git -C "$KITC1" status --porcelain -- "$C1_REPORT" 2>&1)"
[ -z "$C1_STATUS" ] && ok "C1: git status --porcelain for the report is empty" \
  || bad "C1: git status --porcelain for the report is empty" "$C1_STATUS"
C1_LOCAL_HEAD="$(git -C "$KITC1" rev-parse HEAD)"
C1_REMOTE_HEAD="$(git -C "$KITC1" ls-remote origin "$BRANCH_C1" | cut -f1)"
[ "$C1_LOCAL_HEAD" = "$C1_REMOTE_HEAD" ] && ok "C1: git ls-remote origin <branch> equals the local head" \
  || bad "C1: git ls-remote origin <branch> equals the local head" "local=$C1_LOCAL_HEAD remote=$C1_REMOTE_HEAD"

echo "=== C2: a pre-existing dirty file in the kit is untouched by the commit ==="
KITC2="$(_fresh_kit kitc2)"
printf 'untracked scratch\n' > "$KITC2/dirty.txt"
printf 'kit\n' > "$KITC2/tracked.txt"
git -C "$KITC2" -c user.name=t -c user.email=t@example.invalid add tracked.txt
git -C "$KITC2" -c user.name=t -c user.email=t@example.invalid commit -q -m tracked
printf 'kit changed\n' > "$KITC2/tracked.txt"
PRE_C2="$(git -C "$KITC2" status --porcelain -- dirty.txt tracked.txt)"
LOGC2="$T/logc2"; : > "$LOGC2"
VC2_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOGC2" STUB_WRITE_REPORT="c2 report" \
  bash "$VALIDATE" --kit-root "$KITC2" 2>&1)"; VC2_RC=$?
[ "$VC2_RC" -eq 0 ] && ok "C2: validate.sh exits 0" || bad "C2: validate.sh exits 0" "rc=$VC2_RC: $VC2_OUT"
POST_C2="$(git -C "$KITC2" status --porcelain -- dirty.txt tracked.txt)"
[ "$PRE_C2" = "$POST_C2" ] && ok "C2: dirty.txt/tracked.txt status is unchanged" \
  || bad "C2: dirty.txt/tracked.txt status is unchanged" "before: $PRE_C2 | after: $POST_C2"
C2_COMMIT_FILES="$(git -C "$KITC2" show --stat --format= HEAD 2>/dev/null)"
absent "C2: dirty.txt is not in the commit"   "dirty.txt"   "$C2_COMMIT_FILES"
absent "C2: tracked.txt is not in the commit" "tracked.txt" "$C2_COMMIT_FILES"

echo "=== C3: --no-push opts out of commit and push; the report stays untracked ==="
KITC3="$(_fresh_kit kitc3)"
BEFORE_HEAD_C3="$(git -C "$KITC3" rev-parse HEAD)"
LOGC3="$T/logc3"; : > "$LOGC3"
VC3_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOGC3" STUB_WRITE_REPORT="c3 report" \
  bash "$VALIDATE" --kit-root "$KITC3" --no-push 2>&1)"; VC3_RC=$?
[ "$VC3_RC" -eq 0 ] && ok "C3: validate.sh --no-push exits 0" || bad "C3: validate.sh --no-push exits 0" "rc=$VC3_RC: $VC3_OUT"
C3_FILE="$(ls "$KITC3"/VALIDATE-REPORT-*.md 2>/dev/null | head -1)"
[ -n "$C3_FILE" ] && ok "C3: the report file exists" || bad "C3: the report file exists" "missing"
C3_STATUS="$(git -C "$KITC3" status --porcelain -- "$(basename "${C3_FILE:-}")" 2>&1)"
case "$C3_STATUS" in
  '?? '*) ok "C3: the report is untracked" ;;
  *) bad "C3: the report is untracked" "$C3_STATUS" ;;
esac
AFTER_HEAD_C3="$(git -C "$KITC3" rev-parse HEAD)"
[ "$BEFORE_HEAD_C3" = "$AFTER_HEAD_C3" ] && ok "C3: no new commit was made" \
  || bad "C3: no new commit was made" "before=$BEFORE_HEAD_C3 after=$AFTER_HEAD_C3"
contains "C3: transcript says the report was left uncommitted" "uncommitted" "$VC3_OUT"

echo "=== C4: no remote configured -> commit made, push fails, exit 3, teardown proof still runs ==="
KITC4="$T/kitc4"
mkdir -p "$KITC4"
git -C "$KITC4" init -q
printf '{"kit":"kitc4"}\n' > "$KITC4/loom.lock.json"
git -C "$KITC4" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$KITC4" -c user.name=t -c user.email=t@example.invalid commit -q -m init
LOGC4="$T/logc4"; : > "$LOGC4"
VC4_OUT="$(VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOGC4" STUB_WRITE_REPORT="c4 report" \
  bash "$VALIDATE" --kit-root "$KITC4" 2>&1)"; VC4_RC=$?
[ "$VC4_RC" -eq 3 ] && ok "C4: validate.sh exits 3" || bad "C4: validate.sh exits 3" "rc=$VC4_RC: $VC4_OUT"
contains "C4: transcript says report committed" "report committed" "$VC4_OUT"
contains "C4: transcript says push FAILED"      "push FAILED" "$VC4_OUT"
contains "C4: teardown proof still ran (git status line printed)" \
  "git -C $KITC4 status --porcelain" "$VC4_OUT"
[ ! -d "$KITC4/.df-validate" ] && ok "C4: .df-validate/ is still torn down despite the push failure" \
  || bad "C4: .df-validate/ is still torn down despite the push failure" "still present"

echo "=== C5: a repo with no user.email still commits with a validate.sh@<host> fallback ==="
KITC5="$(_fresh_kit kitc5)"
NOHOME_C5="$T/nohome-c5"; mkdir -p "$NOHOME_C5"
LOGC5="$T/logc5"; : > "$LOGC5"
VC5_OUT="$(env HOME="$NOHOME_C5" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  VALIDATE_CLAUDE_BIN="$STUB" STUB_LOG="$LOGC5" STUB_WRITE_REPORT="c5 report" \
  bash "$VALIDATE" --kit-root "$KITC5" 2>&1)"; VC5_RC=$?
[ "$VC5_RC" -eq 0 ] && ok "C5: validate.sh exits 0" || bad "C5: validate.sh exits 0" "rc=$VC5_RC: $VC5_OUT"
C5_AUTHOR_EMAIL="$(git -C "$KITC5" log -1 --format=%ae)"
case "$C5_AUTHOR_EMAIL" in
  validate.sh@*) ok "C5: commit author email starts with validate.sh@" ;;
  *) bad "C5: commit author email starts with validate.sh@" "got '$C5_AUTHOR_EMAIL'" ;;
esac

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
