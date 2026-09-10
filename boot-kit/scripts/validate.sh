#!/usr/bin/env bash
# validate.sh — the ONE command the installer's final box points at.
#
# Arms a throwaway notepad (validate-arm.sh), opens a fresh session in it running
# `/df-governed:validate`, then tears the scaffolding down and PROVES the tree is clean.
# This is the mechanism half of the fix VALIDATE-INSTALL.md's Part 2 preamble describes: the
# session needs a notepad because every mission-scoped gate walks up from cwd for NOTES.md,
# and it needs to be a FRESH session because a plugin materialised by an install is not
# loaded until the next one starts.
#
# MEASURED 2026-09-08, from `claude --help`: the CLI's own usage line is
# `claude [options] [command] [prompt]`, with a positional `prompt` argument documented as
# "Your prompt" -- an interactive session opened with that argument treats it as the first
# message, the same path a typed `/skill-name` resolves through (documented under --bare:
# "Skills still resolve via /skill-name"). So a slash command IS honoured as the initial
# prompt argument, and it is passed that way below, unquoted-by-shell as a single arg. This
# was checked against --help output, not against a live session -- this script's own
# contract forbids launching a real one to find out, so this is as far as "measured" goes
# without a session, and is why the check is spelled out here rather than assumed silently.
#
# `--headless` runs the session non-interactively, so a run can be started over ssh with no
# TTY: `"$CLAUDE_BIN" -p "/df-governed:validate" --permission-mode bypassPermissions
# --output-format text`. `--permission-mode bypassPermissions` is load-bearing here, not
# decoration -- a `-p` (print-mode) session has no TTY and nobody to answer a permission
# prompt, so without it every tool call the validate skill makes is denied and the run
# reports nothing at all. Interactive mode (no flag) is unchanged. Either way, the mode is
# printed -- `mode headless` / `mode interactive` -- before the session launches.
#
# `--kit-root` overrides discovery. Left unset, the kit root is resolved from a lockfile,
# walking UP from $PWD -- never from $0, because this script is meant to run vendored, under
# a Tier-3 instance's `vendor/dark-factory/boot-kit/scripts/`, where $0's own ancestry is the
# CACHE, not the kit being validated. This is the same walk Task 0 of VALIDATE-INSTALL.md
# does by hand, and the same rule `lock-verify.sh` follows for its `--lock` default.
#
# `--keep` skips teardown (and says so) -- useful for inspecting a failed run by hand. The
# report commit/push (below) still happens under `--keep`: the report lands at the kit root,
# outside the throwaway notepad `--keep` is preserving, so there is nothing for teardown to
# protect it from.
# `VALIDATE_CLAUDE_BIN` overrides the binary, so a test suite can stub it and never launch a
# real session.
#
# The report is named `VALIDATE-REPORT-<date>T<HHMM>Z-<instance>.md` (and, if the session
# raised anything for the operator, `VALIDATE-OPERATOR-TODO-<same stamp>-<instance>.md`
# alongside it). `<instance>` comes from `env.LOOM_LOCK` in the armed notepad's own
# `.claude/settings.json` -- the value validate-arm.sh merged in there: that lockfile's own
# `.instance` field (a string, or `.instance.name` when it is an object). Falling back, in
# order: the kit root's own single `*.lock.json`'s `.instance`; then the literal string
# `kit`. Sanitised to `[A-Za-z0-9._-]` either way, so a stray character in a lockfile can't
# smuggle a path separator into a filename this script is about to `git add`.
#
# The report (and the operator-todo, when one was raised) is committed and pushed FROM THE
# KIT ROOT, default ON. `--no-push` opts out of BOTH the commit and the push -- the file
# still lands at the kit root, just uncommitted. The add AND the commit name their paths,
# never `-A` and never a bare `git commit`, so a kit that was already dirty before this run --
# modified, or already STAGED -- is never swept into the commit (a bare commit takes the whole
# index; measured 2026-09-10 on an ESO Coder holding unrelated staged work). A push failure never loses the commit -- it is
# reported and the script's own exit code becomes 3, but only after the teardown proof below
# has still run and printed.
#
#        5 ANOTHER validate.sh is already running against this same kit root -- refused, and
#          nothing was touched. ⚠️ MEASURED 2026-09-09 on the Poland Coder: two --headless runs
#          were started against one kit a few minutes apart, and the second one's arm re-`git
#          init`ed the SAME .df-validate/ under the first, which was still live. The two
#          sessions then interleaved commits in one repo and each reported on a notepad the
#          other had been rewriting. The step below could not tell a `--keep` LEFTOVER from a
#          RUNNING peer, because nothing recorded an owner; now it does.
#
# Usage: validate.sh [--kit-root <dir> | --kit-root=<dir>] [--keep] [--headless] [--no-push]
# Exit:  0 validated and torn down clean (or --keep, which exits 0 unless the push below
#          failed -- see 3).
#        1 the session ran but teardown left drift.
#        2 bad arguments, no lockfile found, or no claude binary on PATH.
#        3 the report did NOT reach the remote — it is at the kit root, and the line before
#          the exit names which step failed: `git add` (refused, e.g. an ignore rule), `git
#          commit`, or the push. ⚠️ Until 2026-09-10 only a failed PUSH got this code: a failed
#          add went unchecked and a failed commit printed FATAL and then EXITED 0, so a run that
#          persisted nothing looked finished. MEASURED that day on two ESO machines at once —
#          both copied their report, neither committed it, GitHub's push log shows no push from
#          either, and each looked done until someone went looking for the commit.
#        4 the SESSION ITSELF failed (non-zero) -- there is no validation to read. ⚠️ MEASURED
#          2026-09-09 on a Coder workspace: `claude -p` died on an account limit ("You've hit
#          your session limit"), wrote no REPORT.md, and this script exited 0 -- so the caller
#          that reads $? (a remote loop over ssh, a CI step) recorded the box as validated
#          while nothing had been validated at all. SESSION_RC was captured and PRINTED, which
#          is why it read as reported: a human sees the line, no machine ever did. Like 3, this
#          is set aside and applied only AFTER the teardown proof below has run and printed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KIT_ROOT=""
KEEP=0
HEADLESS=0
NO_PUSH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --kit-root)   KIT_ROOT="${2:?--kit-root needs a path}"; shift 2 ;;
    --kit-root=*) KIT_ROOT="${1#--kit-root=}"
                  [ -n "$KIT_ROOT" ] || { echo "FATAL: --kit-root= needs a path" >&2; exit 2; }
                  shift ;;
    --keep) KEEP=1; shift ;;
    --headless) HEADLESS=1; shift ;;
    --no-push) NO_PUSH=1; shift ;;
    -h|--help) sed -n '2,64p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'FATAL unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -z "$KIT_ROOT" ]; then
  d="$PWD"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if ls "$d"/*.lock.json >/dev/null 2>&1; then
      KIT_ROOT="$d"
      break
    fi
    d="$(dirname "$d")"
  done
fi
if [ -z "$KIT_ROOT" ]; then
  printf 'FATAL: no *.lock.json found walking up from %s -- pass --kit-root\n' "$PWD" >&2
  exit 2
fi
[ -d "$KIT_ROOT" ] || { printf 'FATAL: no such directory: %s\n' "$KIT_ROOT" >&2; exit 2; }
KIT_ROOT="$(cd "$KIT_ROOT" && pwd)"

CLAUDE_BIN="${VALIDATE_CLAUDE_BIN:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  printf 'FATAL: no %s on PATH (set VALIDATE_CLAUDE_BIN to override)\n' "$CLAUDE_BIN" >&2
  exit 2
fi

ARM="$HERE/validate-arm.sh"
[ -f "$ARM" ] || { printf 'FATAL: missing sibling script: %s\n' "$ARM" >&2; exit 2; }

# Deliverable B: the <instance> token for the report name. `$2` is the ARMED notepad, whose
# .claude/settings.json carries the env.LOOM_LOCK value validate-arm.sh already resolved (or
# copied from the kit's own settings.local.json) -- this reads that same value rather than
# re-deriving it, so the filename always names the record the session actually ran under.
_resolve_instance() {  # $1 = kit root, $2 = armed notepad -> sanitised instance string
  local kit_root="$1" np="$2" settings lock="" val=""
  settings="$np/.claude/settings.json"
  if [ -f "$settings" ] && command -v jq >/dev/null 2>&1; then
    lock="$(jq -r '.env.LOOM_LOCK // empty' "$settings" 2>/dev/null || true)"
    case "$lock" in
      /*|"") : ;;
      *) lock="$kit_root/$lock" ;;
    esac
  fi
  if [ -n "$lock" ] && [ -f "$lock" ]; then
    val="$(jq -r 'if (.instance|type)=="object" then (.instance.name // empty) else (.instance // empty) end' "$lock" 2>/dev/null || true)"
  fi
  if [ -z "$val" ]; then
    local locks
    locks=("$kit_root"/*.lock.json)
    if [ "${#locks[@]}" -eq 1 ] && [ -f "${locks[0]}" ] && command -v jq >/dev/null 2>&1; then
      val="$(jq -r 'if (.instance|type)=="object" then (.instance.name // empty) else (.instance // empty) end' "${locks[0]}" 2>/dev/null || true)"
    fi
  fi
  [ -n "$val" ] || val="kit"
  val="$(printf '%s' "$val" | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "$val" ] || val="kit"
  printf '%s' "$val"
}

printf 'validate.sh: kit root %s\n' "$KIT_ROOT"

# "Leave the tree as you found it" is measured against how it was FOUND, not against empty.
# A kit that was already dirty before this run (an install that wrote probed.* into the
# lockfile, an operator's uncommitted edit) must not fail teardown for drift it did not cause.
STATUS_BEFORE=""
if git -C "$KIT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  STATUS_BEFORE="$(git -C "$KIT_ROOT" status --porcelain 2>/dev/null || true)"
fi

NP="$KIT_ROOT/.df-validate"
OWNER="$NP/.validate-owner"
# A leftover from a `--keep` run is throwaway by contract; this is the one command the
# installer points at, so it must not strand the user on validate-arm.sh's refusal.
#
# ⛔ BUT A LEFTOVER AND A LIVE PEER LOOK IDENTICAL ON DISK, and until 2026-09-09 this step
# treated both as leftovers. MEASURED that day on the Poland Coder: a second --headless run
# started while the first was still going, `--force`d the same .df-validate/ out from under
# it, re-`git init`ed the notepad, and the two sessions then interleaved commits in one repo
# -- each writing a report about a working directory the other kept rewriting. Neither run
# errored. So the directory now names its owner, and a live owner is refused.
#
# ⚠️ THE PID ALONE IS NOT ENOUGH: pids are reused, and a stale file naming a recycled pid
# would refuse forever for no reason. The command line is checked too, so "alive" means
# "alive AND still a validate.sh", which is the claim being made.
if [ -e "$OWNER" ]; then
  OWNER_PID="$(head -1 "$OWNER" 2>/dev/null || true)"
  case "$OWNER_PID" in
    ''|*[!0-9]*) OWNER_PID="" ;;
  esac
  if [ -n "$OWNER_PID" ] && kill -0 "$OWNER_PID" 2>/dev/null &&
     ps -p "$OWNER_PID" -o command= 2>/dev/null | grep -q 'validate\.sh'; then
    printf 'FATAL: another validate.sh (pid %s) is already running against %s\n' "$OWNER_PID" "$KIT_ROOT" >&2
    printf '       Nothing was touched. Wait for it to finish, or kill it and remove %s\n' "$NP" >&2
    exit 5
  fi
fi
ARM_ARGS=()
if [ -e "$NP" ]; then
  printf 'validate.sh: removing leftover %s from a previous --keep run\n' "$NP"
  ARM_ARGS=(--force)
fi
bash "$ARM" "$KIT_ROOT" "${ARM_ARGS[@]+"${ARM_ARGS[@]}"}" || exit 1

if [ ! -d "$NP" ]; then
  printf 'FATAL: validate-arm.sh reported success but %s is missing\n' "$NP" >&2
  exit 1
fi

# Claim the directory for THIS process, so a concurrent run refuses above instead of forcing
# its way in. Written after the arm, because the arm creates (and with --force recreates) the
# directory. It goes with the notepad at teardown -- there is nothing extra to clean up.
printf '%s\n' "$$" > "$OWNER"

if [ "$HEADLESS" -eq 1 ]; then
  printf 'validate.sh: mode headless\n'
else
  printf 'validate.sh: mode interactive\n'
fi

SESSION_RC=0
if [ "$HEADLESS" -eq 1 ]; then
  ( cd "$NP" && "$CLAUDE_BIN" -p "/df-governed:validate" --permission-mode bypassPermissions --output-format text ) || SESSION_RC=$?
else
  ( cd "$NP" && "$CLAUDE_BIN" "/df-governed:validate" ) || SESSION_RC=$?
fi
printf 'validate.sh: session exited %d\n' "$SESSION_RC"
RUN_FAILED=0
if [ "$SESSION_RC" -ne 0 ]; then
  RUN_FAILED=1
  printf 'validate.sh: the session FAILED -- whatever follows is teardown, not validation\n' >&2
fi

STAMP="$(date -u +%Y-%m-%dT%H%MZ)"
INSTANCE="$(_resolve_instance "$KIT_ROOT" "$NP")"

REPORT_BASENAME=""
if [ -f "$NP/REPORT.md" ]; then
  REPORT_BASENAME="VALIDATE-REPORT-${STAMP}-${INSTANCE}.md"
  cp "$NP/REPORT.md" "$KIT_ROOT/$REPORT_BASENAME"
  printf 'validate.sh: report copied to %s\n' "$KIT_ROOT/$REPORT_BASENAME"
else
  printf 'validate.sh: no REPORT.md in the armed notepad -- nothing copied\n'
  [ "$RUN_FAILED" -eq 0 ] && printf 'validate.sh: WARNING: the session exited 0 and produced NO report -- nothing was validated\n' >&2
fi

# MEASURED 2026-09-08 on the homelab Coder: df-operator-todo resolves the NEAREST notepad —
# which, inside a validate run, is this throwaway one — so anything the session raised for
# the operator was written here and would have been destroyed with the directory. Carry
# every open item out beside the report; an empty page leaves nothing behind.
TODO_BASENAME=""
if [ -f "$NP/operator-todo.md" ] && grep -q '^- \[ \]' "$NP/operator-todo.md"; then
  TODO_BASENAME="VALIDATE-OPERATOR-TODO-${STAMP}-${INSTANCE}.md"
  cp "$NP/operator-todo.md" "$KIT_ROOT/$TODO_BASENAME"
  printf 'validate.sh: the session raised item(s) for the operator -- copied to %s\n' "$KIT_ROOT/$TODO_BASENAME"
fi

# --- Deliverable C: commit + push the report (and any operator-todo) from the kit root ----
# Default ON. `--no-push` opts out of BOTH the commit and the push -- the file still lands
# at the kit root, just uncommitted, so a hand run can inspect it before deciding. Only when
# a report was actually copied AND the kit root is a git work tree: a kit with no report (the
# session raised nothing) or no git history has nothing here to commit.
PUSH_FAILED=0
if [ "$NO_PUSH" -eq 1 ]; then
  if [ -n "$REPORT_BASENAME" ]; then
    printf 'validate.sh: --no-push set, report left uncommitted\n'
  fi
elif [ -n "$REPORT_BASENAME" ] && git -C "$KIT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ADD_PATHS=("$REPORT_BASENAME")
  [ -n "$TODO_BASENAME" ] && ADD_PATHS+=("$TODO_BASENAME")
  # Explicit pathspec, NEVER `-A` -- a pre-existing dirty file in the kit (an operator's
  # uncommitted edit, an install's probed.* write) stays exactly as it was, staged or not.
  # ⚠️ That holds only because the COMMIT below names the same paths. `git add -- <paths>`
  # scopes what is staged, but a bare `git commit` commits the WHOLE index, so work the
  # operator had already staged would have ridden this commit to the remote.
  if ! git -C "$KIT_ROOT" add -- "${ADD_PATHS[@]}"; then
    printf 'validate.sh: FATAL: git add refused the report (git said why, above) -- NOT committed, NOT pushed; it is at %s\n' "$KIT_ROOT/$REPORT_BASENAME" >&2
    PUSH_FAILED=1
  fi

  ID_ARGS=()
  if [ -z "$(git -C "$KIT_ROOT" config user.email 2>/dev/null)" ]; then
    ID_ARGS=(-c "user.name=validate.sh" -c "user.email=validate.sh@$(hostname)")
  fi
  COMMIT_MSG="M-VALIDATE: validation report — ${INSTANCE} ${STAMP} [M-VALIDATE]"
  if [ "$PUSH_FAILED" -eq 0 ] && git -C "$KIT_ROOT" "${ID_ARGS[@]+"${ID_ARGS[@]}"}" commit -q -m "$COMMIT_MSG" -- "${ADD_PATHS[@]}"; then
    COMMIT_SHA="$(git -C "$KIT_ROOT" rev-parse --short HEAD)"
    printf 'validate.sh: report committed %s\n' "$COMMIT_SHA"

    CURRENT_BRANCH="$(git -C "$KIT_ROOT" symbolic-ref --short -q HEAD || true)"
    _push_report() {
      if git -C "$KIT_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        PUSH_OUT="$(git -C "$KIT_ROOT" push 2>&1)"; PUSH_RC=$?
      else
        PUSH_OUT="$(git -C "$KIT_ROOT" push -u origin "$CURRENT_BRANCH" 2>&1)"; PUSH_RC=$?
      fi
    }
    # git's REASON, not its first line. The first line of a rejected push is "To <url>" -- it says
    # where, never why. MEASURED 2026-09-10 on the ESO laptop: the whole diagnostic this script
    # printed was "push FAILED: To <remote url>".
    _push_reason() {
      printf '%s\n' "$PUSH_OUT" | grep -E '^ ?! |^(error|fatal|remote):' | head -3 | tr '\n' ' '
    }
    _push_report
    # ⚠️ ONE record repo serves every machine in an estate (five, on ESO), and every validate run
    # pushes to it -- so "the remote moved since this checkout last pulled" is the NORMAL case,
    # not an edge. MEASURED 2026-09-10: the ESO laptop's push was rejected while a Coder's report
    # and a repin had landed on the same main. Merge the remote in once and push again. A MERGE,
    # never a rebase: it rewrites nothing. git refuses it outright when the index holds staged
    # work or a tracked edit would be overwritten, and a conflict is aborted -- every refusal
    # leaves the report commit exactly where it was and falls through to exit 3 below.
    if [ "$PUSH_RC" -ne 0 ] && printf '%s' "$PUSH_OUT" | grep -qE 'fetch first|non-fast-forward|\[rejected\]'; then
      printf 'validate.sh: push rejected, the remote moved (%s) -- merging origin/%s and retrying once\n' "$(_push_reason)" "$CURRENT_BRANCH"
      if git -C "$KIT_ROOT" fetch -q origin "$CURRENT_BRANCH" 2>/dev/null \
        && git -C "$KIT_ROOT" "${ID_ARGS[@]+"${ID_ARGS[@]}"}" merge -q --no-edit "origin/$CURRENT_BRANCH" >/dev/null 2>&1; then
        _push_report
      else
        git -C "$KIT_ROOT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && git -C "$KIT_ROOT" merge --abort
        PUSH_OUT="the automatic merge of origin/$CURRENT_BRANCH was refused or conflicted, and was aborted -- nothing changed"
        PUSH_RC=1
      fi
    fi
    if [ "$PUSH_RC" -eq 0 ]; then
      REMOTE_URL="$(git -C "$KIT_ROOT" remote get-url origin 2>/dev/null || true)"
      printf 'validate.sh: report pushed to %s (%s)\n' "$REMOTE_URL" "$CURRENT_BRANCH"
    else
      PUSH_WHY="$(_push_reason)"
      [ -n "$PUSH_WHY" ] || PUSH_WHY="$(printf '%s\n' "$PUSH_OUT" | tail -1)"
      printf 'validate.sh: report committed, push FAILED: %s -- finish by hand: git -C %s pull --no-rebase, then git -C %s push\n' "$PUSH_WHY" "$KIT_ROOT" "$KIT_ROOT"
      PUSH_FAILED=1
    fi
  else
    [ "$PUSH_FAILED" -eq 1 ] || printf 'validate.sh: FATAL: git commit failed (see above) -- NOT pushed; the report is at %s\n' "$KIT_ROOT/$REPORT_BASENAME" >&2
    PUSH_FAILED=1
  fi
fi

if [ "$KEEP" -eq 1 ]; then
  printf 'validate.sh: --keep set, leaving %s in place -- teardown skipped\n' "$NP"
  [ "$RUN_FAILED" -eq 1 ] && exit 4
  [ "$PUSH_FAILED" -eq 1 ] && exit 3
  exit 0
fi

# --- teardown, then PROVE it -------------------------------------------------
rm -rf "$NP"
if git -C "$KIT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # ⚠️ MEASURED: --git-path is relative to $KIT_ROOT, not to this script's cwd -- see the
  # matching comment in validate-arm.sh. Same fix, same reason.
  EXCL="$(git -C "$KIT_ROOT" rev-parse --git-path info/exclude 2>/dev/null || true)"
  case "$EXCL" in
    /*) : ;;
    *)  EXCL="$KIT_ROOT/$EXCL" ;;
  esac
  if [ -n "$EXCL" ] && [ -f "$EXCL" ]; then
    grep -vxF '.df-validate/' "$EXCL" > "$EXCL.tmp" 2>/dev/null && mv "$EXCL.tmp" "$EXCL"
  fi
fi

printf 'validate.sh: git -C %s status --porcelain\n' "$KIT_ROOT"
STATUS="$(git -C "$KIT_ROOT" status --porcelain 2>/dev/null || true)"
printf '%s\n' "$STATUS"

printf 'validate.sh: ls .df-validate (must not exist)\n'
LS_OUT="$(cd "$KIT_ROOT" && ls .df-validate 2>&1)"
LS_RC=$?
printf '%s\n' "$LS_OUT"

# "Clean" means: nothing in the status now that was not in it BEFORE arming, except the ONE
# file this run knowingly left behind on purpose (the copied report) -- same rule
# VALIDATE-INSTALL.md's own teardown states for a human doing this by hand: "expect: empty,
# or ONLY files you knowingly changed." Anything else is unexplained and fails the check.
STATUS_UNEXPLAINED="$STATUS"
if [ -n "$STATUS_BEFORE" ]; then
  STATUS_UNEXPLAINED="$(printf '%s\n' "$STATUS_UNEXPLAINED" | grep -vxF -f <(printf '%s\n' "$STATUS_BEFORE") || true)"
fi
if [ -n "$REPORT_BASENAME" ]; then
  STATUS_UNEXPLAINED="$(printf '%s\n' "$STATUS_UNEXPLAINED" | grep -vF "$REPORT_BASENAME" || true)"
fi
if [ -n "$TODO_BASENAME" ]; then
  STATUS_UNEXPLAINED="$(printf '%s\n' "$STATUS_UNEXPLAINED" | grep -vF "$TODO_BASENAME" || true)"
fi

CLEAN=1
[ -z "$STATUS_UNEXPLAINED" ] || CLEAN=0
[ "$LS_RC" -ne 0 ] || CLEAN=0

if [ "$CLEAN" -eq 1 ]; then
  printf 'validate.sh: teardown clean\n'
  [ "$RUN_FAILED" -eq 1 ] && exit 4
  [ "$PUSH_FAILED" -eq 1 ] && exit 3
  exit 0
else
  printf 'validate.sh: teardown left drift -- see status above\n' >&2
  exit 1
fi
