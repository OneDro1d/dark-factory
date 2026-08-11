#!/usr/bin/env bash
# hooks/commit-gate.sh — U8 code-commit staleness gate (DESIGN §7.6, acceptance 7).
#
# Wiring: PreToolUse on Bash, declared in the NOTEPAD's .claude/settings.json so it
# arms only in notepad sessions and governs AGENT git-commits (manual human commits
# are governed by that repo's own git pre-commit hook — see df-context-store).
#
# Contract (hook recipe): read the tool-call JSON on stdin, inspect
# tool_input.command; emit {} to allow or {"decision":"block","reason":...} to
# block. EXIT 0 ALWAYS (a non-zero exit would be an error, not a policy decision).
#
# What it does: if the command is a `git [ -C <repo> ] commit …`, resolve the
# target repo and run a SIMPLE, documented staleness check —
#   staged (and, for `commit -a`, unstaged-tracked) changes that touch STRUCTURAL
#   globs (schema / contract / migration / service dirs, configurable) while the
#   repo's `.claude/context/` store has NO file in the same change set  →  DRIFT.
# Drift → block with a fix hint. Everything else → allow ({}).
#
# Abstains ({}) when: not a commit; repo unresolved / not a git worktree; repo has
# no `.claude/context/` store (nothing to govern); nothing staged; `--no-verify`
# in the command; or AGENT_NOTEPAD_COMMIT_GATE=off.
#
# Config (env, all optional):
#   AGENT_NOTEPAD_COMMIT_GATE=off        disable the gate entirely
#   AGENT_NOTEPAD_STRUCTURAL_GLOBS=...   newline/space-separated case-globs to treat
#                                        as structural (overrides the default set)
#   AGENT_NOTEPAD_CONTEXT_GLOB=...       glob whose match counts as "store updated"
#                                        (default: .claude/context/*)
set -u

allow() { printf '{}\n'; exit 0; }
block() { # reason-text
  jq -n --arg r "$1" '{decision:"block", reason:$r}' 2>/dev/null \
    || printf '{"decision":"block","reason":%s}\n' "\"${1//\"/\\\"}\""
  exit 0
}

[ "${AGENT_NOTEPAD_COMMIT_GATE:-on}" = "off" ] && allow

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cmd" ] && allow

# ── parse the command: is it a git-commit? extract -C <path> and -a/--all ────
# python3 + shlex tokenization handles `git -C <path> commit`, quoting, and a
# `git commit` segment inside a compound command. Prints one of:
#   NOTCOMMIT
#   COMMIT\t<repo-or-empty>\t<all:0|1>\t<noverify:0|1>
parsed="$(python3 - "$cmd" <<'PY'
import shlex, sys, os
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    toks = shlex.split(cmd)
except ValueError:
    print("NOTCOMMIT"); sys.exit(0)

# git global options that consume the following token as their value
VAL_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
            "--super-prefix", "--config-env"}

def scan(start):
    """From token index `start` (just after a 'git'), return (subcmd, cpath) or (None,None)."""
    i, cpath = start, ""
    n = len(toks)
    while i < n:
        t = toks[i]
        if t == "-C" and i + 1 < n:
            cpath = toks[i + 1]; i += 2; continue
        if t.startswith("-C") and len(t) > 2:      # -C/path (glued)
            cpath = t[2:]; i += 1; continue
        if t in VAL_OPTS and i + 1 < n:
            i += 2; continue
        if t.startswith("--") and "=" in t:
            i += 1; continue
        if t.startswith("-"):                       # a global flag (e.g. --no-pager)
            i += 1; continue
        return t, cpath                             # first bare token = subcommand
    return None, cpath

i, n = 0, len(toks)
while i < n:
    if os.path.basename(toks[i]) == "git":
        sub, cpath = scan(i + 1)
        if sub == "commit":
            rest = toks[i + 1:]
            allf = "1" if ("-a" in rest or "--all" in rest or "-am" in rest) else "0"
            nov  = "1" if ("--no-verify" in rest or "-n" in rest) else "0"
            print("COMMIT\t%s\t%s\t%s" % (cpath, allf, nov)); sys.exit(0)
    i += 1
print("NOTCOMMIT")
PY
)"

case "$parsed" in
  NOTCOMMIT|"") allow ;;
esac

IFS=$'\t' read -r _kind cpath allflag noverify <<EOF
$parsed
EOF

[ "${noverify:-0}" = "1" ] && allow   # respect an explicit --no-verify bypass

# ── resolve the target repo ─────────────────────────────────────────────────
repo="$cpath"
[ -z "$repo" ] && repo="$cwd"
[ -z "$repo" ] && repo="$PWD"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || allow
# normalise to the worktree root so path matching is repo-relative
root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$root" ] && repo="$root"

# only govern repos that actually carry a df-context-store
[ -d "$repo/.claude/context" ] || allow

# ── collect the change set (repo-relative paths) ────────────────────────────
changed="$(git -C "$repo" diff --cached --name-only --diff-filter=ACMR 2>/dev/null)"
if [ "${allflag:-0}" = "1" ]; then
  # `commit -a` also sweeps in modified tracked files that aren't staged yet
  more="$(git -C "$repo" diff --name-only --diff-filter=ACMR 2>/dev/null)"
  changed="$(printf '%s\n%s\n' "$changed" "$more")"
fi
changed="$(printf '%s\n' "$changed" | sed '/^$/d' | awk '!seen[$0]++')"
[ -z "$changed" ] && allow   # nothing to commit → not our concern

# ── structural + context globs ──────────────────────────────────────────────
DEFAULT_STRUCTURAL='*contracts* *.proto *.avsc *.avdl *shared-models* *.sql *migration* *migrations* */schema/* schema/* */schemas/* */services/* services/* */service/*'
STRUCTURAL="${AGENT_NOTEPAD_STRUCTURAL_GLOBS:-$DEFAULT_STRUCTURAL}"
CONTEXT_GLOB="${AGENT_NOTEPAD_CONTEXT_GLOB:-.claude/context/*}"

OLDIFS=$IFS
struct_hits=""
ctx_updated=0
# Split the change set on newline only (filenames may contain spaces).
IFS='
'
for f in $changed; do
  # Restore default IFS so the glob lists below split on whitespace/newlines
  # (STRUCTURAL may be space- OR newline-separated per the env-override contract).
  IFS=$OLDIFS
  # context store updated?
  # shellcheck disable=SC2254
  case "$f" in $CONTEXT_GLOB) ctx_updated=1 ;; esac
  # structural?
  for g in $STRUCTURAL; do
    # shellcheck disable=SC2254
    case "$f" in $g) struct_hits="${struct_hits}${f}
"; break ;; esac
  done
  IFS='
'
done
IFS=$OLDIFS

# ── verdict ─────────────────────────────────────────────────────────────────
if [ -n "$struct_hits" ] && [ "$ctx_updated" -eq 0 ]; then
  hits="$(printf '%s' "$struct_hits" | sed '/^$/d' | sed 's/^/  - /')"
  reason="$(printf '%s\n%s\n\n%s\n%s\n%s\n%s' \
    "Commit blocked by agent-notepad: structural change in $repo is not reflected in its context store." \
    "Structural files staged:" \
    "$hits" \
    "…but no file under .claude/context/ is in this commit — the store is stale." \
    "Fix: update the repo's df-context-store (SERVICE-MAP.md / DATA-FLOW.md via the commit-sync / knowledge-keeper skill), stage it, and re-commit." \
    "Bypass (intentional): add --no-verify, or AGENT_NOTEPAD_COMMIT_GATE=off.")"
  block "$reason"
fi

allow
