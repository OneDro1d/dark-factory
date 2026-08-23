#!/usr/bin/env node
/**
 * Stage 1 — synthesize the narration and MEASURE it.
 *
 * Audio is built first and the video is later paced to it. The alternative — record, then
 * stretch audio to fit — forces either clipped speech or dead air, because you cannot know
 * how long a sentence takes until it is spoken. Here every beat's true duration is known
 * before the browser opens.
 *
 * Out: <out>/audio/*.wav + <out>/timing.json
 */
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SKILL = resolve(HERE, "..");
const OUT = resolve(process.env.WT_OUT || ".walkthrough");
const NARRATION = resolve(process.env.WT_NARRATION || "narration.json");
const PIPER = process.env.WT_PIPER_PYTHON || join(SKILL, ".venv/bin/python");
const VOICES = process.env.WT_VOICES || join(SKILL, ".voices");
const PAD_S = Number(process.env.WT_PAD_SECONDS || 1.0);

if (!existsSync(NARRATION)) {
  console.error(`no narration at ${NARRATION} — set WT_NARRATION, or copy templates/narration.example.json`);
  process.exit(1);
}
if (!existsSync(PIPER)) {
  console.error(`no TTS engine at ${PIPER} — run scripts/setup.sh`);
  process.exit(1);
}

const script = JSON.parse(readFileSync(NARRATION, "utf8"));
const voice = process.env.WT_VOICE || script.voice || "en_US-lessac-medium";
mkdirSync(join(OUT, "audio"), { recursive: true });

const durationOf = (wav) =>
  Number(
    execFileSync("ffprobe", [
      "-v", "error", "-show_entries", "format=duration",
      "-of", "default=nw=1:nk=1", wav,
    ], { encoding: "utf8" }).trim()
  );

const timing = { voice, padSeconds: PAD_S, sections: [] };

for (const section of script.sections) {
  const beats = [];
  let offset = 0;
  for (const [i, beat] of section.beats.entries()) {
    const wav = join(OUT, "audio", `${section.id}-${String(i).padStart(2, "0")}.wav`);
    execFileSync(
      PIPER,
      ["-m", "piper", "-m", voice, "--data-dir", VOICES, "-f", wav],
      { input: beat.say ?? "", stdio: ["pipe", "ignore", "pipe"] }
    );
    const speech = durationOf(wav);
    beats.push({
      index: i,
      action: beat.action || { type: "none" },
      caption: beat.caption || "",
      wav,
      speechSeconds: Number(speech.toFixed(3)),
      totalSeconds: Number((speech + PAD_S).toFixed(3)),
      startSeconds: Number(offset.toFixed(3)),
    });
    offset += speech + PAD_S;
  }
  timing.sections.push({
    id: section.id,
    title: section.title || section.id,
    durationSeconds: Number(offset.toFixed(3)),
    beats,
  });
  console.log(`${section.id}: ${offset.toFixed(1)}s (${beats.length} beats)`);
}

timing.totalSeconds = Number(
  timing.sections.reduce((a, s) => a + s.durationSeconds, 0).toFixed(3)
);
writeFileSync(join(OUT, "timing.json"), JSON.stringify(timing, null, 2));
console.log(`\nTOTAL ${(timing.totalSeconds / 60).toFixed(2)} min -> ${join(OUT, "timing.json")}`);
