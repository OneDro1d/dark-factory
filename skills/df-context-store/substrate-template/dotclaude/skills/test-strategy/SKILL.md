---
name: test-strategy
description: Decide what to test and write the tests for a change — regression guards, edge cases, cross-service contracts — and scaffold the test project in the repo's conventions. Use after a fix or feature, or to assess coverage. Triggers on "write tests", "test coverage", "regression test", "validate change", "review test quality".
allowed-tools: Read, Write, Edit, Bash, Grep, Glob
---

# Test Strategy + Scaffolding

Goal: protect against regressions cheaply. Test pure logic and cross-service contracts — that's where silent bugs live (record detection, object-store-key drift, data-class split, type coercion). Skip trivial getters.

## Test-first (RED → GREEN → REFACTOR)
Write the test **before** the production code, not after — the bug/feature's
test should exist and **fail (RED)** first, then the implementer makes it pass
**(GREEN)**, then refactor under green. The test list is **derived from the
Design Spec's ACCEPTANCE criteria** (one criterion → one named test), not
invented at validation time. The implementer may not weaken a RED test to pass;
a wrong test goes back to feature-architect. (Validation that lands *after* code
is test-after — a weaker guard. See `.claude/context/AGENT-CONTRACTS.md`.)

## What to test (priority)
1. **The exact bug being fixed** — a test that fails before the fix, passes after.
2. **Cross-service contracts** — drift = silent wedge (object-store key shape, record fields, routing keys).
3. **Security/segregation** — restricted vs non-restricted data routing, fail-safe defaults.
4. **Edge cases** — empty/missing, wrong type, boundary (padding, blank + coerced value).
Avoid tests needing live queue/DB/object-store (those are integration — keep a separate fixture for them).

## Scaffolding conventions
Mirror the repo's existing test layout and pinned tooling versions. Common stacks:
- **.NET** → a `<Service>.Tests` project referencing the service `.csproj` (xUnit). To test `private` helpers, widen to `internal` (never `public`) + add `<InternalsVisibleTo>` to the service csproj. Run: `dotnet test <proj>`.
- **Go** → in-package `<file>_test.go`, table-driven. If valuable logic is inlined in `main()`, extract a named pure func first, then test it. Run: `cd <service> && go test ./...`.
- **Python** → `test_<module>.py` next to the code or under `tests/`. Run: `pytest`.

## Run before reporting — green is the bar
Run the repo's test command (e.g. `dotnet test`, `go test ./...`, `pytest`) and mirror an existing passing suite for structure.

## Output (Validation Report)
```
TESTED: <what + why it matters>
RESULT: <pass/fail summary>
EDGE CASES: <covered>
REGRESSIONS: <checked / found>
VERDICT: <safe / not safe> — and what's still unverified
```
No secrets/PII in fixtures. Don't commit without explicit approval.
