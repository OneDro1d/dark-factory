#!/usr/bin/env node
/**
 * Stage 3 — narration track, burned-in captions, final mp4.
 *
 * Audio and captions land at the offsets the recorder MEASURED, not the ones it planned.
 * The raw webm begins at browser-context creation, which is before sign-in; the recorded
 * `videoPrefixSeconds` trims that head so the login never appears.
 */
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";

const OUT = resolve(process.env.WT_OUT || ".walkthrough");
const TMP = join(OUT, "tmp-audio");
const FINAL = join(OUT, process.env.WT_BASENAME || "walkthrough.mp4");

const tlPath = join(OUT, "recorded-timeline.json");
if (!existsSync(tlPath)) {
  console.error(`no recorded-timeline.json in ${OUT} — run record-walkthrough.mjs first`);
  process.exit(1);
}
const tl = JSON.parse(readFileSync(tlPath, "utf8"));
mkdirSync(TMP, { recursive: true });

const sh = (cmd, args) => execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
const probe = (f) =>
  Number(sh("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", f]).trim());

const beats = tl.sections.flatMap((s) => s.beats).sort((a, b) => a.startSeconds - b.startSeconds);

// ---- captions (ASS, burned in with libass) ---------------------------------
const t = (sec) => {
  const s = Math.max(0, sec);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return `${h}:${String(m).padStart(2, "0")}:${(s % 60).toFixed(2).padStart(5, "0")}`;
};
const esc = (s) => s.replace(/[{}]/g, "").replace(/\r?\n/g, "\\N");

const W = tl.width || 1600;
const H = tl.height || 900;
const font = process.env.WT_FONT || "DejaVu Sans";
const ass = [
  "[Script Info]", "ScriptType: v4.00+", `PlayResX: ${W}`, `PlayResY: ${H}`,
  "WrapStyle: 0", "ScaledBorderAndShadow: yes", "",
  "[V4+ Styles]",
  "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
  // BorderStyle 3 + an alpha BackColour is what makes the translucent band behind the text
  `Style: Cap,${font},33,&H00FFFFFF,&H000000FF,&H00000000,&HB0140F0A,-1,0,0,0,100,100,0,0,3,7,0,2,140,140,44,1`,
  "",
  "[Events]",
  "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
];
for (const b of beats) {
  if (!b.caption) continue;
  ass.push(`Dialogue: 0,${t(b.startSeconds)},${t(b.endSeconds)},Cap,,0,0,0,,${esc(b.caption)}`);
}
const assPath = join(OUT, "captions.ass");
writeFileSync(assPath, ass.join("\n") + "\n");
console.log(`captions: ${beats.filter((b) => b.caption).length} cues`);

// ---- narration track -------------------------------------------------------
// Each beat's WAV is front-padded by the silence between the previous beat's speech ending
// and this beat's measured start, then all are concatenated.
const parts = [];
let cursor = 0;
for (const [i, b] of beats.entries()) {
  const gap = Math.max(0, b.startSeconds - cursor);
  const padded = join(TMP, `p${String(i).padStart(3, "0")}.wav`);
  sh("sox", [b.wav, padded, "pad", gap.toFixed(3), "0"]);
  parts.push(padded);
  cursor = b.startSeconds + probe(b.wav);
}
const narration = join(OUT, "narration.wav");
sh("sox", [...parts, narration]);
console.log(`narration: ${probe(narration).toFixed(1)}s`);

// ---- burn + mux ------------------------------------------------------------
const prefix = tl.videoPrefixSeconds || 0;
console.log(`video: ${probe(tl.videoPath).toFixed(1)}s raw, trimming ${prefix.toFixed(1)}s of pre-roll`);

sh("ffmpeg", [
  "-y",
  "-ss", String(prefix),
  "-i", tl.videoPath,
  "-i", narration,
  "-filter_complex", `[0:v]subtitles=${assPath}[v]`,
  "-map", "[v]", "-map", "1:a",
  "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
  "-c:a", "aac", "-b:a", "160k",
  "-movflags", "+faststart",
  FINAL,
]);

rmSync(TMP, { recursive: true, force: true });
console.log(`\nFINAL: ${FINAL}`);
console.log(`duration ${(probe(FINAL) / 60).toFixed(2)} min`);
