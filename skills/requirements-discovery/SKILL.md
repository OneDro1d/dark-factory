---
name: requirements-discovery
description: Interactive requirements gathering that produces machine-executable specs for microservices. Guides conversation through structured rounds to produce a complete requirements doc where every section maps to a code artifact (SQL, Zod schemas, handlers, tests). Triggers on "new feature", "new service", "requirements", "I want to build", "let's spec out", "define requirements".
---

# Requirements Discovery

Transform a vague feature description into a precise, machine-executable requirements document. Every section of the output maps 1:1 to a code artifact.

## When to Use

- Starting a new microservice or handler
- Adding new database tables or message events
- Any feature that touches multiple services
- When someone says "I want to build [X]"

## Primary Goal

Zero ambiguity in the output. The requirements doc should be so precise that autonomous development can execute it without asking questions.

## Step 0: Load Context

Before asking any questions:
1. Read the project's CLAUDE.md for architecture patterns and conventions
2. Read `docs/service-map.md` (or equivalent) for existing services and responsibilities
3. Read `REQUIREMENTS-TEMPLATE.md` in this skill's directory for the output format
4. Understand existing EVENT_TYPES, database tables, and service boundaries

## Discovery Rounds

### Round 1: Domain & Scope

Ask ALL of these. Do NOT proceed until answered:

1. **What problem does this solve?** (1-2 sentences, business context)
2. **Who or what triggers this?** (User action / scheduled / event from another service / external webhook)
3. **What is the expected output/effect?** (Data created / event published / state changed / notification sent)
4. **Which existing service is this most similar to?** (This becomes the reference implementation)
5. **Which repository does this belong in?** (Suggest one based on the description, confirm with user)

After answers: **Summarize your understanding. Ask "Is this accurate?"**

### Round 2: Data & Integration

1. **What data does this need to READ?** (Which tables, which fields)
2. **What NEW data does this create?** (New tables? New columns?)
3. **Which existing events does it CONSUME?** (From the event catalog)
4. **What NEW events should it PUBLISH?** (Name them, describe payload structure)
5. **External API integrations?** (Remind: one integration point per external service)
6. **New database access methods needed?** (Check what already exists)

**CHALLENGE vague answers.** If someone says "it needs price data," ask: "Live price from the exchange, or cached market data, or calculated NAV?"

### Round 3: Business Rules & Edge Cases

1. **Core business rules?** (The unique logic)
2. **Failure handling for each failure mode:**
   - Database write fails → retry? skip? alert?
   - External API timeout → fallback? cached data?
   - Missing upstream data → reject? defaults? log warning?
3. **Idempotency?** (Can the handler safely process the same event twice?)
4. **Timing/scheduling?** (Cron? Interval? Which timezone?)
5. **Financial precision?** (Touches money? Rounding direction?)
6. **Concurrency?** (Multiple instances? Locking needed?)

### Round 4: Acceptance & Testing

1. **What does "done" look like?** (Observable outcomes, not "it works")
2. **Integration test scenarios** (3-5 scenarios in this format):
   ```
   TRIGGER: [what you do to start the test — emit event / call API / insert DB row]
   VERIFY:  [what you check — DB state / logs / error table / downstream event]
   EXPECT:  [specific expected values]
   ```
3. **Performance requirements?** (Latency, throughput)
4. **Environment?** (Dev first, then prod? Straight to prod?)
5. **Dependencies?** (What must exist first?)
6. **Out of scope?** (What this feature does NOT do)

## Challenge Rules

You MUST push back on vague requirements:

| Vague | Challenge With |
|-------|---------------|
| "Handle errors gracefully" | "Which errors? What recovery action for each?" |
| "Store the data" | "Which table? Columns? Who writes? Who reads?" |
| "Notify the user" | "Email/push/in-app? Template? Trigger condition?" |
| "It should be fast" | "Latency target in ms? Under what load?" |
| "Keep it secure" | "Auth method? Which middleware? Rate limiting?" |

## Output: Requirements Document

After all 4 rounds, generate the complete document. Structure:

```
## 1. Context
  - Problem statement, business value, reference implementation

## 2. Data Model
  - Exact SQL (CREATE TABLE, indexes)
  - Table ownership (who writes, who reads)
  - New database access methods (typed signatures)

## 3. Message Contracts
  - New events with Zod schemas (V1 naming)
  - Queue definitions (service.event-type pattern)
  - Event flow diagram (ASCII)
  - Existing events consumed/published

## 4. Handlers
  - For each handler:
    - Trigger (event type / cron / HTTP)
    - Input type
    - Step-by-step logic
    - Output (event published)
    - Error handling
    - Idempotency strategy

## 5. HTTP Endpoints (if any)
  - Route, method, auth, request/response schemas

## 6. Integration Test Scenarios
  - For each scenario:
    - TRIGGER: how to initiate (emit event, call API, insert row)
    - VERIFY: what to check (DB query, log search, error table)
    - EXPECT: specific expected values

## 7. Configuration
  - Environment variables
  - Runtime config entries

## 8. Deployment
  - Port, health check, Dockerfile, app spec

## 9. Definition of Done
  - Measurable checklist (not "it works")

## 10. Out of Scope
  - Explicit exclusions to prevent scope creep
```

Save to: `docs/requirements/[feature-name].md`

## Quality Checks

Before presenting:
- [ ] Every table has an owner service
- [ ] Every handler has trigger, input, output, error handling
- [ ] Test scenarios use TRIGGER/VERIFY/EXPECT format (not unit test Given/When/Then)
- [ ] No VARCHAR — all TEXT
- [ ] Events use Zod schemas with V1 naming
- [ ] Reference implementation identified
- [ ] Definition of Done has verifiable items
- [ ] Out of Scope prevents obvious creep
