#!/usr/bin/env bash
# install.sh — agent-notepad installer (DESIGN §13 U10, §15).
#
# Copies the plugin's runtime tree to the STABLE path
#   <HOME>/.claude/hooks/agent-notepad/{hooks,lib,bin,notepad-template}
# (NOT the branch-fragile repo path), installs the skill under
#   <HOME>/.claude/skills/agent-notepad/, and idempotently merges the four
# user-level Notes hooks (SessionStart/UserPromptSubmit/PreCompact/Stop) into
#   <HOME>/.claude/settings.json  (jq).
#
# It SUPERSEDES handoff-auto: any handoff-auto hook entries in settings.json are
# UNWIRED (their command strings are removed), while handoff-auto's files are left
# on disk untouched — reversible. settings.json is backed up before every edit.
#
# The PreToolUse commit gate is deliberately NOT wired user-level: it ships in the
# notepad template's .claude/settings.json so it arms only inside a notepad session.
#
# Target override (REQUIRED for hermetic tests — never run against the real ~/.claude
# in a test): pass `--target <DIR>` / `--home <DIR>`, or set AGENT_NOTEPAD_INSTALL_HOME.
# Default target is $HOME.
#
# Portable: bash + jq only. Idempotent: safe to re-run.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"     # .../agent-notepad/plugin
SKILL_SRC="$(dirname "$SRC")"            # .../agent-notepad  (SKILL.md, DESIGN.md)

usage() {
  cat <<EOF
agent-notepad installer

Usage: install.sh [--target <HOME_DIR>]

  --target, --home <DIR>   install into <DIR>/.claude instead of \$HOME/.claude
                           (env: AGENT_NOTEPAD_INSTALL_HOME)
  -h, --help               show this help

Installs to the stable runtime path <HOME>/.claude/hooks/agent-notepad/, wires the
four user-level Notes hooks into <HOME>/.claude/settings.json (idempotent), installs
the skill, and unwires handoff-auto (files kept — reversible via the settings backup).
EOF
}

# --- resolve target HOME -----------------------------------------------------
TARGET_HOME="${AGENT_NOTEPAD_INSTALL_HOME:-${HOME:-}}"
while [ $# -gt 0 ]; do
  case "$1" in
    --target|--home) TARGET_HOME="${2:?--target needs a directory}"; shift 2 ;;
    --target=*|--home=*) TARGET_HOME="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [ -z "$TARGET_HOME" ]; then
  echo "install.sh: no target HOME (pass --target or set HOME)" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 3; }

CLAUDE_DIR="$TARGET_HOME/.claude"
DEST="$CLAUDE_DIR/hooks/agent-notepad"
SKILL_DEST="$CLAUDE_DIR/skills/agent-notepad"
SETTINGS="$CLAUDE_DIR/settings.json"

# The stable command path baked into settings.json. Literal ${HOME} so it resolves
# at hook-run time for the runtime user (matches the notepad template convention).
STABLE_HOOKS='${HOME}/.claude/hooks/agent-notepad/hooks'

echo "agent-notepad: installing into $CLAUDE_DIR"

# --- 1) copy the runtime tree to the stable path -----------------------------
mkdir -p "$DEST" "$SKILL_DEST" "$CLAUDE_DIR"
for d in hooks lib bin notepad-template; do
  if [ -d "$SRC/$d" ]; then
    rm -rf "${DEST:?}/$d"
    cp -R "$SRC/$d" "$DEST/$d"
  fi
done
chmod +x "$DEST"/hooks/*.sh 2>/dev/null || true
chmod +x "$DEST"/bin/*.py 2>/dev/null || true
chmod +x "$DEST"/lib/*.py 2>/dev/null || true
echo "agent-notepad:   runtime tree -> $DEST/{hooks,lib,bin,notepad-template}"

# --- 1b) register the sessions/index.json merge driver -----------------------
# ⚠️ .gitattributes only NAMES a driver; git will not run one it has no config for. Shipping
# the attribute without this registration leaves the attribute INERT — declared, installed, and
# never invoked, which is this estate's signature defect.
#
# ⚠️ Registered at USER scope on purpose: a notepad is a repo per objective and there will be
# more of them, so per-repo registration would have to be repeated forever and would be
# forgotten exactly once.
#
# ⚠️ FAIL-SAFE EITHER WAY. Without the config git falls back to an ordinary conflict — today's
# behaviour — never to corruption. So this is a convenience, not a load-bearing guarantee, and
# a machine that skips it is inconvenienced rather than broken.
#
# ⛔ `--global` DOES NOT HONOUR `--target`, AND THAT ESCAPED THE TEST HOME. Measured on this
# laptop hours after the first version shipped: the real `~/.gitconfig` held
#   python3 /var/folders/.../T/tmp.k3YHwrrg3s/.claude/hooks/agent-notepad/lib/merge-session-index.py
# — a path inside a DELETED temp dir, written by `test_install.sh` running the installer with
# `--target <tmpdir>`. Everything else this script writes is under "$TARGET_HOME"; this one
# line was addressed by SCOPE instead, so the hermetic test was not hermetic and it silently
# reconfigured the developer's own machine. Point the global scope AT THE TARGET.
#
# ⛔ AND DO NOT SKIP WHEN PRESENT. The first version returned early on
# `git config --global ... >/dev/null` succeeding — a PRESENCE check, which cannot tell a good
# registration from one naming a directory that no longer exists. It reported "already
# registered" over exactly the dead path above and left it there. Idempotent means CONVERGES
# ON CORRECT, not "leaves whatever it finds": compare the value and rewrite when it differs.
#
# ⚠️ THE OVERRIDE IS ONLY FOR A REDIRECTED TARGET, NEVER FOR THE REAL HOME. Forcing
# GIT_CONFIG_GLOBAL=$HOME/.gitconfig would CREATE that file on a machine whose global config
# actually lives at the XDG path (~/.config/git/config) — and git reads XDG only when
# ~/.gitconfig is absent, so creating it would silently shadow every global setting the user
# has. On the real HOME, plain `--global` lets git resolve its own file.
_git_cfg() { # run `git config --global ...` against the TARGET's global config
  if [ "$TARGET_HOME" = "${HOME:-}" ]; then
    git config --global "$@"
  else
    GIT_CONFIG_GLOBAL="$TARGET_HOME/.gitconfig" git config --global "$@"
  fi
}
if command -v git >/dev/null 2>&1; then
  _want="python3 $DEST/lib/merge-session-index.py %O %A %B"
  _have="$(_git_cfg merge.loom-session-index.driver 2>/dev/null || true)"
  if [ "$_have" = "$_want" ]; then
    echo "agent-notepad:   merge driver already registered (correct path)"
  else
    _git_cfg merge.loom-session-index.name \
      "agent-notepad sessions/index.json union, keyed by sessionId" 2>/dev/null || true
    if _git_cfg merge.loom-session-index.driver "$_want" 2>/dev/null; then
      if [ -n "$_have" ]; then
        echo "agent-notepad:   merge driver RE-registered (stale path replaced: $_have)"
      else
        echo "agent-notepad:   merge driver registered (sessions/index.json)"
      fi
    else
      echo "agent-notepad: ! could not register the merge driver — index.json conflicts stay manual"
    fi
  fi
fi

# --- 2) install the skill ----------------------------------------------------
if [ -f "$SKILL_SRC/SKILL.md" ]; then
  cp "$SKILL_SRC/SKILL.md" "$SKILL_DEST/SKILL.md"
fi
if [ -f "$SKILL_SRC/DESIGN.md" ]; then
  cp "$SKILL_SRC/DESIGN.md" "$SKILL_DEST/DESIGN.md"
fi
echo "agent-notepad:   skill        -> $SKILL_DEST/"

# Install the plugin's invocable sub-skills as top-level skills so that
# /scope-init, /scope-retire, and the retargeted /handoff are discoverable.
# (The retargeted handoff deliberately supersedes the prior handoff skill.)
if [ -d "$SRC/skills" ]; then
  for sk in "$SRC"/skills/*/; do
    [ -d "$sk" ] || continue
    name="$(basename "$sk")"
    rm -rf "${CLAUDE_DIR:?}/skills/$name"
    cp -R "$sk" "$CLAUDE_DIR/skills/$name"
    echo "agent-notepad:   sub-skill    -> $CLAUDE_DIR/skills/$name/ (/$name)"
  done
fi

# --- 3) settings.json: backup, unwire handoff-auto, merge Notes hooks --------
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
BACKUP="$SETTINGS.bak.agent-notepad.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "agent-notepad:   backup       -> $BACKUP"

# 3a) unwire any handoff-auto hook entries (remove those command strings, drop
#     groups left empty). handoff-auto FILES are untouched — reversible.
_tmp="$(mktemp)"
jq '
  if (.hooks | type) == "object" then
    .hooks |= with_entries(
      .value |= (
        map( .hooks |= ((. // []) | map(select((.command // "") | test("handoff-auto") | not))) )
        | map(select(((.hooks // []) | length) > 0))
      )
    )
    | (.hooks |= with_entries(select((.value | length) > 0)))
  else . end
' "$SETTINGS" > "$_tmp" && mv "$_tmp" "$SETTINGS"

# 3b) idempotent merge of one Notes hook (adds only if that command is absent)
merge_hook() { # event script [matcher]
  local ev="$1" script="$2" matcher="${3:-}"
  local cmd="$STABLE_HOOKS/$script"
  local t; t="$(mktemp)"
  jq --arg ev "$ev" --arg cmd "$cmd" --arg m "$matcher" '
    .hooks = (.hooks // {})
    | .hooks[$ev] = (.hooks[$ev] // [])
    | if ([.hooks[$ev][]?.hooks[]?.command] | index($cmd)) != null
      then .
      else .hooks[$ev] += [
        ( if $m == "" then {hooks: [{type:"command", command:$cmd}]}
          else {matcher:$m, hooks: [{type:"command", command:$cmd}]} end )
      ]
      end
  ' "$SETTINGS" > "$t" && mv "$t" "$SETTINGS"
}
merge_hook SessionStart    session-start.sh "startup|resume|clear|compact"
merge_hook UserPromptSubmit user-prompt.sh  ""
merge_hook PreCompact      pre-compact.sh   ""
merge_hook Stop            stop.sh          ""
echo "agent-notepad:   hooks wired  -> SessionStart, UserPromptSubmit, PreCompact, Stop"

# --- 4) summary --------------------------------------------------------------
cat <<EOF

agent-notepad installed.

  runtime : $DEST
  skill   : $SKILL_DEST
  settings: $SETTINGS (backup: $BACKUP)

SUPERSEDES handoff-auto: its hook entries were unwired from settings.json; its files
were left in place. To reverse this install, restore the backup:
  cp "$BACKUP" "$SETTINGS"

The commit gate is NOT user-level — it ships in each notepad's .claude/settings.json
(via the template) and arms only in notepad sessions. Create a notepad with /scope-init.
EOF
