#!/usr/bin/env bash
# test-kit-notepad-runtime.sh — a kit that names the notepad must install a notepad that WORKS.
#
# Enrolled by GLOB, per tests/README.md — "a suite is enrolled by existing".
#
# ⛔ WHAT IT PROTECTS. Until 2026-09-11 kits/agent-ops named the agent-notepad SKILL and none of
# its runtime. A kit bootstrapped from it could run /scope-init and got a notepad that restored
# nothing: the Notes hooks and the libraries they source were installed by no one, the plugin's
# own installer is run by no one, and /scope-init pointed at a template path that does not exist
# from skills/scope-init/. Every check that looked at the kit passed. Separately, the starter
# settings template wired one hook while the generic kits declared five more, so lock-verify L9
# found them inert on every install. This suite asserts the JOIN, end to end:
#   N1  the resolver emits the notepad suite with sources that EXIST in this repo
#   N2  every hook either kit declares is WIRED by the starter template or EXCUSED in
#       hooksUnwired — the condition lock-verify L9 applies on a machine
#   N3  bootstrap --kit carries the hooksUnwired reasons into the record
#   N4  knowledge-worker can run a mission: it carries scope-init, vinculum-map, dark-factory-build
#   N5  rehydrate installs and wires a NESTED hook name (agent-notepad/hooks/x.sh)
#   N6  /scope-init's template path resolves from where kits install it
#
# Usage: bash boot-kit/scripts/tests/test-kit-notepad-runtime.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
ROOT="$(cd "$SCRIPTS/../.." && pwd)"
RESOLVER="$SCRIPTS/kit-resolve.py"
RH="$SCRIPTS/rehydrate.sh"
BOOTSTRAP="$ROOT/starter-kit/instance/bootstrap.sh"
TPL="$ROOT/starter-kit/instance/boot-kit/settings.template.json"
for f in "$RESOLVER" "$RH" "$BOOTSTRAP" "$TPL"; do [ -f "$f" ] || { echo "missing $f"; exit 2; }; done
command -v jq >/dev/null || { echo "jq required"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/notepadrt.XXXXXX")"
trap 'rm -rf "$W"' EXIT

TPLCMDS="$(jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command? // empty] | .[]' "$TPL")"

for K in dev knowledge-worker; do
  J="$(python3 "$RESOLVER" "$K" --root "$ROOT" 2>/dev/null)"
  if [ -z "$J" ]; then bad "N1 kits/$K resolves" "resolver failed"; continue; fi

  echo "=== N1 kits/$K: the notepad suite is declared, with sources that exist ==="
  for h in agent-notepad/hooks/session-start.sh agent-notepad/hooks/stop.sh agent-notepad/lib/notepad.sh; do
    src="$(printf '%s' "$J" | jq -r --arg h "$h" '.hookSources[$h] // empty')"
    if [ -z "$src" ]; then bad "N1 kits/$K declares $h" "not in hookSources"; continue; fi
    if [ -f "$ROOT/${src#dark-factory/}" ]; then ok "N1 kits/$K $h -> $src exists"
    else bad "N1 kits/$K $h source exists" "$src"; fi
  done
  MISSING="$(printf '%s' "$J" | jq -r '.hookSources | to_entries[] | .value' | while read -r s; do [ -f "$ROOT/${s#dark-factory/}" ] || printf '%s ' "$s"; done)"
  [ -z "$MISSING" ] && ok "N1 kits/$K every emitted hook source exists" || bad "N1 kits/$K every emitted hook source exists" "$MISSING"

  echo "=== N2 kits/$K: every declared hook is wired by the template or excused ==="
  INERT=""
  while read -r h; do
    [ -n "$h" ] || continue
    grep -qF -- "$h" <<<"$TPLCMDS" && continue
    printf '%s' "$J" | jq -e --arg h "$h" '(.hooksUnwired // {})[$h] | strings | length > 0' >/dev/null 2>&1 && continue
    INERT="$INERT $h"
  done < <(printf '%s' "$J" | jq -r '.hooks[]')
  [ -z "$INERT" ] && ok "N2 kits/$K no declared hook is left inert" || bad "N2 kits/$K no declared hook is left inert" "$INERT"
done

echo "=== N3/N4: bootstrap --kit knowledge-worker writes a record that can run a mission ==="
bash "$BOOTSTRAP" nb "$W/nb" --kit knowledge-worker >/dev/null 2>&1
L="$W/nb/loom.lock.json"
if [ -f "$L" ]; then
  if jq -e '.install.hooksUnwired["agent-notepad/lib/notepad.sh"] | strings | length > 0' "$L" >/dev/null; then
    ok "N3 the record carries the hooksUnwired reasons"
  else bad "N3 the record carries the hooksUnwired reasons" "$(jq -c '.install.hooksUnwired' "$L")"; fi
  for s in agent-notepad scope-init vinculum-map vinculum-loop dark-factory-build; do
    jq -e --arg s "$s" '.install.skills | index($s)' "$L" >/dev/null && ok "N4 knowledge-worker declares $s" || bad "N4 knowledge-worker declares $s" "absent"
  done
else
  bad "N3 bootstrap wrote a record" "no $L"
fi

echo "=== N5: rehydrate installs and wires a NESTED hook name ==="
K="$W/rh"
mkdir -p "$K/boot-kit/config" "$K/vendor/dark-factory/skills/agent-notepad/plugin/hooks" "$K/live"
printf '#!/bin/sh\nexit 0\n' > "$K/vendor/dark-factory/skills/agent-notepad/plugin/hooks/x.sh"
jq -n '{vendorDir:"vendor",upstreams:{},install:{skills:[],skillSources:{},
    hooks:["agent-notepad/hooks/x.sh"],
    hookSources:{"agent-notepad/hooks/x.sh":"dark-factory/skills/agent-notepad/plugin/hooks/x.sh"}}}' > "$K/loom.lock.json"
cat > "$K/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [
  { "type": "command", "command": "__HOME__/.claude/hooks/agent-notepad/hooks/x.sh" } ] } ] } }
JSON
( cd "$K" && env -u LOOM_LOCK LOOM_LIVE="$K/live" LOOM_BIN="$K/bin" bash "$RH" --offline >"$W/rh.out" 2>&1 )
if [ -x "$K/live/hooks/agent-notepad/hooks/x.sh" ]; then ok "N5 the nested hook file is installed"
else bad "N5 the nested hook file is installed" "$(grep -i 'x.sh' "$W/rh.out" | head -3 | tr '\n' ' ')"; fi
if grep -qF 'agent-notepad/hooks/x.sh' "$K/live/settings.json" 2>/dev/null; then ok "N5 and it is wired"
else bad "N5 and it is wired" "not in live settings.json"; fi

echo "=== N6: /scope-init's template path resolves from where kits install it ==="
SI="$ROOT/skills/scope-init/SKILL.md"
PATHS="$(grep -o '`[^`]*notepad-template/[^`]*`' "$SI" | tr -d '`' | sed 's|notepad-template/.*|notepad-template|' | sort -u)"
[ -n "$PATHS" ] || bad "N6 scope-init names its template" "no notepad-template path found"
for p in $PATHS; do
  if [ -d "$ROOT/skills/scope-init/$p" ]; then ok "N6 $p resolves from skills/scope-init/"
  else bad "N6 $p resolves from skills/scope-init/" "no such directory"; fi
done

echo
printf 'notepad runtime: %d ok, %d failed\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
