---
name: develop-and-test
description: Autonomous development and integration testing from a requirements doc. Implements everything — database changes, contracts, handlers, configuration — then tests against real infrastructure (dev DB, dev RabbitMQ). Verifies by emitting events, checking DB state, reading logs, and checking error tables. Triggers on "develop this", "implement this", "build from requirements", "start development", "execute the plan", "build and test".
---

# Autonomous Develop & Test

Takes a completed requirements document and implements + tests everything against real dev infrastructure.

## When to Use

- After a requirements doc is approved (from `/requirements-discovery`)
- When there's a completed requirements doc
- When the user says "build it" or "implement this"

## Primary Goal

Implement the feature AND verify it works by testing against real infrastructure. Not unit tests — real events, real database writes, real log verification.

## Pre-Flight Checks

Before writing any code:

1. **Read the requirements doc** completely
2. **Read the reference implementation** service
3. **Verify dev infrastructure is available:**
   - Dev Supabase branch/project accessible (try a test query via MCP)
   - Dev RabbitMQ accessible (check via service health endpoint)
   - Dev DigitalOcean app exists (if deployment testing needed)
4. **Run `pnpm build:shared`** to ensure clean baseline
5. **Present implementation plan** with numbered steps to user for quick approval

## Implementation Sequence

### Phase 1: Build (Steps 1-6)

Follow this exact order. Each step must succeed before the next.

#### Step 1: Database Layer

**New tables:**
1. Apply SQL via Supabase MCP (`execute_sql` or `apply_migration`)
2. Verify table exists: `SELECT * FROM table_name LIMIT 1`

**New database access methods:**
1. Add to `DatabaseClient` (shared package)
2. Add query/command handlers to `database-service`
3. Run `pnpm build:shared`

**CHECKPOINT**: "DB layer complete. [N] methods added. Build passes."

#### Step 2: Message Contracts

If new events needed:
1. Write the Zod schemas
2. Present exact code for contracts package update
3. User publishes new version (or: if contracts are in-repo, update directly)

**CHECKPOINT**: "Contracts defined. [N] new events."

#### Step 3: Service Skeleton (if new service)

Clone structure from reference implementation:
```
packages/service-name/
├── src/
│   ├── index.ts      (bootstrap)
│   ├── routes/
│   │   └── health.ts
│   └── handlers/
├── package.json
├── tsconfig.json
└── .env.example
```

Wire: Fastify, RabbitMQ, DatabaseClient, NotifyingLogger, global error handlers, graceful shutdown.

#### Step 4: Handlers

For each handler in the requirements:
1. Create handler file
2. Implement logic following reference implementation patterns
3. Include idempotency checks
4. Use structured logging

**CHECKPOINT**: "Handlers complete. [N] handlers implemented."

#### Step 5: Event Subscriptions

Wire handlers to events in `index.ts`:
```typescript
await messageBus.subscribe<PayloadType>(EVENT_TYPE, async (event) => {
  await handlerFunction(event.payload, notifyingLogger);
});
```

#### Step 6: Configuration & Build

1. Create `.env.example`
2. Full build verification:
   ```bash
   pnpm build:shared && pnpm build && pnpm lint
   ```

**CHECKPOINT**: "Build complete. All packages compile. Moving to integration testing."

---

### Phase 2: Integration Test (Steps 7-9)

This is where the real verification happens. NOT unit tests.

#### Step 7: Start Services Locally

```bash
# Start the service(s) against dev infrastructure
# Use dev .env pointing to dev Supabase + dev RabbitMQ
pnpm dev:[service-name]
```

Verify health check:
```bash
curl http://localhost:[port]/health
```

#### Step 8: Execute Test Scenarios

For each test scenario from the requirements doc, follow the TRIGGER → VERIFY → EXPECT pattern:

**TRIGGER methods (choose based on scenario):**

1. **Emit RabbitMQ event:**
   Write and run a test script that publishes an event to the dev RabbitMQ:
   ```typescript
   // scripts/test-[feature].ts
   const messageBus = getMessageBus({ url: process.env.RABBITMQ_URL, serviceName: 'test-runner' });
   await messageBus.connect();
   await messageBus.publish(EVENT_TYPE, payload);
   ```

2. **Call HTTP endpoint:**
   ```bash
   curl -X POST http://localhost:[port]/endpoint -H "Content-Type: application/json" -d '{"key": "value"}'
   ```

3. **Insert data into dev DB:**
   Use Supabase MCP `execute_sql` to insert trigger data:
   ```sql
   INSERT INTO table_name (column1, column2) VALUES ('test-value', 'test-data');
   ```

**VERIFY methods (check all of these):**

1. **Check DB state:**
   Use Supabase MCP `execute_sql`:
   ```sql
   SELECT * FROM target_table WHERE id = 'expected-id';
   ```
   Verify: correct columns, correct values, correct status

2. **Check service logs:**
   Read the terminal output from the running service. Look for:
   - Expected log messages (structured logging keys)
   - No error-level logs (unless testing error paths)
   - Correct event processing sequence

3. **Check error table (if applicable):**
   ```sql
   SELECT * FROM email_logs WHERE created_at > '[test-start-time]';
   ```
   Verify: no unexpected error alerts fired

4. **Check downstream effects:**
   If the handler publishes events, verify the downstream service received and processed them:
   ```sql
   SELECT * FROM downstream_table WHERE correlation_id = 'test-correlation-id';
   ```

**EXPECT:**
Compare actual values against the EXPECT section in the requirements. Report:
- PASS: actual matches expected
- FAIL: actual vs expected, with root cause analysis

#### Step 9: Report Results

For each test scenario, produce:

```
Scenario: [name]
  TRIGGER: [what was done]
  VERIFY:
    - DB state: PASS/FAIL [details]
    - Logs: PASS/FAIL [details]
    - Errors: PASS/FAIL [details]
    - Downstream: PASS/FAIL [details]
  RESULT: PASS/FAIL
```

**If any FAIL:**
1. Analyze root cause from logs and DB state
2. Fix the code
3. Re-run ONLY the failed scenario (not all scenarios)
4. Maximum 3 fix-and-retry cycles per scenario

**CHECKPOINT**: "Integration testing complete. [N/M] scenarios pass."

---

### Phase 3: Deploy & Verify (Step 10)

#### Step 10: Deploy to Dev Environment

1. Push to the `dev` branch (where the pipeline auto-deploys from that branch — verify whether
   yours does; if deploys are an explicit, separate act, a push deploys nothing)
2. Wait for deployment (check the platform's app health)
3. Re-run critical test scenarios against deployed service (not localhost)
4. Verify health check on deployed URL

**CHECKPOINT**: "Deployed to dev. Health check passes. [N/M] scenarios verified on deployed service. Ready for merge to main (prod)."

## Guardrails

### Must NOT Do Without Asking
- Modify production database tables
- Delete or modify existing message contracts
- Change existing handler behavior in other services
- Install new npm packages
- Push to production branch (`main`)
- Execute against production infrastructure

### CAN Do Autonomously
- Create new files in target service
- Add new DatabaseClient methods (additive)
- Add new message contract schemas (append-only)
- Write to dev database via Supabase MCP
- Emit events on dev RabbitMQ
- Push to `dev` branch
- Run integration tests
- Fix and retry failed tests

## Error Recovery

| Error | Action |
|-------|--------|
| Build failure | Read error, fix code, rebuild |
| Test scenario fails | Analyze logs + DB, fix code, re-run (max 3 attempts) |
| Service won't start | Check env vars, check RabbitMQ connection, check build |
| DB write fails | Check table exists, check column types, check MCP access |
| Event not received | Check queue binding, check event type spelling, check RabbitMQ management UI |
| Stuck (3+ failures) | Stop. Report to user: what tried, exact error, suspected root cause |
