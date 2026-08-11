---
title: Adversary Solution Architect Review
stage: 2. Solution Architect
type: adversary-process
status: living
---

# Adversary Solution Architect Review

## TL;DR

An adversary attacks the three SA docs before the lanes consume them: find a PO scenario with no Data Flow, a Prime Directive with no honouring point (and no ADR), a Service Map row missing a delta a lane needs, or a cross-lane coupling. Verdict: **Pass / Conditional / Fail**.

## Review checklist (signal)

| Check | Pass? |
|---|---|
| Every PO test scenario has a Data Flow path | |
| Every service is single-responsibility (no "and") | |
| Every inter-service hop is AMQP, or the sync hop has an ADR (Directive 3/4) | |
| Each of the 10 Prime Directives has a honouring point, or an ADR for the deviation | |
| Data Model declares ownership + PHI/PII + retention per domain | |
| Service Map rows carry the deltas Developer + Infra need (no guessing) | |
| Observability Surface named: required dashboards/queries ([standard](../../reference/observability-standard.md)) with each flow/saga panel mapped to a PO scenario (Directive 1 — the eyes QA depends on) | |
| Two-Lane test: Developer and Infra can each start independently | |
| Platform boilerplate is referenced, not restated (noise check) | |
| Every transform tagged `pure`/`effect`; every effect has idempotency + compensation; every ingress lists its LOCAL validation rules; every fact in >1 place names an `authority` ([lens](00-solution-architect-guide.md#through-the-data-transform-lens)) | |

## Verdict

- **Pass** — every check yes; cold Developer + cold Infra tests pass.
- **Conditional** — minor gaps, owned and time-boxed.
- **Fail** — uncovered scenario, undirected Directive, missing delta, or cross-lane coupling.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Adversary prompt

```text
You are an adversarial principal architect reviewing a Data Model, Data Flow, and Service Map you did not write.
Using critical thinking:
- List PO test scenarios with no Data Flow path.
- For each of the 10 Prime Directives, demand the point in the architecture where it is honoured; flag any that are absent without an ADR.
- Demand the Observability Surface: for each PO scenario, which dashboard/flow panel will show it ran? If a scenario has no eye on it, QA will be blind — flag it (Directive 1).
- Find sync inter-service hops with no ADR (Directive 3/4).
- Run the cold Developer and cold Infra tests in your head: where would each have to guess or invent?
- Confirm the two lanes are independent (no sequential coupling).
- Flag any platform boilerplate restated instead of referenced (noise).
Return: findings table (severity | check | evidence | fix) + Prime Directive audit table + verdict Pass/Conditional/Fail.
```

## What to attack

- **Coverage:** scenario → data-flow holes.
- **Directive compliance:** the 10 Directives are non-negotiable; deviations need ADRs.
- **Lane sufficiency:** missing deltas = downstream guessing = cold-test fail.
- **Parallelism + noise:** coupling, and restated boilerplate.

## Output format

Findings table + a Prime Directive audit table + verdict. Any uncovered scenario, undirected Directive, or failed cold test forces **Fail**.
