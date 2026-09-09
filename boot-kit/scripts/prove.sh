#!/usr/bin/env bash
# prove.sh — the MECHANICAL half of VALIDATE-INSTALL.md Part 1 (§1-§4), scripted.
#
# WHY THIS EXISTS. That document's own header states the recurring defect: a component
# DECLARED, INSTALLED, and wired to nothing, where every check that looks for a FILE passes
# while the thing does nothing. A human reading that document by hand is the mechanism that
# was supposed to catch it, and a mechanism that only runs when someone remembers to paste a
# markdown file into a fresh session is exactly the kind of check this method keeps finding
# broken elsewhere. This script is the part of that document that never needed a human eye:
# identity, lock-verify, every wired hook fed a real input, two positive controls, preflight,
# and the kit's own suite. Part 2 (continuity, the operator's /clear step) stays human.
#
# NO LLM, NO NETWORK, NO LOGIN, NO WRITE OUTSIDE A TEMP DIR. It never touches `.df/`, the
# lockfile, `$HOME/.claude/settings.json`, or the kit's git tree -- every fixture this script
# builds for itself (P3a's tmpdir, P3b's throwaway git repo) is created under `mktemp -d` and
# removed before the check returns.
#
# Usage:
#   bash boot-kit/scripts/prove.sh [--lock <path>|--lock=<path>] [--kit-root <dir>] [--no-tests]
#
# --lock resolves like lock-verify.sh's own --lock, plus df-preflight's own disambiguation
# when it is OMITTED: search $PWD for *.lock.json and instances/*/loom.lock.json, and if more
# than one exists, narrow by the `machine` block the same way df-preflight.py's find_lock()
# does. Search starts from $PWD, not from $0 -- this script may itself be running from a
# VENDORED copy (<kit>/vendor/dark-factory/boot-kit/scripts/prove.sh), and $0's directory says
# nothing about which INSTANCE is being proven.
#
# --kit-root overrides the walk-up. Default: dirname of the resolved lockfile -- never two
# levels up from $0, for the same vendored-layout reason.
#
# Honoured env: LOCK_VERIFY_CLAUDE_BIN, LOOM_LIVE, LOOM_CLAUDE_JSON, PROVE_SETTINGS (default
# $LOOM_LIVE/settings.json, falling back to ~/.claude/settings.json). All are simply left in
# the environment for the child scripts (lock-verify.sh, df-preflight.py) to inherit; this
# script does not re-parse them except to pick PROVE_SETTINGS's own default.
#
# Checks, each printed as `[Pn] <name>` then one PASS/FAIL/UNKNOWN verdict line:
#   P1  identity           — identify.sh --lock <record>
#   P2  lock-verify        — lock-verify.sh --lock <record>, parses === RESULT:
#   P3  hooks runnable     — every declared hook that is ALSO wired gets fed a benign input
#   P3a compound-bash       — positive control, only if a compound-bash hook is wired
#   P3b commit-gate         — positive control, only if commit-gate.sh is declared
#   P4  preflight           — df-preflight.py --report [--profile <lockfile.defaultProfile>]
#   P5  kit suites          — <kit-root>/boot-kit/scripts/run-tests.sh, skipped by --no-tests
#
# UNKNOWN is a third verdict, never a synonym for PASS or FAIL.
# Exit: 0 PASS (with or without unknowns), 1 FAIL, 2 the harness itself could not run.
set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCK=""
LOCK_GIVEN=0
KITROOT=""
NO_TESTS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lock)      LOCK="${2:?--lock needs a path}"; LOCK_GIVEN=1; shift 2 ;;
    --lock=*)    LOCK="${1#--lock=}"
                 [ -n "$LOCK" ] || { echo "FATAL: --lock= needs a path" >&2; exit 2; }
                 LOCK_GIVEN=1; shift ;;
    --kit-root)  KITROOT="${2:?--kit-root needs a path}"; shift 2 ;;
    --kit-root=*) KITROOT="${1#--kit-root=}"
                 [ -n "$KITROOT" ] || { echo "FATAL: --kit-root= needs a path" >&2; exit 2; }
                 shift ;;
    --no-tests)  NO_TESTS=1; shift ;;
    -h|--help)   sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           printf 'FATAL unknown option: %s\n' "$1" >&2
                 printf '  valid: --lock <path>|--lock=<path>  --kit-root <dir>  --no-tests\n' >&2
                 exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

# ---- resolve the lockfile ---------------------------------------------------
# Mirrors df-preflight.py's find_lock(): every *.lock.json at the search root, plus
# instances/*/loom.lock.json, and -- when more than one exists -- narrow by the `machine`
# block against THIS machine (platform + home; never hostname, which is unstable on both
# Coder and macOS). Search root is $PWD: the natural invocation directory, the same
# convention lock-verify.sh's own bare "loom.lock.json" default already relies on.
resolve_lock() {
  if [ "$LOCK_GIVEN" -eq 1 ]; then
    [ -f "$LOCK" ] || { echo "FATAL: no lockfile at $LOCK" >&2; exit 2; }
    return
  fi
  local base="$PWD"
  local cands=() f
  for f in "$base"/*.lock.json; do
    [ -f "$f" ] && cands+=("$f")
  done
  if [ -d "$base/instances" ]; then
    for f in "$base"/instances/*/loom.lock.json; do
      [ -f "$f" ] && cands+=("$f")
    done
  fi
  if [ "${#cands[@]}" -eq 0 ]; then
    echo "FATAL: no *.lock.json under $base (root) or instances/*/loom.lock.json -- pass --lock" >&2
    exit 2
  fi
  if [ "${#cands[@]}" -eq 1 ]; then
    LOCK="${cands[0]}"
    return
  fi
  local me_home me_plat matched=() h p
  me_home="$HOME"
  me_plat="$(uname -s 2>/dev/null || echo unknown)"
  for f in "${cands[@]}"; do
    h="$(jq -r '.machine.home // empty' "$f" 2>/dev/null)"
    p="$(jq -r '.machine.platform // empty' "$f" 2>/dev/null)"
    [ -n "$h$p" ] || continue
    [ -n "$h" ] && [ "$h" != "$me_home" ] && continue
    [ -n "$p" ] && [ "$p" != "$me_plat" ] && continue
    matched+=("$f")
  done
  if [ "${#matched[@]}" -eq 1 ]; then
    LOCK="${matched[0]}"
    return
  fi
  echo "FATAL: ${#cands[@]} candidate lockfile(s) under $base, ${#matched[@]} match this machine -- pass --lock" >&2
  printf '  %s\n' "${cands[@]}" >&2
  exit 2
}
resolve_lock
LOCK="$(cd "$(dirname "$LOCK")" && pwd)/$(basename "$LOCK")"

# MEASURED 2026-09-09 on a Coder workspace (M-KITLOOP): the default kit root was the lockfile's
# own directory, and an INSTANCE record lives at <kit>/instances/<name>/loom.lock.json -- a
# directory holding the record, MACHINE.md and a `vendor` symlink, never boot-kit/. So P5 looked
# for <kit>/instances/<name>/boot-kit/scripts/run-tests.sh, found nothing, and every install on
# every instance record ended "PROVE: PASS (1 unknown -- P5 kit suites)" while the kit's runner
# sat two levels up. An instance record's kit root is the directory that holds `instances/`; a
# root record's is its own directory; --kit-root overrides both.
if [ -z "$KITROOT" ]; then
  KITROOT="$(dirname "$LOCK")"
  if [ "$(basename "$(dirname "$KITROOT")")" = "instances" ]; then
    KITROOT="$(dirname "$(dirname "$KITROOT")")"
  fi
fi
[ -d "$KITROOT" ] || { echo "FATAL: --kit-root $KITROOT is not a directory" >&2; exit 2; }

LIVE="${LOOM_LIVE:-$HOME/.claude}"
SETTINGS="${PROVE_SETTINGS:-}"
if [ -z "$SETTINGS" ]; then
  if [ -f "$LIVE/settings.json" ]; then SETTINGS="$LIVE/settings.json"
  else SETTINGS="$HOME/.claude/settings.json"
  fi
fi

echo "=== prove ==="
echo "lock     = $LOCK"
echo "kit-root = $KITROOT"
echo "settings = $SETTINGS"
echo ""

# ---- verdict bookkeeping -----------------------------------------------------
TOTAL=0
NFAIL=0
NUNK=0
FAIL_TAGS=()
UNK_TAGS=()

pass()  { printf 'PASS  %s\n' "$1"; TOTAL=$((TOTAL + 1)); }
fail()  { printf 'FAIL  %s\n' "$1"; TOTAL=$((TOTAL + 1)); NFAIL=$((NFAIL + 1)); FAIL_TAGS+=("$2"); }
unk()   { printf 'UNKNOWN  %s\n' "$1"; TOTAL=$((TOTAL + 1)); NUNK=$((NUNK + 1)); UNK_TAGS+=("$2"); }
note()  { printf '    %s\n' "$1"; }
pskip() { printf 'SKIPPED  %s\n' "$1"; }

# feed_hook <command> <json> -> stdout on success; rc left in $? for the caller.
# ${HOME}/$HOME are expanded because settings.json commands carry them literally (the
# lockfile substitutes __HOME__ per machine at hook-copy time, not at settings-write time).
feed_hook() {
  local expanded="$1"
  expanded="${expanded//\$\{HOME\}/$HOME}"
  expanded="${expanded//\$HOME/$HOME}"
  printf '%s' "$2" | bash -c "$expanded" 2>/dev/null
}

# every command string in every event chain of a settings file, the same jq lock-verify's
# L9 uses -- one implementation of "what does this settings.json wire", not two that drift.
settings_cmds() {
  [ -f "$1" ] || return 0
  jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command? // empty] | .[]' "$1" 2>/dev/null
}

# ---- P1: identity -------------------------------------------------------------
echo "[P1] identity"
IDENTIFY="$SELFDIR/identify.sh"
if [ ! -f "$IDENTIFY" ]; then
  unk "identify.sh not present beside prove.sh -- cannot probe identity" "P1 identity"
else
  P1_OUT="$(bash "$IDENTIFY" --lock "$LOCK" 2>&1)"; P1_RC=$?
  case "$P1_RC" in
    0) pass "identify.sh --lock $LOCK: exit 0" ;;
    3)
      P1_LINE="$(printf '%s\n' "$P1_OUT" | grep -m1 'DIFFERENT MACHINE')"
      [ -n "$P1_LINE" ] || P1_LINE="$(printf '%s\n' "$P1_OUT" | grep -m1 '⛔')"
      fail "identify.sh exit 3 -- ${P1_LINE:-no DIFFERENT MACHINE line found}" "P1 identity"
      ;;
    *) unk "identify.sh exited $P1_RC (neither 0 nor 3) -- could not probe cleanly" "P1 identity" ;;
  esac
fi
echo ""

# ---- P2: lock-verify ------------------------------------------------------------
echo "[P2] lock-verify"
LOCKVERIFY="$SELFDIR/lock-verify.sh"
if [ ! -f "$LOCKVERIFY" ]; then
  unk "lock-verify.sh not present beside prove.sh -- cannot verify the lock" "P2 lock-verify"
else
  P2_OUT="$(cd "$KITROOT" && bash "$LOCKVERIFY" --lock "$LOCK" 2>&1)"
  P2_RESULT="$(printf '%s\n' "$P2_OUT" | grep -m1 '^=== RESULT:')"
  case "$P2_RESULT" in
    *"LOCKED (locally)"*) pass "${P2_RESULT#=== }" ;;
    *"LOCKED"*)           pass "${P2_RESULT#=== }" ;;
    *"DRIFT"*)
      fail "lock-verify reported DRIFT" "P2 lock-verify"
      printf '%s\n' "$P2_OUT" | grep '^DRIFT ' | while IFS= read -r l; do note "$l"; done
      ;;
    *) unk "lock-verify.sh produced no === RESULT: line" "P2 lock-verify" ;;
  esac
fi
echo ""

# ---- P3: hooks runnable -----------------------------------------------------
# Only hooks that are BOTH declared AND wired are fed anything -- a declared-but-unwired
# hook is the L9 finding, not this one, and re-judging it here would be the same fact
# reported twice by two checks that could then disagree.
echo "[P3] hooks runnable"
P3_COMPOUND_CMD=""
P3_COMMITGATE_CMD=""
DECLARED_HOOKS="$(jq -r 'if (.install.hooks|type)=="array" then (.install.hooks // [])[] else empty end' "$LOCK" 2>/dev/null)"
if [ -z "$DECLARED_HOOKS" ]; then
  pass "no hooks declared -- nothing to run"
else
  WIRED_CMDS="$(settings_cmds "$SETTINGS")"
  P3_BAD=""
  P3_WIRED_N=0
  P3_UNWIRED=""
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    MATCH="$(printf '%s\n' "$WIRED_CMDS" | grep -F -- "$h" | head -1)"
    if [ -z "$MATCH" ]; then
      REASON="$(jq -r --arg h "$h" '.install.hooksUnwired[$h] // empty' "$LOCK" 2>/dev/null)"
      P3_UNWIRED="$P3_UNWIRED$h${REASON:+ -- $REASON}"$'\n'
      continue
    fi
    P3_WIRED_N=$((P3_WIRED_N + 1))
    case "$h" in *compound-bash*) P3_COMPOUND_CMD="$MATCH" ;; esac
    case "$h" in *commit-gate.sh*) P3_COMMITGATE_CMD="$MATCH" ;; esac

    EXPANDED="${MATCH//\$\{HOME\}/$HOME}"; EXPANDED="${EXPANDED//\$HOME/$HOME}"
    FIRST_TOK="$(awk '{print $1}' <<<"$EXPANDED")"
    if [ -n "$FIRST_TOK" ] && ! command -v "$FIRST_TOK" >/dev/null 2>&1 && [ ! -e "$FIRST_TOK" ]; then
      P3_BAD="${P3_BAD}${h}: wired command's target is missing on disk ($FIRST_TOK); "
      continue
    fi

    TMPDIR_P3="$(mktemp -d "${TMPDIR:-/tmp}/prove-p3.XXXXXX")"
    P3_HOOK_OUT="$(feed_hook "$MATCH" \
      "$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"%s"}' "$TMPDIR_P3")")"
    P3_HOOK_RC=$?
    rm -rf "$TMPDIR_P3"
    if [ "$P3_HOOK_RC" -ne 0 ]; then
      P3_BAD="${P3_BAD}${h}: exit $P3_HOOK_RC on a benign input; "
      continue
    fi
    # Plain text on stdout is a VALID hook output (SessionStart and UserPromptSubmit hooks
    # add it as context), so only output that starts like JSON and fails to parse is judged
    # -- that is a hook whose JSON the harness would reject, not a hook that chose prose.
    case "$P3_HOOK_OUT" in
      \{*)
        if ! jq -e . >/dev/null 2>&1 <<<"$P3_HOOK_OUT"; then
          P3_BAD="${P3_BAD}${h}: printed non-JSON stdout: ${P3_HOOK_OUT:0:120}; "
          continue
        fi
        ;;
    esac
  done <<<"$DECLARED_HOOKS"

  if [ -n "$P3_BAD" ]; then
    fail "$P3_BAD" "P3 hooks runnable"
  elif [ "$P3_WIRED_N" -eq 0 ]; then
    pass "no declared hook is wired in $SETTINGS -- nothing runnable to check"
  else
    pass "$P3_WIRED_N wired, declared hook(s) ran clean on a benign input"
  fi
  if [ -n "$P3_UNWIRED" ]; then
    note "declared but unwired (not judged -- see the lockfile's hooksUnwired):"
    printf '%s' "$P3_UNWIRED" | while IFS= read -r l; do [ -n "$l" ] && note "  $l"; done
  fi
fi
echo ""

# ---- P3a: positive control, compound-bash -----------------------------------
if [ -n "$P3_COMPOUND_CMD" ]; then
  echo "[P3a] positive control, compound-bash"
  TMPDIR_P3A="$(mktemp -d "${TMPDIR:-/tmp}/prove-p3a.XXXXXX")"
  P3A_OUT="$(feed_hook "$P3_COMPOUND_CMD" \
    "$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi && echo there"},"cwd":"%s"}' "$TMPDIR_P3A")")"
  P3A_RC=$?
  rm -rf "$TMPDIR_P3A"
  P3A_BLOCKED=0
  [ "$P3A_RC" -eq 2 ] && P3A_BLOCKED=1
  if [ "$P3A_BLOCKED" -eq 0 ] && printf '%s' "$P3A_OUT" \
      | jq -e 'select(.decision=="block" or .hookSpecificOutput.permissionDecision=="deny")' \
      >/dev/null 2>&1; then
    P3A_BLOCKED=1
  fi
  if [ "$P3A_BLOCKED" -eq 1 ]; then
    pass "compound bash (echo hi && echo there) was blocked"
  else
    fail "gate present, not gating" "P3a compound-bash"
  fi
  echo ""
fi

# ---- P3b: positive control, commit-gate --------------------------------------
if [ -n "$P3_COMMITGATE_CMD" ]; then
  echo "[P3b] positive control, commit-gate"
  REPO_P3B="$(mktemp -d "${TMPDIR:-/tmp}/prove-p3b.XXXXXX")"
  GITC_P3B=(-c user.email=prove@example.com -c user.name=prove)
  git -C "$REPO_P3B" init -q
  mkdir -p "$REPO_P3B/.claude/context" "$REPO_P3B/contracts"
  echo seed > "$REPO_P3B/.claude/context/SERVICE-MAP.md"
  git "${GITC_P3B[@]}" -C "$REPO_P3B" add -A
  git "${GITC_P3B[@]}" -C "$REPO_P3B" commit -q -m seed
  echo "structural change" > "$REPO_P3B/contracts/x.proto"
  git "${GITC_P3B[@]}" -C "$REPO_P3B" add contracts/x.proto
  # PLAIN `git commit`, no `-C` -- the exact shape that shipped broken on 2026-09-08.
  P3B_OUT="$(feed_hook "$P3_COMMITGATE_CMD" \
    "$(printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m probe"},"cwd":"%s"}' "$REPO_P3B")")"
  P3B_RC=$?
  rm -rf "$REPO_P3B"
  P3B_BLOCKED=0
  [ "$P3B_RC" -eq 2 ] && P3B_BLOCKED=1
  if [ "$P3B_BLOCKED" -eq 0 ] && printf '%s' "$P3B_OUT" \
      | jq -e 'select(.decision=="block" or .hookSpecificOutput.permissionDecision=="deny")' \
      >/dev/null 2>&1; then
    P3B_BLOCKED=1
  fi
  if [ "$P3B_BLOCKED" -eq 1 ]; then
    pass "plain git commit with a stale context store was blocked"
  else
    fail "commit gate fails open for plain git commit" "P3b commit-gate"
  fi
  echo ""
fi

# ---- P4: preflight -------------------------------------------------------------
echo "[P4] preflight"
PREFLIGHT="$SELFDIR/df-preflight.py"
if [ ! -f "$PREFLIGHT" ] || ! command -v python3 >/dev/null 2>&1; then
  unk "df-preflight.py or python3 not available -- could not probe the machine" "P4 preflight"
else
  P4_PROFILE="$(jq -r '.defaultProfile // empty' "$LOCK" 2>/dev/null)"
  P4_ARGS=(--report)
  [ -n "$P4_PROFILE" ] && P4_ARGS+=(--profile "$P4_PROFILE")
  P4_OUT="$(cd "$KITROOT" && LOOM_LOCK="$LOCK" python3 "$PREFLIGHT" "${P4_ARGS[@]}" 2>&1)"
  P4_SUMMARY="$(printf '%s\n' "$P4_OUT" | grep -m1 -Eo 'ok=[0-9]+ drift=[0-9]+ unknown=[0-9]+')"
  if [ -z "$P4_SUMMARY" ]; then
    unk "df-preflight.py produced no ok=/drift=/unknown= summary" "P4 preflight"
  else
    P4_DRIFT="$(printf '%s' "$P4_SUMMARY" | sed -n 's/.*drift=\([0-9]*\).*/\1/p')"
    P4_UNK="$(printf '%s' "$P4_SUMMARY" | sed -n 's/.*unknown=\([0-9]*\).*/\1/p')"
    if [ "${P4_DRIFT:-0}" -gt 0 ]; then
      fail "df-preflight: $P4_SUMMARY" "P4 preflight"
      printf '%s\n' "$P4_OUT" | sed -n '/── DRIFT ──/,/^$/p' | while IFS= read -r l; do
        [ -n "$l" ] && note "$l"
      done
    elif [ "${P4_UNK:-0}" -gt 0 ]; then
      pass "df-preflight: $P4_SUMMARY ($P4_UNK unknown)"
    else
      pass "df-preflight: $P4_SUMMARY"
    fi
  fi
fi
echo ""

# ---- P5: kit suites -------------------------------------------------------------
echo "[P5] kit suites"
if [ "$NO_TESTS" -eq 1 ]; then
  pskip "--no-tests: this kit's run-tests.sh was not run"
else
  RUNTESTS="$KITROOT/boot-kit/scripts/run-tests.sh"
  if [ ! -f "$RUNTESTS" ]; then
    unk "this kit ships no runner ($RUNTESTS absent)" "P5 kit suites"
  else
    P5_OUT="$(cd "$KITROOT" && env -u RUN_TESTS_ACTIVE bash "$RUNTESTS" 2>&1)"; P5_RC=$?
    P5_LINE="$(printf '%s\n' "$P5_OUT" | grep -m1 -E '^=== [0-9]+ passed')"
    if [ "$P5_RC" -eq 0 ]; then
      pass "${P5_LINE:-run-tests.sh exited 0}"
    else
      fail "${P5_LINE:-run-tests.sh exited $P5_RC}" "P5 kit suites"
      printf '%s\n' "$P5_OUT" | sed -n '/^Failing suites:/,$p' | while IFS= read -r l; do
        [ -n "$l" ] && note "$l"
      done
    fi
  fi
fi
echo ""

# ---- verdict ---------------------------------------------------------------
if [ "$NFAIL" -gt 0 ]; then
  TAGS=""
  for t in "${FAIL_TAGS[@]}"; do TAGS="${TAGS:+$TAGS, }$t"; done
  echo "=== PROVE: FAIL — $NFAIL of $TOTAL: $TAGS ==="
  exit 1
fi
if [ "$NUNK" -gt 0 ]; then
  TAGS=""
  for t in "${UNK_TAGS[@]}"; do TAGS="${TAGS:+$TAGS, }$t"; done
  echo "=== PROVE: PASS ($NUNK unknown — $TAGS) — say which and why ==="
  exit 0
fi
echo "=== PROVE: PASS — $TOTAL checks, 0 unknown ==="
exit 0
