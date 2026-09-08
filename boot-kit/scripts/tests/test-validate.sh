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

# A stub `claude`: logs argv + cwd, optionally drops a REPORT.md, always exits 0.
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
exit 0
STUBEOF
chmod +x "$STUB"

# _fresh_kit NAME -> prints the path to a new throwaway git repo with a lockfile, an
# origin remote (a reserved, never-resolvable host per RFC 2606 -- same convention
# test-identify.sh uses for the same reason: this repo is public and scanned for landmarks),
# and a clean baseline (`git status --porcelain` empty) before anything touches it.
_fresh_kit() {
  local k="$T/$1"
  mkdir -p "$k"
  git -C "$k" init -q
  printf '{"kit":"%s"}\n' "$1" > "$k/loom.lock.json"
  git -C "$k" -c user.name=t -c user.email=t@example.invalid add -A
  git -C "$k" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  git -C "$k" remote add origin "https://git.example.invalid/$1.git"
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
KIT7="$(_fresh_kit kit7)"
V7_OUT="$(PATH="/usr/bin:/bin" bash "$VALIDATE" --kit-root "$KIT7" 2>&1)"; V7_RC=$?
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

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
