---
title: Operations — Stage Guide
stage: 6. Operations
type: stage-guide
status: living
consumes: QA Pass verdict + deployed system + SA/Infra artifacts (service map, deployment spec, observability, runtime trust)
produces: Operations Runbook
---

# Operations — Stage Guide

## TL;DR

Operations keeps the live system healthy and responds to incidents. It produces **one must-have doc: the Operations Runbook** — the single page an on-call human or agent uses to see system state, turn the operational knobs (slow / stop / redirect / inspect), and resolve any firing alert. Operations is the last stage in the loop; it is continuous, not one-shot.

## Where this stage sits

`… → QA (Deploy & Test) → PO Final Sign-off → **Operations** (run it) ↺ feeds incidents back to PO/SA`

## Inputs (must arrive from upstream)

| Input | From | Why Operations needs it |
|---|---|---|
| Deployed, QA-passed system | QA (stage 5) | The thing being operated |
| Working observability (dashboards, metrics, alerts) | Infra (4) wires sinks; **SA Service Map (Alerts & SLOs)** names the alerts | "Healthy" must be visible; alerts must fire before customers report (Directive 6) |
| Operational knobs wired up | Infra (4) via SA (Directive 10) | Slow / stop / redirect / inspect without code edits |
| Runtime trust + secrets posture | Infra (4) via SA RTP | Who/what can act; how to rotate |
| Service map + deployment spec | SA (2) / Infra (4) | What is running, where, how to reach it |

If any input is missing, Operations cannot be run safely — raise it to the stage that owns it, do not improvise.

## Must-have output (the small list)

| Output | Purpose | Template |
|---|---|---|
| **Operations Runbook** | Service snapshot · ops knobs · alert→response playbook · SLOs · escalation. The only doc on-call needs. | [`templates/operations-runbook-template.md`](templates/operations-runbook-template.md) |

## Optional outputs

- Capacity / cost model (scale and spend planning)
- Incident postmortem (per incident; feeds learnings back to PO/SA)

## Exit gate

> **Cold on-call test:** Can an on-call human or agent who has never seen this system keep it healthy and resolve any firing alert using the Runbook alone — without reading code or pinging the original team?

If no, the Runbook is incomplete. Every alert in the observability spec must have a matching entry in the Runbook's alert→response playbook.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Through the data-transform lens

See [`reference/data-transform-model.md`](../../reference/data-transform-model.md). Operations runs the **GLOBAL validation rules live**:

- The system's cross-system invariants (ledger == exchange, sub-ledgers == master, sent == requested) become **monitored reconciliation checks**; a breach resolves toward the declared `authority`.
- Most incidents are a **transform that lost an invariant** or an **effect that ran without idempotency/compensation** (double-charge, double-send). Triage along those two axes first.
- Knob actions that touch the outside world are **effects** — irreversible, human-gated.

## Interaction mode

**AI, supervised by humans.** Routine response (acknowledge, run a documented knob, follow a playbook) is AI-executable. Irreversible or customer-visible actions (failover, data deletion, customer comms) require human approval — they are hard stops, exactly as in the platform's autonomous-action gates.

## Workflow

1. **Assemble the Runbook** from upstream artifacts — do not re-derive. Pull the service list and knobs from the SA Service Map (Directive 10), the alerts/SLOs from the SA Service Map (Alerts & SLOs), the trust/secrets from the Infra spec (runtime trust).
2. **One playbook entry per alert.** For every alert condition the SA/Infra defined, write: symptom → likely cause → diagnostic knob (inspect) → mitigation knob (slow/stop/redirect) → escalation trigger.
3. **Define SLOs** from the PO's real-life test scenarios (latency, availability, data-freshness the product promised).
4. **Wire escalation** — on-call rotation, severity ladder, who approves irreversible actions.
5. **Validate** by table-top: pick three alerts at random, confirm the Runbook resolves each without external knowledge.

## Handoff / loop-back

Operations closes the loop. An incident that reveals a wrong requirement or missing capability becomes a **PO** input; an incident that reveals an architecture flaw becomes an **SA** input. Postmortems route findings to the owning stage — Operations does not silently patch around design defects.

## Failure modes

- Runbook duplicates the observability spec instead of pointing at it and adding the *response*.
- An alert fires that has no playbook entry (Directive 6 violation: customer reports it first).
- Knobs described but not actually wired (Infra never provisioned them) — caught at the table-top, not at 3am.
- Irreversible actions documented as routine — missing the human-approval gate.

## References

- [`reference/operating-agents-promise-theory.md`](../../reference/operating-agents-promise-theory.md) — **how to run agents in this stage:** the pipeline is a promise network; verify unforgeable evidence; safe autonomy = unforgeable-evidence × reversible-action; humans legislate (mission + axioms) / judge / anchor trust. Operations owns this doc operationally.
- [`reference/data-transform-model.md`](../../reference/data-transform-model.md) — the lens: monitor GLOBAL invariants + reconcile by `authority`; incidents = lost invariant or effect without idempotency
- [`reference/10-prime-directives.md`](../../reference/10-prime-directives.md) — Directive 1 (nothing unwatched), 6 (no customer-first), 10 (operational knobs)
- [`reference/service-anatomy.md`](../../reference/service-anatomy.md) — health/metrics/DLQ surfaces the Runbook watches
- [`01-adversary-operations.md`](01-adversary-operations.md) — the gate before this stage is trusted
