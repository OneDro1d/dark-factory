---
title: Adversary Developer Review
stage: 3. Developer
type: adversary-process
status: living
---

# Adversary Developer Review

## TL;DR

An adversary attacks each service before it moves to QA: prove the Build Spec cannot boot a cold agent, find an anti-pattern (custom AMQP, `Log.Error`, `latest` tag), or a message contract that drifted from the SA Data Model. Verdict: **Pass / Conditional / Fail**.

## Review checklist (signal)

| Check | Pass? |
|---|---|
| Build Spec boots a fresh AI session to a working smoke test | |
| Consumed/published Avro schemas match the SA Data Model exactly | |
| Service Anatomy present (health/metrics/log/DLQ/correlation/shutdown/config) | |
| No anti-patterns: custom AMQP, `Log.Error`, `latest` tags, <3 replicas, shared DB | |
| Unit + integration tests green and meaningful (not assertion-free) | |
| Deviations from the 8 patterns each have an ADR pointer | |
| Every ingress validates before consuming (no sticky/transitive trust); every effect handler is idempotent + has compensation; no source-of-truth value overwritten by a local cache ([lens](00-developer-guide.md#through-the-data-transform-lens)) | |

## Verdict

- **Pass** — every check yes; smoke test reproducible from the Build Spec.
- **Conditional** — minor gaps, owned and time-boxed.
- **Fail** — contract drift, any anti-pattern, or a Build Spec that cannot boot an agent.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Adversary prompt

```text
You are an adversarial senior engineer reviewing a service you did not build.
Using critical thinking:
- Boot a fresh agent using only the Per-Service Build Spec. Does it reach a working smoke test, or does it have to guess?
- Diff the service's consumed/published Avro schemas against the SA Data Model. Flag any drift.
- Grep for anti-patterns: custom AMQP (not the shared messaging library), Log.Error, latest image tags, replicas<3, shared databases.
- Confirm Service Anatomy is complete.
Return: findings table (severity | check | evidence | fix) + verdict Pass/Conditional/Fail.
```

## What to attack

- **Boot-ability:** the Build Spec is the contract with the next cold agent.
- **Contract fidelity:** schema drift from SA.
- **Pattern compliance:** the 8 patterns + anatomy are defaults, not suggestions.

## Output format

Findings table + verdict. Contract drift or any anti-pattern forces **Fail**.
