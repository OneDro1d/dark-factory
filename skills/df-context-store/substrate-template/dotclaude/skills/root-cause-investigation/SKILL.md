---
name: root-cause-investigation
description: Turn a symptom into a confirmed root cause using evidence, not guesses — across any service, DB, queue, API, or infra. Use for "find the bug", "why is this failing", "0 records / stuck / DLQ / timeout / wrong data". Checks known findings first; escalates when evidence is missing instead of assuming.
allowed-tools: Read, Grep, Glob, Bash
---

# Root-Cause Investigation (evidence-first)

Goal: fast, correct root cause with minimum tokens. A plausible guess is worse than "need more evidence."

## Procedure
1. **Check memory**: `.claude/context/FINDINGS.md` — if already root-caused, reuse it and stop.
2. **Locate**: use SERVICE-MAP + the relevant `<service>/CLAUDE.md` to find where the symptom lives.
3. **Trace**: follow the flow (dependency-mapping) to the component where expected ≠ actual.
4. **Gather evidence** before concluding: the exact `file:line`, the data/log/state that proves it, and what you ruled out.
5. **Confirm the mechanism**: state precisely *why* the code produces the symptom (e.g. "reads a scope column the copy path never writes → 0 rows").
6. **Escalate, don't guess**: if you can't confirm in code/data, list the missing evidence and what would resolve it.

## Common failure modes to check first
- Silent zero-records (record-element detection / stale build).
- Object-store key drift writer↔reader (consumer requeues forever).
- Stale container / non-regenerated artifact (silent).
- Secondary store write inside the primary DB txn → timeout under load.
- Restricted/non-restricted data misroute (fail-safe default).
- Poison vs transient Nack misclassification (dead-letter vs infinite requeue).

## Output → Root Cause Analyzer / user
```
SYMPTOM: <observed>
ROOT CAUSE: <one sentence, mechanism>
EVIDENCE: <file:line, data/log, what was ruled out>
BLAST RADIUS: <other flows/services affected>
FIX OPTIONS: <1-3, no code> | CONFIDENCE: high/med/low
UNKNOWNS: <missing evidence, if any>
```
Confirmed causes get written to FINDINGS.md (via knowledge-keeper).
