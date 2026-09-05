#!/usr/bin/env bash
# test-plugin-invariants.sh — structural invariants of plugins/df-governed that a reviewer would
# otherwise have to remember. Each one was earned:
#   I1  settings.json carries no `agent`, and plugin.json declares no settings.agent.
#       Measured (B4 §3 S-1): a plugin settings.json `agent` key hijacks the MAIN THREAD of a
#       headless -p worker, which then never runs its tool and still reports success. And per the
#       sub-agents docs the agent prompt REPLACES the harness system prompt entirely.
#   I2  every command in hooks/hooks.json names a file under hooks/ that exists and is executable.
#   I3  every hooks/*.py is referenced by hooks.json (declared both directions — the L7 shape).
#   I4  monitors.json is a JSON array; every command names a file under bin/ that exists.
#   I5  claude plugin validate passes with no warnings (a shipped warning is one people learn to skip).
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

echo "=== I1: no agent activation shipped ==="
A="$(jq -r '.agent // "unset"' "$ROOT/settings.json")"
[ "$A" = "unset" ] && ok "settings.json has no agent" || bad "settings.json has no agent" "agent=$A"
B="$(jq -r '.settings.agent // "unset"' "$ROOT/.claude-plugin/plugin.json")"
[ "$B" = "unset" ] && ok "plugin.json has no settings.agent" || bad "plugin.json has no settings.agent" "agent=$B"

echo "=== I2: every hooks.json command resolves to an executable under hooks/ ==="
while IFS= read -r cmd; do
  f="$(printf '%s' "$cmd" | sed -n 's#.*\${CLAUDE_PLUGIN_ROOT}/\(hooks/[^" ]*\).*#\1#p')"
  if [ -z "$f" ]; then bad "command names a hooks/ file" "$cmd"; continue; fi
  [ -f "$ROOT/$f" ] && ok "exists: $f" || bad "exists: $f" "missing"
  [ -x "$ROOT/$f" ] && ok "executable: $f" || bad "executable: $f" "mode $(stat -f %Lp "$ROOT/$f" 2>/dev/null || stat -c %a "$ROOT/$f")"
done < <(jq -r '.hooks[][] | .hooks[] | .command' "$ROOT/hooks/hooks.json")

echo "=== I3: every hooks/*.py is declared in hooks.json ==="
for py in "$ROOT"/hooks/*.py; do
  n="$(basename "$py")"
  grep -q "hooks/$n" "$ROOT/hooks/hooks.json" && ok "declared: $n" || bad "declared: $n" "present on disk, absent from hooks.json"
done

echo "=== I4: monitors.json commands resolve under bin/ ==="
jq -e 'type=="array"' "$ROOT/monitors/monitors.json" >/dev/null && ok "monitors.json is an array" || bad "monitors.json is an array" "not an array"
while IFS= read -r cmd; do
  f="$(printf '%s' "$cmd" | sed -n 's#.*\${CLAUDE_PLUGIN_ROOT}/\(bin/[^" ]*\).*#\1#p')"
  [ -n "$f" ] && [ -f "$ROOT/$f" ] && ok "monitor command exists: $f" || bad "monitor command exists" "$cmd"
done < <(jq -r '.[].command' "$ROOT/monitors/monitors.json")

echo "=== I5: validator passes with no warnings ==="
if command -v claude >/dev/null 2>&1; then
  V="$(cd "$ROOT/.." && claude plugin validate "$(basename "$ROOT")" 2>&1)"
  case "$V" in
    *"Validation passed with warnings"*) bad "validate: no warnings" "$V" ;;
    *"Validation passed"*) ok "validate: passed, no warnings" ;;
    *) bad "validate: passed" "$V" ;;
  esac
else
  printf '  SKIP %s -- %s\n' "I5: validate" "claude CLI not on PATH here. This is the ONE place the validator is asserted, so a run without the CLI has NOT proven I5; run this suite where claude is installed before shipping"
fi

echo
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
