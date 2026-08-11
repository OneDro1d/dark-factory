---
name: feature-planning
description: Design a minimal-impact implementation for a new feature or fix before any code is written — files to touch, contracts, migrations, risks, and a test plan. Use for "implement X", "add feature", "how should we build this". Reuses the context store; records the decision as an ADR.
allowed-tools: Read, Grep, Glob, Bash
---

# Feature Planning (minimal-impact design)

Goal: the smallest correct change that respects existing architecture, with the blast radius known up front. No code here — design only.

## Procedure
1. **Reuse context**: SERVICE-MAP (where), DECISIONS (constraints you must honor), the relevant `<service>/CLAUDE.md` (contracts/gotchas). Do NOT re-derive architecture.
2. **Confirm requirements**: restate the goal + acceptance criteria. If ambiguous, escalate with specific questions — don't assume.
3. **Map impact** (dependency-mapping): every service, table, queue, object-store key, API the change touches; flag shared contracts.
4. **Choose the minimal approach**: prefer extending an existing pattern over a new mechanism. Check DECISIONS so you don't fight an intentional design (e.g. source-of-truth store, scoping rules, transport model).
5. **Plan migrations carefully**: migrations may live in several places (migrations dir + deploy config + bootstrap script) — all must be synced; idempotent (`IF NOT EXISTS`).
6. **Define the test plan** (test-strategy) as part of the design, not after.

## Output → Code Implementer
```
FEATURE: <name> | ACCEPTANCE: <criteria>
APPROACH: <minimal design, why this over alternatives>
FILES TO TOUCH: <service/file each, what changes>
CONTRACTS/MIGRATIONS: <new routing keys / columns / migrations + all sync points>
RISKS / BLAST RADIUS: <downstream effects>
TEST PLAN: <unit + cross-service checks>
ADR: <decision + why → for DECISIONS.md>
OPEN QUESTIONS: <if any — block here, don't guess>
```

## Don't
- Don't introduce broader-scoped rules, move source-of-truth off the primary store, or change data models without checking DECISIONS (consult the project owner for model changes).
