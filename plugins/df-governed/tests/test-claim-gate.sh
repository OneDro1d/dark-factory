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
# scratch()/claimcols() layer DF_SCRATCH / DF_CLAIM_COLUMNS on top of an armed call.
scratch()       { printf '%s' "$3" | env DF_TICKET="$1" DF_SCRATCH="$2" python3 "$HOOK"; }
decide_scratch() { scratch "$1" "$2" "$3" | python3 -c "$CLASSIFY"; }
claimcols()      { printf '%s' "$3" | env DF_TICKET="$1" DF_CLAIM_COLUMNS="$2" python3 "$HOOK"; }
decide_claimcols() { claimcols "$1" "$2" "$3" | python3 -c "$CLASSIFY"; }

# generic() layers DF_CLAIM_TOOL / DF_CLAIM_ITEM_KEYS / DF_CLAIM_VALUES_KEY (and, when
# given, DF_CLAIM_COLUMNS) on top of an armed call — one tracker's shape, generalised.
# vmode is "set" (export DF_CLAIM_VALUES_KEY even when vkey is the empty string — the
# "match tool_input itself" case) or "unset" (do not export DF_CLAIM_VALUES_KEY at all).
# This is the ONLY way the two are told apart, mirroring claim_values_key() itself.
generic() {  # ticket claim_tool item_keys vkey vmode claim_columns event
  local ticket="$1" tool="$2" keys="$3" vkey="$4" vmode="$5" cols="$6" ev="$7"
  local envs=(DF_TICKET="$ticket")
  [ -n "$tool" ] && envs+=(DF_CLAIM_TOOL="$tool")
  [ -n "$keys" ] && envs+=(DF_CLAIM_ITEM_KEYS="$keys")
  if [ "$vmode" = "set" ]; then envs+=(DF_CLAIM_VALUES_KEY="$vkey"); fi
  [ -n "$cols" ] && envs+=(DF_CLAIM_COLUMNS="$cols")
  printf '%s' "$ev" | env "${envs[@]}" python3 "$HOOK"
}
decide_generic() { generic "$1" "$2" "$3" "$4" "$5" "$6" "$7" | python3 -c "$CLASSIFY"; }

ev_tool() {  # hook_event_name cwd tool_name tool_input_json [tool_response_json]
  if [ -n "${5:-}" ]; then
    printf '{"session_id":"t","hook_event_name":"%s","cwd":"%s","tool_name":"%s","tool_input":%s,"tool_response":%s}' "$1" "$2" "$3" "$4" "$5"
  else
    printf '{"session_id":"t","hook_event_name":"%s","cwd":"%s","tool_name":"%s","tool_input":%s}' "$1" "$2" "$3" "$4"
  fi
}

# default_armed(): DF_TICKET set, but DF_CLAIM_TOOL / DF_CLAIM_ITEM_KEYS / DF_CLAIM_VALUES_KEY
# / DF_CLAIM_COLUMNS explicitly UNSET — proves the three new vars change nothing when absent,
# not merely that they happen not to have been set yet in this process.
default_armed() { printf '%s' "$2" | env -u DF_CLAIM_TOOL -u DF_CLAIM_ITEM_KEYS -u DF_CLAIM_VALUES_KEY -u DF_CLAIM_COLUMNS DF_TICKET="$1" python3 "$HOOK"; }
decide_default() { default_armed "$1" "$2" | python3 -c "$CLASSIFY"; }

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
ev_write_cv() {  # cwd itemId columnValues-json-string  (PreToolUse tracker write, columnValues given)
  printf '{"session_id":"t","hook_event_name":"PreToolUse","cwd":"%s","tool_name":"mcp__onedroid__monday-pww__change_item_column_values","tool_input":{"itemId":"%s","boardId":"1","columnValues":%s}}' "$1" "$2" "$3"
}
ev_post_cv() {   # cwd itemId columnValues-json-string  (PostToolUse tracker write, successful)
  printf '{"session_id":"t","hook_event_name":"PostToolUse","cwd":"%s","tool_name":"mcp__onedroid__monday-pww__change_item_column_values","tool_input":{"itemId":"%s","columnValues":%s},"tool_response":{"ok":true}}' "$1" "$2" "$3"
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
# ── 8. DF_SCRATCH: the marker moves with the worker's scratch, not its cwd ─────────────
# ⛔ THE BUG THIS GUARDS. Measured on the first live dispatch (2026-09-05): the worker's
# cwd is not fixed for its whole life — it `cd`s into the repo it was told to edit, and a
# marker written under the OLD cwd is invisible from the new one. A marker appeared in the
# target repo, and the very next call was denied as still-unclaimed.
SCR="$WORK/df-scratch"; mkdir -p "$SCR"
REPO_CWD="$WORK/repo-cwd"; mkdir -p "$REPO_CWD"
equals "S1 DF_SCRATCH set: claim write for THIS item abstains" "abstain" \
  "$(decide_scratch 200 "$SCR" "$(ev_write "$REPO_CWD" 200)")"
scratch 200 "$SCR" "$(ev_post "$REPO_CWD" 200)" >/dev/null
if [ -f "$SCR/.claim-done" ]; then ok "S2 the marker is written under DF_SCRATCH"
else bad "S2 the marker is written under DF_SCRATCH" "no $SCR/.claim-done"; fi
if [ ! -e "$REPO_CWD/.claim-done" ]; then ok "S3 no marker is written under the hook's cwd"
else bad "S3 no marker is written under the hook's cwd" "marker exists at $REPO_CWD/.claim-done"; fi
# The worker then `cd`s again (cwd moves a second time) — DF_SCRATCH must still resolve it.
REPO_CWD2="$WORK/repo-cwd-2"; mkdir -p "$REPO_CWD2"
equals "S4 after cd, DF_SCRATCH still finds the claim (Bash abstains)" "abstain" \
  "$(decide_scratch 200 "$SCR" "$(ev_bash "$REPO_CWD2")")"
# DF_SCRATCH unset -> unchanged, cwd-keyed behaviour (backward compatible).
equals "S5 DF_SCRATCH unset: behaviour is unchanged (cwd-keyed)" "deny" \
  "$(decide_armed 201 "$(ev_bash "$WORK/df-scratch-unused")")"

echo ""
# ── 9. DF_CLAIM_COLUMNS: the claim is validated by CONTENT, not just by shape ──────────
# ⛔ THE BUG THIS GUARDS. Measured same dispatch: unarmed by DF_CLAIM_COLUMNS, ANY write to
# DF_TICKET was accepted as the claim — a worker wrote an email into one text column and
# never touched DF Status, and the gate could not tell that apart from a real claim.
CC='{"text_mm5vefjv": "w@example.invalid", "color_mm5v40tp": {"label": "Doing"}}'
MATCH_CV='{"text_mm5vefjv": "w@example.invalid", "color_mm5v40tp": {"label": "Doing"}}'
MISMATCH_CV='{"text_mm5vefjv": "w@example.invalid"}'
CWD3="$WORK/scratch3"; mkdir -p "$CWD3"

equals "K1 DF_CLAIM_COLUMNS set + matching write: abstains" "abstain" \
  "$(decide_claimcols 300 "$CC" "$(ev_write_cv "$CWD3" 300 "$MATCH_CV")")"
claimcols 300 "$CC" "$(ev_post_cv "$CWD3" 300 "$MATCH_CV")" >/dev/null
if [ -f "$CWD3/.claim-done" ]; then ok "K2 a matching claim writes the marker"
else bad "K2 a matching claim writes the marker" "no $CWD3/.claim-done"; fi

CWD4="$WORK/scratch4"; mkdir -p "$CWD4"
equals "K3 DF_CLAIM_COLUMNS set + mismatching write to DF_TICKET: DENIED" "deny" \
  "$(decide_claimcols 301 "$CC" "$(ev_write_cv "$CWD4" 301 "$MISMATCH_CV")")"
K3_REASON="$(claimcols 301 "$CC" "$(ev_write_cv "$CWD4" 301 "$MISMATCH_CV")" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])')"
contains "K4 the denial names the expected columnValues payload" "text_mm5vefjv" "$K3_REASON"
contains "K5 the denial names the expected status value too" "Doing" "$K3_REASON"
claimcols 301 "$CC" "$(ev_post_cv "$CWD4" 301 "$MISMATCH_CV")" >/dev/null
if [ ! -e "$CWD4/.claim-done" ]; then ok "K6 a mismatching write creates no marker"
else bad "K6 a mismatching write creates no marker" "marker exists"; fi

# columnValues given as an ALREADY-DECODED JSON object (not a string) is handled the same.
CWD5="$WORK/scratch5"; mkdir -p "$CWD5"
OBJ_EVENT='{"session_id":"t","hook_event_name":"PreToolUse","cwd":"'"$CWD5"'","tool_name":"mcp__onedroid__monday-pww__change_item_column_values","tool_input":{"itemId":"302","columnValues":{"text_mm5vefjv":"w@example.invalid","color_mm5v40tp":{"label":"Doing"}}}}'
equals "K7 columnValues as a decoded object (not a string) still matches" "abstain" \
  "$(decide_claimcols 302 "$CC" "$OBJ_EVENT")"

# DF_CLAIM_COLUMNS unset -> unchanged: any write to DF_TICKET is the claim, as before.
CWD6="$WORK/scratch6"; mkdir -p "$CWD6"
equals "K8 DF_CLAIM_COLUMNS unset: old behaviour (any write is the claim)" "abstain" \
  "$(decide_armed 303 "$(ev_write "$CWD6" 303)")"

echo ""
# ── 10. TRACKER-AGNOSTIC: the same claim, a different tracker's shape ──────────────────
# ⛔ THE BUG THIS GUARDS (measured, second live estate). claim-gate.py recognised the claim
# ONLY as tool_name matching the Monday regex, with the item id in itemId/item_id/itemID
# and the values in columnValues. A Notion worker (tool `...notion-update-page`, item id in
# `page_id`, claim fields nested under `properties`) or a Jira worker (tool
# `...jira_update_issue`, item id in `issue_key`, claim fields — assignee/fields — at the
# TOP LEVEL of tool_input, no nested values object at all) can never satisfy that shape and
# is denied every tool call for the whole session.
NOTION_TOOL='^mcp__.*notion.*notion-update-page$'
NOTION_ITEM_KEYS='page_id'
NOTION_VKEY='properties'
NOTION_COLS='{"Claimed By": "dev/x", "Status": "Doing"}'
NOTION_TOOL_NAME='mcp__hub__notion-example__notion-update-page'

CWDN1="$WORK/scratchN1"; mkdir -p "$CWDN1"
NOTION_MATCH_TI='{"page_id":"page-N1","command":"update_properties","properties":{"Claimed By":"dev/x","Status":"Doing"}}'
equals "N1 Notion: a matching write abstains" "abstain" \
  "$(decide_generic page-N1 "$NOTION_TOOL" "$NOTION_ITEM_KEYS" "$NOTION_VKEY" set "$NOTION_COLS" \
      "$(ev_tool PreToolUse "$CWDN1" "$NOTION_TOOL_NAME" "$NOTION_MATCH_TI")")"
generic page-N1 "$NOTION_TOOL" "$NOTION_ITEM_KEYS" "$NOTION_VKEY" set "$NOTION_COLS" \
  "$(ev_tool PostToolUse "$CWDN1" "$NOTION_TOOL_NAME" "$NOTION_MATCH_TI" '{"ok":true}')" >/dev/null
if [ -f "$CWDN1/.claim-done" ]; then ok "N2 Notion: PostToolUse on the matching write creates the marker"
else bad "N2 Notion: PostToolUse on the matching write creates the marker" "no $CWDN1/.claim-done"; fi

# claimed: a write to ANOTHER page_id is denied
equals "N3 Notion: a write to another page_id is DENIED once claimed" "deny" \
  "$(decide_generic page-N1 "$NOTION_TOOL" "$NOTION_ITEM_KEYS" "$NOTION_VKEY" set "$NOTION_COLS" \
      "$(ev_tool PreToolUse "$CWDN1" "$NOTION_TOOL_NAME" '{"page_id":"page-OTHER","properties":{"Claimed By":"dev/x","Status":"Doing"}}')")"

# unclaimed, same page_id, properties missing Status: DENIED, naming the expected values
CWDN2="$WORK/scratchN2"; mkdir -p "$CWDN2"
NOTION_MISS_TI='{"page_id":"page-N2","properties":{"Claimed By":"dev/x"}}'
equals "N4 Notion: properties missing Status is DENIED" "deny" \
  "$(decide_generic page-N2 "$NOTION_TOOL" "$NOTION_ITEM_KEYS" "$NOTION_VKEY" set "$NOTION_COLS" \
      "$(ev_tool PreToolUse "$CWDN2" "$NOTION_TOOL_NAME" "$NOTION_MISS_TI")")"
N4_REASON="$(generic page-N2 "$NOTION_TOOL" "$NOTION_ITEM_KEYS" "$NOTION_VKEY" set "$NOTION_COLS" \
  "$(ev_tool PreToolUse "$CWDN2" "$NOTION_TOOL_NAME" "$NOTION_MISS_TI")" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])')"
contains "N5 the denial names the tool regex"   "$NOTION_TOOL"    "$N4_REASON"
contains "N6 the denial names the item key"     "page_id"         "$N4_REASON"
contains "N7 the denial names the expected values" "Status"       "$N4_REASON"
contains "N8 the denial names the expected values (Doing)" "Doing" "$N4_REASON"
generic page-N2 "$NOTION_TOOL" "$NOTION_ITEM_KEYS" "$NOTION_VKEY" set "$NOTION_COLS" \
  "$(ev_tool PostToolUse "$CWDN2" "$NOTION_TOOL_NAME" "$NOTION_MISS_TI" '{"ok":true}')" >/dev/null
if [ ! -e "$CWDN2/.claim-done" ]; then ok "N9 Notion: a mismatching write creates no marker"
else bad "N9 Notion: a mismatching write creates no marker" "marker exists"; fi

echo ""
# Jira: item id in issue_key; claim fields (assignee) at the TOP LEVEL of tool_input, so
# DF_CLAIM_VALUES_KEY="" — the empty string, EXPLICITLY SET — means "match tool_input itself".
JIRA_TOOL='^mcp__.*jira_update_issue$'
JIRA_ITEM_KEYS='issue_key'
JIRA_COLS='{"assignee": "abc"}'
JIRA_TOOL_NAME='mcp__onedroid__jira_update_issue'

CWDJ1="$WORK/scratchJ1"; mkdir -p "$CWDJ1"
JIRA_MATCH_TI='{"workspace_id":"ws1","issue_key":"TICK-J1","fields":{"foo":"bar"},"assignee":"abc"}'
equals "J1 Jira: a matching write (values key '') abstains" "abstain" \
  "$(decide_generic TICK-J1 "$JIRA_TOOL" "$JIRA_ITEM_KEYS" "" set "$JIRA_COLS" \
      "$(ev_tool PreToolUse "$CWDJ1" "$JIRA_TOOL_NAME" "$JIRA_MATCH_TI")")"
generic TICK-J1 "$JIRA_TOOL" "$JIRA_ITEM_KEYS" "" set "$JIRA_COLS" \
  "$(ev_tool PostToolUse "$CWDJ1" "$JIRA_TOOL_NAME" "$JIRA_MATCH_TI" '{"ok":true}')" >/dev/null
if [ -f "$CWDJ1/.claim-done" ]; then ok "J2 Jira: PostToolUse on the matching write creates the marker"
else bad "J2 Jira: PostToolUse on the matching write creates the marker" "no $CWDJ1/.claim-done"; fi

# a write to the same issue_key whose top-level assignee does not match: DENIED
CWDJ2="$WORK/scratchJ2"; mkdir -p "$CWDJ2"
JIRA_MISS_TI='{"workspace_id":"ws1","issue_key":"TICK-J2","fields":{},"assignee":"someone-else"}'
equals "J3 Jira: a wrong top-level assignee is DENIED" "deny" \
  "$(decide_generic TICK-J2 "$JIRA_TOOL" "$JIRA_ITEM_KEYS" "" set "$JIRA_COLS" \
      "$(ev_tool PreToolUse "$CWDJ2" "$JIRA_TOOL_NAME" "$JIRA_MISS_TI")")"

# DF_CLAIM_VALUES_KEY UNSET (not the empty string) with a Jira-shaped tool must NOT match
# top level — it falls back to the "columnValues" default key, which Jira's shape has none
# of, so parsed_values() finds nothing and the write cannot satisfy the claim.
equals "J4 Jira: DF_CLAIM_VALUES_KEY UNSET does not fall back to top-level matching" "deny" \
  "$(decide_generic TICK-J3 "$JIRA_TOOL" "$JIRA_ITEM_KEYS" "" unset "$JIRA_COLS" \
      "$(ev_tool PreToolUse "$WORK/scratchJ3" "$JIRA_TOOL_NAME" '{"issue_key":"TICK-J3","assignee":"abc"}')")"

echo ""
# ── 11. THE DEFAULT, RE-CONFIRMED: no new env at all, a Monday write is unchanged ───────
# DF_CLAIM_TOOL / DF_CLAIM_ITEM_KEYS / DF_CLAIM_VALUES_KEY / DF_CLAIM_COLUMNS explicitly
# UNSET (not merely never-yet-set) — an unset environment must be byte-for-byte the old gate.
CWDG="$WORK/scratchG"; mkdir -p "$CWDG"
equals "G1 default: a Monday itemId/columnValues write still abstains as the claim" "abstain" \
  "$(decide_default 777 "$(ev_write "$CWDG" 777)")"
default_armed 777 "$(ev_post "$CWDG" 777)" >/dev/null
if [ -f "$CWDG/.claim-done" ]; then ok "G2 default: PostToolUse still writes the marker"
else bad "G2 default: PostToolUse still writes the marker" "no $CWDG/.claim-done"; fi
equals "G3 default: a write to ANOTHER item is still DENIED" "deny" \
  "$(decide_default 777 "$(ev_write "$CWDG" 888)")"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
