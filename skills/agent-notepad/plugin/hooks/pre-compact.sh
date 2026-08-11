#!/usr/bin/env bash
# hooks/pre-compact.sh — PreCompact deterministic floor (DESIGN §7.5).
# Before context is compacted/cleared, snapshot recent user-intent + files-touched
# from the transcript, REDACT secrets, and persist so the next session rehydrates:
#   - inside a notepad → refresh a delimited "PreCompact floor" block in NOTES.md
#     AND append a `precompact` milestone entry to the session journal;
#   - outside a notepad → handoff-auto parity: write the snapshot to
#     <cwd>/.claude/handoff/handoff-latest.md (best-effort).
# Never blocks compaction. Emits {} on stdout (valid JSON). EXIT 0 ALWAYS.
set -u
_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/notepad.sh
. "$_DIR/../lib/notepad.sh"
# shellcheck source=../lib/snapshot.sh
. "$_DIR/../lib/snapshot.sh"

done_ok() { printf '{}\n'; exit 0; }

input="$(cat)"
tp="$(printf '%s' "$input"  | jq -r '.transcript_path // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)"
trig="$(printf '%s' "$input" | jq -r '.trigger // "auto"' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

snap="$(extract_snapshot "$tp")"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

np="$(find_notepad "$cwd" 2>/dev/null || true)"

if [ -n "$np" ]; then
  # ── 1) refresh the delimited floor block in NOTES.md (replace prior floor) ──
  notes="$np/NOTES.md"
  [ -f "$notes" ] || : > "$notes"
  begin='<!-- pc-floor:start -->'
  end='<!-- pc-floor:end -->'
  block="$(printf '%s\n## PreCompact floor (deterministic, %s)\n_Auto-written before compaction (trigger=%s, session=%s). Model may fold this into the sections above, then it is safe to drop._\n\n%s\n%s\n' \
             "$begin" "$now" "$trig" "$sid" "$snap" "$end")"
  tmp="$notes.tmp.$$"
  # strip any previous floor block, then append the fresh one
  awk -v b="$begin" -v e="$end" '
    $0==b {skip=1} skip==1 {if($0==e) skip=0; next} {print}
  ' "$notes" > "$tmp" 2>/dev/null || cp "$notes" "$tmp"
  printf '%s\n' "$block" >> "$tmp"
  mv "$tmp" "$notes" 2>/dev/null || true

  # ── 2) append a precompact milestone to the session journal (append-only) ──
  jf=""
  jf="$(ls -1t "$np/sessions/"*.jsonl 2>/dev/null | head -1)"
  if [ -z "$jf" ]; then
    jf="$(new_journal_file "$np" "$sid")"
  fi
  text="$(printf 'PreCompact floor written (trigger=%s)' "$trig")"
  line="$(jq -nc --arg ts "$now" --arg t "$text" --arg s "$sid" \
    '{ts:$ts, kind:"milestone", text:("precompact: " + $t), refs:[], commit:null, session:$s}' 2>/dev/null)"
  [ -z "$line" ] && line="{\"ts\":\"$now\",\"kind\":\"milestone\",\"text\":\"precompact floor\",\"refs\":[],\"commit\":null,\"session\":\"$sid\"}"
  append_journal "$jf" "$line"
else
  # ── outside a notepad: handoff-auto parity (best-effort, non-fatal) ─────────
  hdir="$cwd/.claude/handoff"
  hf="$hdir/handoff-latest.md"
  mkdir -p "$hdir" 2>/dev/null || true
  if should_flush "$hf" "$tp"; then
    tmp="$hf.tmp.$$"
    {
      printf '<!-- handoff session=%s trigger=%s source=deterministic -->\n' "$sid" "$trig"
      printf '## Handoff snapshot (deterministic floor)\n\n%s\n' "$snap"
    } > "$tmp" 2>/dev/null
    mv "$tmp" "$hf" 2>/dev/null || true
  fi
fi

done_ok
