#!/usr/bin/env python3
"""PreToolUse hook: turn the Promise-Theory dispatch doctrine into a DECISION, not advice.

The prior version of this hook (df-dispatch-subagents-reminder.py) only ever emitted
additionalContext — a paragraph the dispatching agent was free to skim and ignore. This
version denies the tool call outright unless the dispatch prompt carries all three of a
PROMISE, an EVIDENCE clause naming an unforgeable artifact, and a BOUND. A gate that can
be talked past by a busy agent is not a gate; PreToolUse can actually block the call, so
this is where the doctrine belongs.

Fails CLOSED: any parse error or missing field denies rather than passes through, because a
gate with a mute button is a gate people learn to ignore.
"""
import json
import re
import sys

ARTIFACT_RE = re.compile(
    r"(\S+/\S+\.[A-Za-z0-9]{1,8})"          # a path: has a slash AND an extension
    r"|(\bexit\s+code\b|\bexit\s+\d+\b)"     # an exit code mention
    r"|(\bcommit\b|\bsha\b|\b[0-9a-f]{7,40}\b)"  # a sha / the word commit
    r"|(\b\d{10,}\b)"                        # a ticket/item id (10+ digits)
    r"|(https?://\S+)"                       # a URL
    r"|(\bdiff\b|\btest output\b|\bverbatim\b)",  # the literal words
    re.IGNORECASE,
)

BOUND_KEYWORDS = ("bounds", "budget", "scope", "only under", "do not", "max-turns", "tool calls")


def first_word(line):
    s = line.strip()
    s = re.sub(r"^[#>\-\*\s]+", "", s)   # strip leading heading/list/bold decoration
    s = s.replace("*", "").strip()        # strip stray bold markers anywhere in the prefix
    if not s:
        return ""
    return re.split(r"\s+", s, maxsplit=1)[0].strip(":—-*").lower()


def has_promise_clause(text):
    # Either a heading/line that opens with PROMISE, or an inline "PROMISE:" / "PROMISE —"
    # label anywhere in a line. The dispatcher's research briefs use the inline form
    # ("Research ticket. PROMISE: return ...") and were denied by the first rule alone.
    for line in text.splitlines():
        if first_word(line) == "promise":
            return True
        if re.search(r"\bPROMISE\b\s*[:\u2014\u2013-]", line):
            return True
    return False


def has_evidence_line(text):
    return any(re.search(r"\bevidence\b", line, re.IGNORECASE) for line in text.splitlines())


def has_bound_clause(text):
    return any(
        keyword in line.lower()
        for line in text.splitlines()
        for keyword in BOUND_KEYWORDS
    )


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


def main():
    data = json.loads(sys.stdin.read())
    tool_name = data["tool_name"]

    if tool_name not in ("Agent", "Task"):
        print("{}")
        return

    tool_input = data["tool_input"]
    prompt = tool_input.get("prompt", "") or ""
    description = tool_input.get("description", "") or ""
    text = prompt + "\n" + description

    if not has_promise_clause(text):
        deny("dispatch-gate: no PROMISE clause (a line opening with PROMISE, or an inline PROMISE: label)")
        return

    evidence_line_ok = has_evidence_line(text)
    artifact_ok = bool(ARTIFACT_RE.search(text))
    if not (evidence_line_ok and artifact_ok):
        if not evidence_line_ok:
            reason = "dispatch-gate: no EVIDENCE clause (no heading/line naming EVIDENCE)"
        else:
            reason = (
                "dispatch-gate: no EVIDENCE clause (no unforgeable-artifact reference — "
                "path, exit code, sha/commit, ticket id, URL, diff/test output/verbatim)"
            )
        deny(reason)
        return

    if not has_bound_clause(text):
        deny(
            "dispatch-gate: no BOUND (Bounds/Budget/Scope/Only under/Do NOT/max-turns/tool calls)"
        )
        return

    # All three clauses present — abstain so other gates still get a say.
    print("{}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        deny("dispatch-gate: internal error — %s" % type(e).__name__)
    sys.exit(0)
