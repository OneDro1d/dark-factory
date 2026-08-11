#!/usr/bin/env python3
"""df-stage-gate — Dark Factory stage-skill gate (PreToolUse: Write|Edit|MultiEdit).

WHY: dark-factory-build's stage table is prose. Across 58 lifetime invocations the
stage skills fired 1-7 times each (df-solution-architect: 1). The model reads
"Stage 2 -> df-solution-architect", understands the stage, and writes the artifact
inline -- the doc gets produced, the skill never runs, and the skill's checklists,
required artifact shape and holdout steps are silently skipped. Prose is advisory;
a hook is not.

Contract: read the tool-call JSON on stdin; print {} to allow or
{"decision":"block","reason":...} to block. EXIT 0 ALWAYS -- a non-zero exit is a
hook error, not a policy decision.

Fails OPEN in every ambiguous case (unparseable event, unreadable transcript,
unknown stage number). Blocking on uncertainty would make the whole toolchain
unusable; the gate only fires when it can positively prove the skill was absent.

Config:
  DF_STAGE_GATE=off                   disable entirely
  in-content marker "df-stage-gate: bypass"   one-off intentional bypass
"""
import json
import os
import re
import sys

# Stage docs live at docs/dark-factory/<NN>-<stage>.md; each is owned by one skill.
OWNER = {
    "00": "df-data-transform-lens",
    "01": "df-product-owner",
    "02": "df-solution-architect",
    "03": "df-infrastructure",
    "04": "df-observability",
    "05": "df-qa",
}

STAGE_RE = re.compile(r"/docs/dark-factory/(\d{2})-[a-z0-9-]+\.md$")


def allow():
    print("{}")
    sys.exit(0)


def block(reason):
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)


def skill_was_invoked(transcript_path, owner):
    """True if this session called Skill(owner). Raises nothing -- caller fails open."""
    with open(transcript_path, errors="replace") as fh:
        for line in fh:
            if '"Skill"' not in line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if obj.get("type") != "assistant":
                continue
            content = (obj.get("message") or {}).get("content") or []
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use" and c.get("name") == "Skill":
                    s = str((c.get("input") or {}).get("skill") or "")
                    # plugin-namespaced skills arrive as "<plugin>:<name>"
                    if s == owner or s.endswith(":" + owner):
                        return True
    return False


def main():
    if os.environ.get("DF_STAGE_GATE", "on") == "off":
        allow()

    try:
        event = json.load(sys.stdin)
    except Exception:
        allow()

    if event.get("tool_name") not in ("Write", "Edit", "MultiEdit"):
        allow()

    tool_input = event.get("tool_input") or {}
    path = tool_input.get("file_path") or ""
    if not path:
        allow()

    # explicit, auditable one-off bypass written into the artifact itself
    blob = " ".join(str(tool_input.get(k, "")) for k in ("content", "new_string"))
    if "df-stage-gate: bypass" in blob:
        allow()

    match = STAGE_RE.search(path.replace(os.sep, "/"))
    if not match:
        allow()

    owner = OWNER.get(match.group(1))
    if not owner:
        allow()

    transcript = event.get("transcript_path") or ""
    if not transcript or not os.path.isfile(transcript):
        allow()  # cannot prove absence -> do not block

    try:
        invoked = skill_was_invoked(transcript, owner)
    except Exception:
        allow()

    if invoked:
        allow()

    block(
        "Dark Factory stage gate: you are writing {doc} without having run the "
        "skill that owns it.\n\n"
        "Call Skill({owner}) FIRST, then write the artifact it specifies.\n\n"
        "This is not a formality. The stage skill carries the checklists, the "
        "required artifact shape, and the holdout/verification steps that writing "
        "the doc from memory skips.\n\n"
        "Bypass (intentional): DF_STAGE_GATE=off, or put 'df-stage-gate: bypass' "
        "in the file content.".format(doc=os.path.basename(path), owner=owner)
    )


if __name__ == "__main__":
    main()
