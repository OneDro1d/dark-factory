---
title: Operations Runbook — <Product Name>
stage: 6. Operations
type: operations-runbook
status: template
consumes: service map, deployment spec, observability spec, runtime trust profile
---

# Operations Runbook — <Product Name>

## TL;DR

<One paragraph: what this system does, who depends on it, and the single most important thing to watch.>

## Service snapshot

| Service | Purpose | Cluster(s) | Health | Dashboard |
|---|---|---|---|---|
| `<service>` | <one line> | startrek / eks-… | `:8080/healthz` | <Grafana link> |

## SLOs (what "healthy" means)

| SLO | Target | Source (PO scenario) |
|---|---|---|
| <e.g. ingestion ack latency> | < 500ms p95 | <scenario id> |
| <availability> | 99.9% | <scenario id> |

## Operational knobs (Directive 10)

| Knob | Action | How | Reversible? | Approval |
|---|---|---|---|---|
| **Slow** | rate-limit ingestion | `<config value / control CLI cmd>` | yes | none |
| **Stop** | pause consumer / drain queue | `<cmd>` | yes | on-call |
| **Redirect** | failover route / alt consumer | `<cmd>` | yes | **human** |
| **Inspect** | tail logs / replay DLQ | `<cmd>` | yes | none |

## Alert → response playbook

One row per alert in the SA Service Map (Alerts & SLOs), wired by Infra. No alert may be missing.

| Alert | Symptom | Likely cause | Diagnostic (inspect) | Mitigation (knob) | Escalate when |
|---|---|---|---|---|---|
| `<alert name>` | <what fires> | <cause> | `<inspect cmd>` | `<knob>` | <condition> |

## Escalation

| Severity | Who | Channel | Approves irreversible actions |
|---|---|---|---|
| SEV1 | on-call → eng lead | <channel> | eng lead |
| SEV2 | on-call | <channel> | on-call |

## Loop-back

- Incident reveals a **wrong/missing requirement** → file to Product Owner.
- Incident reveals an **architecture flaw** → file to Solution Architect.
- Attach the postmortem; do not patch around a design defect silently.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Secrets & rotation

| Secret | Used by | Source | Rotation |
|---|---|---|---|
| `<KEY>` | `<service>` | AWS SM / sealed-secret | <cadence> |

## Runtime trust (who can act)

Per service: identity, granted scopes, data classification (HIPAA/PHI/PII), revocation path. Pull from the Runtime Trust Profile — do not restate, link and note deltas.

## Notes for the AI on-call agent

- Routine knobs (slow, inspect, documented stop) are AI-executable.
- Redirect, scale-to-zero, data deletion, customer comms = **human approval required**.
- Every action you take logs to the audit sink named in the Runtime Trust Profile.
