---
name: df-ui-verify
description: "Drive and verify a Clerk-protected web UI end-to-end with a backend-minted session, no human login: mint the session, emit Playwright storageState, click through capturing per-scenario evidence and a verdict. Triggers on 'verify the UI', 'click through the app', 'test the front end', 'Clerk Playwright', 'authed UI test', 'UI evidence'."
---

# Dark Factory — Authed UI Verification (df-ui-verify)

## Overview
`df-ui-verify` drives and verifies a **Clerk-protected web UI end-to-end with no human login**. It is a **feeder to `df-qa`**: the mechanism by which QA gets "eyes on" an authed front-end. Two phases (the df convention): a deterministic auth **script** mints a real Clerk session and writes a Playwright `storageState`; then the agent **drives** the live UI per PO scenarios, capturing browser-surface evidence and a verdict.

The auth breakthrough that makes this universal: the backend **`dev_browser` handshake** mints the `__clerk_db_jwt` that the old "headed-login → capture storageState" flow could only get from a real browser. With it, the whole flow runs headless from a backend secret key.

## Scope — the kernel, not your drivers
This skill ships the **portable half**: session minting, storageState assembly, evidence layout, and the verdict rule. It ships **no application drivers**. The per-app click-through scripts — the ones that know your routes, your selectors and your host — belong in the layer that owns the app, not in a generic method repo. Keep them beside the app or in your org's layer, and treat this skill as what they call.

## When to use
- Verifying a deployed, Clerk-gated UI against PO requirements / test scenarios.
- "Look at the website and click through it" — agent-driven exploratory verification.
- Capturing per-scenario UI evidence for a df-qa verdict.

## Phase 1 — Authenticate (run the script)

Populate `skills/df-ui-verify/.env.local` (gitignored), then run the kernel:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/df-ui-verify}/scripts/clerk-auth.sh"
```

**Env contract:**

| Var | Meaning |
|---|---|
| `CLERK_SECRET_KEY` | `sk_test_*` (dev). Drives instance detection. Never logged beyond its prefix. |
| `CLERK_FRONTEND_API` | Frontend API host, e.g. `https://<slug>.clerk.accounts.dev`. |
| `CLERK_USER_ID` | `user_…` to impersonate. (Or set `CLERK_USER_EMAIL` and the script resolves it.) |
| `APP_ORIGIN` | App origin — must be in Clerk **Allowed Origins**. Sent as `Origin` header. |
| `APP_BASE_URL` | Where the UI is served (navigate target). |

⚠️ **Every one of these is a landmark.** The secret key is a credential; the frontend-API slug, the user id and the origin together identify the instance, the person and the deployment. They live in `.env.local`, which is gitignored, and they belong in no committed file — not a doc, not a fixture, not a test. The test suite here uses placeholder hosts for exactly this reason.

**Outputs** (in `.run/`, gitignored): `storageState.json` (Playwright-native: `__session` + `__clerk_db_jwt` + `__client_uat` cookies + localStorage), `session.jwt` (raw `Bearer` for API-level assertions).

## Phase 2 — Drive & verdict (judgment)

Two ways to consume `storageState.json`:

- **Playwright MCP (agent click-through).** Fill `scripts/inject-session.template.js` with `.run/storageState.json`, copy to `<target-repo>/.playwright-mcp/inject-session.js` (an MCP-allowed path, **NOT `/tmp`** — the sandbox blocks `require`/`import`). `browser_navigate` → `APP_ORIGIN` → run the inject via `browser_evaluate` → `browser_navigate` → protected route → `browser_snapshot`/click.
- **Native (`npx playwright test`).** Set `storageState: '.run/storageState.json'` in config (cookies present at context creation — the robust path if running-page injection trips Clerk's continuity guard). Pin `@playwright/mcp@0.0.41`; bundled Chromium avoids the system-Chrome singleton conflict.

For multi-route coverage under MCP, the working pattern is a **small Node builder that inlines `storageState` into a generated `drive.js`**, loaded with `filename=`, which does `context.addCookies` + `addInitScript` localStorage + `goto`. Drive the SPA by **clicks** rather than full `page.goto` reloads so the Clerk SDK stays warm. Those builders are app-shaped — write them where the app lives.

**Per-scenario evidence** (one PO scenario → one dir under `.run/evidence/<slug>/`): `screenshot.png`, `snapshot.txt` (DOM/a11y), `network.json` (`[{url,status,correlationId?}]`), `console.txt`. `network.json` is the spine. Extract `correlationId`s and **hand them to df-qa** for the deep backend-trace lookup — this skill does not query the trace store itself.

**Verdict** (`scripts/verdict.sh <scenario_dir>`): **PASS** (expected render + all calls 2xx + clean console) · **CONDITIONAL** (renders, only known-harmless noise like `clerk-telemetry.com` 400s) · **FAIL** (wrong render, a call ≥400, or a blocking console error). **No PASS without evidence** — an empty `network.json` is a FAIL. Route a FAIL to its lane: render → frontend, API ≥400 → backend/Infra, missing scenario → PO.

## Prod read-only guardrail
On a `sk_live_` instance, drive **observe-only**: navigate, snapshot, read, assert-rendered. Any control that submits/sends/purchases/deletes is a **hard stop** — surface the intended click and wait for explicit human go.

> **Prod path — NOT YET IMPLEMENTED.** The kernel currently handles dev (`sk_test_`) only; it exits on `sk_live_`. The prod first-party cookie flow (no `dev_browser`/`db_jwt`) is designed but unbuilt — implement + live-verify before trusting it.

## Verification
- [ ] `.run/storageState.json` written; `cookies[]` non-empty; `__clerk_db_jwt` in cookies + localStorage; `__client_uat` non-zero.
- [ ] Navigating a protected route renders the **authed shell**, not the sign-in splash.
- [ ] ≥1 scenario captured all four evidence files; `network.json` has status codes.
- [ ] `bash test/test-df-ui-verify.sh` is green — 14 assertions across instance detection, storageState and verdict.
- [ ] **Prod path:** unticked — out of scope until built + live-verified.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `dev_browser_unauthenticated` | missing `__clerk_db_jwt` | run step 1; pass db_jwt as query **and** Cookie |
| Sign-in widget renders **empty** | `APP_ORIGIN` not in Clerk Allowed Origins | add the host in the Clerk dashboard |
| 401/403 after auth, session valid | session token missing `email` claim | Clerk → Sessions → Customize: add `"email":"{{user.primary_email_address}}"` |
| MCP "Opening in existing browser session" | system Chrome singleton | SSE transport or native `npx playwright test` (bundled Chromium) |
| `require()`/`import` fails in MCP | sandbox blocks them | inline JSON into `.playwright-mcp/*.js`, not `/tmp` |
| Authed shell won't render after inject | running-page inject trips Clerk continuity guard | use the native recipe — storageState at context creation |
| Route never matches | app uses HashRouter (`#/path`) | match on hash, not path |
| Stale code after edit | Vite atomic-write misses chokidar | `touch <file>` after Edit |
| MCP drops mid-session | `@latest` pulls betas | pin `@playwright/mcp@0.0.41` |
| `Clerk was not loaded with Ui components` | clerk-js v6 split `@clerk/ui` | bundle `@clerk/ui` — a target-app issue; flag it, do not fix it from here |
| All routes redirect to sign-in after ~1 min | minted session JWT TTL ≈ 60s expired | **re-mint immediately before driving**; navigate via in-app **clicks (SPA)** not full `page.goto` reloads so the Clerk SDK stays warm and auto-refreshes |
| Row/tab click doesn't navigate | rows are framework row-click (not `<a>`); tabs share text with list headers | `browser_snapshot` to get the real element ref (an explicit button, or `role=tab`), then `browser_click` that ref |

## Resources
- `scripts/clerk-auth.sh` — the auth kernel (executed, not loaded into context).
- `scripts/lib/storage-state.sh` — pure storageState assembly.
- `scripts/verdict.sh` — Pass/Conditional/Fail from evidence.
- `scripts/inject-session.template.js` — Playwright-MCP injection helper.
- `test/test-df-ui-verify.sh` — unit suite, zero test-framework dependency. The `test_*.sh`
  units beside it are not discovered directly; this entry point sums their assertion counts.
- Pairs with: `df-qa` (parent), `df-observability` (the correlationId trace).
