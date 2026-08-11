---
title: Adversary Operations Review
stage: 6. Operations
type: adversary-process
status: living
---

# Adversary Operations Review

## TL;DR

Before the Operations Runbook is trusted, an adversary (AI or human, ideally one who did not write it) attacks it: pick real alerts and prove the Runbook cannot resolve them, or that a knob it relies on does not exist. Verdict is **Pass / Conditional / Fail**.

## Review checklist (signal)

| Check | Pass? |
|---|---|
| Every observability-spec alert has a playbook entry | |
| Every knob referenced (slow/stop/redirect/inspect) is actually provisioned | |
| SLOs trace to PO real-life scenarios, not invented | |
| Irreversible actions are gated with a human-approval step | |
| Escalation path names roles, not individuals only | |
| Loop-back routing (incident → PO or SA) is explicit | |
| Cold on-call test passes for 3 randomly chosen alerts | |
| Every GLOBAL invariant is a live reconciliation check with a declared `authority`; effect knobs (irreversible) are human-gated ([lens](00-operations-guide.md#through-the-data-transform-lens)) | |

## Verdict

- **Pass** — every check yes; table-top of 3 alerts resolved from the Runbook alone.
- **Conditional** — small explicit gaps, each tagged with an owner and a close-by date.
- **Fail** — any alert with no response, any knob that does not exist, or the cold on-call test fails.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Adversary prompt

```text
You are an adversarial SRE reviewing an Operations Runbook for a system you did not build.
Using critical thinking, try to make the runbook fail:
- Pick alerts and walk them step by step. Where does the responder have to guess, read code, or call someone?
- For each knob the runbook tells the responder to turn, ask: was it actually provisioned by Infrastructure? Cite where.
- Find an alert in the observability spec with no playbook entry (Directive 6 violation).
- Find an irreversible action presented as routine.
Return a findings table: severity | check | evidence | fix. Then a verdict: Pass / Conditional / Fail.
```

## What to attack

- **Coverage:** alerts without responses. Cross-check the observability spec line-by-line.
- **Reality:** knobs and secrets that the Runbook assumes but Infra never built.
- **Safety:** irreversible actions missing the human gate.
- **Provenance:** SLOs that do not trace to a PO scenario are arbitrary.

## Output format

A findings table plus verdict. High-severity findings (uncovered alert, missing knob, ungated irreversible action) force a **Fail** until fixed.
