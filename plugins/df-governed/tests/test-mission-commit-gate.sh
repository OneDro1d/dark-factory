#!/usr/bin/env bash
# test-mission-commit-gate.sh — the mission predicate, resolved by the SESSION's cwd, not
# the commit's own target.
#
# MEASURED DEFECT this covers (see the hook's own docstring): commit-gate.sh resolves the
# RUNNING mission by walking up from the commit TARGET (`-C <path>` or hook cwd), so from a
# notepad session with a mission RUNNING, `git -C <code repo> commit -m wip` walks up from
# the code repo, finds no notepad, finds no mission, and is ALLOWED. Every case below is RED
# against the previous tree, because this hook did not exist there at all — there is no file
# to import and no behaviour to fall back to; `mission-commit-gate.py` is entirely new.
#
# Cases (SPEC letters):
#   A  notepad cwd + RUNNING mission + `git -C <code repo> commit -m wip` -> DENY, naming the
#      mission and both accepted forms.
#   B  same with a message naming the mission, and with a message naming a tracker id -> {}.
#   C  cwd is a CODE repo with no notepad above it -> {} even with -m wip.
#   D  notepad cwd, mission state DONE -> {}.
#   E  env -C <repo>, cd <repo> &&, bash -c "..." wrappers -> DENY (wrappers do not relocate
#      the session).
#   F  -F msg.txt naming the mission -> {}; unreadable file -> DENY.
#   G  -C HEAD reuse -> DENY; no -m at all -> DENY; --no-verify -m wip -> DENY, reason says
#      --no-verify does not bypass.
#   H  malformed stdin -> {} + systemMessage "internal error", exit 0.
#   I  a non-commit git command (git status, git push) -> {}.
#
# This hook never shells out to git itself (it is a pure string/token parser over the Bash
# tool_input.command), so none of the fixtures below need to be real git repositories —
# plain directories with or without a NOTES.md marker are enough to exercise notepad
# resolution, and the "commit target" named in -C/cd/env never needs to exist on disk at all.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SELF/../hooks/mission-commit-gate.py"
[ -f "$HOOK" ] || { echo "missing $HOOK"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

# HERMETIC TO THE DISPATCH ENVIRONMENT — see lib/dispatch-env-scrub.sh: a df-dispatched
# worker's own process carries DF_TICKET/DF_SCRATCH/... and WORKER_*, none of which this hook
# reads, but scrub_dispatch_env is the house discipline for every gate suite regardless, so a
# suite run BY a dispatched worker never inherits ambient state its own cases did not declare.
T1="$(cd "$SELF/../../.." && pwd)"
# shellcheck source=boot-kit/scripts/tests/lib/dispatch-env-scrub.sh
source "$T1/boot-kit/scripts/tests/lib/dispatch-env-scrub.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains()     { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output: $3" ;; esac; }
not_contains() { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output: $3" ;; *) ok "$1" ;; esac; }
equals()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2' got '$3'"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mcg.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ── fixture builders ────────────────────────────────────────────────────────────────
mk_notepad() {  # mk_notepad <dir> -- prints the dir back
  local dir="$1"
  mkdir -p "$dir/.df/missions"
  printf 'notes\n' > "$dir/NOTES.md"
  printf '%s' "$dir"
}

mk_running() {  # mk_running <notepad> <mission_id>
  local notepad="$1" id="$2"
  mkdir -p "$notepad/.df/missions/$id"
  printf 'RUNNING\n' > "$notepad/.df/missions/$id/state"
}

mk_done() {  # mk_done <notepad> <mission_id>
  local notepad="$1" id="$2"
  mkdir -p "$notepad/.df/missions/$id"
  printf 'DONE\n' > "$notepad/.df/missions/$id/state"
}

# A plain directory, never given a NOTES.md -- stands in for a code repo commit TARGET (or,
# when used as cwd, for a session that is not inside any notepad).
mk_bare_dir() {
  mktemp -d "${TMPDIR:-/tmp}/mcgdir.XXXXXX"
}

# ── invoking the hook, hermetically ─────────────────────────────────────────────────
build_event() {  # build_event <cwd> <command> -- python builds the JSON so no manual
  # shell/JSON escaping is needed for messages containing quotes, spaces, etc.
  python3 -c '
import json, sys
cwd, cmd = sys.argv[1], sys.argv[2]
print(json.dumps({"hook_event_name": "PreToolUse", "cwd": cwd,
                   "tool_name": "Bash", "tool_input": {"command": cmd}}))
' "$1" "$2"
}

run_hook() {  # run_hook <cwd> <command> -- routes the ACTUAL hook invocation (not the JSON
  # builder above) through scrub_dispatch_env, per house discipline.
  build_event "$1" "$2" | scrub_dispatch_env python3 "$HOOK"
}

MISSION_ID="M-PROBE-1"

echo "=== A: notepad cwd + RUNNING mission + commit into a DIFFERENT (code) repo -- DENY ==="
NOTEPAD_A="$(mk_notepad "$T/notepad-a")"
mk_running "$NOTEPAD_A" "$MISSION_ID"
CODEREPO_A="$(mk_bare_dir)"
O="$(run_hook "$NOTEPAD_A" "git -C $CODEREPO_A commit -m wip")"; rc=$?
equals   "A: exits 0 (decision is in the JSON, not the exit code)" "0" "$rc"
contains "A: denies" "permissionDecision" "$O"
contains "A: reason names the RUNNING mission" "$MISSION_ID" "$O"
contains "A: reason names the tracker-id form" "1[0-9]{10,}" "$O"
contains "A: reason names the mission-id form" "M-[A-Z0-9][A-Z0-9-]{3,}" "$O"

echo "=== B: a message naming the mission, or a tracker id, satisfies the rule -- {} ==="
O="$(run_hook "$NOTEPAD_A" "git -C $CODEREPO_A commit -m \"$MISSION_ID: x\"")"
equals "B: message naming the mission id allows" "{}" "$O"
O="$(run_hook "$NOTEPAD_A" "git -C $CODEREPO_A commit -m \"close 12983000509\"")"
equals "B: message naming a tracker id allows" "{}" "$O"

echo "=== C: cwd is a CODE repo with no notepad above it -- {} even with -m wip ==="
CODEREPO_C="$(mk_bare_dir)"
O="$(run_hook "$CODEREPO_C" "git commit -m wip")"
equals "C: no notepad above cwd allows unconditionally" "{}" "$O"

echo "=== D: notepad cwd, mission state DONE -- {} ==="
NOTEPAD_D="$(mk_notepad "$T/notepad-d")"
mk_done "$NOTEPAD_D" "$MISSION_ID"
O="$(run_hook "$NOTEPAD_D" "git commit -m wip")"
equals "D: a DONE (not RUNNING) mission allows" "{}" "$O"

echo "=== E: wrapper spellings do not relocate the SESSION -- still DENY ==="
CODEREPO_E="$(mk_bare_dir)"
for CMD in \
  "env -C $CODEREPO_E git commit -m wip" \
  "cd $CODEREPO_E && git commit -m wip" \
  "bash -c 'git commit -m wip'"; do
  O="$(run_hook "$NOTEPAD_A" "$CMD")"
  contains "E: seen and denied: $CMD" "permissionDecision" "$O"
  contains "E: reason still names the mission: $CMD" "$MISSION_ID" "$O"
done

echo "=== F: -F message file -- content naming the mission allows, unreadable denies ==="
printf '%s: picking this up\n' "$MISSION_ID" > "$NOTEPAD_A/msg.txt"
O="$(run_hook "$NOTEPAD_A" "git -C $CODEREPO_A commit -F msg.txt")"
equals "F: -F file content naming the mission allows" "{}" "$O"
O="$(run_hook "$NOTEPAD_A" "git -C $CODEREPO_A commit -F does-not-exist.txt")"
contains "F: unreadable -F file denies" "permissionDecision" "$O"
contains "F: reason names the unreadable file" "does-not-exist.txt" "$O"

echo "=== G: -C reuse denies; no -m at all denies; --no-verify does not bypass ==="
O="$(run_hook "$NOTEPAD_A" "git -C $CODEREPO_A commit -C HEAD")"
contains "G: -C (reuse) message denies" "permissionDecision" "$O"
contains "G: reason says the message is not inspectable" "not inspectable" "$O"
O="$(run_hook "$NOTEPAD_A" "git -C $CODEREPO_A commit --allow-empty")"
contains "G: no -m/-F/--message at all denies" "permissionDecision" "$O"
contains "G: reason says an editor would open" "editor would open" "$O"
O="$(run_hook "$NOTEPAD_A" "git -C $CODEREPO_A commit --no-verify -m wip")"
contains "G: --no-verify -m wip (unnamed message) still denies" "permissionDecision" "$O"
contains "G: reason says --no-verify does not bypass" "does not bypass" "$O"

echo "=== H: malformed stdin -- {} plus systemMessage naming an internal error, exit 0 ==="
O="$(printf 'not json at all' | scrub_dispatch_env python3 "$HOOK")"; rc=$?
contains     "H: surfaces a systemMessage" "systemMessage" "$O"
contains     "H: names an internal error" "internal error" "$O"
not_contains "H: never denies on malformed input (fails OPEN)" "permissionDecision" "$O"
equals       "H: still exits 0" "0" "$rc"

echo "=== I: a non-commit git command is not this hook's business -- {} ==="
O="$(run_hook "$NOTEPAD_A" "git status")"
equals "I: git status allows" "{}" "$O"
O="$(run_hook "$NOTEPAD_A" "git -C $CODEREPO_A push origin main")"
equals "I: git push allows" "{}" "$O"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
