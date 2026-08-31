// df-ui-verify — Playwright-MCP session injection helper.
//
// The Playwright-MCP sandbox blocks require()/import, so the storageState is
// INLINED: replace the literal __STORAGE_STATE__ below with the contents of
// .run/storageState.json, write this file to <target-repo>/.playwright-mcp/inject-session.js
// (an MCP-allowed path — NOT /tmp), then run it via browser_evaluate AFTER a
// browser_navigate to APP_ORIGIN (so cookies land on the right origin).
//
// If the authed shell does not render after inject + reload, the running-page
// injection tripped Clerk's session-continuity guard (resets __client_uat=0).
// Fall back to the NATIVE recipe: pass storageState.json at BrowserContext
// creation (`npx playwright test`, storageState in config) — cookies present
// BEFORE first navigation, which Clerk accepts as a fresh legitimate session.
(() => {
  const s = __STORAGE_STATE__;
  for (const c of s.cookies) document.cookie = `${c.name}=${c.value}; path=${c.path}`;
  for (const o of s.origins) for (const kv of o.localStorage) localStorage.setItem(kv.name, kv.value);
  return { cookies: s.cookies.length, ls: s.origins.reduce((n, o) => n + o.localStorage.length, 0) };
})();
