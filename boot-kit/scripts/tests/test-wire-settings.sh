#!/usr/bin/env bash
# test-wire-settings.sh — installing a hook is TWO acts, and the installer only did one.
#
# ⚠️ WHY THIS EXISTS. `install.sh` copies a hook file into ~/.claude/hooks and then tells the
# operator, in prose, to copy the settings template by hand. Every hook declared since a
# machine's last hand-copy therefore sat on disk INERT while the install printed
# `install complete`. Measured twice: 15 declared / 8 wired on an ESO Coder after a reset, and
# mission-completeness-gate.py on the Poland Coder on 2026-09-03.
#
# A required manual step that silently no-ops is the defect, not a safety feature. The caution
# that IS warranted is about clobbering the operator's own file — so every case below is as
# much about what this script REFUSES to touch as about what it wires.
#
# Engram is one of the memory stores whose hooks this wires. What it is and how to reach it is
# documented in exactly one place:
# [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
W8="$SELF/../wire-settings.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wire8.XXXXXX")"
trap 'rm -rf "$T"' EXIT
H="$T/home"
mkdir -p "$H/.claude/hooks"

TMPL="$T/settings.json.template"
cat > "$TMPL" <<'JSON'
{
  "outputStyle": "Loom Voice",
  "permissions": { "allow": ["Bash"] },
  "hooks": {
    "Stop": [ { "matcher": "", "hooks": [
      { "type": "command", "command": "__HOME__/.claude/hooks/gate.py" } ] } ],
    "SessionStart": [ { "matcher": "", "hooks": [
      { "type": "command", "command": "__HOME__/.claude/hooks/boot.sh" } ] } ]
  }
}
JSON

run() { python3 "$W8" --template "$TMPL" --live "$1" --home "$H" ${2:-} 2>&1; }

echo "=== A: no live settings — write the rendered template whole ==="
L="$T/a.json"
O="$(run "$L")"
contains "A: says it wrote the template"  "writing the rendered template" "$O"
if [ -f "$L" ]; then ok "A: the file exists"; else bad "A: the file exists" "nothing written"; fi
# ⚠️ RENDERED, not copied: a literal __HOME__ in a live settings file is a path that cannot exist.
absent   "A: __HOME__ was substituted"    "__HOME__"                      "$(cat "$L")"
contains "A: the real home is in the path" "$H/.claude/hooks/gate.py"     "$(cat "$L")"

# ⚠️ AND --dry-run MUST NOT CLAIM A WRITE IT DID NOT MAKE. This branch said "writing the
# rendered template whole" under --dry-run and wrote nothing. Caught by the rehydrate suite,
# not by this one — a dry run that reports a write it never performed is the same lie as an
# install reporting a wiring it never did, smaller and in the same direction.
L="$T/a-dry.json"
O="$(run "$L" --dry-run)"
contains "A: --dry-run says so on the no-live-file path" "dry run" "$O"
if [ -f "$L" ]; then bad "A: --dry-run creates no file" "it wrote one"
else ok "A: --dry-run creates no file"; fi

echo "=== B: an existing file is MERGED, never clobbered ==="
L="$T/b.json"
cat > "$L" <<JSON
{ "model": "opus", "permissions": { "allow": ["Read"] },
  "hooks": { "Stop": [ { "matcher": "", "hooks": [
    { "type": "command", "command": "$H/.claude/hooks/mine.sh" } ] } ] } }
JSON
O="$(run "$L")"
contains "B: the missing hook is added"        "gate.py"        "$O"
contains "B: the other event is added too"     "boot.sh"        "$O"
# ⚠️ THE WHOLE POINT. The operator's own keys and their own hook must survive untouched.
contains "B: the operator's hook survives"     "mine.sh"        "$(cat "$L")"
contains "B: an unrelated key survives"        '"model"'        "$(cat "$L")"
# ⚠️ permissions is a SECURITY POSTURE. An installer that quietly widens it is a worse bug
# than an unwired hook, so a difference is reported and never applied.
contains "B: permissions are NOT overwritten"  '"Read"'         "$(cat "$L")"
absent   "B: permissions were not widened"     '"Bash"'         "$(cat "$L")"
contains "B: but the difference is reported"   "NOT changed"    "$O"

echo "=== C: idempotent — a second run changes nothing ==="
O="$(run "$L")"
contains "C: says there is nothing to do" "already wired" "$O"
absent   "C: adds nothing"                "+ Stop"        "$O"

echo "=== D: \$HOME and a rendered path are ONE file, not two ==="
# ⚠️ A template renders to an absolute path while a hand-wired entry may say $HOME/... .
# Comparing the strings would wire the same hook TWICE — and a hook that fires twice looks
# like it is working, which is worse than one that does not fire. lock-verify L9 normalises
# both spellings for the same reason.
L="$T/d.json"
cat > "$L" <<'JSON'
{ "hooks": { "Stop": [ { "matcher": "", "hooks": [
  { "type": "command", "command": "$HOME/.claude/hooks/gate.py" } ] } ] } }
JSON
O="$(HOME="$H" run "$L")"
absent "D: a \$HOME-spelled entry is not re-added" "+ Stop" "$O"

echo "=== E: arguments do not make one hook into two ==="
L="$T/e.json"
cat > "$L" <<JSON
{ "hooks": { "Stop": [ { "matcher": "", "hooks": [
  { "type": "command", "command": "$H/.claude/hooks/gate.py --verbose" } ] } ] } }
JSON
O="$(run "$L")"
absent "E: the same hook with arguments is not re-added" "+ Stop" "$O"

echo "=== F: unparseable live settings is a REFUSAL, not an overwrite ==="
# ⚠️ Claude Code cannot read it either, so nothing is wired right now — but it is the
# operator's file and may be one comma from correct. Overwriting trades a visible breakage
# for an invisible loss.
L="$T/f.json"
printf '{ "hooks": THIS IS NOT JSON\n' > "$L"
BEFORE="$(cat "$L")"
O="$(run "$L")"
contains "F: refuses"                    "REFUSING to overwrite" "$O"
if [ "$(cat "$L")" = "$BEFORE" ]; then ok "F: the file is untouched"
else bad "F: the file is untouched" "it was overwritten"; fi
if python3 "$W8" --template "$TMPL" --live "$L" --home "$H" >/dev/null 2>&1; then
  bad "F: exits non-zero" "a refusal that exits 0 is invisible to the installer"
else ok "F: exits non-zero"; fi

echo "=== G: --dry-run writes nothing ==="
L="$T/g.json"
cat > "$L" <<'JSON'
{ "hooks": {} }
JSON
BEFORE="$(cat "$L")"
O="$(run "$L" --dry-run)"
contains "G: reports what it would add" "gate.py" "$O"
contains "G: says nothing was written"  "dry run" "$O"
if [ "$(cat "$L")" = "$BEFORE" ]; then ok "G: the file is unchanged"
else bad "G: the file is unchanged" "--dry-run wrote to disk"; fi

echo "=== H: a real write leaves a backup ==="
L="$T/h.json"
cat > "$L" <<'JSON'
{ "model": "keep-me", "hooks": {} }
JSON
O="$(run "$L")"
contains "H: names the backup" "backup:" "$O"
BK="$(ls "$T"/h.json.bak.* 2>/dev/null | head -1)"
if [ -n "$BK" ]; then ok "H: the backup exists"; else bad "H: the backup exists" "none written"; fi
contains "H: the backup holds the PRE-write content" "keep-me" "$(cat "$BK")"
absent   "H: and not the new wiring"                 "gate.py" "$(cat "$BK")"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
