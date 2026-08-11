---
title: Adversary QA Review
stage: 5. QA
type: adversary-process
status: living
---

# Adversary QA Review

## TL;DR

An adversary attacks the Test Plan before its verdict is trusted: find a PO scenario with no test, a "pass" with no evidence, or a quality gate that was quietly lowered. Verdict: **Pass / Conditional / Fail**.

## Review checklist (signal)

| Check | Pass? |
|---|---|
| Pre-test gate ran: the Observability Surface was verified rendering live data + `$correlationId` resolving **before** scenarios ([standard](../../reference/observability-standard.md)); a dark surface was routed to Infra, not papered over | |
| Every PO real-life scenario maps to ≥1 test case | |
| Every "pass" has observability evidence (metric/log/trace by correlationId) | |
| Failures are recorded, not hidden | |
| Quality gates match the SA Test Strategy (not silently relaxed) | |
| Holdout/regression run, or its omission is explicitly justified | |
| Verdict gates correctly (Fail routes to the owning lane) | |
| Each validation rule has a test (`LOCAL` → reject at edge, `GLOBAL` → reconciliation); every effect tested for idempotency (replay) + compensation (rollback) ([lens](00-qa-guide.md#through-the-data-transform-lens)) | |

## Verdict

- **Pass** — full scenario coverage with evidence; gates honoured.
- **Conditional** — minor gaps, each owned and time-boxed.
- **Fail** — any uncovered scenario, any evidence-free pass, or a relaxed gate.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Adversary prompt

```text
You are an adversarial QA lead reviewing a Test Plan & Results you did not write.
Using critical thinking:
- Confirm the pre-test eyes gate ran: were the dashboards/queries verified rendering live data before scenarios? If the surface was dark and QA tested anyway, every "pass" is unverifiable — flag it and demand routing to Infra.
- List PO real-life scenarios with no corresponding test case.
- For each "pass", demand the evidence (metric name, log line, or trace by correlationId). Flag every pass that cannot produce it.
- Check whether any quality gate was lowered relative to the SA Test Strategy.
- Confirm the verdict routes failures to the correct lane (code→Developer, deploy→Infra, requirement→PO).
Return: findings table (severity | check | evidence | fix) + verdict Pass/Conditional/Fail.
```

## What to attack

- **Coverage:** scenario → test mapping holes.
- **Evidence:** unverifiable passes (the most common QA lie).
- **Gate integrity:** relaxed thresholds.
- **Routing:** a Fail that does not name the owning lane is a dead end.

## Output format

Findings table + verdict. Any evidence-free pass or uncovered scenario forces **Fail**.
