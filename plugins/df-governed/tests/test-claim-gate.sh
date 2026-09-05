#!/usr/bin/env bash
# test-claim-gate.sh — the claim, made mechanical.
#
# ⛔ THE BUG THIS GUARDS. The claim used to be a sentence in the worker's prompt ("FIRST
# ACTION: set Claimed By ... claim BEFORE any work"). It was skipped, and nothing noticed,
# because the thing that would have noticed is the tracker row the worker never wrote. A
# race is closed by the process that owns the race, not by asking a model to remember.
#
# Two properties are asserted, and they are different properties:
#   ARMED     — with DF_TICKET set, no tool call but the claim write is permitted until the
#               claim lands, and no OTHER item may be written afterwards.
#   INERT     — with DF_TICKET unset, every event returns `{}`. This is not politeness: the
#               same gate loaded in an orchestrator's own session would deny every tool
#               call until it claimed a ticket it does not have, i.e. brick it.
#
# Every case asserts the DECISION parsed out of the hook's JSON, never a substring of it,
# and every invocation must exit 0 — a non-zero exit is a hook error, not a policy decision.
#
# Enrolled by GLOB — a suite is enrolled by existing.
#
# Usage: bash plugins/df-governed/tests/test-claim-gate.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SELF/../hooks/claim-gate.py"
[ -f "$HOOK" ] || { echo "missing $HOOK"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
equals() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2' got '$3'"; fi; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claimgate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CWD="$WORK/scratch"
mkdir -p "$CWD"

CLASSIFY='import json,sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("NOT-JSON"); raise SystemExit(0)
if d == {}:
    print("abstain")
else:
    print(((d.get("hookSpecificOutput") or {}).get("permissionDecision")) or "MALFORMED")'

# armed: DF_TICKET set.  bare: DF_TICKET removed from the environment entirely.
armed() { printf '%s' "$2" | env DF_TICKET="$1" python3 "$HOOK"; }
bare()  { printf '%s' "$1" | env -u DF_TICKET python3 "$HOOK"; }
decide_armed() { armed "$1" "$2" | python3 -c "$CLASSIFY"; }
decide_bare()  { bare "$1"      | python3 -c "$CLASSIFY"; }

ev_bash() {   # cwd
  printf '{"session_id":"t","hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"ls"}}' "$1"
}
ev_write() {  # cwd itemId  (PreToolUse tracker write)
  printf '{"session_id":"t","hook_event_name":"PreToolUse","cwd":"%s","tool_name":"mcp__onedroid__monday-pww__change_item_column_values","tool_input":{"itemId":"%s","boardId":"1","columnValues":"{}"}}' "$1" "$2"
}
ev_post() {   # cwd itemId  (PostToolUse tracker write, successful)
  printf '{"session_id":"t","hook_event_name":"PostToolUse","cwd":"%s","tool_name":"mcp__onedroid__monday-pww__change_item_column_values","tool_input":{"itemId":"%s"},"tool_response":{"ok":true}}' "$1" "$2"
}
ev_post_err() {
  printf '{"session_id":"t","hook_event_name":"PostToolUse","cwd":"%s","tool_name":"mcp__onedroid__monday-pww__change_item_column_values","tool_input":{"itemId":"%s"},"tool_response":{"is_error":true}}' "$1" "$2"
}

# ── 1. INERT with no DF_TICKET ──────────────────────────────────────────────────────────
equals "C1 unarmed: Bash abstains"                 "abstain" "$(decide_bare "$(ev_bash "$CWD")")"
equals "C2 unarmed: a tracker write abstains"      "abstain" "$(decide_bare "$(ev_write "$CWD" 999)")"
bare "$(ev_bash "$CWD")" >/dev/null 2>&1
equals "C3 unarmed: exit 0"                        "0" "$?"
if [ ! -e "$CWD/.claim-done" ]; then ok "C4 unarmed: no marker is created"
else bad "C4 unarmed: no marker is created" "marker exists"; fi

# ── 2. ARMED, unclaimed ─────────────────────────────────────────────────────────────────
equals "C5 armed+unclaimed: Bash is DENIED"                 "deny"    "$(decide_armed 123 "$(ev_bash "$CWD")")"
equals "C6 armed+unclaimed: a write to ANOTHER item is DENIED" "deny" "$(decide_armed 123 "$(ev_write "$CWD" 456)")"
equals "C7 armed+unclaimed: the claim write for THIS item abstains" "abstain" "$(decide_armed 123 "$(ev_write "$CWD" 123)")"

REASON="$(armed 123 "$(ev_bash "$CWD")" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])')"
contains "C8 the denial names the item id"   "123"                        "$REASON"
contains "C9 the denial names the tool"      "change_item_column_values"  "$REASON"

# ── 3. the claim lands ──────────────────────────────────────────────────────────────────
equals "C10 PostToolUse on the claim abstains" "abstain" "$(decide_armed 123 "$(ev_post "$CWD" 123)")"
if [ -f "$CWD/.claim-done" ]; then ok "C11 PostToolUse creates the marker"
else bad "C11 PostToolUse creates the marker" "no $CWD/.claim-done"; fi

# ── 4. ARMED, claimed ───────────────────────────────────────────────────────────────────
equals "C12 armed+claimed: Bash abstains"                    "abstain" "$(decide_armed 123 "$(ev_bash "$CWD")")"
equals "C13 armed+claimed: a write to ANOTHER item is DENIED" "deny"   "$(decide_armed 123 "$(ev_write "$CWD" 456)")"
equals "C14 armed+claimed: a write to THIS item abstains"     "abstain" "$(decide_armed 123 "$(ev_write "$CWD" 123)")"

# ── 5. a FAILED claim must not unlock the gate ──────────────────────────────────────────
CWD2="$WORK/scratch2"; mkdir -p "$CWD2"
decide_armed 123 "$(ev_post_err "$CWD2" 123)" >/dev/null
if [ ! -e "$CWD2/.claim-done" ]; then ok "C15 a failed claim write creates no marker"
else bad "C15 a failed claim write creates no marker" "marker exists"; fi
decide_armed 123 "$(ev_post "$CWD2" 456)" >/dev/null
if [ ! -e "$CWD2/.claim-done" ]; then ok "C16 a claim on ANOTHER item creates no marker"
else bad "C16 a claim on another item creates no marker" "marker exists"; fi
equals "C17 that scratch is still locked" "deny" "$(decide_armed 123 "$(ev_bash "$CWD2")")"

# ── 6. the marker is per-cwd, not global ────────────────────────────────────────────────
# Two workers share a machine; one worker's claim must not unlock another's session.
equals "C18 a claimed cwd does not unlock a different cwd" "deny" "$(decide_armed 123 "$(ev_bash "$WORK")")"

# ── 7. FAIL CLOSED ──────────────────────────────────────────────────────────────────────
# ⛔ A gate that cannot evaluate has decided nothing. Reading that as permission is exactly
# how the claim gets skipped again — so armed + broken input is a DENY, never an allow.
equals "C19 armed: malformed stdin DENIES"   "deny"    "$(decide_armed 123 'not json at all')"
contains "C20 the deny says it is an internal error" "internal error" \
  "$(printf 'not json at all' | env DF_TICKET=123 python3 "$HOOK")"
equals "C21 unarmed: malformed stdin abstains" "abstain" "$(decide_bare 'not json at all')"
printf 'not json' | env DF_TICKET=123 python3 "$HOOK" >/dev/null 2>&1
equals "C22 a policy decision still exits 0"  "0" "$?"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
