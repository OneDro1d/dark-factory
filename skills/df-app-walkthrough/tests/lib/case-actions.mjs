/**
 * The action vocabulary — `scripts/lib/actions.mjs`, driven against a stub page.
 *
 * What is actually under test here is the part that DECIDES: which element a descriptor
 * resolves to, which scope it resolves in, what order the cursor/ripple/click happen in,
 * and when the beat refuses instead of guessing. None of that needs Chromium.
 */
import { runAction } from "../../scripts/lib/actions.mjs";
import { journal, makePage, checker } from "./stub-page.mjs";

const t = checker();
const VIS = (box = { x: 10, y: 20, width: 30, height: 40 }) => ({ visible: true, box });
const HID = { visible: false, box: null };

// ---------------------------------------------------------------- no-ops
{
  const j = journal();
  await runAction(makePage(j), { type: "none" });
  t.eq(j.names(), [], "type:none touches the page not at all");
}
{
  const j = journal();
  await runAction(makePage(j), undefined);
  t.eq(j.names(), [], "a missing action holds the view (no page calls)");
}
{
  const j = journal();
  await runAction(makePage(j), {});
  t.eq(j.names(), [], "an action with no type holds the view");
}

// ---------------------------------------------------------------- refusals
// ⛔ These two are why the suite exists. A typo'd selector that waits 30s burns dead video
// and is invisible on playback; a mistyped action TYPE that silently did nothing would be
// worse, because the recording would look deliberate.
{
  const j = journal();
  await t.throws(
    () => runAction(makePage(j), { type: "clcik", selector: "#b" }),
    /unknown action type: clcik/,
    "an unknown action type REFUSES rather than holding the frame"
  );
}
{
  const j = journal();
  await t.throws(
    () => runAction(makePage(j), { type: "click" }),
    /needs one of selector \| role \| text/,
    "a descriptor with no selector, role or text REFUSES"
  );
}
{
  const j = journal();
  await t.throws(
    () => runAction(makePage(j, { target: [HID, HID] }), { type: "click", selector: "#b" }),
    /no visible match for/,
    "all matches hidden REFUSES rather than clicking a hidden element"
  );
}
{
  // The refusal must name what it was looking for. A message that says only "not found"
  // sends the reader back to the narration file to guess which beat failed.
  const j = journal();
  try {
    await runAction(makePage(j, { target: [HID] }), { type: "click", role: "button", name: "Save" });
    t.ok(false, "hidden-match refusal names the descriptor");
  } catch (e) {
    t.ok(
      /"role":"button"/.test(e.message) && /Save/.test(e.message),
      "hidden-match refusal names the descriptor",
      e.message
    );
  }
}

// ---------------------------------------------------------------- wait / scroll
{
  const j = journal();
  await runAction(makePage(j), { type: "wait", ms: 1234 });
  t.eq(j.of("waitForTimeout").map((e) => e.ms), [1234], "wait honours ms");
}
{
  const j = journal();
  await runAction(makePage(j), { type: "wait" });
  t.eq(j.of("waitForTimeout").map((e) => e.ms), [1000], "wait defaults to 1000ms");
}
{
  const j = journal();
  await runAction(makePage(j), { type: "scroll", dy: 900 });
  t.eq(j.of("wheel").map((e) => [e.dx, e.dy]), [[0, 900]], "scroll honours dy");
}
{
  const j = journal();
  await runAction(makePage(j), { type: "scroll" });
  t.eq(j.of("wheel").map((e) => [e.dx, e.dy]), [[0, 400]], "scroll defaults to dy 400");
}

// ---------------------------------------------------------------- the card
{
  const j = journal();
  await runAction(makePage(j), { type: "card", title: "Hello", bullets: ["a", "b"], reveal: 2 });
  const ev = j.of("evaluate");
  t.eq(ev.map((e) => e.kind), ["card"], "card draws the card");
  t.eq(ev[0].args, ["Hello", ["a", "b"], 2], "card passes title, bullets and the reveal index");
}
{
  const j = journal();
  await runAction(makePage(j), { type: "card" });
  t.eq(j.of("evaluate")[0].args, ["", [], 1], "card with nothing set reveals bullet 1 of none");
}

// ⛔ EVERY NAVIGATING ACTION MUST DROP THE CARD FIRST. A full-screen card left up would
// cover the very step the beat exists to show, and the recording would be of the card.
for (const [label, action] of [
  ["goto", { type: "goto", url: "https://x.invalid/" }],
  ["scroll", { type: "scroll" }],
  ["point", { type: "point", selector: "#b" }],
  ["click", { type: "click", selector: "#b" }],
  ["fill", { type: "fill", selector: "#b", text: "x" }],
]) {
  const j = journal();
  await runAction(makePage(j), action);
  const first = j.of("evaluate")[0];
  t.ok(first && first.kind === "dropCard", `${label} drops the card before anything else`,
    `first evaluate was ${first ? first.kind : "none"}`);
}

// ---------------------------------------------------------------- goto
{
  const j = journal();
  await runAction(makePage(j), { type: "goto", url: "https://x.invalid/a" });
  const g = j.of("goto")[0];
  t.eq([g.url, g.waitUntil], ["https://x.invalid/a", "domcontentloaded"], "goto navigates and waits for DOM");
  t.eq(j.of("waitForTimeout").map((e) => e.ms), [1500], "goto settles for the 1500ms default");
}
{
  const j = journal();
  await runAction(makePage(j), { type: "goto", url: "https://x.invalid/", settle: 42 });
  t.eq(j.of("waitForTimeout").map((e) => e.ms), [42], "settle:0-or-more overrides the default");
}
{
  // `typeof a.settle === "number"` — so settle:0 must mean zero, not "falsy, use 1500".
  const j = journal();
  await runAction(makePage(j), { type: "goto", url: "https://x.invalid/", settle: 0 });
  t.eq(j.of("waitForTimeout").map((e) => e.ms), [0], "settle:0 means zero, not the default");
}

// ---------------------------------------------------------------- click order
// ⛔ THE ORDER IS THE FEATURE. The drawn cursor has to arrive, and the ripple has to be
// drawn, BEFORE the click lands — otherwise the video shows an effect with no visible
// cause, which is exactly the "reads as a slideshow" failure the cursor exists to fix.
{
  const j = journal();
  await runAction(makePage(j), { type: "click", selector: "#save" });
  const names = j.names();
  const iMove = names.indexOf("evaluate:move");
  const iRipple = names.indexOf("evaluate:ripple");
  const iClick = names.indexOf("click");
  t.ok(iMove > -1 && iRipple > iMove && iClick > iRipple,
    "click: cursor glides, THEN ripples, THEN clicks",
    `order was ${names.join(" > ")}`);
  t.eq(j.of("waitForTimeout").map((e) => e.ms), [600, 220, 1500],
    "click holds 600ms for the glide, 220ms for the ripple, then settles");
}
{
  // ⚠️ A CLICK WAITS FOR VISIBILITY TWICE, ON TWO DIFFERENT CLOCKS, and the distinction is
  // the point. `resolve()` waits with the 6s RESOLVE_TIMEOUT — short on purpose, because a
  // typo'd selector on Playwright's 30s default burns half a minute of dead video. Then
  // `showClick` waits again with its own 20s ceiling, which is the one that tolerates a
  // slow app. My first version of this assertion read waitFor[0] and expected 20000; it
  // was measuring the resolve wait and would have "passed" had the two been swapped.
  const j = journal();
  await runAction(makePage(j), { type: "click", selector: "#save" });
  const waits = j.of("waitFor").map((e) => [e.state, e.timeout]);
  t.eq(waits, [["visible", 6000], ["visible", 20000]],
    "click waits for visible twice: 6s to resolve, then 20s to act");
}
{
  // The resolve ceiling is tunable, and must not be confused with the act ceiling.
  const j = journal();
  await runAction(makePage(j), { type: "click", selector: "#save", timeout: 250 });
  t.eq(j.of("waitFor").map((e) => e.timeout), [250, 20000],
    "a per-beat timeout moves the RESOLVE wait only, not showClick's act ceiling");
}
{
  // An element with no layout must still be clicked — glideTo returns null and showClick
  // has to carry on. A regression here would make every off-layout control unclickable.
  const j = journal();
  await runAction(makePage(j), { type: "click", selector: "#b" });
  t.ok(true, "sanity: visible-with-box clicks"); // paired control for the next case
  const j2 = journal();
  await runAction(makePage(j2, { target: [{ visible: true, box: null }] }), { type: "click", selector: "#b" });
  t.eq(j2.of("click").length, 1, "an element with no bounding box is still clicked");
  t.eq(j2.of("evaluate").filter((e) => e.kind === "ripple").length, 0,
    "…and no ripple is drawn at a point that does not exist");
}

// ---------------------------------------------------------------- point
{
  const j = journal();
  await runAction(makePage(j), { type: "point", selector: "#b" });
  t.eq(j.of("click").length, 0, "point glides WITHOUT clicking");
  t.eq(j.of("evaluate").filter((e) => e.kind === "move").length, 1, "point moves the cursor");
}

// ---------------------------------------------------------------- fill
{
  const j = journal();
  await runAction(makePage(j), { type: "fill", selector: "#i", text: "abc" });
  t.eq(j.of("fill").map((e) => e.text), ["abc"], "fill types the text");
}
{
  // `a.text ?? ""` — a fill with no text clears the field rather than typing "undefined".
  const j = journal();
  await runAction(makePage(j), { type: "fill", selector: "#i" });
  t.eq(j.of("fill").map((e) => e.text), [""], "fill with no text clears the field");
}
{
  const j = journal();
  await runAction(makePage(j), { type: "fill", selector: "#i", text: "x", settle: 9000 });
  const last = j.of("waitForTimeout").slice(-1)[0];
  t.eq(last.ms, 1000, "fill caps its settle at 1000ms however large settle is");
}

// ---------------------------------------------------------------- resolution
// ⛔ VISIBLE-FIRST, NOT FIRST. Many UI frameworks render every tab's contents and hide the
// inactive ones. "First match" then resolves to a hidden twin and the action reports
// success against something no viewer can see.
// ⚠️ These run through `t.step`, which attributes an unexpected throw to the assertion's
// own label. A mutant that collapses visible-first resolution makes showClick throw on the
// hidden element, and without the guard that rejection would abort the file and delete
// every assertion after it — including the one written to catch that exact mutant.
await t.step("resolution skips a hidden match and takes the first VISIBLE one", async () => {
  const j = journal();
  await runAction(makePage(j, { target: [HID, VIS()] }), { type: "click", selector: ".row" });
  t.eq(j.of("click").map((e) => e.label), ["target[1]"],
    "resolution skips a hidden match and takes the first VISIBLE one");
});
await t.step("…and takes match 0 when match 0 is visible", async () => {
  const j = journal();
  await runAction(makePage(j, { target: [VIS(), VIS()] }), { type: "click", selector: ".row" });
  t.eq(j.of("click").map((e) => e.label), ["target[0]"],
    "…and takes match 0 when match 0 is visible");
});
await t.step("an explicit nth is honoured over visible-first", async () => {
  // An explicit nth is an instruction, not a hint: it must be honoured even when an
  // earlier match is visible, and it must wait for THAT element.
  const j = journal();
  await runAction(makePage(j, { target: [VIS(), VIS()] }), { type: "click", selector: ".row", nth: 1 });
  t.eq(j.of("click").map((e) => e.label), ["target[1]"], "an explicit nth is honoured over visible-first");
});
{
  const j = journal();
  await t.throws(
    () => runAction(makePage(j, { target: [VIS(), HID] }), { type: "click", selector: ".row", nth: 1 }),
    /not visible/,
    "nth pointing at a hidden element REFUSES instead of falling back to a visible one"
  );
}
{
  // nth:0 must be an explicit selection, not "falsy, so scan". The code guards with
  // `typeof a.nth === "number"`, and this is the case that proves the guard.
  const j = journal();
  await t.throws(
    () => runAction(makePage(j, { target: [HID, VIS()] }), { type: "click", selector: ".row", nth: 0 }),
    /not visible/,
    "nth:0 is an explicit selection, not a falsy fall-through to the scan"
  );
}
{
  const j = journal();
  await runAction(makePage(j), { type: "click", role: "button", name: "Save" });
  const l = j.of("lookup")[0];
  t.eq([l.by, l.role], ["role", "button"], "a role descriptor resolves by role");
  t.ok(/Save/.test(l.name) && /i/.test(String(l.name).split("/").pop()),
    "a role NAME becomes a case-insensitive regex", `name was ${l.name}`);
}
{
  const j = journal();
  await runAction(makePage(j), { type: "click", role: "button", name: "Save", nameFlags: "gi" });
  t.eq(String(j.of("lookup")[0].name), "/Save/gi", "a non-empty nameFlags is honoured");
}
{
  // ⛔ THE EMPTY STRING MUST MEAN CASE-SENSITIVE, NOT "absent". `a.nameFlags || "i"` treated
  // it as absent and handed back "i", so the one value a caller would actually reach for to
  // get a case-sensitive match was the only one that could not work — the same
  // falsy-vs-absent conflation `settle` guards against with `typeof` a few lines away.
  // Fixed alongside this suite; the mutation suite puts the `||` back.
  const j = journal();
  await runAction(makePage(j), { type: "click", role: "button", name: "Save", nameFlags: "" });
  t.eq(String(j.of("lookup")[0].name), "/Save/",
    'nameFlags:"" means case-SENSITIVE, not "fall back to insensitive"');
}
{
  // And absent still means insensitive, which is the default every narration file relies on.
  const j = journal();
  await runAction(makePage(j), { type: "click", role: "button", name: "Save" });
  t.eq(String(j.of("lookup")[0].name), "/Save/i", "an absent nameFlags still defaults to insensitive");
}
{
  const j = journal();
  await runAction(makePage(j), { type: "click", text: "Continue" });
  t.eq(j.of("lookup")[0].by, "text", "a text descriptor resolves by text");
}
{
  const j = journal();
  await runAction(makePage(j), { type: "click", selector: "#a", role: "button" });
  t.eq(j.of("lookup")[0].by, "selector", "selector wins over role when both are given");
}
{
  const j = journal();
  await runAction(makePage(j), { type: "click", selector: "#b", timeout: 777 });
  t.eq(j.of("waitFor").filter((e) => e.timeout === 777).length > 0, true,
    "a per-beat timeout reaches the resolve wait");
}

// ---------------------------------------------------------------- scoping
// ⛔ THE REASON actions.mjs EXISTS. With a visible tab panel on the page, a lookup must go
// through the PANEL. Resolving page-wide returns plausible, wrong data from a hidden panel.
{
  const j = journal();
  await runAction(makePage(j, { panels: [{ visible: false }, { visible: true }] }),
    { type: "click", selector: ".cell" });
  t.eq(j.of("lookup").map((e) => e.scope), ["panel"],
    "with a visible tab panel, lookups resolve INSIDE the panel");
}
{
  const j = journal();
  await runAction(makePage(j, { panels: [{ visible: false }] }), { type: "click", selector: ".cell" });
  t.eq(j.of("lookup").map((e) => e.scope), ["page"],
    "with no VISIBLE panel, lookups fall back to the page");
}
{
  const j = journal();
  await runAction(makePage(j, { panels: [] }), { type: "click", selector: ".cell" });
  t.eq(j.of("lookup").map((e) => e.scope), ["page"], "with no panels at all, lookups use the page");
}
{
  // `global: true` is the escape hatch for chrome outside the panel — a nav bar, a toast.
  const j = journal();
  await runAction(makePage(j, { panels: [{ visible: true }] }),
    { type: "click", selector: ".nav", global: true });
  t.eq(j.of("lookup").map((e) => e.scope), ["page"], "global:true bypasses the panel scope");
  t.eq(j.of("tabpanels").length, 0, "global:true does not even look for panels");
}

// ---------------------------------------------------------------- select
{
  const j = journal();
  await runAction(makePage(j, { options: [{ visible: true, box: null }, { visible: true, box: null }] }),
    { type: "select", selector: "#dd", option: 1 });
  const clicks = j.of("click").map((e) => e.label);
  t.eq(clicks, ["target[0]", "option[1]"], "select opens the control, then clicks the chosen option");
}
{
  const j = journal();
  await runAction(makePage(j, { options: [{ visible: true, box: null }], filterBox: [{ visible: true, box: null }] }),
    { type: "select", selector: "#dd", filter: "chair" });
  t.eq(j.of("fill").map((e) => e.text), ["chair"], "select types into the filter box when one is present");
}
{
  // No filter box on the page: the beat must still pick an option rather than throwing.
  const j = journal();
  await runAction(makePage(j, { options: [{ visible: true, box: null }], filterBox: [] }),
    { type: "select", selector: "#dd", filter: "chair" });
  t.eq(j.of("fill").length, 0, "select skips filtering when no filter box exists");
  t.eq(j.of("click").map((e) => e.label), ["target[0]", "option[0]"], "…and still picks the option");
}

t.done();
