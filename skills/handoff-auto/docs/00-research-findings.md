# 00 — Research Findings: Auto-Handoff Across Compaction

**Date:** 2026-06-26 · **Stage:** DF research (pre-design) · **Author:** Loom

## TL;DR

- You **cannot** trigger a hook "at 90% context used." Claude Code does not expose live
  context usage to hooks, and **auto-compaction is internally controlled (~95%)**.
- The reliable automatic trigger is the **`PreCompact`** hook (fires at the compaction
  boundary, distinguishes auto vs manual `/compact`). It **cannot block** compaction — it
  runs a side effect, then compaction proceeds.
- A hook is a **shell script** — it cannot itself make the model write a rich summary. You
  get model-fidelity content only if the model wrote it **before** PreCompact fires.
- **Restoration is solved**: a `SessionStart(compact|clear)` hook injects the saved handoff
  as `additionalContext` / `systemMessage`. This is the universal read-back path.
- A mature open-source ecosystem already exists; we should **reuse, not reinvent** — and
  Loom already owns a rich `handoff` skill (model-written, Engram + temp, redaction,
  artifact-referencing, suggested-skills).

## The compaction mechanism (ground truth)

| Fact | Detail | Source |
|---|---|---|
| Auto-compact threshold | ~95% context capacity, internally controlled | badlogic compaction research |
| Manual path | `/compact [instructions]` | Claude Code docs |
| Pre-compaction hook | `PreCompact` — fires before auto or manual compact; can run side effects, **cannot stop** compaction; can distinguish trigger type | Claude Code hooks reference |
| Live % to hooks | **Not exposed.** No documented way to read current token count / % from a hook | badlogic research (explicitly: "doesn't detail programmatic access to real-time usage") |
| Summarization | Whole history → LLM condense → new session seeded with summary | badlogic / inside-claude-code |
| Restore path | `SessionStart` with matcher `compact`/`clear` → inject `additionalContext` | Claude Code docs |
| Failure mode | "model can go off the rails if auto-compact happens mid-task" | badlogic research |

**Implication:** the achievable triggers are (a) the PreCompact boundary, (b) continuous
per-turn freshness, or (c) an external watcher estimating %. There is no native "90%" event.

## Open-source landscape

| Project | Mechanism | Content | Fidelity | Notes |
|---|---|---|---|---|
| [who96/claude-code-context-handoff](https://github.com/who96/claude-code-context-handoff) | `PreCompact` + `SessionEnd(clear)` write; `SessionStart(compact\|clear)` restore | **Deterministic shell dump**: last 15 user msgs (dedup 85%), last 10 assistant snippets, file paths, command-like strings | Mechanical (no semantics) | Fully automatic, zero model effort. Explicitly: triggers on lifecycle events, **not** % threshold. cwd-match + 900s age window fallback. |
| [Sonovore/claude-code-handoff](https://github.com/Sonovore/claude-code-handoff) | `UserPromptSubmit` (live update each turn) + `PostToolUse` (track edits) + `PreCompact` (final flush) + `SessionStart` (restore) | **Model-maintained** `session-state.md`, rewrite-mode capped 60–120 lines | Semantic, always current | Survives autocompaction "without manual intervention." Needs `bash`+`jq`. Per-turn token tax. |
| [thepushkarp/handoff](https://github.com/thepushkarp/handoff) | Plugin: PreCompact + SessionStart restore | Model-written checkpoint | Semantic | Packaged as a Claude Code plugin. |
| [REMvisual/claude-handoff](https://github.com/REMvisual/claude-handoff) | Skill: `/handoff` on demand | Model-written, **chain-linked** (inherits chain tag + sequence) | High | Skill, not auto. Chain-link idea is worth stealing. |
| [parcadei/Continuous-Claude-v3](https://github.com/parcadei/Continuous-Claude-v3) | Ledgers + handoffs + MCP isolated-context orchestration | Heavy framework | High | "Compound, don't compact." Larger surface than we need. |
| [robertguss/claude-code-toolkit · handoff](https://github.com/robertguss/claude-code-toolkit/tree/main/skills/handoff) | Skill | Model-written structured doc | High | Reference skill structure. |

Background: [Context Compaction (Inside Claude Code)](https://y-agent.github.io/inside-claude-code/04-context-compaction.html),
[Claude Code vs OpenCode 5.3](https://0xtresser.github.io/Claude-Code-VS-OpenCode/en/Chapter_05_Session_and_Context/5.3_Context_Compaction.html),
[Hooks reference](https://code.claude.com/docs/en/hooks).

## What Loom already has (reuse surface)

- **`handoff` skill** — model-written; saves to OS temp + Engram; references artifacts by
  path/URL instead of duplicating; redacts secrets/PII; emits a "Suggested Skills" section.
  This is our high-fidelity content engine — designs should *invoke it*, not re-implement a dump.
- **Engram** — durable, searchable cross-session store (chain-linkable handoffs).
- **SessionStart hook** already injecting the Synapse capability map (so the read-back slot
  is already wired; we add a handoff section).
- **Hook discipline (from memory):** SessionStart latency budget 1–3s → *read a precomputed
  file, never compute*; restoration must be a **hard mechanism**, not a soft imperative;
  non-tool-event hooks (PreCompact/SessionStart/Stop) use `systemMessage`.

## Open design tension (carried into options)

Rich, model-written fidelity requires the doc to exist **before** PreCompact. Two ways to
guarantee that: keep it **continuously fresh** (per-turn cost) or run a **watcher** that
fires the skill near a ~90% estimate (complexity + racy). The fallback that always works is a
**deterministic PreCompact dump** (low fidelity, zero cost, unskippable). The options trade
exactly along this fidelity ↔ cost/complexity axis.
