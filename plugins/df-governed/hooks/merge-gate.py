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

MEASURED DEFECT: `<git-common-dir>/publish-gate.ok` only exists inside the checkout that
produced it, so it is unreachable when `gh pr merge` runs from a cwd outside the checkout —
the normal case for an orchestrator whose cwd is its own session directory, not a clone of
the repo it is merging in. That cwd used to be denied outright with "run the merge from
inside the checkout", and the record was never consulted at all. publish-gate.sh now
ADDITIONALLY writes the identical record to a per-user registry file keyed by repo slug —
`<registry-dir>/<owner>__<repo>.json`, owner/repo taken from the checkout's own origin
remote — so this hook can find it without needing cwd to be anywhere near the checkout. The
registry directory defaults to `~/.claude/df-governed/publish-gate` and is overridden by
`DF_PUBLISH_GATE_REGISTRY` (both here and in publish-gate.sh, so tests can point both halves
at the same scratch directory).

Resolution order: the registry entry for the target repo slug is read FIRST; the
`<git-common-dir>` record is consulted only as a fallback, and only when cwd is actually
inside a checkout whose own origin matches the target repo. cwd being somewhere else is
never, by itself, a reason to deny.

Contract: read the PreToolUse event JSON on stdin, print one JSON object, ALWAYS exit 0 (a
non-zero exit is a hook error, not a policy decision). Three possible outputs:

  {}                                            allow the tool call to proceed normally
  {"systemMessage": "<note>"}                   allow, but surface a visible note (used when
                                                 the target repo has no registry entry at all
                                                 and cwd cannot supply one either — this may
                                                 not be a gated repo, so the hook abstains
                                                 rather than assuming either way)
  {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                           "permissionDecision": "deny",
                           "permissionDecisionReason": "<specific reason>"}}

Not a merge command -> {}. A merge command in a repo that does not ship
boot-kit/scripts/publish-gate.sh, checked when cwd IS that repo's own checkout -> {} (this
gate is not that repo's business). A merge command whose target repo has never recorded a
gate run anywhere reachable -> {"systemMessage": ...} (see above — abstain, don't guess).
Anything that goes wrong while evaluating an in-scope merge with a KNOWN gated history ->
DENY, never allow: this hook fails CLOSED, because the whole point is that a
missing/stale/unreadable record must never read as permission.

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


def allow_with_message(message):
    """Allow the tool call, same as allow(), but surface a visible note. Used for the
    abstain case: the target repo has no record anywhere this hook can reach, which may
    mean it simply is not gated -- {} would be silently indistinguishable from that, so
    this says so instead of guessing either way."""
    print(json.dumps({"systemMessage": message}))
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


DEFAULT_REGISTRY_DIR = os.path.join(
    os.path.expanduser("~"), ".claude", "df-governed", "publish-gate"
)


def registry_dir():
    # Same env var publish-gate.sh honours, so a test can point both halves of the
    # feature at one scratch directory instead of two.
    return os.environ.get("DF_PUBLISH_GATE_REGISTRY") or DEFAULT_REGISTRY_DIR


def registry_path_for(slug):
    """Path to the registry file for an "owner/repo" slug. Tries the exact filename
    publish-gate.sh would have written (the origin URL's own casing) first, then falls
    back to a case-insensitive scan of the directory -- GitHub owner/repo names are
    case-insensitive, but a --repo flag or a cwd-derived slug is not guaranteed to match
    the casing the registry entry was written with byte-for-byte."""
    d = registry_dir()
    filename = slug.strip("/").replace("/", "__") + ".json"
    exact = os.path.join(d, filename)
    if os.path.isfile(exact):
        return exact
    try:
        names = os.listdir(d)
    except OSError:
        return exact
    target = filename.lower()
    for name in names:
        if name.lower() == target:
            return os.path.join(d, name)
    return exact


def record_from_path(path):
    """Load and validate a publish-gate record file. None if missing, unreadable, or not
    a JSON object -- callers treat that identically to "no record", never as a pass."""
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path) as fh:
            record = json.load(fh)
    except Exception:
        return None
    return record if isinstance(record, dict) else None


def check_record(record, head_sha):
    """The three checks a record must clear once it has been found, in the order the
    original single-source version applied them. Returns a deny reason, or None to allow."""
    if record.get("conf") != "real":
        return (
            "placeholder conf: the local publish-gate run that produced this record used "
            "the placeholder landmark patterns, not the real ones"
        )
    if record.get("dirty") is not False:
        return (
            "dirty tree: the local publish-gate run that produced this record was made "
            "with uncommitted changes present"
        )
    record_commit = record.get("commit")
    if not isinstance(record_commit, str) or record_commit != head_sha:
        got = (record_commit or "")[:7] or "none"
        want = head_sha[:7]
        return "commit mismatch: publish-gate.ok is for %s, the PR head is %s" % (got, want)
    return None


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
    if not pr_number:
        deny("merge-gate: could not determine the PR number from the merge command")

    cwd = event.get("cwd") or ""

    # cwd's own checkout, if it has one. This is used two ways below: to resolve a target
    # repo slug when the command carries no --repo/-R, and to decide whether the
    # <git-common-dir> record is even reachable as a fallback. Neither use requires cwd to
    # be inside any PARTICULAR checkout -- cwd not being a git repo at all is not an error
    # by itself, only a reason those two things are unavailable.
    cwd_checkout = None
    cwd_origin_repo = None
    toplevel_proc = git(["rev-parse", "--show-toplevel"], cwd)
    if toplevel_proc.returncode == 0 and toplevel_proc.stdout.strip():
        cwd_checkout = toplevel_proc.stdout.strip()
        origin_proc = git(["remote", "get-url", "origin"], cwd_checkout)
        if origin_proc.returncode == 0 and origin_proc.stdout.strip():
            cwd_origin_repo = parse_owner_repo(origin_proc.stdout.strip())

    if repo_flag:
        target_repo = repo_flag.strip("/")
    elif cwd_origin_repo:
        target_repo = cwd_origin_repo
    else:
        deny(
            "merge-gate: could not determine the target repo (no --repo/-R on the "
            "command and cwd is not a git checkout)"
        )

    # "Matching checkout": cwd is a git repo AND its own origin IS the target repo. Only
    # in this case is the <git-common-dir> record reachable, or the gate_script presence
    # check meaningful -- cwd being some OTHER repo, or no repo, must never by itself
    # deny a merge of a DIFFERENT repo named via --repo.
    matching_checkout = (
        cwd_checkout is not None
        and cwd_origin_repo is not None
        and cwd_origin_repo.lower() == target_repo.lower()
    )

    if matching_checkout:
        gate_script = os.path.join(cwd_checkout, "boot-kit", "scripts", "publish-gate.sh")
        if not os.path.isfile(gate_script):
            # This repo does not ship a publish gate at all -- not this hook's business.
            allow()

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
            cwd=cwd_checkout,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except subprocess.TimeoutExpired:
        deny("merge-gate: gh error (timed out resolving the PR head sha)")
    except Exception as e:
        deny("merge-gate: gh error (%s)" % type(e).__name__)
    if pr_proc.returncode != 0 or not pr_proc.stdout.strip():
        detail = (pr_proc.stderr or "").strip()[:200] or "could not resolve the PR head sha"
        deny("merge-gate: gh error (%s)" % detail)
    head_sha = pr_proc.stdout.strip()

    # Registry FIRST: it is the only path reachable when cwd is not the checkout. The
    # <git-common-dir> record is a fallback, tried only when cwd actually IS the checkout
    # for this exact target repo.
    record = record_from_path(registry_path_for(target_repo))

    if record is None and matching_checkout:
        common_proc = git(["rev-parse", "--git-common-dir"], cwd_checkout)
        if common_proc.returncode == 0 and common_proc.stdout.strip():
            common_dir = common_proc.stdout.strip()
            if not os.path.isabs(common_dir):
                common_dir = os.path.normpath(os.path.join(cwd_checkout, common_dir))
            record = record_from_path(os.path.join(common_dir, "publish-gate.ok"))

    if record is None:
        if matching_checkout:
            # cwd IS this repo's own checkout, and it ships the gate (checked above) --
            # so this repo is definitely gated, and "no record anywhere" is a real finding.
            deny(
                "no record: publish-gate.sh has not been run locally against this PR's head"
            )
        # cwd can't confirm this repo is gated at all, and the registry has never heard of
        # it either -- a repo that never ran the gate looks identical to one that is not
        # gated. Abstain rather than guess either way, but say so instead of a silent {}.
        allow_with_message(
            "merge-gate: no publish-gate record for %s (no registry entry, and cwd is "
            "not that repo's checkout) -- abstaining, this may not be a gated repo"
            % target_repo
        )

    reason = check_record(record, head_sha)
    if reason:
        deny(reason)

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
