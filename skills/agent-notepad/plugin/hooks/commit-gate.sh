#!/usr/bin/env bash
# hooks/commit-gate.sh — U8 code-commit staleness gate (DESIGN §7.6, acceptance 7).
#
# Wiring: PreToolUse on Bash, declared in the NOTEPAD's .claude/settings.json so it
# arms only in notepad sessions and governs AGENT git-commits (manual human commits
# are governed by that repo's own git pre-commit hook — see df-context-store).
#
# Contract (hook recipe): read the tool-call JSON on stdin, inspect
# tool_input.command; emit {} to allow, or a block decision (both the documented
# permissionDecision and the legacy top-level decision) with exit 2 — see block().
#
# What it does: if the command is a `git [ -C <repo> ] commit …`, resolve the
# target repo and run a SIMPLE, documented staleness check —
#   staged (and, for `commit -a`, unstaged-tracked) changes that touch STRUCTURAL
#   globs (schema / contract / migration / service dirs, configurable) while the
#   repo's `.claude/context/` store has NO file in the same change set  →  DRIFT.
# Drift → block with a fix hint. Everything else → allow ({}).
#
# NEW predicate (additive, DESIGN §2 Objective 6 + dispatcher amendments): resolve
# the NOTEPAD the commit targets (the `-C <path>` or `cwd`; walk up for NOTES.md).
# If that notepad has any `.df/missions/<id>/state` whose first line is RUNNING,
# the commit MESSAGE must name a tracker item id (`\b1[0-9]{10,}\b`) or a mission
# id (`\bM-[A-Z0-9][A-Z0-9-]{3,}\b`) — otherwise BLOCK, naming the RUNNING
# mission(s) and the two accepted forms. `--no-verify` does NOT bypass this
# predicate (the hook governs the agent driving Bash, not a human committer; a
# bypass here would just turn the mechanism back into an instruction) — it still
# bypasses the older df-context-store staleness rule below, unchanged. No RUNNING
# mission, or a commit outside any notepad, falls straight through to the
# pre-existing behaviour.
#
# Abstains ({}) when: not a commit; no RUNNING mission governs the commit AND
# (repo unresolved / not a git worktree; repo has no `.claude/context/` store
# (nothing to govern); nothing staged; `--no-verify` in the command); or
# AGENT_NOTEPAD_COMMIT_GATE=off.
#
# Config (env, all optional):
#   AGENT_NOTEPAD_COMMIT_GATE=off        disable the gate entirely (both rules)
#   AGENT_NOTEPAD_STRUCTURAL_GLOBS=...   newline/space-separated case-globs to treat
#                                        as structural (overrides the default set)
#   AGENT_NOTEPAD_CONTEXT_GLOB=...       glob whose match counts as "store updated"
#                                        (default: .claude/context/*)
set -u

allow() { printf '{}\n'; exit 0; }
block() { # reason-text
  # Two output shapes on purpose. The documented PreToolUse decision is
  # hookSpecificOutput.permissionDecision (code.claude.com/docs/en/hooks); the top-level
  # {decision:"block"} this gate used to emit is no longer in the docs, though the harness
  # in use here still honours it. Emitting both keeps older and newer harnesses blocking.
  # Exit 2 is the third belt: the docs list exit 2 as "Blocks the tool call" for PreToolUse
  # independent of JSON, and say the JSON decision supplies the message when present.
  jq -n --arg r "$1" '{decision:"block", reason:$r,
      hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny",
                          permissionDecisionReason:$r}}' 2>/dev/null \
    || printf '{"decision":"block","reason":%s}\n' "\"${1//\"/\\\"}\""
  printf '%s\n' "$1" >&2
  exit 2
}

[ "${AGENT_NOTEPAD_COMMIT_GATE:-on}" = "off" ] && allow

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cmd" ] && allow

# ── parse the command: is it a git-commit? extract -C <path>, -a/--all, and ──
# ── (new) run the mission-RUNNING message-format predicate ───────────────────
# python3 + shlex tokenization handles `git -C <path> commit`, quoting, and a
# `git commit` segment inside a compound command. Also resolves the notepad
# (walk up from -C path or cwd for NOTES.md), checks its
# `.df/missions/<id>/state` files for RUNNING, and — only when at least one is
# RUNNING — extracts the commit message (`-m`, `-m<text>`, `--message=<text>`,
# `-F <file>`/`--file=<file>`, or the `-C`/`-c <commit>` reuse forms) and checks
# it against the tracker-id / mission-id patterns. Prints one of:
#   NOTCOMMIT
#   COMMIT\t<repo-or-empty>\t<all:0|1>\t<noverify:0|1>
#   MISSION_BLOCK\n<reason, one or more lines>
parsed="$(python3 - "$cmd" "$cwd" <<'PY'
import glob, os, re, shlex, sys

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
hook_cwd = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    toks = shlex.split(cmd)
except ValueError:
    print("NOTCOMMIT"); sys.exit(0)

# git global options that consume the following token as their value
VAL_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
            "--super-prefix", "--config-env"}

def scan(start):
    """From token index `start` (just after a 'git'), return (subcmd, cpath, subidx)."""
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
        return t, cpath, i                          # first bare token = subcommand
    return None, cpath, i

TRACKER_RE = re.compile(r"\b1[0-9]{10,}\b")
MISSION_RE = re.compile(r"\bM-[A-Z0-9][A-Z0-9-]{3,}\b")

def find_notepad(start):
    """Walk up from `start` looking for a NOTES.md marker file. None if not found."""
    if not start:
        return None
    d = os.path.abspath(start)
    while True:
        if os.path.isfile(os.path.join(d, "NOTES.md")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent

def running_missions(notepad):
    ids = []
    for state_file in sorted(glob.glob(os.path.join(notepad, ".df", "missions", "*", "state"))):
        try:
            with open(state_file, "r", errors="replace") as fh:
                first = fh.readline().strip()
        except OSError:
            continue
        if first == "RUNNING":
            ids.append(os.path.basename(os.path.dirname(state_file)))
    return ids

def read_msg_file(path, cwd):
    p = path if os.path.isabs(path) else os.path.join(cwd or os.getcwd(), path)
    try:
        with open(p, "r", errors="replace") as fh:
            return "OK", fh.read()
    except OSError as e:
        return "FILE_ERR", "%s (%s)" % (p, e.strerror or e)

def extract_message(tokens, cwd):
    """Scan tokens AFTER the 'commit' subcommand for a message source.
    Returns (status, value): status in OK/FILE_ERR/REUSE/NONE/MISSING_VAL."""
    parts = []
    got = False
    i, n = 0, len(tokens)
    while i < n:
        t = tokens[i]
        if t == "-am":
            if i + 1 >= n:
                return "MISSING_VAL", "-am requires a value"
            parts.append(tokens[i + 1]); got = True; i += 2; continue
        if t == "-m":
            if i + 1 >= n:
                return "MISSING_VAL", "-m requires a value"
            parts.append(tokens[i + 1]); got = True; i += 2; continue
        if t.startswith("-m") and len(t) > 2 and not t.startswith("--"):
            parts.append(t[2:]); got = True; i += 1; continue
        if t == "--message":
            if i + 1 >= n:
                return "MISSING_VAL", "--message requires a value"
            parts.append(tokens[i + 1]); got = True; i += 2; continue
        if t.startswith("--message="):
            parts.append(t[len("--message="):]); got = True; i += 1; continue
        if t in ("-F", "--file"):
            if i + 1 >= n:
                return "MISSING_VAL", "%s requires a value" % t
            return read_msg_file(tokens[i + 1], cwd)
        if t.startswith("--file="):
            return read_msg_file(t[len("--file="):], cwd)
        if t in ("-C", "-c"):
            if i + 1 >= n:
                return "MISSING_VAL", "%s requires a value" % t
            return "REUSE", None
        i += 1
    if got:
        return "OK", "\n".join(parts)
    return "NONE", None

def mission_block_reason(mission_ids, why):
    names = ", ".join(sorted(mission_ids))
    return (
        "Commit blocked by agent-notepad: mission %s is RUNNING, so this commit "
        "message must name a tracker item id (\\b1[0-9]{10,}\\b, e.g. 12983000509) "
        "or a mission id (\\bM-[A-Z0-9][A-Z0-9-]{3,}\\b, e.g. M-KITV2-20260905). %s\n"
        "Fix: re-commit with a message naming the ticket or mission you are working, "
        "e.g. `close 12983000509` or `map: M-KITV2-20260905 frontier`."
    ) % (names, why)

i, n = 0, len(toks)
while i < n:
    if os.path.basename(toks[i]) == "git":
        sub, cpath, subidx = scan(i + 1)
        if sub == "commit":
            rest = toks[i + 1:]
            after_commit = toks[subidx + 1:]
            allf = "1" if ("-a" in rest or "--all" in rest or "-am" in rest) else "0"
            nov  = "1" if ("--no-verify" in rest or "-n" in rest) else "0"

            notepad = find_notepad(cpath or hook_cwd)
            running = running_missions(notepad) if notepad else []
            if running:
                status, value = extract_message(after_commit, hook_cwd)
                if status == "OK":
                    if TRACKER_RE.search(value) or MISSION_RE.search(value):
                        pass  # message satisfies the rule; fall through to COMMIT
                    else:
                        reason = mission_block_reason(
                            running, "The commit message names neither.")
                        if nov == "1":
                            reason += " --no-verify does not bypass the mission commit gate."
                        print("MISSION_BLOCK"); print(reason); sys.exit(0)
                elif status == "FILE_ERR":
                    reason = mission_block_reason(
                        running, "The message file %s could not be read." % value)
                    if nov == "1":
                        reason += " --no-verify does not bypass the mission commit gate."
                    print("MISSION_BLOCK"); print(reason); sys.exit(0)
                elif status == "REUSE":
                    reason = mission_block_reason(
                        running, "The message is reused from another commit (-C/-c) "
                        "and is not inspectable here.")
                    if nov == "1":
                        reason += " --no-verify does not bypass the mission commit gate."
                    print("MISSION_BLOCK"); print(reason); sys.exit(0)
                elif status == "NONE":
                    reason = mission_block_reason(
                        running, "No -m/--message/-F/--file was given — an editor "
                        "would open, which a hook cannot inspect.")
                    if nov == "1":
                        reason += " --no-verify does not bypass the mission commit gate."
                    print("MISSION_BLOCK"); print(reason); sys.exit(0)
                elif status == "MISSING_VAL":
                    reason = ("commit-gate: could not parse the commit command — %s" % value)
                    if nov == "1":
                        reason += " --no-verify does not bypass the mission commit gate."
                    print("MISSION_BLOCK"); print(reason); sys.exit(0)

            print("COMMIT\t%s\t%s\t%s" % (cpath, allf, nov)); sys.exit(0)
    i += 1
print("NOTCOMMIT")
PY
)"

first_line="$(printf '%s\n' "$parsed" | head -n 1)"

case "$first_line" in
  NOTCOMMIT|"") allow ;;
  MISSION_BLOCK)
    reason="$(printf '%s\n' "$parsed" | tail -n +2)"
    block "$reason"
    ;;
esac

IFS=$'\t' read -r _kind cpath allflag noverify <<EOF
$first_line
EOF

[ "${noverify:-0}" = "1" ] && allow   # respect an explicit --no-verify bypass (old rule only)

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
