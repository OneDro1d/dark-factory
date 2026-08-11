# Context Store — read this FIRST

This folder is the project's shared memory. **Every agent reads the relevant part of it before touching code, and never re-scans the repo to re-derive what's already written here.** That is the whole point: analyze once, reuse forever, keep token usage low.

## Files

| File | What it holds | Read it when |
|------|---------------|-------------|
| `SERVICE-MAP.md` | Every service/db/queue/API in one line each + the cross-service flows (structure) | Always, first — to know where things live and how they connect |
| `DATA-FLOW.md` | Data nodes (schema/origin/**authority**/class) + the transform graph + validation rules (semantics) | Before designing a feature, changing a contract, or moving where truth lives |
| `FINDINGS.md` | Known bugs + confirmed root causes (+ status) | Before investigating a bug — it may already be solved/known |
| `DECISIONS.md` | Architecture decisions & rulings (ADR log) | Before designing a feature or questioning "why is it like this" |
| `../<service>/CLAUDE.md` | Deep per-service detail (contracts, files, gotchas) | Only the ONE service you're working in |
| shared-models `CLAUDE.md` | The message contract index | Tracing a routing key / RPC across services |

## Read-first protocol (all agents)
1. Read `SERVICE-MAP.md` (cheap, ~1 screen) to locate the area.
2. Check `FINDINGS.md` — if the issue is already root-caused, stop and reuse it.
3. For a feature/contract/data change, read `DATA-FLOW.md` — know the data's authority, class, and the validation rules before touching it.
4. Read **only** the relevant `<service>/CLAUDE.md`, not every service.
5. Check `DECISIONS.md` before proposing an architecture change.
6. Only then read source — targeted, by `file:line`, not whole-repo scans.

## Write-back protocol (knowledge-keeper agent owns this)
- A confirmed root cause → append to `FINDINGS.md` so it's never re-investigated.
- An architecture/design decision → append to `DECISIONS.md`.
- A new/changed service or contract → update `SERVICE-MAP.md` + the service `CLAUDE.md`.
- Keep entries terse: one fact, status, code ref. Compress, don't accumulate prose.

## Rules
- **No guessing** — every entry cites a source (`file:line`, ruling, ticket). Mark unknowns explicitly.
- Bugs can be in **any** service, DB, queue, API, or infra — nothing is "not in scope."
