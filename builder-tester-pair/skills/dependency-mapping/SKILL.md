---
name: dependency-mapping
description: Trace a request/data flow end-to-end across services, queues, databases, object stores, and APIs to find every component a change or bug touches. Use when a problem spans boundaries or before changing a shared contract. Triggers on "trace the flow", "what depends on", "blast radius", "end to end path", "who consumes/produces".
allowed-tools: Read, Grep, Glob, Bash
---

# Dependency Mapping (cross-boundary tracing)

Goal: produce the exact chain of components a flow or change touches, so nothing downstream is missed. In a message-driven system, follow the **routing keys**, not just function calls.

## Method
1. Start from `.claude/context/SERVICE-MAP.md` (the "In → Out" columns give the spine).
2. For each hop, confirm in code: producer's `publish`/routing key → the consumer whose config binds that key → its handler. Use the shared-models `CLAUDE.md` contract index to resolve names.
3. Note every **store** touched (DB table, graph edge, object-store key) and every **API** (HTTP route, gRPC RPC).
4. Flag the **cross-service contracts** that break silently if changed (object-store key shape, record field names, routing keys, shared DB columns).

## Output (structured, hand to investigator/architect)
```
FLOW: <name>
HOPS: svc → (routingKey) → svc → ...   [each with file:line]
STORES: <DB tables / graph edges / object-store keys touched>
APIS: <HTTP routes / RPCs>
SHARED CONTRACTS AT RISK: <list>
UNKNOWNS: <what you could not confirm in code>
```

## Don't
- Don't assume the SERVICE-MAP diagram is current if code disagrees — report the drift.
- Don't stop at the first service; a "fix" in one hop often needs the consumer updated too.
