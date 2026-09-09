#!/usr/bin/env bash
# validate-arm.sh — mint a throwaway notepad so mission-scoped gates have something to guard.
#
# MEASURED 2026-09-08: every mission-scoped gate (escalation, commit, handoff Stop,
# df-worker, df-operator-todo, mission-tick) finds its mission by walking UP from the
# session's cwd for a NOTES.md. Part 2 of VALIDATE-INSTALL.md only exercises those gates
# when the kit root you validate happens to already BE a notepad -- on a kit root that is
# not, every gate abstains, silently and correctly, and that got recorded as "the plugin
# did not load" rather than "started outside a notepad", which is the wrong finding for the
# right symptom. This script arms the kit's OWN throwaway notepad so Part 2 always has one,
# on any kit, without touching anything the kit's real notepad (if it has one) is using.
#
# What it creates, under <kit-root>/.df-validate/:
#   NOTES.md                        the marker find_notepad() looks for
#   repos.manifest.json             one entry describing the kit itself
#   handoffs/, sessions/            the shape agent-notepad's hooks expect
#   MAP.md                          minimal
#   .df/missions/M-VALIDATE/state       RUNNING
#   .df/missions/M-VALIDATE/MISSION.md  what this mission is and its hard stops
#
# It is its own git repo (one commit, NO remote) -- so the agent-notepad Stop hook's
# best-effort push, which only fires when `git remote` lists something, never fires here.
# It is excluded from the KIT's git status via `.git/info/exclude`, NEVER `.gitignore`:
# `.gitignore` is tracked content and this directory must leave no trace of having existed
# once validate.sh tears it down. `.git/info/exclude` is local-only and untracked by design.
#
# Idempotent: re-arming an existing .df-validate/ refuses (so a leftover from a `--keep` run
# is visible, not silently clobbered). `--force` removes it and recreates.
#
# Usage: validate-arm.sh <kit-root> [--force]
# Exit:  0 armed. 1 already armed (pass --force). 2 bad arguments.
set -uo pipefail

FORCE=0
KIT_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'FATAL unknown option: %s\n' "$1" >&2; exit 2 ;;
    *)
      if [ -n "$KIT_ROOT" ]; then
        printf 'FATAL unexpected argument: %s\n' "$1" >&2
        exit 2
      fi
      KIT_ROOT="$1"
      shift
      ;;
  esac
done

[ -n "$KIT_ROOT" ] || { printf 'FATAL: usage: validate-arm.sh <kit-root> [--force]\n' >&2; exit 2; }
[ -d "$KIT_ROOT" ] || { printf 'FATAL: no such directory: %s\n' "$KIT_ROOT" >&2; exit 2; }
KIT_ROOT="$(cd "$KIT_ROOT" && pwd)"

NP="$KIT_ROOT/.df-validate"
# T1-F/T1-I: the record that names this machine's defaultProfile and its own LOOM_LOCK
# path, resolved the same way df-worker resolves them -- via mcp-profile-config.py's own
# resolve_machine_lock()/kit_records(), executed standalone (runpy, never imported: see
# that script's own "stays standalone" precedent) so this arm carries no import coupling.
MCP_TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mcp-profile-config.py"

# `git -C "$KIT_ROOT" rev-parse --git-path info/exclude` resolves through a worktree's real
# gitdir, unlike hand-building "$KIT_ROOT/.git/info/exclude" -- a worktree's .git is a file,
# not a directory, and that path would be wrong there.
# ⚠️ MEASURED: `--git-path` prints a path RELATIVE TO THE REPO IT NAMED (here, $KIT_ROOT),
# never relative to this script's own cwd and never absolute on its own. Using it bare from
# outside $KIT_ROOT resolved to THIS script's cwd instead -- and when that cwd was itself a
# worktree, ".git" there is a FILE, so `mkdir -p "$(dirname ".git/info/exclude")"` failed
# with "Not a directory". Prefixing with $KIT_ROOT (unless git already returned an absolute
# path, which it does for a gitdir outside the worktree) is what makes this correct
# regardless of where validate-arm.sh itself was invoked from.
KIT_IS_GIT=0
EXCL=""
if git -C "$KIT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  KIT_IS_GIT=1
  EXCL="$(git -C "$KIT_ROOT" rev-parse --git-path info/exclude 2>/dev/null || true)"
  case "$EXCL" in
    /*) : ;;
    *)  EXCL="$KIT_ROOT/$EXCL" ;;
  esac
fi

_remove_exclude_line() {
  [ "$KIT_IS_GIT" -eq 1 ] || return 0
  [ -n "$EXCL" ] && [ -f "$EXCL" ] || return 0
  grep -vxF '.df-validate/' "$EXCL" > "$EXCL.tmp" 2>/dev/null && mv "$EXCL.tmp" "$EXCL"
}

# T1-F: which record picks this machine's defaultProfile -- resolve_machine_lock()'s own
# pick, falling back to a record directly at the kit root when resolve_machine_lock cannot
# disambiguate (0 candidates, or an unresolved tie between several).
_pick_record() {  # $1 = kit root -> the resolved record path, or empty
  [ -f "$MCP_TOOL" ] || return 0
  python3 -c "
import os, runpy, sys
kit_root = os.path.abspath(sys.argv[1])
mod = runpy.run_path(sys.argv[2], run_name='_validate_arm')
lock = mod['resolve_machine_lock'](kit_root)
if not lock:
    for r in mod['kit_records'](kit_root):
        if os.path.dirname(os.path.abspath(r)) == kit_root:
            lock = r
            break
print(lock or '')
" "$1" "$MCP_TOOL" 2>/dev/null || true
}

# T1-I: env.LOOM_LOCK the notepad's copied settings.json should carry -- the kit's own
# settings.local.json when it declares one, else the record that resolves unambiguously
# for THIS machine (same resolver, no fallback to an ambiguous tie: a guess here would put
# a worker on the wrong estate's record).
# ⚠️ A resolved record is only trusted here when it actually SELF-DECLARES a `machine`
# block -- resolve_machine_lock() also returns a lone lockfile with NO machine info at all
# (its own documented "a single candidate wins outright" rule), and a bare, unaddressed
# lockfile is not evidence this machine is the one it describes. Every fixture in this repo
# that means "resolved for THIS machine" writes that block explicitly (platform+home); one
# that never did is not this machine's record, it is an untyped placeholder.
_resolved_loom_lock() {  # $1 = kit root -> the resolved record's absolute path, or empty
  [ -f "$MCP_TOOL" ] || return 0
  python3 -c "
import json, os, runpy, sys
kit_root = os.path.abspath(sys.argv[1])
mod = runpy.run_path(sys.argv[2], run_name='_validate_arm')
lock = mod['resolve_machine_lock'](kit_root)
if lock:
    try:
        with open(lock, encoding='utf-8') as fh:
            d = json.load(fh) or {}
    except Exception:
        d = {}
    if not isinstance(d.get('machine'), dict) or not d.get('machine'):
        lock = None
print(os.path.abspath(lock) if lock else '')
" "$1" "$MCP_TOOL" 2>/dev/null || true
}

_merge_env_loom_lock() {  # $1 = settings.json path, $2 = value for env.LOOM_LOCK
  mkdir -p "$(dirname "$1")"
  python3 -c "
import json, os, sys
path, val = sys.argv[1], sys.argv[2]
doc = {}
if os.path.isfile(path):
    try:
        with open(path, encoding='utf-8') as fh:
            doc = json.load(fh) or {}
    except Exception:
        doc = {}
env = doc.get('env')
if not isinstance(env, dict):
    env = {}
env['LOOM_LOCK'] = val
doc['env'] = env
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(doc, fh, indent=2)
    fh.write('\n')
" "$1" "$2"
}

if [ -e "$NP" ]; then
  if [ "$FORCE" -eq 1 ]; then
    _remove_exclude_line
    rm -rf "$NP"
  else
    printf 'FATAL: %s already exists -- pass --force to remove and recreate it\n' "$NP" >&2
    exit 1
  fi
fi

mkdir -p "$NP/handoffs" "$NP/sessions" "$NP/.df/missions/M-VALIDATE"

KIT_NAME="$(basename "$KIT_ROOT")"
REMOTE=""
[ "$KIT_IS_GIT" -eq 1 ] && REMOTE="$(git -C "$KIT_ROOT" remote get-url origin 2>/dev/null || true)"
TODAY="$(date -u +%Y-%m-%d)"

cat > "$NP/NOTES.md" <<EOF
# M-VALIDATE — throwaway notepad

Created by validate-arm.sh on $TODAY for M-VALIDATE. This directory exists so the
mission-scoped gates (escalation, commit, handoff Stop, df-worker, df-operator-todo,
mission-tick) have a real mission to guard while \`/df-governed:validate\` runs. \`validate.sh\`
removes it -- and the \`.git/info/exclude\` line pointing at it -- once that session ends.
Nothing written here is meant to survive the run.
EOF

python3 - "$NP/repos.manifest.json" "$KIT_NAME" "$KIT_ROOT" "$REMOTE" <<'PY'
import json
import sys

path, name, kit_root, remote = sys.argv[1:5]
doc = {"repos": [{"name": name, "path": kit_root, "remote": remote, "role": "kit"}]}
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

cat > "$NP/MAP.md" <<EOF
# MAP

Throwaway notepad for M-VALIDATE, armed $TODAY. See NOTES.md.
EOF

printf 'RUNNING\n' > "$NP/.df/missions/M-VALIDATE/state"

cat > "$NP/.df/missions/M-VALIDATE/MISSION.md" <<EOF
Validate \`$KIT_NAME\` in the fresh session \`validate.sh\` opens in this notepad. Hard stops:
touch nothing outside this directory except read-only probes of the kit; do not \`rm\` this
cwd yourself -- \`validate.sh\` removes it after the session ends.
EOF

# T1-F, MEASURED 2026-09-09: `.df/missions/M-VALIDATE/` used to get MISSION.md and state
# only -- no `profile` -- so df-worker inside a validate run always hit the "no defaultProfile
# fallback" bug (T1-C) even on a kit whose record declares one. Write the resolved record's
# own defaultProfile here when it has one; omit the file when it does not (df-worker's own
# fallback chain then continues to "default", exactly as it does with no file at all).
PICKED_RECORD="$(_pick_record "$KIT_ROOT")"
if [ -n "$PICKED_RECORD" ] && [ -f "$PICKED_RECORD" ]; then
  DEFAULT_PROFILE="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        d = json.load(fh) or {}
except Exception:
    d = {}
print(d.get('defaultProfile') or '')
" "$PICKED_RECORD" 2>/dev/null || true)"
  if [ -n "$DEFAULT_PROFILE" ]; then
    printf '%s\n' "$DEFAULT_PROFILE" > "$NP/.df/missions/M-VALIDATE/profile"
  fi
fi

printf '[]\n' > "$NP/sessions/index.json"

# The commit and push gates are wired at PROJECT level — in the kit root's own
# .claude/settings.json — never at user level (lock-verify L9 reads user settings only, and
# the lockfile's hooksUnwired says so). This notepad is its own git repo under its own cwd,
# so the kit root's project settings do NOT reach it. MEASURED 2026-09-08 on the first real
# run: every other gate fired, and `git commit -m wip` went straight through with M-VALIDATE
# RUNNING — the exact bypass Part 2 step 4 exists to catch, reported as a finding about the
# gate when it was a finding about the arm. Copy the kit's project settings in, verbatim, so
# the armed notepad wires what the kit wires.
if [ -f "$KIT_ROOT/.claude/settings.json" ]; then
  mkdir -p "$NP/.claude"
  cp "$KIT_ROOT/.claude/settings.json" "$NP/.claude/settings.json"
  # MEASURED 2026-09-08 on the homelab Coder: the copied settings name relative hook paths
  # (`bash .claude/hooks/ensure-gate.sh`) that did not exist in the notepad, so a declared
  # SessionStart hook failed silently on every session start there. Settings and the hooks
  # they name travel together or not at all.
  if [ -d "$KIT_ROOT/.claude/hooks" ]; then
    cp -R "$KIT_ROOT/.claude/hooks" "$NP/.claude/hooks"
  fi
fi

# T1-I, MEASURED 2026-09-08: the arm above copies the kit's .claude/settings.json and
# .claude/hooks/ into the notepad but never the env.LOOM_LOCK an installer wrote into
# <kit>/.claude/settings.local.json -- so the validate session, the one session that must
# launch a worker, is the one where the record is unknown. settings.local.json's own value
# wins outright (it is what the installer actually resolved for this machine); only when it
# names none do we fall back to resolving the record ourselves, and only when exactly one
# resolves -- never guessed.
LOOM_LOCK_VALUE=""
LOOM_LOCK_VIA=""
if [ -f "$KIT_ROOT/.claude/settings.local.json" ]; then
  LOOM_LOCK_VALUE="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        d = json.load(fh) or {}
except Exception:
    d = {}
print(((d.get('env') or {}).get('LOOM_LOCK')) or '')
" "$KIT_ROOT/.claude/settings.local.json" 2>/dev/null || true)"
  [ -n "$LOOM_LOCK_VALUE" ] && LOOM_LOCK_VIA="settings.local.json"
fi
if [ -z "$LOOM_LOCK_VALUE" ]; then
  LOOM_LOCK_VALUE="$(_resolved_loom_lock "$KIT_ROOT")"
  [ -n "$LOOM_LOCK_VALUE" ] && LOOM_LOCK_VIA="resolved record"
fi
if [ -n "$LOOM_LOCK_VALUE" ]; then
  _merge_env_loom_lock "$NP/.claude/settings.json" "$LOOM_LOCK_VALUE"
  printf 'arm: LOOM_LOCK=%s (via %s)\n' "$LOOM_LOCK_VALUE" "$LOOM_LOCK_VIA"
fi

git -C "$NP" init -q
# MEASURED 2026-09-08 on the homelab Coder: the kit's git identity was REPO-LOCAL (nothing
# global), so the notepad this script initialised inherited none — the handoff helper wrote
# and staged but could not commit ("Author identity unknown"), and Part 2's commit-gate PASS
# path was untestable until the operator set one by hand. Give the notepad an identity of its
# own: the kit's if git can resolve one from there, else this script's throwaway name.
GIT_NAME="$(git -C "$KIT_ROOT" config --get user.name 2>/dev/null || true)"
GIT_EMAIL="$(git -C "$KIT_ROOT" config --get user.email 2>/dev/null || true)"
git -C "$NP" config user.name "${GIT_NAME:-df-validate}"
git -C "$NP" config user.email "${GIT_EMAIL:-df-validate@localhost}"
git -C "$NP" add -A
git -C "$NP" commit -q -m "M-VALIDATE: arm throwaway notepad"

if [ "$KIT_IS_GIT" -eq 1 ]; then
  mkdir -p "$(dirname "$EXCL")"
  touch "$EXCL"
  grep -qxF '.df-validate/' "$EXCL" || printf '.df-validate/\n' >> "$EXCL"
fi

printf '%s\n' "$NP"
printf 'arm: %s\n' "$NP"
