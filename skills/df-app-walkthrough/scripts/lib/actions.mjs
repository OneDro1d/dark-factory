/**
 * The action vocabulary. One `action` object per beat, resolved here.
 *
 * Locators resolve against the VISIBLE tab panel when the page has one. Many UI frameworks
 * render every tab's contents and hide the inactive ones, so a page-level selector silently
 * resolves against a hidden panel and returns plausible, wrong data.
 */
import { glideTo, showClick } from "./session.mjs";

const DEFAULT_SETTLE = 1500;

/** Prefer the visible tabpanel as the search root; fall back to the page. */
async function scopeFor(page) {
  const panels = await page.getByRole("tabpanel").all().catch(() => []);
  for (const p of panels) if (await p.isVisible().catch(() => false)) return p;
  return page;
}

const RESOLVE_TIMEOUT = Number(process.env.WT_RESOLVE_TIMEOUT_MS || 6000);

/**
 * Resolve a {role,name,selector,nth} descriptor to a locator, scoped and visible-first.
 *
 * Throws promptly when nothing matches. That is deliberate: Playwright's default action
 * timeout is 30s, so a typo'd selector silently burns half a minute of dead video AND is
 * invisible unless the miss is surfaced. Here the beat fails fast, the recorder logs it as
 * a problem, and verify.mjs reports it instead of you discovering it on playback.
 */
async function resolve(page, a) {
  const scope = a.global ? page : await scopeFor(page);
  let loc;
  if (a.selector) {
    loc = scope.locator(a.selector);
  } else if (a.role) {
    const opts = {};
    if (a.name) opts.name = new RegExp(a.name, a.nameFlags || "i");
    if (a.exact) opts.exact = true;
    loc = scope.getByRole(a.role, opts);
  } else if (a.text) {
    loc = scope.getByText(new RegExp(a.text, "i"));
  } else {
    throw new Error(`action needs one of selector | role | text: ${JSON.stringify(a)}`);
  }
  const timeout = a.timeout || RESOLVE_TIMEOUT;
  const chosen = typeof a.nth === "number" ? loc.nth(a.nth) : null;
  if (chosen) {
    await chosen.waitFor({ state: "visible", timeout });
    return chosen;
  }

  // otherwise take the first VISIBLE match rather than the first match
  await loc.first().waitFor({ state: "visible", timeout }).catch(() => {});
  const n = await loc.count();
  for (let i = 0; i < n; i++) {
    const c = loc.nth(i);
    if (await c.isVisible().catch(() => false)) return c;
  }
  throw new Error(
    `no visible match for ${JSON.stringify({ role: a.role, name: a.name, text: a.text, selector: a.selector })} within ${timeout}ms`
  );
}

/**
 * A full-screen card drawn INSIDE the live page.
 *
 * Deliberately not page.setContent(): that replaces the document and drops the SPA's
 * in-memory session, which is fine for a closing card and fatal mid-video when later beats
 * still need the app.
 */
async function showCard(page, a) {
  await page.evaluate(
    ([title, bullets, reveal]) => {
      let el = document.getElementById("__wt_card");
      if (!el) {
        // The stylesheet goes in <head>. Appending it inside the card makes it a flex ITEM
        // of the card's own column layout, which throws the centring out.
        if (!document.getElementById("__wt_card_style")) {
          const style = document.createElement("style");
          style.id = "__wt_card_style";
          style.textContent = `
            #__wt_card{position:fixed;top:0;left:0;right:0;bottom:0;width:100vw;height:100vh;
              z-index:2147483000;background:#f6f8fa;color:#0f172a;opacity:1;
              padding:5rem 7rem;box-sizing:border-box;display:flex;flex-direction:column;
              justify-content:center;font-family:system-ui,-apple-system,"Segoe UI",sans-serif;}
            #__wt_card h2{font-size:2.9rem;margin:0 0 2.4rem;letter-spacing:-.02em;}
            #__wt_card ul{margin:0;padding:0;}
            #__wt_card li{font-size:1.45rem;line-height:1.45;margin:0 0 1.25rem;list-style:none;
              padding-left:1.8rem;position:relative;opacity:0;transform:translateY(8px);
              transition:opacity .45s ease,transform .45s ease;}
            #__wt_card li.on{opacity:1;transform:none;}
            #__wt_card li:before{content:"";position:absolute;left:0;top:.62em;width:.62rem;
              height:.62rem;border-radius:50%;background:#0f9d6e;}
          `;
          (document.head || document.documentElement).appendChild(style);
        }
        el = document.createElement("div");
        el.id = "__wt_card";
        // belt and braces: a host page's own rules must not make this translucent
        el.style.cssText = "background:#f6f8fa;opacity:1;";
        const h = document.createElement("h2");
        h.textContent = title || "";
        el.appendChild(h);
        const ul = document.createElement("ul");
        bullets.forEach((b, i) => {
          const li = document.createElement("li");
          li.id = "__wt_b" + (i + 1);
          li.textContent = b;          // textContent, not innerHTML — bullets are data
          ul.appendChild(li);
        });
        el.appendChild(ul);
        document.body.appendChild(el);
      }
      const li = document.getElementById("__wt_b" + reveal);
      if (li) li.classList.add("on");
    },
    [a.title || "", a.bullets || [], a.reveal || 1]
  );
}

const dropCard = (page) =>
  page.evaluate(() => document.getElementById("__wt_card")?.remove()).catch(() => {});

/** Run one beat's action. Unknown/absent types hold the current view. */
export async function runAction(page, action) {
  const a = action || { type: "none" };
  const settle = typeof a.settle === "number" ? a.settle : DEFAULT_SETTLE;

  switch (a.type) {
    case undefined:
    case "none":
      return;

    case "wait":
      await page.waitForTimeout(a.ms || 1000);
      return;

    case "card":
      await showCard(page, a);
      await page.waitForTimeout(250);
      return;

    case "goto":
      await dropCard(page);
      await page.goto(a.url, { waitUntil: "domcontentloaded", timeout: 45000 });
      await page.waitForTimeout(settle);
      return;

    case "scroll":
      await dropCard(page);
      await page.mouse.wheel(0, a.dy || 400);
      await page.waitForTimeout(Math.min(settle, 1000));
      return;

    case "point": {
      await dropCard(page);
      const loc = await resolve(page, a);
      await glideTo(page, loc);
      return;
    }

    case "click": {
      await dropCard(page);
      const loc = await resolve(page, a);
      await showClick(page, loc);
      await page.waitForTimeout(settle);
      return;
    }

    case "fill": {
      await dropCard(page);
      const loc = await resolve(page, a);
      await glideTo(page, loc);
      await loc.fill(a.text ?? "");
      await page.waitForTimeout(Math.min(settle, 1000));
      return;
    }

    case "select": {
      await dropCard(page);
      const loc = await resolve(page, a);
      await showClick(page, loc);
      await page.waitForTimeout(800);
      if (a.filter) {
        const box = page.locator(
          a.filterSelector || "input[role=searchbox], .p-select-filter, .p-dropdown-filter, input[type=search]"
        );
        if (await box.count()) {
          await box.first().fill(a.filter);
          await page.waitForTimeout(900);
        }
      }
      const optSel = a.optionSelector || "li[role=option], [role=option], option";
      const opt = page.locator(optSel).nth(a.option || 0);
      await showClick(page, opt);
      await page.waitForTimeout(settle);
      return;
    }

    default:
      throw new Error(`unknown action type: ${a.type}`);
  }
}
