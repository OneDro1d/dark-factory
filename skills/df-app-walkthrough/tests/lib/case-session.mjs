/**
 * Auth modes, the drawn cursor, and the glide — `scripts/lib/session.mjs`.
 *
 * ⚠️ ONE CASE PER PROCESS, AND THAT IS NOT TIDINESS. `session.mjs` reads `WT_AUTH` at
 * MODULE LOAD (`const AUTH = process.env.WT_AUTH || "none"`), so a single process cannot
 * test two modes: the second would silently run under the first mode's constant and pass
 * for the wrong reason. The suite picks the case by argv and sets the env around the whole
 * node invocation. If that constant is ever changed to a per-call read, these cases keep
 * working — the dependency is declared here so the next reader does not have to find it.
 *
 *   node case-session.mjs <case-name>
 */
import { checker } from "./stub-page.mjs";
import { journal, makePage } from "./stub-page.mjs";

const CASE = process.argv[2] || "";
const t = checker();
const mod = await import("../../scripts/lib/session.mjs");
const { contextOptions, signIn, glideTo, showClick, CURSOR_INIT_SCRIPT } = mod;

/** Replace global fetch with a recorder. Returns the call log. */
function stubFetch(reply) {
  const calls = [];
  globalThis.fetch = async (url, opts) => {
    calls.push({ url: String(url), auth: (opts?.headers || {}).Authorization ? "present" : "absent", body: opts?.body });
    return reply(calls.length);
  };
  return calls;
}
const jsonReply = (status, body) => ({
  ok: status >= 200 && status < 300,
  status,
  json: async () => body,
});

switch (CASE) {
  // ------------------------------------------------------------ contextOptions
  case "ctx-none": {
    t.eq(contextOptions(), {}, "WT_AUTH unset: no extra context options");
    break;
  }
  case "ctx-storage-missing": {
    // ⛔ The refusal is the feature. Without it Playwright opens an UNAUTHENTICATED context,
    // records eight minutes of a sign-in page, and every later beat fails one at a time.
    let threw = "";
    try { contextOptions(); } catch (e) { threw = e.message; }
    t.ok(/needs WT_STORAGE_STATE/.test(threw),
      "storage-state mode with no WT_STORAGE_STATE REFUSES up front", threw || "did not throw");
    break;
  }
  case "ctx-storage-ok": {
    t.eq(contextOptions(), { storageState: "/tmp/does-not-need-to-exist.json" },
      "storage-state mode passes the path through to the context");
    break;
  }
  case "ctx-clerk": {
    // clerk-ticket signs in through the page, so it must NOT also set storageState.
    t.eq(contextOptions(), {}, "clerk-ticket mode adds no storageState");
    break;
  }

  // ------------------------------------------------------------ signIn: simple modes
  case "signin-none": {
    const j = journal();
    const r = await signIn(makePage(j), { readySelector: "#app" });
    t.eq(r, true, "auth none: signIn reports ready");
    t.eq(j.of("goto").map((e) => e.url), ["https://app.invalid/"], "auth none: navigates to WT_APP");
    t.eq(j.of("waitForSelector").map((e) => e.selector), ["#app"], "auth none: waits for the ready selector");
    break;
  }
  case "signin-none-noapp": {
    // No WT_APP: nothing to navigate to, and it must not invent a URL or crash.
    const j = journal();
    const r = await signIn(makePage(j));
    t.eq(r, true, "auth none with no WT_APP still reports ready");
    t.eq(j.of("goto").length, 0, "auth none with no WT_APP navigates nowhere");
    break;
  }
  case "signin-unknown": {
    const j = journal();
    await t.throws(() => signIn(makePage(j)), /unknown WT_AUTH: totally-made-up/,
      "an unrecognised WT_AUTH REFUSES and names the bad value");
    t.eq(j.of("goto").length, 0, "…before touching the page");
    break;
  }

  // ------------------------------------------------------------ signIn: clerk-ticket
  case "signin-clerk-nokey": {
    const j = journal();
    await t.throws(() => signIn(makePage(j)), /needs CLERK_SECRET_KEY and CLERK_USER_ID/,
      "clerk-ticket with no credentials REFUSES and names both variables");
    break;
  }
  case "signin-clerk-http": {
    stubFetch(() => jsonReply(500, {}));
    await t.throws(() => signIn(makePage(journal())), /sign_in_tokens returned 500/,
      "a non-2xx from sign_in_tokens REFUSES and reports the status");
    break;
  }
  case "signin-clerk-notoken": {
    // A 200 with no token is the dangerous shape: it looks like success.
    stubFetch(() => jsonReply(200, { ohDear: true }));
    await t.throws(() => signIn(makePage(journal())), /returned no token/,
      "a 200 with no token REFUSES rather than navigating with 'undefined'");
    break;
  }
  case "signin-clerk-ok": {
    const calls = stubFetch((n) => jsonReply(200, { token: `tk${n}` }));
    const j = journal();
    const r = await signIn(makePage(j, { leaveSignIn: true }), { readySelector: "#app" });
    t.eq(r, true, "clerk-ticket: signIn reports ready once the app redirects");
    t.eq(calls.length, 1, "clerk-ticket: one ticket minted when the first one lands");
    t.eq(calls[0].auth, "present", "clerk-ticket: the secret key goes in the Authorization header");
    const g = j.of("goto")[0];
    t.ok(/\/sign-in\?__clerk_ticket=tk1$/.test(g.url),
      "clerk-ticket: the ticket is handed to the sign-in route", g.url);
    t.eq(j.of("waitForURL").length, 1, "clerk-ticket: waits for the REDIRECT, not a fixed sleep");
    t.eq(j.of("waitForSelector").map((e) => e.selector), ["#app"], "clerk-ticket: then waits for the app");
    break;
  }
  case "signin-clerk-retry": {
    // ⛔ THE RETRY MUST MINT A FRESH TICKET. The widget consumes the ticket asynchronously
    // and intermittently misses the first one; replaying the SAME ticket retries with a
    // credential the server has already burned, so the retry cannot ever succeed. Three
    // DIFFERENT tickets is the assertion — three attempts alone would not catch a replay.
    const calls = stubFetch((n) => jsonReply(200, { token: `tk${n}` }));
    const j = journal();
    await t.throws(() => signIn(makePage(j, { leaveSignIn: false })), /failed after 3 attempts/,
      "clerk-ticket gives up after 3 attempts rather than hanging");
    t.eq(calls.length, 3, "clerk-ticket mints exactly 3 tickets");
    const tickets = j.of("goto").map((e) => e.url.split("__clerk_ticket=")[1]);
    t.eq(tickets, ["tk1", "tk2", "tk3"], "each attempt uses a FRESH ticket, never a replay");
    break;
  }
  case "signin-clerk-path": {
    const calls = stubFetch(() => jsonReply(200, { token: "tk" }));
    const j = journal();
    await signIn(makePage(j, { leaveSignIn: true }));
    t.ok(j.of("goto")[0].url.includes("/enter?__clerk_ticket="),
      "WT_SIGNIN_PATH overrides the /sign-in default", j.of("goto")[0].url);
    t.eq(calls.length, 1, "…and still mints one ticket");
    break;
  }

  // ------------------------------------------------------------ the drawn cursor
  case "cursor": {
    // ⛔ THIS STRING IS SHIPPED TO A BROWSER AND NEVER PARSED BY NODE. A syntax error, or a
    // renamed element id, would surface only mid-recording — after the TTS has run and the
    // browser is up. Parsing and EXECUTING it against a DOM stub moves that failure here.
    let fn = null;
    try {
      fn = new Function("window", "document", "setInterval", CURSOR_INIT_SCRIPT);
      t.ok(true, "CURSOR_INIT_SCRIPT parses as JavaScript");
    } catch (e) {
      t.ok(false, "CURSOR_INIT_SCRIPT parses as JavaScript", e.message);
    }

    if (fn) {
      // A DOM small enough to be obviously correct, and no smaller than the script needs.
      const byId = new Map();
      // ⛔ THE classList MUST RECORD AN OP LOG, NOT JUST A SET OF CLASSES, and this was a
      // real inert assertion caught by test-walkthrough-mutations.sh. Re-triggering a CSS
      // animation is `remove(); void offsetWidth; add()` — a reflow sandwiched between two
      // class ops. A Set-backed classList cannot express that: after the first ripple the
      // class is already present, so `has("__wt_pop")` is true whether the re-trigger ran
      // or not, and the mutant that deleted the remove+reflow SURVIVED. The order of the
      // operations IS the mechanism, so the order is what gets recorded.
      const mkEl = (tag) => {
        const el = {
          tagName: tag, id: "", textContent: "",
          style: {},
          children: [],
          ops: [],
          reflows: 0,
          classList: {
            _s: new Set(),
            add(c) { el.ops.push("add:" + c); this._s.add(c); },
            remove(c) { el.ops.push("remove:" + c); this._s.delete(c); },
            has(c) { return this._s.has(c); },
          },
          appendChild(c) { el.children.push(c); if (c.id) byId.set(c.id, c); return c; },
        };
        // Reading offsetWidth is how the script forces the reflow; count the reads.
        Object.defineProperty(el, "offsetWidth", {
          get() { el.ops.push("reflow"); el.reflows++; return 1; },
        });
        return el;
      };
      const body = mkEl("body");
      const head = mkEl("head");
      const doc = {
        readyState: "complete",
        body, head,
        documentElement: mkEl("html"),
        createElement: mkEl,
        getElementById: (id) => byId.get(id) || null,
        addEventListener() { t.ok(false, "DOMContentLoaded path taken with readyState complete"); },
      };
      const win = {};
      let intervals = 0;
      fn(win, doc, () => { intervals++; return 0; });

      t.ok(typeof win.__wtMove === "function", "it installs window.__wtMove");
      t.ok(typeof win.__wtRipple === "function", "it installs window.__wtRipple");
      t.ok(intervals === 1, "it re-installs on a timer, so an SPA route change cannot lose the cursor",
        `setInterval called ${intervals} times`);
      t.ok(doc.getElementById("__wt_cursor") !== null, "it creates the cursor element");
      t.ok(doc.getElementById("__wt_ripple") !== null, "it creates the ripple element");
      // The stylesheet must land in <head>. Appended into the cursor's own subtree it would
      // still "work" in some browsers and is exactly the mistake showCard documents hitting.
      const styles = head.children.filter((c) => c.tagName === "style");
      t.eq(styles.length, 1, "it appends exactly one stylesheet to <head>");
      t.ok(styles.length === 1 && styles[0].textContent.includes("#__wt_cursor"),
        "…and that stylesheet is the one styling the cursor");

      win.__wtMove(5, 7);
      const c = doc.getElementById("__wt_cursor");
      t.eq([c.style.left, c.style.top], ["5px", "7px"], "__wtMove positions the cursor in px");

      const r = doc.getElementById("__wt_ripple");
      r.ops.length = 0;
      win.__wtRipple(11, 13);
      t.eq([r.style.left, r.style.top], ["11px", "13px"], "__wtRipple positions the ripple");
      t.ok(r.classList.has("__wt_pop"), "__wtRipple starts the pop animation");

      // ⛔ Called a SECOND time, the animation must actually restart, and the only thing
      // that restarts a CSS animation is removing the class, forcing a reflow, and adding
      // it back. Asserting the class is merely PRESENT cannot see this: it is already
      // present from the first ripple. So assert the three operations, in order.
      r.ops.length = 0;
      r.reflows = 0;
      win.__wtRipple(1, 1);
      t.eq(r.ops, ["remove:__wt_pop", "reflow", "add:__wt_pop"],
        "a SECOND ripple removes the class, forces a reflow, then re-adds it");
      t.eq(r.reflows, 1, "…reading offsetWidth exactly once to force that reflow");
      t.ok(r.classList.has("__wt_pop"), "…and ends with the animation running");

      // Idempotence: a re-install must not duplicate the cursor or throw.
      const before = doc.getElementById("__wt_cursor");
      fn(win, doc, () => 0);
      t.ok(doc.getElementById("__wt_cursor") === before, "re-installing does not duplicate the cursor");
    }
    break;
  }

  // ------------------------------------------------------------ glide / showClick
  case "glide": {
    {
      const j = journal();
      const p = makePage(j);
      const loc = p.locator("#b");
      const pt = await glideTo(p, loc);
      t.eq(pt, { x: 25, y: 40 }, "glideTo returns the element's centre, rounded");
      t.eq(j.of("evaluate").map((e) => [e.kind, e.args]), [["move", [25, 40]]],
        "glideTo drives the cursor to that point");
      t.eq(j.of("waitForTimeout").map((e) => e.ms), [600], "glideTo waits out the CSS transition");
    }
    {
      // ⚠️ No layout -> null, and NOTHING is evaluated. A glide to a non-existent point
      // would park the cursor at a stale position and the next click would look causeless.
      const j = journal();
      const p = makePage(j, { target: [{ visible: true, box: null }] });
      const pt = await glideTo(p, p.locator("#b"));
      t.eq(pt, null, "glideTo returns null for an element with no bounding box");
      t.eq(j.of("evaluate").length, 0, "…and moves nothing");
      t.eq(j.of("waitForTimeout").length, 0, "…and waits for nothing");
    }
    {
      // Fractional geometry must round, not leak a float into a px string.
      const j = journal();
      const p = makePage(j, { target: [{ visible: true, box: { x: 10.4, y: 20.6, width: 3.3, height: 5.1 } }] });
      const pt = await glideTo(p, p.locator("#b"));
      t.eq(pt, { x: 12, y: 23 }, "glideTo rounds a fractional centre to whole pixels");
    }
    {
      const j = journal();
      const p = makePage(j);
      await showClick(p, p.locator("#b"), { timeout: 1234 });
      t.eq(j.of("waitFor").map((e) => [e.state, e.timeout]), [["visible", 1234]],
        "showClick honours an explicit timeout on the visibility wait");
      t.eq(j.of("click").map((e) => e.timeout), [1234], "…and on the click");
    }
    break;
  }

  default:
    console.error(`case-session: unknown case: ${CASE}`);
    process.exit(2);
}

t.done();
