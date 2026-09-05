#!/usr/bin/env python3
"""merge-gate — PreToolUse(Bash): refuse a PR merge that a real local publish-gate run has
not verified at the PR's own head sha.

WHY: a public repo's publish-gate.sh reads its real denylist from a gitignored local config.
CI never sees that config, so CI's run is always the placeholder-pattern run by design — a
real leak can sit on a green PR indefinitely, because "run the real gate locally before
merging" is a sentence in a doc, not something the merge itself depends on. This hook makes
that dependency mechanical: publish-gate.sh (additively) writes a record —
`<git-common-dir>/publish-gate.ok` — only when it just ran CLEAN against the real config on
a clean tree, and this hook refuses `gh pr merge` / `gh api .../pulls/<n>/merge` unless that
record exists, names the real config, is clean, and matches the PR's current head sha.

Contract: read the PreToolUse event JSON on stdin, print one JSON object, ALWAYS exit 0 (a
non-zero exit is a hook error, not a policy decision). Two possible outputs:

  {}                                            allow the tool call to proceed normally
  {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                           "permissionDecision": "deny",
                           "permissionDecisionReason": "<specific reason>"}}

Not a merge command -> {}. A merge command in a repo that does not ship
boot-kit/scripts/publish-gate.sh -> {} (this gate is not that repo's business). Anything
that goes wrong while evaluating an in-scope merge -> DENY, never allow: this hook fails
CLOSED, because the whole point is that a missing/stale/unreadable record must never read as
permission.

No estate names, hosts, people, or machine paths appear in this file or in anything it
prints — it is generic Tier-1 method, shipped in a public repo.
"""
import json
import os
import re
import shlex
import subprocess
import sys

# gh flags (on `gh pr merge` and `gh pr view`) that consume the NEXT token as a value, so a
# bare-token scan for the PR number must skip both the flag and its value together, not just
# the flag. Boolean flags (--admin, --auto, -m/--merge, -s/--squash, -r/--rebase, --delete-
# branch, --disable-auto, ...) consume nothing extra and fall through to the generic skip.
VALUE_FLAGS = {"--repo", "-R", "--subject", "--body", "--body-file", "--match-head-commit"}

# Shell control operators that separate independent commands within one Bash tool call. A
# merge smuggled after `&&`/`;`/`|` must still be caught, so the command is split on these
# BEFORE each piece is parsed with shlex, rather than shlex-ing the whole string as one command.
SEP_TOKENS = {"&&", "||", ";", ";;", "|", "|&"}

API_MERGE_RE = re.compile(r"repos/([^/\s]+/[^/\s]+)/pulls/(\d+)/merge")
API_MERGE_NOREPO_RE = re.compile(r"(?:^|[\s/])pulls/(\d+)/merge(?:$|[\s/?])")


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
    real shell parser."""
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


def first_positional(tokens):
    """First token that is not a flag and not a flag's value, or None."""
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok.startswith("-") and tok != "-":
            if "=" in tok:
                i += 1
                continue
            if tok in VALUE_FLAGS:
                i += 2
                continue
            i += 1
            continue
        return tok
    return None


def find_flag_value(tokens, names):
    for i, tok in enumerate(tokens):
        for name in names:
            if tok == name and i + 1 < len(tokens):
                return tokens[i + 1]
            if tok.startswith(name + "="):
                return tok[len(name) + 1 :]
    return None


def detect_merge(tokens):
    """Return (pr_number_or_None, repo_flag_or_None) if these tokens invoke a PR merge,
    else None."""
    if not tokens or tokens[0] != "gh":
        return None

    if len(tokens) >= 3 and tokens[1] == "pr" and tokens[2] == "merge":
        repo = find_flag_value(tokens, ("--repo", "-R"))
        pr = first_positional(tokens[3:])
        return (pr, repo)

    if len(tokens) >= 2 and tokens[1] == "api":
        joined = " ".join(tokens)
        m = API_MERGE_RE.search(joined)
        if m:
            return (m.group(2), m.group(1))
        m2 = API_MERGE_NOREPO_RE.search(joined)
        if m2:
            repo = find_flag_value(tokens, ("--repo", "-R"))
            return (m2.group(1), repo)
        return None

    return None


def parse_owner_repo(url):
    url = url.strip()
    m = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$", url)
    if not m:
        return None
    return "%s/%s" % (m.group(1), m.group(2))


def git(args, cwd, timeout=10):
    return subprocess.run(
        ["git"] + args, cwd=cwd, capture_output=True, text=True, timeout=timeout
    )


def evaluate(event):
    if not isinstance(event, dict) or event.get("tool_name") != "Bash":
        allow()

    command = (event.get("tool_input") or {}).get("command")
    if not isinstance(command, str) or not command.strip():
        allow()

    merge_hit = None
    for tokens in split_commands(command):
        hit = detect_merge(tokens)
        if hit:
            merge_hit = hit
            break

    if merge_hit is None:
        allow()

    pr_number, repo_flag = merge_hit
    cwd = event.get("cwd") or ""

    NOT_IN_CHECKOUT = (
        "run the merge from inside the checkout so the publish-gate record can be verified"
    )

    toplevel_proc = git(["rev-parse", "--show-toplevel"], cwd)
    if toplevel_proc.returncode != 0 or not toplevel_proc.stdout.strip():
        deny(NOT_IN_CHECKOUT)
    checkout = toplevel_proc.stdout.strip()

    origin_proc = git(["remote", "get-url", "origin"], checkout)
    if origin_proc.returncode != 0 or not origin_proc.stdout.strip():
        deny(NOT_IN_CHECKOUT)
    origin_repo = parse_owner_repo(origin_proc.stdout.strip())
    if not origin_repo:
        deny(NOT_IN_CHECKOUT)

    if repo_flag:
        if repo_flag.strip("/").lower() != origin_repo.lower():
            deny(NOT_IN_CHECKOUT)
        target_repo = repo_flag
    else:
        target_repo = origin_repo

    gate_script = os.path.join(checkout, "boot-kit", "scripts", "publish-gate.sh")
    if not os.path.isfile(gate_script):
        # This repo does not ship a publish gate at all -- not this hook's business.
        allow()

    if not pr_number:
        deny("merge-gate: could not determine the PR number from the merge command")

    try:
        pr_proc = subprocess.run(
            [
                "gh",
                "pr",
                "view",
                str(pr_number),
                "--repo",
                target_repo,
                "--json",
                "headRefOid",
                "-q",
                ".headRefOid",
            ],
            cwd=checkout,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except subprocess.TimeoutExpired:
        deny("merge-gate: gh error (timed out resolving the PR head sha)")
    if pr_proc.returncode != 0 or not pr_proc.stdout.strip():
        detail = (pr_proc.stderr or "").strip()[:200] or "could not resolve the PR head sha"
        deny("merge-gate: gh error (%s)" % detail)
    head_sha = pr_proc.stdout.strip()

    common_proc = git(["rev-parse", "--git-common-dir"], checkout)
    if common_proc.returncode != 0 or not common_proc.stdout.strip():
        deny("merge-gate: internal error git-common-dir")
    common_dir = common_proc.stdout.strip()
    if not os.path.isabs(common_dir):
        common_dir = os.path.normpath(os.path.join(checkout, common_dir))
    record_path = os.path.join(common_dir, "publish-gate.ok")

    if not os.path.isfile(record_path):
        deny(
            "no record: publish-gate.sh has not been run locally against this PR's "
            "head (%s not found)" % os.path.relpath(record_path, checkout)
            if record_path.startswith(checkout)
            else "no record: publish-gate.sh has not been run locally against this PR's head"
        )

    try:
        with open(record_path) as fh:
            record = json.load(fh)
        if not isinstance(record, dict):
            raise ValueError("record is not a JSON object")
    except Exception:
        deny("no record: publish-gate.ok is unreadable or invalid")

    if record.get("conf") != "real":
        deny(
            "placeholder conf: the local publish-gate run that produced this record used "
            "the placeholder landmark patterns, not the real ones"
        )

    if record.get("dirty") is not False:
        deny(
            "dirty tree: the local publish-gate run that produced this record was made "
            "with uncommitted changes present"
        )

    record_commit = record.get("commit")
    if not isinstance(record_commit, str) or record_commit != head_sha:
        got = (record_commit or "")[:7] or "none"
        want = head_sha[:7]
        deny(
            "commit mismatch: publish-gate.ok is for %s, the PR head is %s"
            % (got, want)
        )

    allow()


def main():
    try:
        raw = sys.stdin.read()
        event = json.loads(raw)
        evaluate(event)
    except SystemExit:
        raise
    except Exception as e:
        deny("merge-gate: internal error %s" % type(e).__name__)


if __name__ == "__main__":
    main()
