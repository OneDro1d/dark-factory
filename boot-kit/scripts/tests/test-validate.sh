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
