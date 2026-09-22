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

echo "=== J: RESUME after the clear — a REAL tmux pane, on a PRIVATE server ==="
# ⛔ WHY REAL TMUX. Every case in I stops at a dry run, so no test had ever sent a key. The resume's
# whole job is typing into a live input line: a mocked `tmux` would prove the code calls a
# function, not that text arrives and is submitted. Here a fake TUI echoes what it receives, and
# the assertion is on what is ON THE SCREEN.
# ⛔ ISOLATION IS ASSERTED, NOT ASSUMED. This suite usually runs inside tmux, next to live agent
# sessions. A scratch pane id like %3 can exist on the real server too, so a leaked command would
# type into a stranger's session. Every tmux call below goes to a socket this suite creates, via
# TMUX (which tmux honours when no -S/-L is given) — and J0 proves the server holds nothing else.
if ! command -v tmux >/dev/null 2>&1; then
  echo "  SKIP J: tmux not installed — the resume is untested on this runner"
else
  SOCK="$W/tmux.sock"
  TUI="$W/tui.sh"
  # A fake Claude Code prompt: draw `❯ `, read one line, echo it back, repeat.
  cat > "$TUI" <<'TUI_EOF'
while true; do printf '\n\342\235\257 '; IFS= read -r line || exit 0; printf 'GOT: %s\n' "$line"; done
TUI_EOF
  # A prompt that is NOT empty: a human draft or a permission menu occupies the input line.
  printf 'printf "\\n\\342\\235\\257 %%s" "$1"; sleep 60\n' > "$W/busy.sh"
  tx() { TMUX="$SOCK,0,0" tmux "$@"; }
  newpane() { tmux -S "$SOCK" new-session -d -s "$1" -x 160 -y 40 "$2"; tmux -S "$SOCK" list-panes -t "$1" -F '#{pane_id}'; }
  shown() { tx capture-pane -p -t "$1" 2>/dev/null; }
  wait_shown() { local i; for i in $(seq 1 40); do shown "$1" | grep -qF -- "$2" && return 0; sleep 0.25; done; return 1; }
  helper() {  # helper <pane> <notepad> <t0> <record>
    env TMUX="$SOCK,0,0" DF_CONTEXT_RESUME_SETTLE=0.5 DF_CONTEXT_RESUME_CLEAR_WAIT=4 \
        DF_CONTEXT_RESUME_READY_WAIT=4 python3 "$GATE" --resume-after-clear "$@"
  }
  now() { python3 -c 'import time; print(repr(time.time()))'; }
  mkdir -p "$W/rnp"; printf '# NOTES\n' > "$W/rnp/NOTES.md"; printf 'old floor\n' > "$W/rnp/PRECOMPACT.md"
  mtime "$W/rnp/PRECOMPACT.md" -600

  P1="$(newpane j1 "bash $TUI")"
  # J0 — the private server holds exactly the pane this suite made, and nothing live.
  NS="$(tmux -S "$SOCK" list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"
  [ "$NS" = "1" ] && ok "J0: ISOLATION — the private tmux server holds only this suite's pane" \
                  || bad "J0: ISOLATION — private server holds only our pane" "saw $NS panes"
  wait_shown "$P1" $'\342\235\257' || true

  # J1 — the clear is observed (floor rewritten after the spawn), the prompt is empty and stable:
  # the resume text ARRIVES in the pane and is SUBMITTED (the TUI echoes it after Enter).
  T0="$(now)"; ( sleep 1; touch "$W/rnp/PRECOMPACT.md" ) &
  helper "$P1" "$W/rnp" "$T0" "$W/j1.rec"; wait
  wait_shown "$P1" "GOT: Autoclear just cleared" \
    && ok "J1: REAL pane — the resume text arrived and was submitted with Enter" \
    || bad "J1: resume text arrived and was submitted" "$(shown "$P1" | tail -5)"
  grep -q '^.* RESUMED ' "$W/j1.rec" && ok "J1: the outcome is recorded as RESUMED" \
                                     || bad "J1: outcome recorded" "$(cat "$W/j1.rec" 2>&1)"

  # ⛔ J2 — CONTROL: the clear never happened (floor untouched). It must type NOTHING. Without this
  # case J1 would also pass for a helper that ignores the floor and types on a timer.
  P2="$(newpane j2 "bash $TUI")"; wait_shown "$P2" $'\342\235\257' || true
  mtime "$W/rnp/PRECOMPACT.md" -600
  helper "$P2" "$W/rnp" "$(now)" "$W/j2.rec"
  shown "$P2" | grep -qF "GOT:" && bad "J2: no clear observed — typed nothing" "$(shown "$P2" | tail -3)" \
                                || ok "J2: CONTROL — no clear observed, so it typed NOTHING"
  grep -q 'clear-not-observed' "$W/j2.rec" && ok "J2: and it says why" || bad "J2: says why" "$(cat "$W/j2.rec" 2>&1)"

  # J3 — a HUMAN DRAFT is in the input line. Never type over it, never clear it.
  P3="$(newpane j3 "bash $W/busy.sh HALF-TYPED-BY-A-HUMAN")"; wait_shown "$P3" "HALF-TYPED" || true
  T0="$(now)"; ( sleep 1; touch "$W/rnp/PRECOMPACT.md" ) &
  helper "$P3" "$W/rnp" "$T0" "$W/j3.rec"; wait
  shown "$P3" | grep -qF "Autoclear" && bad "J3: a human draft is never typed over" "$(shown "$P3" | tail -3)" \
                                     || ok "J3: a human's half-typed draft is left alone"
  grep -q 'prompt-never-ready' "$W/j3.rec" && ok "J3: and it says the prompt was never ready" \
                                           || bad "J3: says why" "$(cat "$W/j3.rec" 2>&1)"

  # J4 — the permission menu reuses the ❯ glyph ("❯ 1. Yes"). It is not an empty prompt.
  P4="$(newpane j4 "bash $W/busy.sh '1. Yes'")"; wait_shown "$P4" "1. Yes" || true
  T0="$(now)"; ( sleep 1; touch "$W/rnp/PRECOMPACT.md" ) &
  helper "$P4" "$W/rnp" "$T0" "$W/j4.rec"; wait
  shown "$P4" | grep -qF "Autoclear" && bad "J4: a permission menu is not a prompt" "$(shown "$P4" | tail -3)" \
                                     || ok "J4: the permission menu (❯ 1. Yes) is not mistaken for a prompt"

  # ⛔ J5 — THE WIRING, end to end through the real hook, with REAL keys (no dry run). The pure
  # helper passing J1 proves nothing about whether the Stop hook ever SPAWNS it — the tested-core,
  # untested-wiring shape (Engram `fdf3e309`). Armed, checkpoint fresh, floor wired: the hook must
  # type /clear into the pane AND leave a detached helper that resumes once the clear is observed.
  wire_floor
  mkdir -p "$W/wnp"; printf '# NOTES\n' > "$W/wnp/NOTES.md"; printf 'old\n' > "$W/wnp/PRECOMPACT.md"
  mtime "$W/wnp/PRECOMPACT.md" -600
  P5="$(newpane j5 "bash $TUI")"; wait_shown "$P5" $'\342\235\257' || true
  RS=(TMUX="$SOCK,0,0" TMUX_PANE="$P5" DF_CONTEXT_RESUME_SETTLE=0.5 DF_CONTEXT_RESUME_CLEAR_WAIT=8 DF_CONTEXT_RESUME_READY_WAIT=8)
  ac sJ5 "$W/i.jsonl" "$W/wnp" "${RS[@]}" >/dev/null           # phase 1: arms
  mtime "$W/wnp/NOTES.md" 600                                   # the checkpoint lands
  ac sJ5 "$W/i.jsonl" "$W/wnp" "${RS[@]}" >/dev/null           # phase 2: fires for real
  wait_shown "$P5" "GOT: /clear" && ok "J5: WIRING — the hook typed /clear into the real pane" \
                                 || bad "J5: hook typed /clear" "$(shown "$P5" | tail -4)"
  touch "$W/wnp/PRECOMPACT.md"                                  # SessionEnd(clear) writes the floor
  wait_shown "$P5" "GOT: Autoclear just cleared" \
    && ok "J5: WIRING — the hook's detached helper then resumed the session" \
    || bad "J5: detached helper resumed" "$(shown "$P5" | tail -4)"

  # J6 — DF_CONTEXT_AUTOCLEAR_RESUME=0 is a real off switch: /clear still fires, no resume follows.
  P6="$(newpane j6 "bash $TUI")"; wait_shown "$P6" $'\342\235\257' || true
  mtime "$W/wnp/PRECOMPACT.md" -600
  RS6=(TMUX="$SOCK,0,0" TMUX_PANE="$P6" DF_CONTEXT_AUTOCLEAR_RESUME=0)
  ac sJ6 "$W/i.jsonl" "$W/wnp" "${RS6[@]}" >/dev/null
  mtime "$W/wnp/NOTES.md" 1200
  ac sJ6 "$W/i.jsonl" "$W/wnp" "${RS6[@]}" >/dev/null
  wait_shown "$P6" "GOT: /clear" || true
  touch "$W/wnp/PRECOMPACT.md"; sleep 2
  shown "$P6" | grep -qF "GOT: Autoclear" && bad "J6: RESUME=0 is off" "$(shown "$P6" | tail -3)" \
                                          || ok "J6: DF_CONTEXT_AUTOCLEAR_RESUME=0 fires the clear and resumes nothing"
  # ⛔ J7 — THE HOOK MUST NOT WAIT FOR ITS OWN HELPER. Claude Code reads a hook's stdout through a
  # PIPE and waits for EOF. A detached child that still holds that pipe keeps it open, and the Stop
  # hook hangs for the child's whole life — this estate has lost 14 min to 15 h exactly so (Engram
  # `ab66cd75`, `26c19661`: "& is not a detach under a group-waiting hook harness"). J5 redirected
  # to /dev/null, which cannot see that failure. Here the output is captured through $( ) — a pipe,
  # the way the harness reads it — and the call is timed while the helper is still alive.
  P7="$(newpane j7 "bash $TUI")"; wait_shown "$P7" $'\342\235\257' || true
  mtime "$W/wnp/PRECOMPACT.md" -600
  RS7=(TMUX="$SOCK,0,0" TMUX_PANE="$P7" DF_CONTEXT_RESUME_CLEAR_WAIT=20 DF_CONTEXT_RESUME_READY_WAIT=20)
  ac sJ7 "$W/i.jsonl" "$W/wnp" "${RS7[@]}" >/dev/null
  mtime "$W/wnp/NOTES.md" 1800
  T_START="$(now)"
  OUT7="$(ac sJ7 "$W/i.jsonl" "$W/wnp" "${RS7[@]}")"            # PIPE capture, like the harness
  T_TOOK="$(python3 -c "import sys,time; print('%.1f' % (time.time()-float(sys.argv[1])))" "$T_START")"
  HELPER_ALIVE="$(pgrep -f -- "--resume-after-clear $P7 " >/dev/null && echo yes || echo no)"
  if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 5 else 1)" "$T_TOOK"; then
    ok "J7: the hook returned in ${T_TOOK}s through a PIPE — it does not wait for its helper"
  else
    bad "J7: hook returns without waiting for its helper" "took ${T_TOOK}s — a harness would HANG"
  fi
  # CONTROL: the helper must still be running, or "returned fast" proves nothing — a helper that
  # died at once would also return fast.
  [ "$HELPER_ALIVE" = "yes" ] && ok "J7: CONTROL — the helper was still alive after the hook returned (really detached)" \
                              || bad "J7: CONTROL — helper alive after the hook returned" "no helper process found"
  touch "$W/wnp/PRECOMPACT.md"
  wait_shown "$P7" "GOT: Autoclear just cleared" && ok "J7: and that detached helper still delivered the resume" \
                                                 || bad "J7: detached helper delivered" "$(shown "$P7" | tail -3)"

  # ⛔ J8 — THE OPERATOR'S "gets ready to clear, but something stops before clearing". Phase 1
  # BLOCKS, so the stop ending the checkpoint turn is ALWAYS a re-entry (stop_hook_active=true).
  # The old early return skipped phase 2 there, so an autonomous session that had just
  # checkpointed went idle "ready for autoclear" and never cleared. Measured live 2026-09-22.
  acr() {  # like ac, but a RE-ENTRY stop
    local s="$1" t="$2" c="$3"; shift 3
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":true}' "$s" "$t" "$c" \
      | env -u DF_CONTEXT_THRESHOLD -u DF_CONTEXT_WINDOW -u DF_CONTEXT_GATE \
            -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u TMUX -u TMUX_PANE -u DF_CONTEXT_AUTOCLEAR_DRYRUN \
            HOME="$W/home" DF_CONTEXT_GATE_MODE=autoclear "$@" python3 "$GATE"
  }
  P8="$(newpane j8 "bash $TUI")"; wait_shown "$P8" $'\342\235\257' || true
  mtime "$W/wnp/PRECOMPACT.md" -600
  RS8=(TMUX="$SOCK,0,0" TMUX_PANE="$P8" DF_CONTEXT_RESUME_SETTLE=0.5 DF_CONTEXT_RESUME_CLEAR_WAIT=8 DF_CONTEXT_RESUME_READY_WAIT=8)
  O8A="$(ac sJ8 "$W/i.jsonl" "$W/wnp" "${RS8[@]}")"               # a clean stop: phase 1 arms + BLOCKS
  case "$O8A" in *"AUTOCLEAR IS ARMED"*) ok "J8: a clean stop arms and blocks (phase 1)";; *) bad "J8: phase 1 arms" "$O8A";; esac
  mtime "$W/wnp/NOTES.md" 2400                                    # the checkpoint turn writes NOTES
  O8B="$(acr sJ8 "$W/i.jsonl" "$W/wnp" "${RS8[@]}")"              # ...and ends: a RE-ENTRY stop
  blocked "$O8B" && bad "J8: re-entry never blocks" "$O8B" || ok "J8: the re-entry stop does not block (no loop)"
  wait_shown "$P8" "GOT: /clear" && ok "J8: the RE-ENTRY stop that ends the checkpoint turn FIRES the clear" \
                                 || bad "J8: re-entry fires phase 2" "$(shown "$P8" | tail -3)"
  touch "$W/wnp/PRECOMPACT.md"
  wait_shown "$P8" "GOT: Autoclear just cleared" && ok "J8: ...and the session is resumed" \
                                                 || bad "J8: resumed after a re-entry fire" "$(shown "$P8" | tail -3)"

  # J9 — re-entry with the checkpoint NOT on disk: a refusal would block, so it must ALLOW and
  # change nothing (no disarm), leaving the next clean stop to retry and explain.
  P9="$(newpane j9 "bash $TUI")"; wait_shown "$P9" $'\342\235\257' || true
  RS9=(TMUX="$SOCK,0,0" TMUX_PANE="$P9")
  ac sJ9 "$W/i.jsonl" "$W/wnp" "${RS9[@]}" >/dev/null             # arms
  mtime "$W/wnp/NOTES.md" -3600                                   # checkpoint NOT written
  O9="$(acr sJ9 "$W/i.jsonl" "$W/wnp" "${RS9[@]}")"
  blocked "$O9" && bad "J9: re-entry refusal must not block" "$O9" || ok "J9: re-entry + stale checkpoint: allowed, never blocked"
  sleep 1; shown "$P9" | grep -qF "GOT: /clear" && bad "J9: no clear without a checkpoint" "it cleared" \
                                               || ok "J9: and no clear is typed without the checkpoint on disk"
  [ -e "$W/home/.claude/state/context-budget/sJ9.e0.disarmed" ] && bad "J9: a re-entry refusal must not disarm" "disarmed" \
                                                                 || ok "J9: nor is it disarmed — the next clean stop retries"

  # J10 — re-entry on a session that was NEVER armed must not arm it: arming blocks.
  O10="$(acr sJ10 "$W/i.jsonl" "$W/wnp" TMUX="$SOCK,0,0" TMUX_PANE="$P9")"
  blocked "$O10" && bad "J10: re-entry never arms" "$O10" || ok "J10: a re-entry stop never ARMS (arming would block)"
  [ -e "$W/home/.claude/state/context-budget/sJ10.e0" ] && bad "J10: no marker on re-entry" "marker written" \
                                                        || ok "J10: and writes no arm marker"

  # J11 — the resume is TYPED, so it must be ONE line: in literal typing a newline IS Enter. A custom
  # text with a newline has to arrive as a single submitted line, never cut in half at the newline.
  P11="$(newpane j11 "bash $TUI")"; wait_shown "$P11" $'\342\235\257' || true
  mtime "$W/rnp/PRECOMPACT.md" -600
  T0="$(now)"; ( sleep 1; touch "$W/rnp/PRECOMPACT.md" ) &
  DF_CONTEXT_AUTOCLEAR_RESUME_TEXT=$'FIRST-HALF\nSECOND-HALF' helper "$P11" "$W/rnp" "$T0" "$W/j11.rec"; wait
  wait_shown "$P11" "GOT: FIRST-HALF SECOND-HALF" \
    && ok "J11: a multi-line resume text is typed as ONE line and submitted once" \
    || bad "J11: resume collapsed to one line" "$(shown "$P11" | tail -4)"

  unwire_floor
  tmux -S "$SOCK" kill-server 2>/dev/null || true
fi

echo
echo "passed $PASS  failed $FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
