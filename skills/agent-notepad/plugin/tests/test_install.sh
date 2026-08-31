#!/usr/bin/env bash
# U10 — Installer contract (DESIGN §15, acceptance-adjacent).
# Runs install.sh against a TEMP HOME (never the real ~/.claude) and asserts:
#   - hooks/lib/bin/notepad-template land at the STABLE runtime path
#     $HOME/.claude/hooks/agent-notepad/ (not the branch-fragile repo path),
#   - the SKILL installs under $HOME/.claude/skills/agent-notepad/,
#   - settings.json wires the four user-level Notes hooks to the stable path,
#   - the merge is idempotent (a second run adds no duplicate),
#   - install SUPERSEDES handoff-auto: pre-existing handoff-auto hook entries are
#     unwired, and a settings.json backup is written (reversible),
#   - the installed hook is executable + pipe-testable ({} outside a notepad).
# TEMP-ONLY: every path is under mktemp -d; the real HOME is never written.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$HERE")"
INSTALL="$PLUGIN_ROOT/install.sh"
. "$HERE/assert.sh"

STABLE="hooks/agent-notepad"      # stable-path marker
REPOMARK="Dark-Factory-Process"   # repo-path anti-marker

test_install_exists_executable() {
  assert_file_exists "$INSTALL" "install.sh exists"
  [ -x "$INSTALL" ] && assert_eq "x" "x" "install.sh is executable" \
                    || assert_eq "x" "" "install.sh is executable"
}

test_install_lays_down_stable_runtime_tree() {
  local T; T="$(mktemp -d)"
  bash "$INSTALL" --target "$T" >/dev/null 2>&1
  local base="$T/.claude/hooks/agent-notepad"
  assert_file_exists "$base/hooks/session-start.sh" "session-start.sh at stable path"
  assert_file_exists "$base/hooks/stop.sh"          "stop.sh at stable path"
  assert_file_exists "$base/hooks/user-prompt.sh"   "user-prompt.sh at stable path"
  assert_file_exists "$base/hooks/pre-compact.sh"    "pre-compact.sh at stable path"
  assert_file_exists "$base/hooks/commit-gate.sh"   "commit-gate.sh at stable path"
  # A hook the template's settings.json names but the installer does not copy is a hook that
  # fails silently at the stable path — the settings entry looks like wiring and installs
  # nothing. Both gates are listed here for that reason.
  assert_file_exists "$base/hooks/push-gate.sh"     "push-gate.sh at stable path"
  assert_file_exists "$base/lib/notepad.sh"          "lib/notepad.sh at stable path"
  assert_file_exists "$base/notepad-template/CLAUDE.md" "notepad-template copied"
  [ -x "$base/hooks/session-start.sh" ] && assert_eq "x" "x" "installed hook is +x" \
                                        || assert_eq "x" "" "installed hook is +x"
  rm -rf "$T"
}

test_install_installs_skill() {
  local T; T="$(mktemp -d)"
  bash "$INSTALL" --target "$T" >/dev/null 2>&1
  assert_file_exists "$T/.claude/skills/agent-notepad/SKILL.md" "SKILL.md installed to skills dir"
  rm -rf "$T"
}

test_settings_wires_four_notes_hooks_to_stable_path() {
  local T; T="$(mktemp -d)"
  bash "$INSTALL" --target "$T" >/dev/null 2>&1
  local s="$T/.claude/settings.json"
  assert_file_exists "$s" "settings.json created"
  jq -e '.' "$s" >/dev/null 2>&1
  assert_eq "0" "$?" "settings.json is valid JSON"
  local ev script
  for pair in "SessionStart:session-start.sh" "Stop:stop.sh" \
              "UserPromptSubmit:user-prompt.sh" "PreCompact:pre-compact.sh"; do
    ev="${pair%%:*}"; script="${pair##*:}"
    local found
    found="$(jq -r --arg e "$ev" --arg sc "$script" \
      '[.hooks[$e][]?.hooks[]?.command | select((. // "") | contains($sc))] | length' "$s")"
    case "$found" in ''|0) assert_eq "1+" "0" "$ev wired to $script" ;;
      *) assert_eq "ok" "ok" "$ev wired to $script" ;;
    esac
  done
  # commands point at the STABLE path, never the repo path
  local allcmds; allcmds="$(jq -r '[.hooks[]?[]?.hooks[]?.command] | join(" ")' "$s")"
  assert_contains "$allcmds" "$STABLE" "hook commands use the stable runtime path"
  assert_not_contains "$allcmds" "$REPOMARK" "hook commands do NOT hardcode the repo path"
  rm -rf "$T"
}

test_install_is_idempotent() {
  local T; T="$(mktemp -d)"
  bash "$INSTALL" --target "$T" >/dev/null 2>&1
  bash "$INSTALL" --target "$T" >/dev/null 2>&1
  local s="$T/.claude/settings.json"
  local n
  n="$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command | select((. // "") | contains("session-start.sh"))] | length' "$s")"
  assert_eq "1" "$n" "SessionStart hook is not duplicated after a second install"
  n="$(jq -r '[.hooks.Stop[]?.hooks[]?.command | select((. // "") | contains("stop.sh"))] | length' "$s")"
  assert_eq "1" "$n" "Stop hook is not duplicated after a second install"
  rm -rf "$T"
}

test_install_supersedes_handoff_auto() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/.claude"
  # pre-seed a settings.json that wires an old handoff-auto hook + an unrelated hook
  cat > "$T/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"hooks":[{"type":"command","command":"${HOME}/.claude/hooks/handoff-auto/hooks/session-start.py"}]}
    ],
    "Stop": [
      {"hooks":[{"type":"command","command":"/usr/bin/true"}]}
    ]
  }
}
JSON
  bash "$INSTALL" --target "$T" >/dev/null 2>&1
  local s="$T/.claude/settings.json"
  local ha; ha="$(jq -r '[.hooks[]?[]?.hooks[]?.command | select((. // "") | contains("handoff-auto"))] | length' "$s")"
  assert_eq "0" "$ha" "handoff-auto hook entries are unwired"
  # unrelated pre-existing hook is preserved
  local keep; keep="$(jq -r '[.hooks[]?[]?.hooks[]?.command | select((. // "") == "/usr/bin/true")] | length' "$s")"
  assert_eq "1" "$keep" "unrelated pre-existing hook preserved"
  # a backup was written (reversible)
  local baks; baks="$(ls "$T/.claude/"settings.json.bak* 2>/dev/null | wc -l | tr -d ' ')"
  case "$baks" in 0) assert_eq "1+" "0" "settings.json backup written" ;;
    *) assert_eq "ok" "ok" "settings.json backup written ($baks)" ;;
  esac
  rm -rf "$T"
}

test_installed_hook_is_pipe_testable() {
  local T; T="$(mktemp -d)"
  bash "$INSTALL" --target "$T" >/dev/null 2>&1
  local ss="$T/.claude/hooks/agent-notepad/hooks/session-start.sh"
  # outside a notepad (a bare temp cwd) the hook must emit {} and exit 0
  local out cwd; cwd="$(mktemp -d)"
  out="$(printf '{"cwd":"%s"}' "$cwd" | AGENT_NOTEPAD_NO_PULL=1 bash "$ss" 2>/dev/null)"
  assert_eq "0" "$?" "installed session-start.sh exits 0"
  assert_eq "{}" "$(printf '%s' "$out" | tr -d '[:space:]')" "installed hook emits {} outside a notepad"
  rm -rf "$T" "$cwd"
}

run_tests
