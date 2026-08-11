---
title: Adversary Infrastructure Architect Review
stage: 4. Infrastructure Architect
type: adversary-process
status: living
---

# Adversary Infrastructure Architect Review

## TL;DR

An adversary attacks the Deployment & Infrastructure Spec: find a service with no overlay, a secret with no source, an SA knob never provisioned, an implicit-trust assumption, or a hidden dependency on the Developer lane. Verdict: **Pass / Conditional / Fail**.

## Review checklist (signal)

| Check | Pass? |
|---|---|
| Every service in the Service Map has a Kustomize overlay per target cluster | |
| Every secret has a source + rotation policy (Directive 9) | |
| Every SA observability entry maps to a provisioned sink (Directive 1) | |
| Observability Surface built as code AND verified rendering live data — every required dashboard, the `$correlationId` query, every alert rule evaluating ([standard](../../reference/observability-standard.md) acceptance bar). "No data" / wrong-cluster dashboards fail this. | |
| Every SA operational knob is wired (Directive 10) | |
| Trust is explicit/scoped — no "inside cluster is trusted" (Directive 5) | |
| No SPOF: ≥3 replicas on data-path services (singletons exempt) | |
| Two-Lane test: independent of the Developer lane | |
| Data placement honours `governance` (residency/class) per data node; no boundary relies on network position; reconciliation + compensation paths have wired knobs ([lens](00-infrastructure-architect-guide.md#through-the-data-transform-lens)) | |

## Verdict

- **Pass** — every check yes.
- **Conditional** — small explicit gaps, owned and time-boxed.
- **Fail** — any unprovisioned service/secret/knob, implicit trust, SPOF, or cross-lane dependency.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Adversary prompt

```text
You are an adversarial SRE/platform reviewer of a Deployment & Infrastructure Spec you did not write.
Using critical thinking:
- Find a service in the SA Service Map with no Kustomize overlay for a target cluster.
- Find a secret with no source or no rotation policy.
- Find an SA-designed operational knob that this spec never provisions.
- Open the dashboards: find any required view that does not render live data, a `$correlationId` query that returns nothing, or an alert rule in "no data"/error — the eyes must work or QA is blind.
- Find any implicit-trust assumption (Directive 5) or any data-path deployment with <3 replicas (no-SPOF).
- Prove a hidden ordering dependency on the Developer lane (the fork must be parallel).
Return: findings table (severity | check | evidence | fix) + verdict Pass/Conditional/Fail.
```

## What to attack

- **Completeness:** service/secret/sink/knob coverage.
- **Trust:** implicit access, missing revocation.
- **Resilience:** SPOF, no bulkheading (Directive 8).
- **Parallelism:** any wait on built code.

## Output format

Findings table + verdict. Any unprovisioned knob, sourceless secret, or implicit trust forces **Fail**.
