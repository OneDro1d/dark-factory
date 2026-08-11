#!/usr/bin/env bash
# U10 — Packaging: SKILL.md + plugin manifest contract.
# Asserts the two static packaging artifacts are well-formed (DESIGN §13 U10, §15):
#   1. the agent-notepad SKILL.md (valid frontmatter: name + description),
#   2. the plugin manifest (valid JSON; declares the four user-level Notes hook
#      events; each hook command references ${CLAUDE_PLUGIN_ROOT}; declares skills).
# Pure static inspection — writes nothing, touches no real config.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$HERE")"                 # .../agent-notepad/plugin
SKILL_ROOT="$(dirname "$PLUGIN_ROOT")"           # .../agent-notepad
SKILL_MD="$SKILL_ROOT/SKILL.md"
. "$HERE/assert.sh"

# resolve the manifest at either sanctioned location
_manifest() {
  if [ -f "$PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
    printf '%s' "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  elif [ -f "$PLUGIN_ROOT/plugin.json" ]; then
    printf '%s' "$PLUGIN_ROOT/plugin.json"
  fi
}

test_skill_md_exists() {
  assert_file_exists "$SKILL_MD" "SKILL.md exists at agent-notepad/SKILL.md"
}

test_skill_md_has_frontmatter() {
  [ -f "$SKILL_MD" ] || { assert_eq "present" "absent" "SKILL.md missing"; return; }
  local first; first="$(head -1 "$SKILL_MD")"
  assert_eq "---" "$first" "SKILL.md opens with YAML frontmatter fence"
  # extract the frontmatter block (between the first two --- fences)
  local fm; fm="$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{print}' "$SKILL_MD")"
  assert_contains "$fm" "name:" "frontmatter declares name:"
  assert_contains "$fm" "description:" "frontmatter declares description:"
  assert_contains "$fm" "agent-notepad" "frontmatter names the skill (agent-notepad)"
}

test_manifest_exists_and_valid_json() {
  local m; m="$(_manifest)"
  assert_file_exists "$m" "plugin manifest exists (.claude-plugin/plugin.json or plugin.json)"
  [ -n "$m" ] || return
  jq -e '.' "$m" >/dev/null 2>&1
  assert_eq "0" "$?" "plugin manifest is valid JSON"
  assert_eq "agent-notepad" "$(jq -r '.name' "$m")" "manifest .name == agent-notepad"
}

test_manifest_declares_four_notes_hooks() {
  local m; m="$(_manifest)"; [ -n "$m" ] || { assert_eq "m" "" "no manifest"; return; }
  local ev
  for ev in SessionStart Stop UserPromptSubmit PreCompact; do
    local n; n="$(jq -r --arg e "$ev" '(.hooks[$e] // []) | length' "$m")"
    case "$n" in ''|0) assert_eq "1+" "0" "manifest declares $ev hook" ;;
      *) assert_eq "ok" "ok" "manifest declares $ev hook ($n group(s))" ;;
    esac
  done
}

test_manifest_hooks_use_plugin_root() {
  local m; m="$(_manifest)"; [ -n "$m" ] || { assert_eq "m" "" "no manifest"; return; }
  # every declared hook command must reference ${CLAUDE_PLUGIN_ROOT} (stable, relocatable)
  local bad
  bad="$(jq -r '[.hooks[]?[]?.hooks[]?.command | select((. // "") | contains("${CLAUDE_PLUGIN_ROOT}") | not)] | length' "$m")"
  assert_eq "0" "$bad" "all manifest hook commands reference \${CLAUDE_PLUGIN_ROOT}"
}

test_manifest_declares_skills() {
  local m; m="$(_manifest)"; [ -n "$m" ] || { assert_eq "m" "" "no manifest"; return; }
  local sk; sk="$(jq -r '(.skills // []) | length' "$m")"
  case "$sk" in ''|0) assert_eq "1+" "0" "manifest declares skills" ;;
    *) assert_eq "ok" "ok" "manifest declares $sk skill ref(s)" ;;
  esac
  # the skill ref is expressed relative to the plugin root
  local ref; ref="$(jq -r '(.skills // []) | join(",")' "$m")"
  assert_contains "$ref" "CLAUDE_PLUGIN_ROOT" "skill ref uses \${CLAUDE_PLUGIN_ROOT}"
}

run_tests
