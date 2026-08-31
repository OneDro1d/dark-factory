# 03 — Install (gated)

**Wiring these hooks into `~/.claude/settings.json` is a persistent-config change that affects
every Claude Code session. It is intentionally NOT applied automatically — apply it yourself
after review.**

## 1. Make hooks executable

```bash
chmod +x hooks/*.sh
```

## 2. settings.json fragment

Merge into `~/.claude/settings.json` (additive to any existing hooks — multiple hooks per event
all run). Use absolute paths.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command",
        "command": "<this-skill-checkout>/hooks/user-prompt.sh" }] }
    ],
    "PreCompact": [
      { "hooks": [{ "type": "command",
        "command": "<this-skill-checkout>/hooks/pre-compact.sh" }] }
    ],
    "SessionStart": [
      { "matcher": "compact|clear",
        "hooks": [{ "type": "command",
        "command": "<this-skill-checkout>/hooks/session-start.sh" }] }
    ]
  }
}
```

## 3. Notes & knobs

- **Coexists with the existing `engram-session-start.sh`** SessionStart hook — both fire; the
  matcher scopes this one to `compact`/`clear` so it only injects after a compaction or clear.
  That hook is an [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram) integration
  from the author's own setup; if you do not have one, there is nothing to coexist with.
- **`HANDOFF_MAX_AGE`** (env, seconds; default `0` = unlimited) caps how old a handoff may be
  and still be restored. Set e.g. `86400` to ignore day-old handoffs.
- **Token tax:** the UserPromptSubmit nudge adds ~4 lines of `additionalContext` per turn. To
  disable just the nudge (keeping the deterministic floor), remove the `UserPromptSubmit` entry.
- **Storage:** `<cwd>/.claude/handoff/handoff-latest.md` per project (cwd-scoped, VR-7). Add
  `.claude/handoff/` to the project's `.gitignore` (runtime artifact).

## 4. Verify after wiring

- Fresh session in a project, do some work, run `/compact`, then confirm the next turn's context
  contains "Restored handoff" (the SessionStart injection). That is the TS-2 acceptance evidence.
