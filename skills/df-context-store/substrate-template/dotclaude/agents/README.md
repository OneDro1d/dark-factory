# Agents — minimal system

Service-agnostic agents that work across **any** service, DB, queue, API, or infra. Built to find root causes fast, implement features safely, and **reuse stored context instead of re-analyzing** — keeping token use low. Auto-routing is driven by each agent's `description` field.

## The model: analyze once, reuse forever

```
            ┌─────────────────────────────────────────────┐
            │  .claude/context/  (read-first, shared memory)│
            │  SERVICE-MAP · FINDINGS · DECISIONS           │
            │  + per-service CLAUDE.md + shared-models index │
            └─────────────────────────────────────────────┘
                 ▲ every agent reads it first, never re-scans the repo
   investigate → analyze → architect → implement → validate
        │           │          │           │          │
   (evidence)  (root cause) (design)    (code)    (verdict)   ──► knowledge-keeper writes it back
```

Each agent emits a **structured output that the next one consumes**, so expensive analysis flows downstream compressed, not re-derived.

## The 4 things you ask → who runs

| You say | Agents (in order) | Skills used |
|---|---|---|
| **"Find the bug"** | `investigator` → `root-cause-analyzer` | codebase-understanding, dependency-mapping, root-cause-investigation |
| **"Explain the root cause"** | `root-cause-analyzer` (on existing evidence) | root-cause-investigation |
| **"Implement this feature"** | `feature-architect` → `implementer` → `validator` | feature-planning, test-strategy |
| **"Review this change"** | `validator` | test-strategy |
| _(any new fact learned)_ | `knowledge-keeper` | context-management |

Add project-specific domain agents here as needed.

## Agents (single responsibility each)

| Agent | Responsibility | Reads | Produces |
|---|---|---|---|
| `investigator` | gather evidence, trace flows (read-only) | context store + targeted source | Evidence Bundle |
| `root-cause-analyzer` | evidence → true root cause (no code) | Evidence Bundle | Root Cause + fix options |
| `feature-architect` | minimal-impact design (no code) | requirement + context store | Design Spec |
| `implementer` | write the code per spec | Design Spec + named files | diff + build result |
| `validator` | test, edge cases, regressions | change + intended behavior | Validation Report (verdict) |
| `knowledge-keeper` | keep context store terse & true | confirmed facts (sourced) | updated FINDINGS/DECISIONS/MAP |

## Skills

`codebase-understanding` · `dependency-mapping` · `root-cause-investigation` · `feature-planning` · `test-strategy` · `context-management` · `commit-sync` · `contract-check`.

`commit-sync` is the wrap-up workflow: before any commit it syncs the knowledge layer (context store + CLAUDE.md + this routing map) to the change, scans for secrets, drafts a proper message, and **stops for your explicit OK before pushing**.

## Rules every agent honors
- **Read the context store first; don't re-scan the repo.** Stop reading as soon as you have enough.
- **No guessing** — gather evidence; cite `file:line`. **Escalate** when evidence is missing rather than assuming.
- **Single responsibility** — hand off via the structured output; don't do the next agent's job.
- **Hand-offs are data contracts** — each structured output has required fields + a rule; a consumer **rejects an incomplete hand-off** (`contract-check`) instead of coping or guessing. See `../context/AGENT-CONTRACTS.md`.
- **Test-first** — tests are derived from the design's ACCEPTANCE as a RED list and built RED→GREEN→REFACTOR; the implementer may not weaken a test to pass.
- **Verify, don't trust (no agent is its own auditor)** — a downstream consumer re-runs the evidence (literal test counts, `file:line`), never accepting a bare "PASS"/"done"; the validator derives an *independent* holdout.
- Bugs can be **anywhere** — no component is "out of scope."
- **Never commit/push/deploy without explicit approval.** Reads only on production stores. No secrets/PII.

## The pipeline as a transform graph (data-transform lens)
Each agent is a **transform**: `pure` (reads only — investigator, root-cause-analyzer, feature-architect) or `effect` (writes code/memory/git — implementer, validator, knowledge-keeper). Effect transforms must be **idempotent** (re-runnable without double-applying) and carry a **compensation** path (undo). The hand-offs between them are typed **data contracts**, the context store files are the shared **data nodes**, and `DECISIONS.md` fixes their **authority** (e.g. the primary DB is source of truth). The full model — contracts, pure/effect tags, validation rules, and the verification gate — lives in **`../context/AGENT-CONTRACTS.md`**, with a runnable checker in **`../skills/contract-check/`**.

## Note
Agents/skills register at session start — after adding or editing one, **reload Claude Code** (or `/agents`) for it to become pickable. These files work locally regardless of whether they are committed.
