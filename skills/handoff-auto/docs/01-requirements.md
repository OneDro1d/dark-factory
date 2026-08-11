# 01 — Requirements (Product Owner): Auto-Handoff Across Compaction

**Date:** 2026-06-26 · **Stage:** DF Stage 1 (PO) · **Author:** Loom
**Frame:** data-transform lens — data nodes + transforms (pure|effect) + validation rules + authority.

## TL;DR

Guarantee that **work survives a context compaction (or `/clear`, or crash) with no human
action**: a bounded, secret-free, semantically-useful handoff is always available and is
**reliably injected** into the next context so the agent resumes from "where we were."

## Vision

> When the context window fills and Claude Code compacts, the agent today loses nuance,
> decisions, and intent. We want **structured continuity instead of lossy compression**: an
> always-ready handoff that the next post-compaction turn reads automatically, so the agent
> keeps its goal, last decisions, next action, and key references across the boundary —
> with zero manual `/handoff`.

**Non-goals:** preventing/blocking compaction; replacing Engram long-term memory; a precise
"exactly 90%" trigger (not achievable natively — see `00-research-findings.md`); multi-repo
orchestration (out of scope for v1).

## Data nodes

| Node | Schema (key fields) | Origin / Authority | Governance |
|---|---|---|---|
| `ConversationTranscript` | JSONL turns (user/assistant/tool) | Claude Code runtime; **authority: harness** | read-only to us; may contain secrets/PII |
| `ContextUsageSignal` | token count / % used | harness; **NOT exposed to hooks** | the binding constraint — treat as unavailable |
| `SessionBoundaryEvent` | `{type: PreCompact\|SessionStart, trigger: auto\|manual\|compact\|clear, cwd, session_id, transcript_path}` | harness hooks | the only reliable timing signal |
| `HandoffDoc` | `{goal, last_decisions[], next_action, key_paths[], blockers[], artifacts[], chain_prev, seq, cwd, ts}` | derived; **authority: the producer (Loom)** | bounded size; redacted; durable |
| `RestoreInjection` | `systemMessage` text appended at SessionStart | derived from latest HandoffDoc | cwd + recency scoped |

## Transforms

| # | Transform | Type | Idempotency / Compensation |
|---|---|---|---|
| T1 | `summarize`: ConversationTranscript → HandoffDoc | **effect** (model-written = non-deterministic) or **pure-ish** (deterministic shell extraction) | overwrite `handoff-latest` (idempotent on session_id); chain-link `seq`/`chain_prev` |
| T2 | `persist`: HandoffDoc → file (+ Engram) | effect | write-temp-then-rename (atomic); `handoff-latest.md` is last-writer-wins per cwd |
| T3 | `inject`: HandoffDoc → RestoreInjection | effect (SessionStart) | must be O(1) file read, no compute (latency budget) |

## Validation rules (single source of truth — flow into design, tests, QA)

| ID | Rule | Locus |
|---|---|---|
| **VR-1** | A handoff for the active cwd MUST exist on disk **before** PreCompact returns (always-ready invariant). | GLOBAL (boundary) |
| **VR-2** | HandoffDoc MUST contain the **resume-minimum**: current goal, last decisions, next action, key file paths, blockers. Missing any ⇒ invalid. | LOCAL (content) |
| **VR-3** | HandoffDoc MUST be **bounded** (rewrite-mode cap, target ≤ ~120 lines) so it does not itself bloat the next context. | LOCAL |
| **VR-4** | Secrets / API keys / PII MUST be redacted from HandoffDoc (reuse `handoff` skill redaction). | LOCAL |
| **VR-5** | On `SessionStart(compact\|clear)`, the latest handoff **for this cwd**, within an age window, MUST be injected. Restoration is a **hard mechanism**, not a soft "please read." | GLOBAL |
| **VR-6** | The SessionStart read-back MUST NOT compute — it reads a precomputed file only (≤ ~200ms). | LOCAL (anti-pattern guard) |
| **VR-7** | Concurrent sessions in different cwds MUST restore their **own** handoff (no cross-contamination). | GLOBAL |
| **VR-8** | HandoffDoc MUST survive a killed/crashed session (durable on disk, not in-memory only). | GLOBAL |
| **VR-9** | Each handoff SHOULD chain-link to its predecessor (`seq`, `chain_prev`) so a work-stream is reconstructable. | LOCAL |

## Test scenarios (evidence standard for QA)

| ID | Scenario | Unforgeable evidence |
|---|---|---|
| **TS-1** | Long session hits **auto-compact** mid-task | Post-compact SessionStart `additionalContext`/`systemMessage` contains handoff; agent answers a "where were we / what's next" probe correctly without re-reading files |
| **TS-2** | Manual `/compact` | same as TS-1 |
| **TS-3** | `/clear` mid-stream | latest cwd-matched handoff (within age window) injected on next SessionStart |
| **TS-4** | Two sessions, different cwds, both compact | each restores only its own handoff (grep the injected text per session) |
| **TS-5** | A secret/token appears in conversation | token string absent from `handoff-latest.md` (grep = 0 hits) |
| **TS-6** | Very long session | `wc -l handoff-latest.md` ≤ cap (rewrite mode held, not append-forever) |
| **TS-7** | Session killed (SIGKILL) before clean exit | `handoff-latest.md` present and non-stale on disk |
| **TS-8** | SessionStart latency | hook wall-time ≤ ~200ms (no compute on critical path) |

## Authority & conflict resolution

- The **harness** owns *when* compaction happens and *whether* usage % is visible (it isn't).
  Designs must accept the PreCompact boundary as the timing authority.
- **Loom (producer)** owns handoff *content* and *redaction*.
- **cwd + recency (age window)** is the disambiguation authority for *which* handoff restores.
- On conflict (two handoffs, same cwd) → **last-writer-wins by timestamp**, older becomes
  `chain_prev` of the newer (VR-9).
