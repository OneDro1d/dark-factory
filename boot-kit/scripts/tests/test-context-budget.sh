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
# ⚠️ Every event carries a cwd INSIDE the temp dir. The gate reads autoCompactWindow from project
# settings by walking up from the session's cwd; without one it walked up from the real shell cwd
# to the real ~/.claude/settings.json and read this machine's value (measured: case B went red).
mkdir -p "$W/plain"
gate() {
  local s="$1" t="$2"; shift 2
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$s" "$t" "$W/plain" \
    | env -u DF_CONTEXT_THRESHOLD -u DF_CONTEXT_WINDOW -u DF_CONTEXT_GATE -u DF_CONTEXT_GATE_MODE \
          -u CLAUDE_CODE_AUTO_COMPACT_WINDOW HOME="$W/home" "$@" python3 "$GATE"
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

echo "=== G: the AUTO-COMPACT window, not the model window, is what the gate scales to ==="
# ⛔ 2026-09-18: `autoCompactWindow: 300000` makes a 1M-window session compact at ~300k. Scaled
# to the model window the gate would wait for 920k and never fire before compaction.
mkdir -p "$W/home/.claude"
printf '{"autoCompactWindow": 300000}\n' > "$W/home/.claude/settings.json"
gatecwd() { local s="$1" t="$2" c="$3"; shift 3
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$s" "$t" "$c" \
    | env -u DF_CONTEXT_THRESHOLD -u DF_CONTEXT_WINDOW -u DF_CONTEXT_GATE -u DF_CONTEXT_GATE_MODE \
          -u CLAUDE_CODE_AUTO_COMPACT_WINDOW HOME="$W/home" "$@" python3 "$GATE"; }
mkdir -p "$W/plain"
transcript "$W/g1.jsonl" claude-opus-5 250000
OUT="$(gatecwd sG1 "$W/g1.jsonl" "$W/plain")"
blocked "$OUT" && ok "G: user autoCompactWindow 300k: 250k (83%) blocks on a 1M model" || bad "G: 250k of a 300k window blocks" "$OUT"
case "$(reason "$OUT")" in *"compaction at 300000"*) ok "G: the reason names the compaction window and its source";;
  *) bad "G: names the compaction window" "$(reason "$OUT")";; esac
transcript "$W/g2.jsonl" claude-opus-5 200000
OUT="$(gatecwd sG2 "$W/g2.jsonl" "$W/plain")"
blocked "$OUT" && bad "G: 200k (66%) of a 300k window stays quiet" "blocked" || ok "G: 200k (66%) of a 300k window stays quiet"
# per-notepad override: a project settings file beats the user one, as in the harness
mkdir -p "$W/notepad/.claude" "$W/notepad/sub"
printf '{"autoCompactWindow": 600000}\n' > "$W/notepad/.claude/settings.json"
OUT="$(gatecwd sG3 "$W/g1.jsonl" "$W/notepad/sub")"
blocked "$OUT" && bad "G: a notepad's own autoCompactWindow (600k) overrides the user 300k" "blocked at 250k" \
               || ok "G: a notepad's own autoCompactWindow (600k) overrides the user 300k"
# the env var outranks every settings file
OUT="$(gatecwd sG4 "$W/g2.jsonl" "$W/notepad/sub" CLAUDE_CODE_AUTO_COMPACT_WINDOW=220000)"
blocked "$OUT" && ok "G: CLAUDE_CODE_AUTO_COMPACT_WINDOW outranks the settings files" || bad "G: env outranks settings" "$OUT"
rm -f "$W/home/.claude/settings.json"

echo "=== H: the window a session STARTED with, not the one on disk now ==="
# ⛔ 2026-09-18: the harness reads autoCompactWindow once, at process start. Sessions started before
# the settings changed to 300k still compact at ~967k, and a gate reading settings at each Stop told
# one at ~350k "116% of the window". SessionStart(startup|resume) now records the value per session.
start() { local s="$1" src="$2"
  printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"%s","cwd":"%s"}' "$s" "$src" "$W/plain" \
    | env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW HOME="$W/home" python3 "$GATE"; }
# H1: started with no autoCompactWindow (1M model window, compacts at ~967k); settings now say 300k
OUT="$(start sH1 startup)"
[ "$OUT" = "{}" ] && ok "H: SessionStart prints {} (never blocks)" || bad "H: SessionStart prints {}" "$OUT"
[ -f "$W/home/.claude/state/context-budget/sH1.window.json" ] && ok "H: SessionStart records the window" \
  || bad "H: SessionStart records the window" "no record"
printf '{"autoCompactWindow": 300000}\n' > "$W/home/.claude/settings.json"
transcript "$W/h1.jsonl" claude-opus-5 280000
OUT="$(gate sH1 "$W/h1.jsonl")"
blocked "$OUT" && bad "H: started at 1M, settings now 300k: 280k (93% of 300k) stays quiet" "$(reason "$OUT")" \
               || ok "H: started at 1M, settings now 300k: 280k (93% of 300k) stays quiet"
transcript "$W/h1b.jsonl" claude-opus-5 350000
OUT="$(gate sH1b "$W/h1b.jsonl")"
blocked "$OUT" && bad "H: no record, 350k held under a 300k setting: the setting is disproven, no fire" "$(reason "$OUT")" \
               || ok "H: no record, 350k held under a 300k setting: the setting is disproven, no fire"
# H2: a fresh session started under 300k fires as today
OUT="$(start sH2 startup)"
transcript "$W/h2.jsonl" claude-opus-5 250000
OUT="$(gate sH2 "$W/h2.jsonl")"
blocked "$OUT" && ok "H: fresh session at 300k: 250k blocks as today" || bad "H: fresh session at 300k blocks" "$OUT"
case "$(reason "$OUT")" in *"recorded at session startup"*) ok "H: the reason names the recorded source";;
  *) bad "H: names the recorded source" "$(reason "$OUT")";; esac
# H3: compact and clear keep the record; a later settings change does not reach the session
OUT="$(start sH3 startup)"
printf '{"autoCompactWindow": 600000}\n' > "$W/home/.claude/settings.json"
OUT="$(start sH3 compact)"
transcript "$W/h3.jsonl" claude-opus-5 250000
OUT="$(gate sH3 "$W/h3.jsonl")"
blocked "$OUT" && ok "H: settings moved to 600k after start, compact did not overwrite: 250k still blocks" \
               || bad "H: the record survives compact and a settings change" "$OUT"
# H4: resume re-reads settings, as the harness does
OUT="$(start sH4 startup)"
printf '{"autoCompactWindow": 300000}\n' > "$W/home/.claude/settings.json"
OUT="$(start sH4 resume)"
transcript "$W/h4.jsonl" claude-opus-5 250000
OUT="$(gate sH4 "$W/h4.jsonl")"
blocked "$OUT" && ok "H: resume re-records: 600k at start, 300k at resume, 250k blocks" || bad "H: resume re-records" "$OUT"
rm -f "$W/home/.claude/settings.json"

echo "=== I: DF_CONTEXT_GATE_MODE=autoclear — two phases, and every precondition checked at FIRE time ==="
# ⚠️ TMUX/TMUX_PANE are INHERITED, and this suite is usually run from inside tmux. Left alone the
# cases would pass for the wrong reason on a developer's box and fail in CI. Every call below
# strips both and sets them back explicitly, so the pane is an INPUT to the test, never ambient.
mkdir -p "$W/np/sessions"
printf '# NOTES\n' > "$W/np/NOTES.md"
mtime() { python3 -c 'import os,sys,time; os.utime(sys.argv[1], (time.time()+float(sys.argv[2]),)*2)' "$1" "$2"; }
wire_floor() {
  mkdir -p "$W/home/.claude"
  printf '{"hooks":{"SessionEnd":[{"matcher":"clear","hooks":[{"type":"command","command":"/x/agent-notepad/hooks/pre-compact.sh"}]}]}}\n' \
    > "$W/home/.claude/settings.json"
}
unwire_floor() { rm -f "$W/home/.claude/settings.json"; }
# ac <session> <transcript> <cwd> [extra env...] — autoclear mode, tmux stripped unless re-set
ac() {
  local s="$1" t="$2" c="$3"; shift 3
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$s" "$t" "$c" \
    | env -u DF_CONTEXT_THRESHOLD -u DF_CONTEXT_WINDOW -u DF_CONTEXT_GATE \
          -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u TMUX -u TMUX_PANE -u DF_CONTEXT_AUTOCLEAR_DRYRUN \
          HOME="$W/home" DF_CONTEXT_GATE_MODE=autoclear "$@" python3 "$GATE"
}
transcript "$W/i.jsonl" claude-opus-5 930000

# I1 — phase 1 is still a block, with the autoclear text rather than the checkpoint text
OUT="$(ac sI1 "$W/i.jsonl" "$W/np")"
R="$(reason "$OUT")"
blocked "$OUT" && ok "I1: phase 1 blocks" || bad "I1: phase 1 blocks" "$OUT"
case "$R" in *"AUTOCLEAR IS ARMED"*) ok "I1: phase 1 says autoclear is armed";; *) bad "I1: phase 1 says autoclear is armed" "$R";; esac
case "$R" in *"DISCARDS the window"*) ok "I1: phase 1 says a clear discards, unlike a compaction";; *) bad "I1: phase 1 warns it discards" "$R";; esac

# ⛔ I2 — THE INTERLOCK. Pane present, floor NOT wired: the clear must refuse, because after a
# /clear there would be nothing mechanical left. This is the case that makes autoclear safe to
# enable on a machine whose fleet pin does not yet carry the floor.
unwire_floor
OUT="$(ac sI1 "$W/i.jsonl" "$W/np" TMUX=/tmp/fake,1,0 TMUX_PANE=%9)"
R="$(reason "$OUT")"
case "$R" in *"floor writer is NOT wired"*) ok "I2: INTERLOCK — no floor wiring, the clear refuses";; *) bad "I2: INTERLOCK — no floor wiring refuses" "$R";; esac
case "$R" in *"now disarmed"*) ok "I2: an environment precondition disarms rather than nags";; *) bad "I2: disarms" "$R";; esac
OUT="$(ac sI1 "$W/i.jsonl" "$W/np" TMUX=/tmp/fake,1,0 TMUX_PANE=%9)"
blocked "$OUT" && bad "I2: once disarmed it stays quiet" "$OUT" || ok "I2: once disarmed it stays quiet"

# I3 — no tmux pane at all: no actuator, so no fire
OUT="$(ac sI3 "$W/i.jsonl" "$W/np")"
OUT="$(ac sI3 "$W/i.jsonl" "$W/np")"
R="$(reason "$OUT")"
case "$R" in *"no tmux pane"*) ok "I3: no pane — nothing to type into, so it does not fire";; *) bad "I3: no pane does not fire" "$R";; esac

# I4 — pane + floor wired, but NOTES.md is OLDER than the marker: the checkpoint never landed.
# Retryable, because that one IS the agent's to fix.
wire_floor
OUT="$(ac sI4 "$W/i.jsonl" "$W/np" TMUX=/tmp/fake,1,0 TMUX_PANE=%9)"
mtime "$W/np/NOTES.md" -600
OUT="$(ac sI4 "$W/i.jsonl" "$W/np" TMUX=/tmp/fake,1,0 TMUX_PANE=%9)"
R="$(reason "$OUT")"
case "$R" in *"not touched since the gate armed"*) ok "I4: a stale NOTES.md is not a checkpoint";; *) bad "I4: stale NOTES.md blocks the fire" "$R";; esac
case "$R" in *"try again"*) ok "I4: a missing checkpoint is retryable, not disarming";; *) bad "I4: missing checkpoint is retryable" "$R";; esac

# I5 — every precondition met: it fires (dry run, so no keys reach a real terminal).
OUT="$(ac sI5 "$W/i.jsonl" "$W/np" TMUX=/tmp/fake,1,0 TMUX_PANE=%9)"
mtime "$W/np/NOTES.md" 600
OUT="$(ac sI5 "$W/i.jsonl" "$W/np" TMUX=/tmp/fake,1,0 TMUX_PANE=%9 DF_CONTEXT_AUTOCLEAR_DRYRUN=1)"
R="$(reason "$OUT")"
case "$R" in *"would have sent /clear"*) ok "I5: CONTROL — with every precondition met it DOES reach the fire path";; *) bad "I5: CONTROL — it reaches the fire path" "$R";; esac
# ⛔ Without I5 the four refusals above prove nothing: a gate that never fires refuses everything,
# and every one of those cases would still be green. I5 is what makes them meaningful.

# I6 — no notepad above cwd: nothing to clear into
mkdir -p "$W/bare"
OUT="$(ac sI6 "$W/i.jsonl" "$W/bare" TMUX=/tmp/fake,1,0 TMUX_PANE=%9)"
OUT="$(ac sI6 "$W/i.jsonl" "$W/bare" TMUX=/tmp/fake,1,0 TMUX_PANE=%9)"
R="$(reason "$OUT")"
case "$R" in *"no notepad above cwd"*) ok "I6: no NOTES.md above cwd — it does not fire";; *) bad "I6: no notepad does not fire" "$R";; esac

# I7 — the DEFAULT mode is untouched by all of this: a second turn in the epoch still just allows
OUT="$(gate sI7 "$W/i.jsonl")"
OUT="$(gate sI7 "$W/i.jsonl")"
blocked "$OUT" && bad "I7: checkpoint mode still fires once per crossing" "$OUT" || ok "I7: checkpoint mode still fires once per crossing"
unwire_floor

echo
echo "passed $PASS  failed $FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
