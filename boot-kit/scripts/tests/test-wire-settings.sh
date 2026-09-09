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

echo "=== I: the LOCKFILE is the authority, not the shared template ==="
# ⛔ MEASURED ON THE POLAND CODER 2026-09-03, the day the wiring step shipped. The settings
# template is SHARED across instances; the lockfile is PER-INSTANCE. Wiring the whole template
# put three hooks into that box that its lockfile declares nowhere — it has no <sibling-org-layer> lane,
# and its own $hookBumpNote records removing the <sibling-org-layer> hooks on 2026-08-31. lock-verify L9
# caught it from the other side: "wired in settings but NOT PRESENT on disk — the chain breaks
# every session."
#
# **Lockfiles are the authority; installers are only mechanism.** This was a mechanism that
# ignored the lockfile.
LOCK="$T/lock.json"
cat > "$LOCK" <<'JSON'
{ "instance": "t-declares-one", "install": { "hooks": ["gate.py"] } }
JSON

L="$T/i.json"
cat > "$L" <<'JSON'
{ "hooks": {} }
JSON
O="$(python3 "$W8" --template "$TMPL" --live "$L" --home "$H" --lock "$LOCK" 2>&1)"
contains "I: a declared hook is still wired"           "gate.py"   "$O"
absent   "I: an UNDECLARED template hook is not wired" "+ SessionStart" "$O"
absent   "I: and it is not in the live file"           "boot.sh"   "$(cat "$L")"
# ⚠️ REPORTED, NEVER SILENT. A skip nobody can see is indistinguishable from a check that
# never ran — the defect class this whole session was spent removing.
contains "I: the skip is reported"                     "NOT wired" "$O"
contains "I: and names the reason"                     "not declared by THIS lockfile" "$O"

# the fresh-machine path must filter too — it is where the damage is greatest, because
# nothing is wired yet so every undeclared entry lands at once
L2="$T/i-fresh.json"
O="$(python3 "$W8" --template "$TMPL" --live "$L2" --home "$H" --lock "$LOCK" 2>&1)"
contains "I: the no-live-file path filters too"        "does not declare" "$O"
absent   "I: undeclared hook absent from a fresh file" "boot.sh"   "$(cat "$L2")"

echo "=== J: --prune-broken repairs a chain that names a missing file ==="
# ⚠️ THE ONLY REMOVAL THIS TOOL WILL EVER MAKE, gated three ways: wired, file ABSENT, and the
# flag passed. Such an entry is not the operator's working config — it errors on every event,
# and nothing is lost because the file it names is not there to run. Removing anything whose
# file EXISTS would be clobbering; the last assertion here guards exactly that.
mkdir -p "$H/.claude/hooks"
printf '#!/bin/sh\n' > "$H/.claude/hooks/gate.py"
L3="$T/j.json"
cat > "$L3" <<JSON
{ "hooks": { "Stop": [ { "matcher": "", "hooks": [
  { "type": "command", "command": "$H/.claude/hooks/ghost-that-is-absent.sh" },
  { "type": "command", "command": "$H/.claude/hooks/gate.py" } ] } ] } }
JSON
O="$(python3 "$W8" --template "$TMPL" --live "$L3" --home "$H" --lock "$LOCK" 2>&1)"
contains "J: a broken chain is reported by default" "breaks every session" "$O"
contains "J: the live file is untouched by default" "ghost-that-is-absent" "$(cat "$L3")"
contains "J: and it names the opt-in remedy"        "--prune-broken"       "$O"
O="$(python3 "$W8" --template "$TMPL" --live "$L3" --home "$H" --lock "$LOCK" --prune-broken 2>&1)"
contains "J: --prune-broken says what it removed"   "PRUNED"               "$O"
absent   "J: the broken entry is gone"              "ghost-that-is-absent" "$(cat "$L3")"
contains "J: the entry whose file EXISTS survives"  "gate.py"              "$(cat "$L3")"

echo "=== K: --deny-file — add-only merge into top-level deniedMcpServers ==="
# ⛔ MEASURED 2026-09-09, the same day session-deny shipped: mcp-profile-config.py can DERIVE
# the list of estates a session must not reach, but nothing WROTE it into settings.json —
# exactly the two-acts problem hooks already had (declared/installed is not wired). This
# closes the same gap for `deniedMcpServers`.
DENYFILE="$T/deny.json"
cat > "$DENYFILE" <<'JSON'
{"deniedMcpServers": [{"serverName": "claude.ai Estate B"}, {"serverUrl": "https://hub-c/mcp"}]}
JSON
# A template with no hooks at all, so every assertion below is about the deny key alone.
NOHOOK_TMPL="$T/tmpl-nohook.json"
cat > "$NOHOOK_TMPL" <<'JSON'
{ "hooks": {} }
JSON
run_deny() { python3 "$W8" --template "$NOHOOK_TMPL" --live "$1" --home "$H" --deny-file "$DENYFILE" ${2:-} 2>&1; }

echo "--- DN1: live file without the key + a deny file of two entries ---"
K1="$T/k1.json"
cat > "$K1" <<'JSON'
{ "hooks": {} }
JSON
O="$(run_deny "$K1")"
contains "DN1: the backup is written"                "backup:"                         "$O"
contains "DN1: the first entry is reported added"    "+ deniedMcpServers serverName=claude.ai Estate B" "$O"
contains "DN1: the second entry is reported added"   "+ deniedMcpServers serverUrl=https://hub-c/mcp"   "$O"
contains "DN1: the summary names both"               "denied 2 server(s)"              "$O"
contains "DN1: the first entry lands in the file"    "claude.ai Estate B"              "$(cat "$K1")"
contains "DN1: the second entry lands in the file"   "https://hub-c/mcp"               "$(cat "$K1")"
BK1="$(ls "$T"/k1.json.bak.* 2>/dev/null | head -1)"
[ -n "$BK1" ] && ok "DN1: a backup file exists" || bad "DN1: a backup file exists" "none written"

echo "--- DN2: run again — no change, file byte-identical ---"
BEFORE_K1="$(cat "$K1")"
O="$(run_deny "$K1")"
contains "DN2: says no change"           "already denied — no change" "$O"
absent   "DN2: nothing reported added"   "+ deniedMcpServers"          "$O"
AFTER_K1="$(cat "$K1")"
[ "$BEFORE_K1" = "$AFTER_K1" ] && ok "DN2: the file is byte-identical" || bad "DN2: the file is byte-identical" "it changed"

echo "--- DN3: one of the two already present, different order — only the missing one is added ---"
K3="$T/k3.json"
cat > "$K3" <<'JSON'
{ "hooks": {}, "deniedMcpServers": [{"serverUrl": "https://hub-c/mcp"}] }
JSON
O="$(run_deny "$K3")"
contains "DN3: only the missing entry is reported"     "+ deniedMcpServers serverName=claude.ai Estate B" "$O"
absent   "DN3: the already-present entry is not re-added" "+ deniedMcpServers serverUrl=https://hub-c/mcp" "$O"
BODY_K3="$(cat "$K3")"
contains "DN3: the pre-existing entry keeps its position first" \
         '"serverUrl": "https://hub-c/mcp"' "$BODY_K3"
contains "DN3: the new entry is appended" "claude.ai Estate B" "$BODY_K3"

echo "--- DN4: --dry-run reports the additions and changes nothing ---"
K4="$T/k4.json"
cat > "$K4" <<'JSON'
{ "hooks": {} }
JSON
BEFORE_K4="$(cat "$K4")"
O="$(run_deny "$K4" --dry-run)"
contains "DN4: reports the additions"        "+ deniedMcpServers serverName=claude.ai Estate B" "$O"
contains "DN4: the summary carries the dry-run suffix" "denied 2 server(s) (dry run — nothing written)" "$O"
AFTER_K4="$(cat "$K4")"
[ "$BEFORE_K4" = "$AFTER_K4" ] && ok "DN4: the file is unchanged" || bad "DN4: the file is unchanged" "--dry-run wrote to disk"

echo "--- DN5: a malformed entry — FATAL, nothing written ---"
BADDENY="$T/bad-deny.json"
cat > "$BADDENY" <<'JSON'
{"deniedMcpServers": [{"name": "x"}]}
JSON
K5="$T/k5.json"
cat > "$K5" <<'JSON'
{ "hooks": {} }
JSON
BEFORE_K5="$(cat "$K5")"
O="$(python3 "$W8" --template "$NOHOOK_TMPL" --live "$K5" --home "$H" --deny-file "$BADDENY" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then ok "DN5: exits non-zero"; else bad "DN5: exits non-zero" "rc=0"; fi
contains "DN5: FATAL names the malformed shape" "FATAL" "$O"
AFTER_K5="$(cat "$K5")"
[ "$BEFORE_K5" = "$AFTER_K5" ] && ok "DN5: nothing written to the live file" || bad "DN5: nothing written to the live file" "it changed"
ls "$T"/k5.json.bak.* >/dev/null 2>&1 && bad "DN5: no backup either" "a backup was written" || ok "DN5: no backup either"

echo "--- DN6: no live file — the seeded file carries the entries ---"
K6="$T/k6.json"
O="$(run_deny "$K6")"
contains "DN6: still says it wrote the (no-hook) rendered template" "no live settings.json" "$O"
contains "DN6: reports the additions too"    "+ deniedMcpServers serverName=claude.ai Estate B" "$O"
BODY_K6="$(cat "$K6" 2>/dev/null)"
contains "DN6: the seeded file carries the first entry"  "claude.ai Estate B"  "$BODY_K6"
contains "DN6: the seeded file carries the second entry" "https://hub-c/mcp"  "$BODY_K6"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
