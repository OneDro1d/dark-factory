/**
 * A recording stand-in for a Playwright Page and Locator.
 *
 * ⛔ WHY A STUB AND NOT A REAL BROWSER. `runAction` and the session helpers are the only
 * parts of this skill that decide anything — which element to touch, in what order, and
 * when to refuse. A real browser would test Chromium's ability to click, which nobody
 * doubts, at the cost of a suite too slow and too network-dependent to run in the gate.
 * Everything a real browser WOULD add is named in `tests/README.md` under what this does
 * not cover, so the gap is declared rather than implied.
 *
 * ⚠️ THE STUB MUST FAIL THE WAY PLAYWRIGHT FAILS, or the tests measure the stub. Two
 * behaviours are load-bearing and were chosen deliberately:
 *   · `waitFor({state:"visible"})` REJECTS on a non-visible target. `resolve()` swallows
 *     that rejection for the `.first()` probe and relies on it for the `nth` path; a stub
 *     that resolved everything would make the `nth` arm untestable.
 *   · `boundingBox()` RESOLVES to null for an off-screen element rather than throwing.
 *     `glideTo` has a `.catch(() => null)`, so a throwing stub would pass for the wrong
 *     reason and hide a regression in that catch.
 *
 * Every call lands in one flat, ordered journal. Order is the assertion that matters most
 * here — "clicked after the ripple was drawn" is the property that makes the click visible
 * in the video, and a set of calls with no order cannot express it.
 */

/** One journal shared by a page and every locator it hands out. */
export function journal() {
  const entries = [];
  return {
    entries,
    push(e) { entries.push(e); return e; },
    /** Calls of one kind, in order. */
    of(call) { return entries.filter((e) => e.call === call); },
    /** Index of the first entry matching a predicate, or -1. */
    indexOf(pred) { return entries.findIndex(pred); },
    names() { return entries.map((e) => e.call + (e.kind ? ":" + e.kind : "")); },
  };
}

/**
 * Derive what an `evaluate` call was FOR from the function's source.
 *
 * The alternative — telling them apart by their arguments — does not work: `glideTo` and
 * the ripple both pass `[x, y]`, so an argument-shape check would conflate the two and an
 * assertion about click order would silently pass on the wrong pair.
 */
function evalKind(fn) {
  const src = String(fn);
  if (src.includes("__wtMove")) return "move";
  if (src.includes("__wtRipple")) return "ripple";
  if (src.includes("__wt_card_style")) return "card";
  if (src.includes("__wt_card")) return "dropCard";
  return "unknown";
}

/**
 * A locator over a fixed list of matches.
 *
 * `matches` is an array of `{ visible, box }`. `box` may be null, which is how a real
 * locator reports an element that is attached but has no layout.
 */
export function makeLocator(j, label, matches, idx = null) {
  const at = (i) => matches[i] || { visible: false, box: null };
  const me = () => (idx === null ? at(0) : at(idx));
  const tag = idx === null ? label : `${label}[${idx}]`;

  const loc = {
    __label: tag,
    async all() {
      return matches.map((_, i) => makeLocator(j, label, matches, i));
    },
    async isVisible() {
      j.push({ call: "isVisible", label: tag });
      return !!me().visible;
    },
    async count() {
      j.push({ call: "count", label });
      return matches.length;
    },
    nth(i) {
      j.push({ call: "nth", label, idx: i });
      return makeLocator(j, label, matches, i);
    },
    first() {
      return makeLocator(j, label, matches, 0);
    },
    async waitFor(opts = {}) {
      j.push({ call: "waitFor", label: tag, state: opts.state, timeout: opts.timeout });
      if (opts.state === "visible" && !me().visible) {
        throw new Error(`stub: ${tag} not visible within ${opts.timeout}ms`);
      }
      return undefined;
    },
    async boundingBox() {
      j.push({ call: "boundingBox", label: tag });
      return me().box;
    },
    async click(opts = {}) {
      j.push({ call: "click", label: tag, timeout: opts.timeout });
    },
    async fill(text) {
      j.push({ call: "fill", label: tag, text });
    },
  };
  return loc;
}

/**
 * A search scope — the page itself, or a tab panel inside it.
 *
 * Both answer the same three lookup methods, and each records WHICH scope served the
 * lookup. That recording is the whole point of the scoping test: a page-level selector
 * resolving against a hidden panel returns plausible, wrong data, and the only way to
 * prove the fix works is to see which scope the lookup went through.
 */
function makeScope(j, j_label, target) {
  return {
    locator(selector) {
      j.push({ call: "lookup", scope: j_label, by: "selector", selector });
      return makeLocator(j, "target", target);
    },
    getByRole(role, opts = {}) {
      j.push({ call: "lookup", scope: j_label, by: "role", role, name: String(opts.name || ""), exact: opts.exact });
      return makeLocator(j, "target", target);
    },
    getByText(re) {
      j.push({ call: "lookup", scope: j_label, by: "text", text: String(re) });
      return makeLocator(j, "target", target);
    },
  };
}

/**
 * Build a stub page.
 *
 * @param j        the journal
 * @param opts.target    matches the action's descriptor resolves to
 * @param opts.panels    tab panels on the page, as `[{visible: bool}]`
 * @param opts.options   matches for the `select` action's option list
 * @param opts.filterBox matches for the `select` action's filter input
 * @param opts.url       what `page.url()` returns
 * @param opts.leaveSignIn  if false, `waitForURL` rejects — an unconsumed Clerk ticket
 */
export function makePage(j, opts = {}) {
  const target = opts.target || [{ visible: true, box: { x: 10, y: 20, width: 30, height: 40 } }];
  const panels = opts.panels || [];
  const pageScope = makeScope(j, "page", target);

  const page = {
    async evaluate(fn, args) {
      j.push({ call: "evaluate", kind: evalKind(fn), args });
      return undefined;
    },
    async waitForTimeout(ms) {
      j.push({ call: "waitForTimeout", ms });
    },
    async goto(url, o = {}) {
      j.push({ call: "goto", url, waitUntil: o.waitUntil, timeout: o.timeout });
    },
    async waitForSelector(sel, o = {}) {
      j.push({ call: "waitForSelector", selector: sel, timeout: o.timeout });
    },
    async waitForURL(pred, o = {}) {
      j.push({ call: "waitForURL", timeout: o.timeout });
      if (opts.leaveSignIn === false) throw new Error("stub: still on the sign-in route");
      return undefined;
    },
    url() {
      return opts.url || "https://stub.invalid/";
    },
    mouse: {
      async wheel(dx, dy) {
        j.push({ call: "wheel", dx, dy });
      },
    },

    // `scopeFor` asks the PAGE for tab panels; every other role lookup is a normal lookup.
    getByRole(role, o = {}) {
      if (role === "tabpanel") {
        j.push({ call: "tabpanels" });
        return makeLocator(j, "panel", panels);
      }
      return pageScope.getByRole(role, o);
    },
    getByText(re) {
      return pageScope.getByText(re);
    },
    // The `select` action reaches for its filter box and option list on the PAGE, not the
    // scope, so those two get their own match lists.
    locator(selector) {
      const optSel = opts.optionSelector || "li[role=option], [role=option], option";
      if (selector === optSel || selector === opts.optionSelectorOverride) {
        j.push({ call: "lookup", scope: "page", by: "options", selector });
        return makeLocator(j, "option", opts.options || [{ visible: true, box: null }]);
      }
      if (selector.includes("searchbox") || selector === opts.filterSelector) {
        j.push({ call: "lookup", scope: "page", by: "filterbox", selector });
        return makeLocator(j, "filterbox", opts.filterBox || []);
      }
      return pageScope.locator(selector);
    },
  };

  // A visible panel must behave as a scope, because `scopeFor` returns it and `resolve`
  // then calls `.locator` / `.getByRole` / `.getByText` ON IT.
  const panelScope = makeScope(j, "panel", target);
  const origAll = makeLocator(j, "panel", panels).all;
  page.__panelLocator = {
    async all() {
      return panels.map((p, i) => ({
        async isVisible() {
          j.push({ call: "isVisible", label: `panel[${i}]` });
          return !!p.visible;
        },
        ...panelScope,
      }));
    },
  };
  // Swap in the scope-capable panel list.
  const realGetByRole = page.getByRole;
  page.getByRole = (role, o = {}) => {
    if (role === "tabpanel") {
      j.push({ call: "tabpanels" });
      return page.__panelLocator;
    }
    return realGetByRole(role, o);
  };
  void origAll;

  return page;
}

/** Tiny assertion helpers. Each prints one line; the bash suite tallies them. */
export function checker() {
  let pass = 0;
  let fail = 0;
  const t = {
    ok(cond, label, detail = "") {
      if (cond) {
        pass++;
        console.log(`  ok   ${label}`);
      } else {
        fail++;
        console.log(`  FAIL ${label}${detail ? "  — " + detail : ""}`);
      }
    },
    eq(got, want, label) {
      t.ok(
        JSON.stringify(got) === JSON.stringify(want),
        label,
        `got ${JSON.stringify(got)} want ${JSON.stringify(want)}`
      );
    },
    /**
     * Run a block whose body is expected to SUCCEED, attributing any throw to `label`.
     *
     * ⛔ WITHOUT THIS, ONE UNEXPECTED THROW SILENTLY DELETES EVERY LATER ASSERTION in the
     * file — the module rejects, the process exits non-zero, and the tally never prints.
     * That is a failure, so it is loud; but it is loud about the WRONG thing, and the
     * assertions after it report nothing at all. Measured: a mutant that collapsed
     * visible-first resolution made `showClick` throw, and the assertion written to catch
     * precisely that mutant never ran. The mutation suite reported WRONG-FAIL and that is
     * how this was found.
     */
    async step(label, fn) {
      try {
        await fn();
      } catch (e) {
        t.ok(false, label, `threw: ${String(e && e.message ? e.message : e)}`);
      }
    },
    /** Assert an async call rejects with a message matching `re`. */
    async throws(fn, re, label) {
      try {
        await fn();
        t.ok(false, label, "did not throw");
      } catch (e) {
        const msg = String(e && e.message ? e.message : e);
        t.ok(re.test(msg), label, `message was: ${msg}`);
      }
    },
    done() {
      console.log(`\nasserted ${pass + fail}  passed ${pass}  failed ${fail}`);
      console.log(`ASSERTIONS: ${pass + fail}`);
      process.exit(fail ? 1 : 0);
    },
  };
  return t;
}
