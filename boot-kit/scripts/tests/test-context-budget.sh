#!/usr/bin/env bash
# test-context-budget.sh — hooks/context-budget.py: checkpoint-then-continue, once per crossing.
#
# WHY THIS EXISTS. The gate had no suite at all. On 2026-09-18 it was measured blocking the HoP
# session at 85, 90 and 95% of one climb, each time asking the operator for a /clear the session
# never needed: one auto-compaction (967,138 -> 37,101 tokens) carried it on, crons and Monitors
# intact. These cases pin the behaviour that replaced it:
#   A  the default text is CHECKPOINT-then-CONTINUE and never asks for a /clear
#   B  the threshold scales with the window: 1M fires at 92%, 200k at 80%
#   C  once per crossing: a second turn in the same epoch is allowed
#   D  a compaction (compact_boundary) re-arms it for the next climb
#   E  DF_CONTEXT_GATE_MODE=restart keeps the old hand-off-and-/clear text
#   F  DF_CONTEXT_THRESHOLD still overrides; stop_hook_active and DF_CONTEXT_GATE=off allow
# Hermetic: HOME points at a temp dir, so the learned-window and marker state never touch ~.
#
# Engram is the memory store the checkpoint text names (case A). What it is and how to reach it
# is documented in exactly one place: [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
#
# Run: bash boot-kit/scripts/tests/test-context-budget.sh      Exit 0 = all pass.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
T1="$(cd "$SELF/../../.." && pwd)"
GATE="${CONTEXT_BUDGET:-$T1/hooks/context-budget.py}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# transcript <file> <model> <occupied> [compactions-before] -- one assistant turn at <occupied>
transcript() {
  local f="$1" model="$2" occ="$3" n="${4:-0}" i
  : > "$f"
  for ((i = 0; i < n; i++)); do
    printf '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto"}}\n' >> "$f"
  done
  printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
    "$model" "$occ" >> "$f"
}
# gate <session> <transcript> [extra env...] -> the gate's stdout
gate() {
  local s="$1" t="$2"; shift 2
  printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$s" "$t" \
    | env -u DF_CONTEXT_THRESHOLD -u DF_CONTEXT_WINDOW -u DF_CONTEXT_GATE -u DF_CONTEXT_GATE_MODE \
          HOME="$W/home" "$@" python3 "$GATE"
}
blocked() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("decision")=="block" else 1)'; }
reason()  { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))'; }

echo "=== A: the default is checkpoint-then-continue, and never asks for a /clear ==="
transcript "$W/a.jsonl" claude-opus-5 930000
OUT="$(gate sA "$W/a.jsonl")"
blocked "$OUT" && ok "A: 93% of 1M blocks once" || bad "A: 93% of 1M blocks once" "$OUT"
R="$(reason "$OUT")"
case "$R" in *"Checkpoint, then CONTINUE"*) ok "A: text says checkpoint, then continue";; *) bad "A: text says checkpoint, then continue" "$R";; esac
case "$R" in *"Keep working"*) ok "A: text says keep working";; *) bad "A: text says keep working" "$R";; esac
case "$R" in *"Engram"*) ok "A: the memory-store nudge moved here from PreCompact";; *) bad "A: the memory-store nudge moved here" "$R";; esac
case "$R" in *"safe to /clear"*|*"Do NOT rely on native"*) bad "A: no restart instruction in the default" "$R";; *) ok "A: no restart instruction in the default";; esac

echo "=== B: the threshold scales with the window ==="
transcript "$W/b1.jsonl" claude-opus-5 900000
OUT="$(gate sB1 "$W/b1.jsonl")"
blocked "$OUT" && bad "B: 90% of 1M is under the 92% default" "blocked" || ok "B: 90% of 1M is under the 92% default"
transcript "$W/b2.jsonl" claude-haiku-4-5-20251001 164000
OUT="$(gate sB2 "$W/b2.jsonl")"
blocked "$OUT" && ok "B: 82% of 200k is over the 80% default" || bad "B: 82% of 200k blocks" "$OUT"
transcript "$W/b3.jsonl" claude-haiku-4-5-20251001 156000
OUT="$(gate sB3 "$W/b3.jsonl")"
blocked "$OUT" && bad "B: 78% of 200k is under the 80% default" "blocked" || ok "B: 78% of 200k is under the 80% default"

echo "=== C: once per crossing — the next turn in the same epoch is allowed ==="
transcript "$W/c.jsonl" claude-opus-5 930000
OUT1="$(gate sC "$W/c.jsonl")"
transcript "$W/c.jsonl" claude-opus-5 960000
OUT2="$(gate sC "$W/c.jsonl")"
blocked "$OUT1" && ok "C: first crossing blocks" || bad "C: first crossing blocks" "$OUT1"
blocked "$OUT2" && bad "C: 96% later in the same climb does NOT block again" "$OUT2" || ok "C: 96% later in the same climb does NOT block again"

echo "=== D: a compaction re-arms it ==="
transcript "$W/d.jsonl" claude-opus-5 930000 0
OUT1="$(gate sD "$W/d.jsonl")"
transcript "$W/d.jsonl" claude-opus-5 930000 1
OUT2="$(gate sD "$W/d.jsonl")"
blocked "$OUT1" && ok "D: epoch 0 blocks" || bad "D: epoch 0 blocks" "$OUT1"
blocked "$OUT2" && ok "D: after one compact_boundary, the next climb blocks again" || bad "D: re-armed after compaction" "$OUT2"

echo "=== E: DF_CONTEXT_GATE_MODE=restart keeps the old text ==="
transcript "$W/e.jsonl" claude-opus-5 930000
OUT="$(gate sE "$W/e.jsonl" DF_CONTEXT_GATE_MODE=restart)"
R="$(reason "$OUT")"
case "$R" in *"safe to /clear"*) ok "E: restart mode asks for the /clear, as before";; *) bad "E: restart mode keeps the old text" "$R";; esac

echo "=== F: overrides and exits ==="
transcript "$W/f.jsonl" claude-opus-5 860000
OUT="$(gate sF "$W/f.jsonl" DF_CONTEXT_THRESHOLD=85)"
blocked "$OUT" && ok "F: DF_CONTEXT_THRESHOLD=85 overrides the scaled default" || bad "F: threshold override" "$OUT"
OUT="$(gate sF2 "$W/a.jsonl" DF_CONTEXT_GATE=off)"
[ "$OUT" = "{}" ] && ok "F: DF_CONTEXT_GATE=off allows" || bad "F: gate off allows" "$OUT"
OUT="$(printf '{"session_id":"sF3","transcript_path":"%s","stop_hook_active":true}' "$W/a.jsonl" | HOME="$W/home" python3 "$GATE")"
[ "$OUT" = "{}" ] && ok "F: stop_hook_active never blocks twice in a row" || bad "F: stop_hook_active allows" "$OUT"
OUT="$(printf 'not json' | HOME="$W/home" python3 "$GATE")"; RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "{}" ] && ok "F: malformed stdin allows, exit 0" || bad "F: malformed stdin" "rc=$RC out=$OUT"

echo
echo "passed $PASS  failed $FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
