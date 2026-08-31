# Playwright helpers

Three scripts for driving a browser from an agent session. They are transport and session
plumbing only — they know nothing about any application.

| script | what it does |
|---|---|
| `start-playwright-sse.sh` | Runs one Playwright MCP server over SSE on `:3001`. The fallback when the stdio transport drops mid-session. `--headed` for a visible browser. |
| `start-playwright-parallel.sh N` | Runs N isolated SSE servers on `:3001…:300N`, each with its own `--user-data-dir`, so parallel sessions cannot share cookies or storage. |
| `capture-auth-state.js` | Opens a browser, waits for a human to sign in, and writes the resulting storage state to a JSON file that Playwright's `storageState` can reuse. |

## Why the isolation matters

Two agent sessions sharing one browser profile share one logged-in identity, and the failure
is silent: the second session's test passes as the first session's user. Every parallel
server gets its own data directory for that reason alone.

## Capturing a session instead of scripting a login

```bash
node boot-kit/scripts/capture-auth-state.js \
  --url http://localhost:5173 \
  --output <project>/playwright/.auth/session.json
```

Sign in in the window that opens; the state is written when you finish. Reuse it with
Playwright's `storageState`, and re-capture when it expires. ⚠️ **The output file is a live
credential.** It belongs in `.gitignore`, not in a repo, and not in a bug report.

## MCP or native, and what it costs

Use the Playwright **MCP** tools to explore a UI interactively — the agent drives the browser
and sees what it finds. Use **native** `playwright test` specs for anything that runs more
than once. MCP costs roughly 4× the tokens per interaction, so a suite driven through MCP is
a suite you will stop running.

⚠️ **What is deliberately NOT here.** The per-project table — which port, which auth mode,
where each app's state file lives — is not generic and does not belong in Tier 1. It belongs
in the instance or org layer that owns those applications. Promoting the estate's version of
this file would have published one estate's hostnames, checkout paths and product names as
the method.

`skills/df-ui-verify` is the layer above these scripts: it mints a session from the backend
and drives a Clerk-protected UI end to end, capturing per-scenario evidence.
