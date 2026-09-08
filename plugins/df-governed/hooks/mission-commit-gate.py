#!/usr/bin/env python3
"""mission-commit-gate — PreToolUse(Bash): while a mission is RUNNING in this session's
notepad, refuse a `git commit` whose message names neither the mission nor a tracker item.

WHY. `skills/agent-notepad/plugin/hooks/commit-gate.sh` resolves the RUNNING mission by
walking up from the COMMIT TARGET (`find_notepad(cpath or hook_cwd)`, where `cpath` comes
from `-C <path>` on the git command itself). From a notepad session with a mission RUNNING,
`git -C ~/Code/some-repo commit -m wip` walks up from the code repo, finds no notepad above
it, finds no mission, and is ALLOWED — only commits INTO the notepad were ever checked. Two
facts were conflated: the MISSION is a property of the SESSION (walk up from the hook's own
cwd, the way `handoff-completeness-gate.py`'s `resolve_notepad` already does for the Stop
gate), while STALENESS (the df-context-store check `commit-gate.sh` also runs) is a property
of the TARGET repo — those are different questions and only one of them cares where `-C`
points. This hook ships the mission half as code, inside the plugin, so it travels with
`--plugin-dir` and arms in every session the plugin loads in, including headless workers the
project-level `commit-gate.sh` (wired per notepad in `.claude/settings.json`) never reaches
at all. The staleness half is unchanged and stays exactly where it is.

CONTRACT. Read the PreToolUse event JSON on stdin, print one JSON object, ALWAYS exit 0 (a
non-zero exit is a hook error, not a policy decision):

  {}                                            allow (not a commit, no RUNNING mission,
                                                 outside any notepad, or the message already
                                                 names the mission)
  {"systemMessage": "<note>"}                   allow, but note an internal error — this hook
                                                 fails OPEN, since a commit gate that can
                                                 crash closed traps every later commit in the
                                                 session on a bug in THIS file
  {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                           "permissionDecision": "deny",
                           "permissionDecisionReason": "<specific reason>"}}

MISSION RESOLUTION is by the SESSION's cwd (`event["cwd"]`), walking up for `NOTES.md` —
never by the commit's own `-C`/`--chdir`/`cd` target, which wrapper detection below still
finds (so a commit into some other repo cannot dodge the rule by relocating), but which plays
no part in deciding whether the rule applies or where a `-F` message file is read from (both
of those are always relative to the session's own cwd, matching `commit-gate.sh`'s embedded
python, which threads `hook_cwd` — never `cpath` — into its own file read).

MESSAGE EXTRACTION copies `commit-gate.sh`'s embedded python exactly: `-m`/`-am`/`-mX`/
`--message`/`--message=X` (parts joined), `-F FILE`/`--file FILE`/`--file=FILE` (read
relative to the session cwd; unreadable -> deny), `-C <commit>`/`-c <commit>` reuse -> deny
(not inspectable here), no message source at all -> deny (an editor would open). `--no-verify`
and `-n` do NOT bypass this predicate — the hook governs the agent driving Bash, not a human
committer, so a bypass flag here would just turn the mechanism back into an instruction; the
denial reason says so explicitly when the flag is present.

No estate names, hosts, people, or machine paths appear in this file or in anything it
prints — it is generic Tier-1 method, shipped in a public repo.
"""
import json
import os
import re
import shlex
import sys

# Shell control operators that separate independent commands within one Bash tool call, so a
# commit smuggled after `&&`/`;`/`|` is still caught. Copied from merge-gate.py so both hooks
# agree on what counts as a separate subcommand.
SEP_TOKENS = {"&&", "||", ";", ";;", "|", "|&"}
SHELLS = ("bash", "sh", "zsh", "dash", "ksh")

TRACKER_RE = re.compile(r"\b1[0-9]{10,}\b")
MISSION_RE = re.compile(r"\bM-[A-Z0-9][A-Z0-9-]{3,}\b")
# Raw-text fallback when shlex cannot tokenise the command (see evaluate()).
RAW_COMMIT_RE = re.compile(r"\bgit\b[\s\S]*?\bcommit\b")

# git global options that consume the following token as their value (between `git` and the
# subcommand). `-C` is handled separately below, both spaced and glued (`-C/path`).
VAL_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
            "--super-prefix", "--config-env"}


def allow():
    print("{}")
    sys.exit(0)


def deny(reason):
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    sys.exit(0)


def split_commands(command):
    """Split a Bash command string into a list of argv-token lists, one per subcommand,
    breaking on shell control operators. Best-effort: this is a hook-side heuristic, not a
    real shell parser. Copied from merge-gate.py."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
    commands = []
    current = []
    for tok in tokens:
        if tok in SEP_TOKENS:
            if current:
                commands.append(current)
            current = []
        else:
            current.append(tok)
    if current:
        commands.append(current)
    return commands


def git_argvs(tokens):
    """Every git argv reachable from this token list: `git` found by basename anywhere in
    the tokens, so a prefix wrapper (env, env -C/--chdir, nice, timeout, an absolute or
    relative path to git, ...) does not hide it, plus recursion into `bash -c "<script>"` /
    `sh -c` / `eval "<script>"` bodies (split the same way and searched again) — the same
    wrapper handling as merge-gate.py's `gh_argvs`. Unlike that function, this one does NOT
    track any `-C`/`--chdir`/`cd` relocation: the commit TARGET plays no part in whether this
    gate applies (mission resolution is by the SESSION's cwd — see the module docstring), so
    there is nothing to carry forward."""
    out = []
    for i, tok in enumerate(tokens):
        base = tok.rsplit("/", 1)[-1]
        if base == "git":
            out.append(tokens[i:])
            break
        if base in SHELLS or base == "eval":
            for j in range(i + 1, len(tokens)):
                nxt = tokens[j]
                if base == "eval" or (nxt.startswith("-") and "c" in nxt and j + 1 < len(tokens)):
                    script = nxt if base == "eval" else tokens[j + 1]
                    try:
                        for sub in split_commands(script):
                            out.extend(git_argvs(sub))
                    except ValueError:
                        pass
                    break
            break
    return out


def git_subcommand(argv):
    """argv[0] is 'git'. Returns (subcommand_or_None, tokens_after_subcommand) — mirrors
    commit-gate.sh's embedded `scan()`, minus its `cpath` bookkeeping, which this gate does
    not need (see `git_argvs`)."""
    i, n = 1, len(argv)
    while i < n:
        t = argv[i]
        if t == "-C" and i + 1 < n:
            i += 2
            continue
        if t.startswith("-C") and len(t) > 2:
            i += 1
            continue
        if t in VAL_OPTS and i + 1 < n:
            i += 2
            continue
        if t.startswith("--") and "=" in t:
            i += 1
            continue
        if t.startswith("-"):
            i += 1
            continue
        return t, argv[i + 1:]
    return None, []


def read_msg_file(path, cwd):
    p = path if os.path.isabs(path) else os.path.join(cwd or os.getcwd(), path)
    try:
        with open(p, "r", errors="replace") as fh:
            return "OK", fh.read()
    except OSError as e:
        return "FILE_ERR", "%s (%s)" % (p, e.strerror or e)


def extract_message(tokens, cwd):
    """Scan tokens AFTER the 'commit' subcommand for a message source. Returns
    (status, value): status in OK/FILE_ERR/REUSE/NONE/MISSING_VAL. Copied from
    commit-gate.sh's embedded `extract_message` exactly, including reading `-F`/`--file`
    relative to the SESSION cwd (`cwd` here is always `event["cwd"]`, never any `-C`/`cd`
    target the command itself carries)."""
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


def resolve_notepad(cwd):
    """Walk up from cwd for the nearest NOTES.md — same resolution as
    handoff-completeness-gate.py's `resolve_notepad`, so the two gates never disagree on
    what session this is."""
    if not cwd:
        return None
    p = os.path.abspath(cwd)
    while True:
        if os.path.isfile(os.path.join(p, "NOTES.md")):
            return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


def running_missions(notepad):
    missions_dir = os.path.join(notepad, ".df", "missions")
    out = []
    if not os.path.isdir(missions_dir):
        return out
    for name in sorted(os.listdir(missions_dir)):
        state_path = os.path.join(missions_dir, name, "state")
        if not os.path.isfile(state_path):
            continue
        with open(state_path, encoding="utf-8", errors="replace") as f:
            if f.readline().strip() == "RUNNING":
                out.append(name)
    return out


def mission_block_reason(mission_ids, why):
    names = ", ".join(sorted(mission_ids))
    return (
        "mission-commit-gate: mission %s is RUNNING, so this commit message must name a "
        "tracker item id (\\b1[0-9]{10,}\\b, e.g. 12983000509) or a mission id "
        "(\\bM-[A-Z0-9][A-Z0-9-]{3,}\\b, e.g. M-KITV2-20260905). %s"
    ) % (names, why)


def evaluate(event):
    if not isinstance(event, dict) or event.get("tool_name") != "Bash":
        allow()

    command = (event.get("tool_input") or {}).get("command")
    if not isinstance(command, str) or not command.strip():
        allow()

    cwd = event.get("cwd") or ""
    notepad = resolve_notepad(cwd)
    if not notepad:
        allow()

    missions = running_missions(notepad)
    if not missions:
        allow()

    try:
        commands = split_commands(command)
    except ValueError as e:
        # The same lexer as merge-gate.py, and the same failure (third homelab run, 2026-09-08):
        # an apostrophe inside a heredoc body is prose to bash and an unclosed quote to shlex.
        # Falling to main()'s "internal error" here would fail OPEN -- and a commit whose message
        # is smuggled behind an unbalanced quote is exactly the shape a gate must not wave
        # through. So: text that mentions a git commit is held to the id rule over the WHOLE
        # command text (an id anywhere in it satisfies the rule); anything else is allowed.
        if RAW_COMMIT_RE.search(command):
            if TRACKER_RE.search(command) or MISSION_RE.search(command):
                allow()
            deny(
                mission_block_reason(
                    missions,
                    "The command could not be tokenised (%s -- an unbalanced quote, often an "
                    "apostrophe inside a heredoc body), so the message could not be read, and "
                    "the command text as a whole names neither. Put the message in -m or in a "
                    "file passed with -F." % e,
                )
            )
        allow()

    for tokens in commands:
        for argv in git_argvs(tokens):
            sub, after_commit = git_subcommand(argv)
            if sub != "commit":
                continue

            rest = argv[1:]
            no_verify = "--no-verify" in rest or "-n" in rest
            bypass_note = (
                " --no-verify does not bypass the mission commit gate." if no_verify else ""
            )

            status, value = extract_message(after_commit, cwd)
            if status == "OK":
                if TRACKER_RE.search(value) or MISSION_RE.search(value):
                    continue
                deny(
                    mission_block_reason(missions, "The commit message names neither.")
                    + bypass_note
                )
            elif status == "FILE_ERR":
                deny(
                    mission_block_reason(
                        missions, "The message file %s could not be read." % value
                    )
                    + bypass_note
                )
            elif status == "REUSE":
                deny(
                    mission_block_reason(
                        missions,
                        "The message is reused from another commit (-C/-c) and is not "
                        "inspectable here.",
                    )
                    + bypass_note
                )
            elif status == "NONE":
                deny(
                    mission_block_reason(
                        missions,
                        "No -m/--message/-F/--file was given — an editor would open, "
                        "which a hook cannot inspect.",
                    )
                    + bypass_note
                )
            elif status == "MISSING_VAL":
                deny("mission-commit-gate: could not parse the commit command — %s" % value)

    allow()


def main():
    try:
        raw = sys.stdin.read()
        event = json.loads(raw)
        evaluate(event)
    except SystemExit:
        raise
    except Exception as e:
        print(json.dumps({"systemMessage": "mission-commit-gate: internal error %s" % type(e).__name__}))
        sys.exit(0)


if __name__ == "__main__":
    main()
