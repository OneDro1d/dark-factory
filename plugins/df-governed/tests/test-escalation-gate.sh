#!/usr/bin/env bash
# test-escalation-gate.sh — the escalation gate must DENY AskUserQuestion/ExitPlanMode inside a
# RUNNING mission unless a fresh, on-topic escalation file already exists, and must otherwise
# abstain. Style: boot-kit/scripts/tests/test-identify.sh (counters, ok/bad/contains helpers,
# mktemp -d + trap cleanup, non-zero exit on any failure).
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SELF/.." && pwd)"
GATE="$PLUGIN_ROOT/hooks/escalation-gate.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output: $3" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d "${TMPDIR:-/tmp}/esc-gate.XXXXXX")"
trap 'rm -rf "$T"' EXIT

event() {
  # $1 = cwd
  printf '{"session_id":"probe","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[]},"cwd":"%s"}' "$1"
}

echo "=== PROBE 4 (revised): the orchestrator agent ships; settings.agent is deliberately NOT set ==="
# code.claude.com/docs/en/sub-agents: "The subagent's system prompt replaces the default Claude Code
# system prompt entirely" — so a plugin-level agent setting would strip the harness prompt from every
# session. The agent ships for explicit --agent use; the tier is a launch-profile decision.
if [ -f "$PLUGIN_ROOT/agents/df-orchestrator.md" ]; then ok "PROBE4: agents/df-orchestrator.md exists"
else bad "PROBE4: agents/df-orchestrator.md exists" "missing"; fi
if grep -q '^model: inherit' "$PLUGIN_ROOT/agents/df-orchestrator.md"; then ok "PROBE4: model is inherit (no frozen model name)"
else bad "PROBE4: model is inherit" "$(grep '^model:' "$PLUGIN_ROOT/agents/df-orchestrator.md")"; fi
O1="$(jq -r '.settings.agent // "unset"' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
if [ "$O1" = "unset" ]; then ok "PROBE4: plugin.json declares no settings.agent"; else bad "PROBE4: plugin.json declares no settings.agent" "got $O1"; fi
O2="$(jq -r '.agent // "unset"' "$PLUGIN_ROOT/settings.json")"
if [ "$O2" = "unset" ]; then ok "PROBE4: settings.json does not set agent"; else bad "PROBE4: settings.json does not set agent" "got $O2"; fi

echo "=== A: no notepad on the walk-up path -> abstain {} ==="
NOPAD="$T/no-notepad-here"
mkdir -p "$NOPAD"
O="$(event "$NOPAD" | python3 "$GATE")"
if [ "$O" = "{}" ]; then ok "A: exact {}"; else bad "A: exact {}" "$O"; fi
absent "A: no permissionDecision" "permissionDecision" "$O"

echo "=== B: a notepad, but no mission RUNNING at all -> abstain {} ==="
NP="$T/notepad-no-mission"
mkdir -p "$NP"
: > "$NP/NOTES.md"
O="$(event "$NP" | python3 "$GATE")"
if [ "$O" = "{}" ]; then ok "B: exact {}"; else bad "B: exact {}" "$O"; fi

echo "=== C: RUNNING mission, no escalation file at all -> deny ==="
NP="$T/notepad-running-noesc"
mkdir -p "$NP/.df/missions/M-1/escalations"
: > "$NP/NOTES.md"
printf 'RUNNING\n' > "$NP/.df/missions/M-1/state"
O="$(event "$NP" | python3 "$GATE")"
contains "C: denies"                    '"permissionDecision":"deny"' "$(printf '%s' "$O" | tr -d ' ')"
contains "C: names the answer-first line" "Answer it yourself first" "$O"
contains "C: names a category"            "credential" "$O"
contains "C: names the exact path to write" ".df/missions/M-1/escalations" "$O"

echo "=== D: RUNNING mission, a FRESH escalation naming 'credential' -> allow {} ==="
NP="$T/notepad-running-fresh-credential"
mkdir -p "$NP/.df/missions/M-1/escalations"
: > "$NP/NOTES.md"
printf 'RUNNING\n' > "$NP/.df/missions/M-1/state"
printf 'Need a credential only the operator holds: the prod DB password.\n' > "$NP/.df/missions/M-1/escalations/e1.md"
O="$(event "$NP" | python3 "$GATE")"
if [ "$O" = "{}" ]; then ok "D: exact {}"; else bad "D: exact {}" "$O"; fi

echo "=== E: RUNNING mission, escalation exists but is OLDER than TTL -> deny ==="
NP="$T/notepad-running-stale"
mkdir -p "$NP/.df/missions/M-1/escalations"
: > "$NP/NOTES.md"
printf 'RUNNING\n' > "$NP/.df/missions/M-1/state"
printf 'Need a credential only the operator holds.\n' > "$NP/.df/missions/M-1/escalations/old.md"
# backdate the file well past the default 1800s TTL and past a short custom TTL too
OLD_TS="$(( $(date +%s) - 7200 ))"
touch -t "$(date -r "$OLD_TS" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$OLD_TS" +%Y%m%d%H%M.%S)" "$NP/.df/missions/M-1/escalations/old.md" 2>/dev/null
O="$(DF_ESCALATION_TTL=1 event "$NP" | DF_ESCALATION_TTL=1 python3 "$GATE")"
contains "E: denies (stale escalation does not count)" '"permissionDecision": "deny"' "$O"

echo "=== F: RUNNING mission, escalation exists but names NO category -> deny ==="
NP="$T/notepad-running-nocat"
mkdir -p "$NP/.df/missions/M-1/escalations"
: > "$NP/NOTES.md"
printf 'RUNNING\n' > "$NP/.df/missions/M-1/state"
printf 'I would like to ask a question because I am unsure what to do next.\n' > "$NP/.df/missions/M-1/escalations/vague.md"
O="$(event "$NP" | python3 "$GATE")"
contains "F: denies (no category keyword)" '"permissionDecision": "deny"' "$O"

echo "=== G: mission state is DONE, not RUNNING -> abstain {} ==="
NP="$T/notepad-done"
mkdir -p "$NP/.df/missions/M-1/escalations"
: > "$NP/NOTES.md"
printf 'DONE\n' > "$NP/.df/missions/M-1/state"
O="$(event "$NP" | python3 "$GATE")"
if [ "$O" = "{}" ]; then ok "G: exact {}"; else bad "G: exact {}" "$O"; fi

echo "=== H: malformed stdin -> deny with internal error, fails closed ==="
O="$(printf 'not json at all {{{' | python3 "$GATE")"
contains "H: denies"                 '"permissionDecision": "deny"' "$O"
contains "H: names an internal error" "escalation-gate: internal error" "$O"

echo "=== I: claude plugin validate plugins/df-governed passes ==="
if command -v claude >/dev/null 2>&1; then
  VOUT="$(cd "$PLUGIN_ROOT/.." && claude plugin validate "$(basename "$PLUGIN_ROOT")" 2>&1)"; vrc=$?
  echo "$VOUT"
  contains "I: validation passed" "Validation passed" "$VOUT"
  if [ "$vrc" -eq 0 ]; then ok "I: exits 0"; else bad "I: exits 0" "exit $vrc"; fi
else
  bad "I: claude plugin validate" "claude CLI not found on PATH — cannot run this probe here"
fi

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
