#!/usr/bin/env node
/**
 * Stage 2 — drive the app and record it.
 *
 * Records ONE continuous video and emits the MEASURED offset of every beat. Assembly then
 * places audio and captions at those measured offsets rather than the planned ones, so a
 * step that overruns its narration becomes a slightly longer pause instead of
 * desynchronising everything after it.
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { APP, signIn, contextOptions, CURSOR_INIT_SCRIPT } from "./lib/session.mjs";
import { runAction } from "./lib/actions.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const SKILL = resolve(HERE, "..");
const OUT = resolve(process.env.WT_OUT || ".walkthrough");
const VIDEO_DIR = join(OUT, "video");
const W = Number(process.env.WT_WIDTH || 1600);
const H = Number(process.env.WT_HEIGHT || 900);

const { chromium } = await import(join(SKILL, "node_modules/playwright-core/index.mjs"));

const timingPath = join(OUT, "timing.json");
if (!existsSync(timingPath)) {
  console.error(`no timing.json in ${OUT} — run build-narration.mjs first`);
  process.exit(1);
}
const timing = JSON.parse(readFileSync(timingPath, "utf8"));
mkdirSync(VIDEO_DIR, { recursive: true });

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || "/usr/bin/chromium",
  args: ["--no-sandbox", "--disable-dev-shm-usage", "--hide-scrollbars"],
});
const ctx = await browser.newContext({
  viewport: { width: W, height: H },
  ignoreHTTPSErrors: true,
  recordVideo: { dir: VIDEO_DIR, size: { width: W, height: H } },
  ...contextOptions(),
});
await ctx.addInitScript(CURSOR_INIT_SCRIPT);
const page = await ctx.newPage();
// recordVideo starts at page creation, i.e. BEFORE sign-in — assembly trims this prefix so
// the login never appears in the cut.
const tVideoStart = Date.now();

const problems = [];
page.on("pageerror", (e) => problems.push(String(e.message || e).slice(0, 140)));

console.log(`signing in (${process.env.WT_AUTH || "none"})…`);
await signIn(page);
await page.waitForTimeout(2000);
console.log("ready:", page.url());

const t0 = Date.now();
const timeline = {
  app: APP,
  width: W,
  height: H,
  startedAt: new Date(t0).toISOString(),
  videoPrefixSeconds: Number(((t0 - tVideoStart) / 1000).toFixed(3)),
  sections: [],
};

for (const section of timing.sections) {
  console.log(`\n== ${section.id} (${section.durationSeconds}s planned)`);
  const secStart = (Date.now() - t0) / 1000;
  const beats = [];

  for (const beat of section.beats) {
    const at = (Date.now() - t0) / 1000;
    try {
      await runAction(page, beat.action);
    } catch (e) {
      const msg = `${section.id}[${beat.index}] ${JSON.stringify(beat.action)}: ${String(e.message || e).split("\n")[0]}`;
      console.log("  !! " + msg);
      problems.push(msg);
    }
    // hold the frame until this beat's narration would have finished
    const elapsed = (Date.now() - t0) / 1000 - at;
    const remain = beat.totalSeconds - elapsed;
    if (remain > 0) await page.waitForTimeout(Math.round(remain * 1000));
    beats.push({
      index: beat.index,
      action: beat.action,
      caption: beat.caption,
      wav: beat.wav,
      startSeconds: Number(at.toFixed(3)),
      endSeconds: Number(((Date.now() - t0) / 1000).toFixed(3)),
      speechSeconds: beat.speechSeconds,
    });
    console.log(`  [${beat.index}] ${beat.action?.type || "none"} @${at.toFixed(1)}s`);
  }

  timeline.sections.push({
    id: section.id,
    title: section.title,
    startSeconds: Number(secStart.toFixed(3)),
    endSeconds: Number(((Date.now() - t0) / 1000).toFixed(3)),
    beats,
  });
}

timeline.totalSeconds = Number(((Date.now() - t0) / 1000).toFixed(3));
timeline.problems = problems;

const video = page.video();
await ctx.close(); // finalises the webm
await browser.close();
timeline.videoPath = await video.path();

writeFileSync(join(OUT, "recorded-timeline.json"), JSON.stringify(timeline, null, 2));
console.log(`\nRECORDED ${timeline.totalSeconds.toFixed(1)}s -> ${timeline.videoPath}`);
console.log(`problems: ${problems.length}`);
for (const p of problems.slice(0, 10)) console.log("  - " + p);
