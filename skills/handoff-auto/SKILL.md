---
name: handoff-auto
description: Automatic session-handoff across Claude Code context compaction. Hooks keep a live handoff fresh, guarantee a deterministic floor at the compaction boundary, and re-inject it after compaction/clear so the agent resumes with intent intact — no manual /handoff. Use when setting up auto-handoff, surviving auto-compact, "don't lose context when it compacts", installing the handoff hooks, or wiring PreCompact/SessionStart/UserPromptSubmit for continuity. Complements the manual `handoff` skill.
---

# handoff-auto — automatic handoff across compaction

## What this is

Claude Code compacts the conversation when context fills (auto-compact ~95%), and the
lossy summary drops decisions, intent, and nuance. This is the **automatic** complement to
the manual [`handoff`](../handoff/SKILL.md) skill: a set of hooks that make a usable handoff
**always exist** and get **re-injected after compaction** — with zero manual `/handoff`.

**Option B** (chosen from a 3-option design study in `docs/02-design-options.md`): a live
model-maintained handoff with a deterministic safety-net.

## Why it works this way (the binding constraint)

You **cannot** trigger "at exactly 90% context used" — Claude Code does not expose live
context % to hooks, and auto-compaction is internally controlled. So instead of chasing a
threshold, this keeps the handoff **always-ready**. See `docs/00-research-findings.md`.

## How it works — the spine

```
UserPromptSubmit ── nudge ──▶ model keeps <cwd>/.claude/handoff/handoff-latest.md fresh
                              (≤120 lines, secrets redacted)               [soft, silent]
PreCompact ─────── flush ───▶ if that handoff is missing/empty/stale, write a deterministic
                              jq snapshot from the transcript                [hard floor, exit 0]
SessionStart(compact|clear) ─ inject the cwd-scoped handoff as the next turn's context
                              (dual-field JSON, age-gated)                   [resume]
```

The soft per-turn nudge gives semantic fidelity; the hard PreCompact floor guarantees a
handoff exists even if the model under-updated. Restoration is a real mechanism, not a
"please remember to read this."

## Components

| Path | Role |
|---|---|
| `hooks/user-prompt.sh` | UserPromptSubmit: terse silent freshness nudge (`additionalContext` only) |
| `hooks/pre-compact.sh` | PreCompact: deterministic floor; never blocks compaction (exit 0) |
| `hooks/session-start.sh` | SessionStart(`compact`/`clear`): restore the cwd handoff |
| `lib/redact.sh` | `redact_secrets` + `bound_lines` (pure, BSD-sed safe) |
| `lib/handoff.sh` | `extract_snapshot` + `should_flush` |
| `lib/restore.sh` | find cwd handoff, age-gate, build resume payload, emit dual-field JSON |
| `lib/directive.sh` | the per-turn nudge text |
| `tests/` | 52 cases across 5 files (`bash tests/run.sh`) |
| `docs/00..03` | research, requirements, design options (decision: B), install |

Dependency-free: **bash + jq**. No shellcheck needed; `bash -n` clean.

## Install

`SKILL_DIR` below = the absolute path to this directory.

### 1. Make hooks executable
```bash
chmod +x SKILL_DIR/hooks/*.sh
```

### 2. Add to `~/.claude/settings.json` (additive — existing hooks keep running)
```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "SKILL_DIR/hooks/user-prompt.sh" }] }
    ],
    "PreCompact": [
      { "hooks": [{ "type": "command", "command": "SKILL_DIR/hooks/pre-compact.sh" }] }
    ],
    "SessionStart": [
      { "matcher": "compact|clear",
        "hooks": [{ "type": "command", "command": "SKILL_DIR/hooks/session-start.sh" }] }
    ]
  }
}
```

### 3. (optional) Ignore the runtime artifact
Add `.claude/handoff/` to the project's `.gitignore` — `handoff-latest.md` is per-project state.

## Use

Nothing day-to-day — it runs automatically. To **verify** after install: in a project, do
some work, run `/compact`, and confirm the next turn's context contains "Restored handoff".

**Knobs:**
- `HANDOFF_MAX_AGE` (env, seconds; default `0` = unlimited) — ignore handoffs older than this.
- To drop just the per-turn token tax (keep the deterministic floor), remove the
  `UserPromptSubmit` entry from settings.json.

## Limitations (honest)

- **No exact-% trigger** — fires at the compaction boundary, not a chosen 90%.
- **Redaction is pattern/keyword based.** It catches API keys, bearer/JWT, GitHub (incl.
  `github_pat_`), Slack `xox*-`, AWS `AKIA*`, PEM private-key blocks, and keyworded
  assignments (`password=`, `aws_secret_access_key=`, `"password": "…"`). It will **not**
  catch a bare high-entropy secret with no keyword/prefix (that would over-redact commit
  SHAs / base64). Provenance: hardened after a blind adversary gate (6 leaks fixed).

## Provenance

Built test-first (TDD) and verified with a blind adversarial gate. Full record in
`docs/`. This is a worked artifact of `dark-factory-build`.
