#!/usr/bin/env python3
"""
outbound-verify-guard.py  —  PreToolUse guard for OUTBOUND sends (never blocks).

Fires before anything that leaves this machine and is seen by a colleague: Teams posts/replies, Jira
comments/creates/updates, Confluence writes, Slack messages, emails, and `gh pr|issue comment|review` via Bash.
It injects a short re-verification checklist so the claims in the message get one deliberate pass before they
are published, flags messages not marked as bot-sent, and flags malformed HTML.

Why: the costly outbound mistakes are predictable — a "correction" aimed at a different object than the one
the colleague meant; an absence asserted from a check that never ran; a parser's error printed as a finding;
a connector silently rewriting the body; a claim of "only here" never checked on the other side.

Exit 0 always. Emits hookSpecificOutput.additionalContext.

  python3 outbound-verify-guard.py --selftest
"""
import json
import re
import sys

# Substrings that identify an outbound tool, matched against the tool name.
OUTBOUND = (
    "send_channel_message", "reply_channel_message", "send_chat_message",
    "send_email", "reply_email", "forward_email",
    "jira_add_comment", "jira_create_issue", "jira_update_issue",
    "jira_transition_issue", "confluence_create_page", "confluence_update_page",
    "confluence_add_comment", "slack_send_message", "slack_schedule_message",
    "slack_send_message_draft",
)

BASH_OUTBOUND = re.compile(
    r"\bgh\s+(pr|issue)\s+(comment|review|create|edit)\b"
    r"|\bgh\s+api\b.*\b(comments|reviews)\b",
    re.I,
)
# `gh api` is a GET unless it carries a method or a body; a GET of comments sends nothing.
GH_API_WRITE = re.compile(r"\s(?:-X|--method)\s*(?:POST|PATCH|PUT|DELETE)\b|\s(?:-f|-F|--field|--raw-field|--input)[\s=]", re.I)

# Bot attribution: an agent-sent message must say plainly that a bot sent it, and must not be signed as the
# human (a human message matters more to readers than a generated one, and bots tend to sound urgent).
# "[bot — <agent>, for <owner>]" is the pair's own post format.
BOT_MARK = re.compile(r"\[bot\b|\U0001F916|\bposted by\b[^.]{0,40}\bagent\b|\bon (?:his|her|their) behalf\b"
                      r"|\bsent by\b[^.]{0,30}\b(?:bot|agent)\b|\bagent[- ]sent\b", re.I)
HUMAN_SIG = re.compile(r"(?:^|\n)\s*[—-]{1,2}\s*[A-Z][a-z]+\s+[A-Z][a-z]+\s*$", re.M)

# Assertion shapes worth a second look before publishing.
CLAIM_PATTERNS = [
    (r"\b(prove[nds]?|confirmed?|verified|demonstrat\w+)\b",
     "You claim something is PROVEN. Name the command and its output, not the conclusion."),
    (r"\b(is not|was not|does not|cannot|never|no longer|nothing)\b",
     "NEGATIVE claim. An absence is the easiest thing to get wrong: an error, a "
     "wrong query, a missing permission and a real absence all look identical. "
     "Did the check actually RUN, and did you see its exit code?"),
    (r"\b(only|solely|exclusively|the only)\b",
     "EXCLUSIVITY claim ('only X', 'X-only'). Did you check the OTHER side, "
     "or infer it?"),
    (r"\b(correct(ing|ion)?|retract\w*|wrong|mistaken|disagree)\b",
     "You are CORRECTING someone. Are you certain you are talking about the SAME "
     "OBJECT they were? A true measurement aimed at the wrong referent is not a "
     "refutation — it is a public error with their name on it. Quote the exact "
     "claim you are answering."),
    (r"\benv\b|\benvironment variable|\bconfig\b|\bsecret\b",
     "Config/secret claim. `spec.env` does NOT show what `envFrom` supplies, and a "
     "`valueFrom` entry prints EMPTY. Confirm with `printenv` in the RUNNING pod."),
    (r"\b\d+\s*(%|/\d+)|\bmd5|\bfingerprint|\bcount\b|\btotal\b",
     "Numbers/fingerprints. Did you re-read them from the tool output just now, or "
     "from memory of an earlier run? State the units and what was excluded."),
    (r"\b(all|every|none|zero|no )\b",
     "UNIVERSAL claim. What was the scope actually enumerated, and what fell "
     "outside it? An empty result is not the same as a checked-and-empty result."),
    (r"\b(step\s*\d|steps|method|procedure|runbook|recipe|instructions)\b",
     "SOMEONE HANDED YOU A PROCEDURE. Did you EXECUTE every step, or only the "
     "ones you found interesting? Enumerate the steps and say, per step, RAN / "
     "COULD NOT RUN / NOT APPLICABLE. A step you skipped silently reads to them "
     "as a step that passed."),
    (r"\b(forbidden|denied|cannot|no access|unauthorized|permission)\b",
     "PERMISSION claim — NAME THE SCOPE YOU MEASURED. A cluster-scope and a "
     "namespace-scope `can-i` can give DIFFERENT answers; reporting the cluster "
     "denial as 'I cannot' overstates the block and sends someone to fix RBAC "
     "that is already fine."),
]



def html_balance(body):
    """Unclosed tags in a Teams post silently swallow the rest of the message.

    A missing </code> once wrapped the closing paragraph AND the sign-off in a code
    block; Teams accepted it and returned 200. On a change-audit surface it reads as broken.
    """
    problems = []
    for tag in ("b", "i", "em", "strong", "p", "code", "ul", "ol", "li",
                "codeblock", "table", "tr", "td"):
        o = len(re.findall(rf"<{tag}(?:\s[^>]*)?>", body, re.I))
        c = len(re.findall(rf"</{tag}\s*>", body, re.I))
        if o != c:
            problems.append(f"<{tag}> opened {o}x, closed {c}x")
    if re.search(r"&lt;(p|b|code)&gt;", body):
        problems.append("PRE-ESCAPED tags (&lt;p&gt;) -- these render literally; "
                        "pass RAW tags with is_html:true")
    return problems


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    tool = str(payload.get("tool_name", ""))
    tin = payload.get("tool_input") or {}

    if tool == "Bash":
        cmd = str(tin.get("command", ""))
        m = BASH_OUTBOUND.search(cmd)
        if not m or (m.group(0).lower().startswith("gh") and re.match(r"gh\s+api", m.group(0), re.I)
                     and not GH_API_WRITE.search(cmd)):
            return 0
        surface = "a GitHub PR/issue comment"
        body = cmd
    elif any(k in tool for k in OUTBOUND):
        surface = tool.rsplit("__", 1)[-1]
        body = " ".join(
            str(v) for k, v in tin.items()
            if k in ("body", "text", "message", "content", "description",
                     "summary", "subject")
        )
    else:
        return 0

    attribution = []
    if body.strip() and not BOT_MARK.search(body):
        attribution.append(
            "NOT MARKED AS BOT-SENT. Readers must be able to tell a bot message from a human one "
            "at a glance. Open with an explicit marker, e.g. \U0001F916 Posted by <owner>'s agent "
            "on their behalf.")
    if HUMAN_SIG.search(body) and not BOT_MARK.search(body):
        attribution.append(
            "SIGNED AS THE HUMAN with no bot marker. A message signed as the person may NOT go "
            "out autonomously — that one needs their review first. Sign as the agent, or get it approved.")

    structural = html_balance(body) if "<" in body else []

    hits = []
    for pattern, note in CLAIM_PATTERNS:
        if re.search(pattern, body, re.I):
            hits.append(note)

    lines = [
        "🛑 OUTBOUND SEND — re-verify before this reaches a colleague.",
        f"   Surface: {surface}. Once sent, a wrong claim costs someone else's time,",
        "   and a correction never fully catches up with the original.",
        "",
        "   ALWAYS, regardless of content:",
        *([""] + ["   \U0001F916 BOT ATTRIBUTION — " + a for a in attribution] if attribution else []),
        "   1. RE-READ THE CONTEXT you are answering. Quote the exact words you are",
        "      responding to. Do not answer a paraphrase you built from memory.",
        "   2. SAME-OBJECT CHECK. If you name a system, instance, cluster, namespace",
        "      or key — is it the SAME one the other person meant? Ask if unsure;",
        "      one clarifying line is cheaper than a public retraction.",
        "   3. EVIDENCE, NOT INFERENCE. For each load-bearing claim: did you run a",
        "      command in THIS session and read its output? If you inferred it, say",
        "      'inferred' or go measure it.",
        "   4. SEPARATE what you measured from what you concluded. Others will reuse",
        "      the measurement long after the conclusion is superseded.",
        "   5. AFTER SENDING, read the echoed body back. Connectors and content",
        "      scanners can silently rewrite text and still return success.",
    ]
    if structural:
        lines.append("")
        lines.append("   🧱 MALFORMED HTML — fix before sending; an unclosed tag "
                     "silently swallows the REST of the message:")
        for pr in structural:
            lines.append(f"     • {pr}")

    if hits:
        lines.append("")
        lines.append("   ⚠️ CLAIM SHAPES DETECTED IN THIS DRAFT:")
        for h in dict.fromkeys(hits):
            lines.append(f"     • {h}")

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": "\n".join(lines),
        }
    }))
    return 0


def selftest():
    import os
    import subprocess
    T = lambda body: {"tool_name": "mcp__hub__microsoft_send_channel_message", "tool_input": {"body": body}}
    B = lambda c: {"tool_name": "Bash", "tool_input": {"command": c}}
    cases = [  # (event, want fired, want "NOT MARKED" warning)
        (T("<p><b>[bot — Forge, for Jane Doe]</b> ✅ smoke 5/5</p>"), True, False),
        (T("\U0001F916 Posted by Jane's agent on her behalf: done"), True, False),
        (T("Deployed api 1.2.3 to dev"), True, True),
        (B("gh pr comment 22 --body 'fixed'"), True, True),
        (B("gh api repos/o/r/pulls/22/comments --paginate --jq '.[].id'"), False, False),
        (B("gh api repos/o/r/pulls/comments/1/replies -f body='[bot — Forge, for Jane] fixed'"), True, False),
        (B("gh api -X POST repos/o/r/issues/22/comments --input reply.json"), True, True),
        (B("ls"), False, False),
    ]
    bad = 0
    for ev, want_fired, want_unmarked in cases:
        out = subprocess.run([sys.executable, os.path.realpath(__file__)], input=json.dumps(ev), text=True,
                             capture_output=True).stdout
        fired, unmarked = bool(out.strip()), "NOT MARKED" in out
        ok = fired == want_fired and unmarked == want_unmarked
        bad += not ok
        print("PASS" if ok else "FAIL", f"fired={fired} unmarked={unmarked}", json.dumps(ev["tool_input"])[:90])
    print("ALL PASS" if not bad else f"{bad} FAILED")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
