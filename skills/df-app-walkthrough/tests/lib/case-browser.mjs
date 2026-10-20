/**
 * The parts of df-app-walkthrough that only a REAL browser can settle.
 *
 * The other five suites drive `actions.mjs` and `session.mjs` through
 * `tests/lib/stub-page.mjs`, and `tests/README.md` declares what that leaves uncovered:
 * that a click lands on the pixel the cursor was DRAWN at, that an SPA re-render gets the
 * cursor back, that `recordVideo` starts when assumed, that the ripple re-triggers. Every
 * case here is one of those lines.
 *
 * ⛔ AND ONE CASE POINTS THE OTHER WAY: `stub-fidelity` asserts that a real Chromium fails
 * the way `stub-page.mjs` says Playwright fails. ~190 assertions in the node-only suites
 * rest on that premise, and nothing checked it. If Playwright ever stops rejecting
 * `waitFor` on a hidden element, those suites keep passing against a stub that models
 * nothing — the quietest way a green suite can go hollow.
 *
 * Offline by construction: fixtures are `file://` pages written to TMPDIR. No network, no
 * app, no TTS. Needs the chromium that `scripts/setup.sh` installs, and (for the video
 * case) Playwright's own bundled ffmpeg, which is a SEPARATE download from the browser.
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { checker } from "./stub-page.mjs";
import { runAction } from "../../scripts/lib/actions.mjs";
import { CURSOR_INIT_SCRIPT, glideTo, showClick } from "../../scripts/lib/session.mjs";

const SKILL = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const { chromium } = await import(`${SKILL}/node_modules/playwright-core/index.mjs`);

const t = checker();
const which = process.argv[2];
const KNOWN = [
  "cursor-install", "cursor-reinstall", "glide-centre", "click-lands-where-drawn",
  "ripple-retriggers", "visible-tabpanel", "nameflags", "card", "record-video",
  "stub-fidelity",
];
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "wt-browser-"));

/** Write a fixture page and return its file:// URL. */
function fixture(name, body, head = "") {
  const p = path.join(TMP, name);
  fs.writeFileSync(
    p,
    `<!doctype html><html><head><meta charset="utf-8">${head}</head><body style="margin:0">${body}</body></html>`
  );
  return "file://" + p;
}

/**
 * A page with the cursor init script already installed.
 *
 * ⚠️ `addInitScript` BEFORE `goto`, and a real navigation — not `setContent`. Init scripts
 * run on a new document; setting content on the current one does not reliably re-run them,
 * which would make every cursor assertion below measure nothing.
 */
async function openPage(browser, url, contextOpts = {}) {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 600 }, ...contextOpts });
  await ctx.addInitScript(CURSOR_INIT_SCRIPT);
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: "domcontentloaded" });
  return { ctx, page };
}

/** Records every real click's viewport coordinates and the element it landed on. */
const CLICK_RECORDER = `
  window.__hits = [];
  document.addEventListener('click', (e) => {
    window.__hits.push({
      x: e.clientX, y: e.clientY,
      text: (e.target.textContent || '').trim(),
      panel: e.target.getAttribute('data-panel') || null,
    });
  }, true);
`;

const cursorPos = (page) =>
  page.evaluate(() => {
    const c = document.getElementById("__wt_cursor");
    if (!c) return null;
    const cs = getComputedStyle(c);
    return { x: Math.round(parseFloat(cs.left)), y: Math.round(parseFloat(cs.top)) };
  });

const browser = await chromium.launch();

try {
  // ------------------------------------------------------------------ the drawn cursor
  if (which === "cursor-install") {
    await t.step("cursor installs into a real document", async () => {
      const { page } = await openPage(browser, fixture("c.html", "<p>hello</p>"));
      await page.waitForSelector("#__wt_cursor", { timeout: 5000 });
      const d = await page.evaluate(() => ({
        cursor: !!document.getElementById("__wt_cursor"),
        ripple: !!document.getElementById("__wt_ripple"),
        // the stylesheet must be in <head>: as a child of the body it is a layout sibling
        styleInHead: !!document.head.querySelector("style"),
        // a visible pointer that ate clicks would break every beat after the first
        events: getComputedStyle(document.getElementById("__wt_cursor")).pointerEvents,
        z: getComputedStyle(document.getElementById("__wt_cursor")).zIndex,
      }));
      t.ok(d.cursor, "#__wt_cursor exists in the real DOM");
      t.ok(d.ripple, "#__wt_ripple exists in the real DOM");
      t.ok(d.styleInHead, "the cursor stylesheet is in <head>");
      t.eq(d.events, "none", "the drawn cursor does not intercept clicks");
      t.ok(Number(d.z) > 2147482000, "the cursor sits above app chrome");
    });
  }

  if (which === "cursor-reinstall") {
    // The init script claims: "SPA route changes can replace large subtrees; re-install
    // cheaply rather than tracking them" — via setInterval(install, 1000). That claim is
    // untestable against a stub, and it is the difference between a cursor for the whole
    // video and a cursor until the first route change.
    await t.step("the cursor comes back after an SPA wipes the body", async () => {
      const { page } = await openPage(browser, fixture("r.html", "<div id=app>one</div>"));
      await page.waitForSelector("#__wt_cursor", { timeout: 5000 });
      await page.evaluate(() => { document.body.innerHTML = "<div id=app>two</div>"; });
      t.ok(
        await page.evaluate(() => !document.getElementById("__wt_cursor")),
        "a body replacement really does destroy the cursor (the premise)"
      );
      await page.waitForSelector("#__wt_cursor", { timeout: 4000 });
      t.ok(true, "the 1s re-install interval restores it unaided");
    });
  }

  // ------------------------------------------------- where the cursor is, where it clicks
  if (which === "glide-centre") {
    await t.step("glideTo lands on the element's measured centre", async () => {
      const { page } = await openPage(
        browser,
        fixture("g.html", "<button id=b style='position:absolute;left:300px;top:200px;width:120px;height:40px'>Go</button>")
      );
      await page.waitForSelector("#__wt_cursor", { timeout: 5000 });
      const loc = page.locator("#b");
      const pt = await glideTo(page, loc);
      const box = await loc.boundingBox();
      const want = { x: Math.round(box.x + box.width / 2), y: Math.round(box.y + box.height / 2) };
      t.eq(pt, want, "glideTo returns the real layout centre");
      const drawn = await cursorPos(page);
      t.ok(Math.abs(drawn.x - want.x) <= 1 && Math.abs(drawn.y - want.y) <= 1,
           "the DRAWN cursor is at that centre", `drawn ${JSON.stringify(drawn)} want ${JSON.stringify(want)}`);
    });
  }

  if (which === "click-lands-where-drawn") {
    // tests/README.md, the first declared gap: "that a click lands on the pixel the cursor
    // was drawn at". A stub can only record that click() was called.
    await t.step("the real click lands on the pixel the cursor was drawn at", async () => {
      const { page } = await openPage(
        browser,
        fixture("k.html", "<button id=b style='position:absolute;left:140px;top:420px;width:90px;height:36px'>Save</button>")
      );
      await page.waitForSelector("#__wt_cursor", { timeout: 5000 });
      await page.evaluate(CLICK_RECORDER);
      const pt = await showClick(page, page.locator("#b"));
      const hits = await page.evaluate(() => window.__hits);
      t.eq(hits.length, 1, "exactly one real click was dispatched");
      t.ok(Math.abs(hits[0].x - pt.x) <= 1 && Math.abs(hits[0].y - pt.y) <= 1,
           "the browser's own clientX/clientY match the drawn cursor",
           `click ${hits[0].x},${hits[0].y} vs drawn ${pt.x},${pt.y}`);
      t.eq(hits[0].text, "Save", "and it landed on the intended element");
    });
  }

  if (which === "ripple-retriggers") {
    // ⛔ THIS IS THE HOLE THE STUB COULD NOT EXPRESS. The mutation suite found that a
    // Set-backed classList stub cannot represent RE-triggering — the class is already
    // present, so deleting `remove(); void offsetWidth;` survived. A real browser fires
    // animationstart again only if the reflow happens.
    await t.step("the ripple re-triggers on a second click at the same point", async () => {
      const { page } = await openPage(
        browser,
        fixture("p.html", "<button id=b style='position:absolute;left:200px;top:120px'>Again</button>")
      );
      await page.waitForSelector("#__wt_ripple", { timeout: 5000 });
      await page.evaluate(() => {
        window.__starts = 0;
        document.getElementById("__wt_ripple")
          .addEventListener("animationstart", () => { window.__starts++; });
      });
      await showClick(page, page.locator("#b"));
      await showClick(page, page.locator("#b"));
      await page.waitForTimeout(250);
      t.eq(await page.evaluate(() => window.__starts), 2,
           "two clicks produce two animation starts (the reflow really restarts it)");
    });
  }

  // ------------------------------------------------------------------ resolution, for real
  if (which === "visible-tabpanel") {
    // actions.mjs opens by claiming locators resolve against the VISIBLE tab panel, because
    // "many UI frameworks render every tab's contents and hide the inactive ones, so a
    // page-level selector silently resolves against a hidden panel". Real visibility.
    // ⛔ THE DECOY IS LOAD-BEARING, AND ABLATION IS HOW I FOUND THAT OUT. The first version
    // of this fixture had only the two panels, and deleting the visible-panel preference from
    // `scopeFor` SURVIVED — because `resolve` ALSO picks the first VISIBLE match, which is the
    // visible panel's button either way. The assertion could not fail. A visible same-named
    // control OUTSIDE any panel and EARLIER in the DOM is what separates the two behaviours:
    // page-scoped resolution takes the decoy, panel-scoped resolution takes the panel.
    await t.step("a same-named control resolves inside the VISIBLE tabpanel", async () => {
      const { page } = await openPage(browser, fixture("tp.html", `
        <button data-panel="decoy-outside-any-panel">Open</button>
        <div role="tabpanel" style="display:none"><button data-panel="hidden">Open</button></div>
        <div role="tabpanel"><button data-panel="visible">Open</button></div>`));
      await page.waitForSelector("#__wt_cursor", { timeout: 5000 });
      await page.evaluate(CLICK_RECORDER);
      await runAction(page, { type: "click", role: "button", name: "Open", settle: 0 });
      const hits = await page.evaluate(() => window.__hits);
      t.eq(hits.map((h) => h.panel), ["visible"], "the click went to the visible panel");
    });
  }

  if (which === "nameflags") {
    // The #226 fix: `nameFlags: ""` is the obvious way to ask for a CASE-SENSITIVE match and
    // `a.nameFlags || "i"` turned it back into "i". Proven against the stub; this proves it
    // against a real accessible-name computation. The lower-case button is FIRST in the DOM,
    // so the two runs must choose DIFFERENT elements — either alone would be unconvincing.
    await t.step("nameFlags:'' is case-sensitive against a real accessible name", async () => {
      const page1 = await openPage(browser, fixture("nf.html",
        `<button data-panel="lower">save</button><button data-panel="upper">Save</button>`));
      await page1.page.waitForSelector("#__wt_cursor", { timeout: 5000 });
      await page1.page.evaluate(CLICK_RECORDER);
      await runAction(page1.page, { type: "click", role: "button", name: "Save", nameFlags: "", settle: 0 });
      t.eq((await page1.page.evaluate(() => window.__hits)).map((h) => h.panel), ["upper"],
           "nameFlags:'' matches only the capitalised control");

      const page2 = await openPage(browser, fixture("nf2.html",
        `<button data-panel="lower">save</button><button data-panel="upper">Save</button>`));
      await page2.page.waitForSelector("#__wt_cursor", { timeout: 5000 });
      await page2.page.evaluate(CLICK_RECORDER);
      await runAction(page2.page, { type: "click", role: "button", name: "Save", settle: 0 });
      t.eq((await page2.page.evaluate(() => window.__hits)).map((h) => h.panel), ["lower"],
           "the default stays case-INSENSITIVE and takes the first match");
    });
  }

  if (which === "card") {
    await t.step("the card renders bullets as TEXT and styles from <head>", async () => {
      const { page } = await openPage(browser, fixture("cd.html", "<main>app</main>"));
      await page.waitForSelector("#__wt_cursor", { timeout: 5000 });
      await runAction(page, {
        type: "card", title: "What we saw", bullets: ["<b>not bold</b>", "second"], reveal: 1,
      });
      const d = await page.evaluate(() => ({
        // bullets are DATA: textContent, never innerHTML
        literal: document.getElementById("__wt_b1").textContent,
        injected: !!document.querySelector("#__wt_card b"),
        styleInHead: !!document.getElementById("__wt_card_style")
          && document.getElementById("__wt_card_style").parentElement.tagName === "HEAD",
        // the card must be opaque, or the app shows through the closing slide
        opacity: getComputedStyle(document.getElementById("__wt_card")).opacity,
        revealed: document.getElementById("__wt_b1").classList.contains("on"),
        notYet: document.getElementById("__wt_b2").classList.contains("on"),
      }));
      t.eq(d.literal, "<b>not bold</b>", "a bullet containing markup renders as text");
      t.ok(!d.injected, "no element was created from bullet content");
      t.ok(d.styleInHead, "the card stylesheet is a child of <head>, not a flex item of the card");
      t.eq(d.opacity, "1", "the card is opaque over the live app");
      t.ok(d.revealed && !d.notYet, "reveal:1 shows the first bullet only");
    });
  }

  // ------------------------------------------------------------------ the recording itself
  if (which === "record-video") {
    // tests/README.md: "that recordVideo starts when assumed" is not tested. ⚠️ Playwright
    // does NOT use the system ffmpeg for this — it pipes screencast frames to its own
    // pinned build, a separate download from the browser (scripts/setup.sh installs both).
    // So this case can fail with a perfectly good system ffmpeg on PATH.
    await t.step("recordVideo produces a real, decodable webm", async () => {
      const dir = path.join(TMP, "vid");
      fs.mkdirSync(dir, { recursive: true });
      const { ctx, page } = await openPage(
        browser,
        fixture("v.html", "<button id=b style='position:absolute;left:120px;top:90px'>Go</button>"),
        { recordVideo: { dir, size: { width: 640, height: 400 } } }
      );
      await page.waitForSelector("#__wt_cursor", { timeout: 5000 });
      await runAction(page, { type: "click", selector: "#b", settle: 200 });
      await runAction(page, { type: "wait", ms: 400 });
      await ctx.close();                       // the file is only finalised on context close
      const files = fs.readdirSync(dir).filter((f) => f.endsWith(".webm"));
      t.eq(files.length, 1, "one video file was written");
      const file = path.join(dir, files[0]);
      t.ok(fs.statSync(file).size > 1000, "it is not a zero-length stub",
           `${fs.statSync(file).size} bytes`);
      const probe = execFileSync("ffprobe", [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=codec_type,width,height,nb_frames",
        "-of", "default=noprint_wrappers=1:nokey=1", file,
      ], { encoding: "utf8" }).trim().split("\n");
      t.eq(probe[0], "video", "ffprobe reports a video stream");
      t.ok(Number(probe[1]) > 0 && Number(probe[2]) > 0, "with real dimensions", probe.join("x"));
    });
  }

  // ------------------------------------------------------- the premise under the other suites
  if (which === "stub-fidelity") {
    // ⛔ ~190 assertions in the node-only suites assume Playwright fails in these two ways.
    // stub-page.mjs says so in its own header. Nothing checked it against a browser.
    await t.step("a real Chromium fails the way stub-page.mjs models", async () => {
      const { page } = await openPage(browser, fixture("sf.html", `
        <button id=hidden style="display:none">Nope</button>
        <button id=shown style="position:absolute;left:50px;top:50px">Yep</button>`));
      await page.waitForSelector("#__wt_cursor", { timeout: 5000 });

      await t.throws(
        () => page.locator("#hidden").waitFor({ state: "visible", timeout: 400 }),
        /Timeout|timeout/,
        "waitFor({visible}) REJECTS on a hidden element, as the stub models"
      );
      t.eq(await page.locator("#hidden").boundingBox(), null,
           "boundingBox resolves to null for display:none, as the stub models");
      t.eq(await page.locator("#hidden").isVisible(), false, "isVisible is false, not a throw");
      t.ok((await page.locator("#shown").boundingBox()).width > 0,
           "and a visible element still measures");

      // glideTo's contract on an unmeasurable element: return null, do not throw.
      t.eq(await glideTo(page, page.locator("#hidden")), null,
           "glideTo returns null for an element with no box");

      // ⛔ AND THE CASE ABOVE DOES NOT EXERCISE THE `.catch(() => null)` IN glideTo — found by
      // ablation: removing the catch SURVIVED, because boundingBox() on display:none RESOLVES
      // to null rather than rejecting. An AMBIGUOUS locator is what makes it reject (strict
      // mode, and it rejects immediately rather than waiting out a timeout), and an ambiguous
      // descriptor is a realistic authoring mistake, not a contrivance.
      await t.step("glideTo swallows a REJECTING boundingBox (ambiguous locator)", async () => {
        t.eq(await glideTo(page, page.locator("button")), null,
             "an ambiguous locator yields null, not a thrown beat");
      });
    });
  }
} finally {
  await browser.close();
  fs.rmSync(TMP, { recursive: true, force: true });
}

// ⛔ A case name that matches nothing must FAIL, not report a clean zero. Every `if` above
// is gated on `which`, so a typo in the runner would run no assertions at all — and
// `run-tests.sh` reads the ASSERTIONS count, where 0 and "asserted nothing" are the same
// green. The runner also asserts n > 0, and this makes the case itself say so.
t.ok(KNOWN.includes(which), `case name "${which}" is one this file implements`);
t.done();
