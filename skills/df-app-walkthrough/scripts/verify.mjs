#!/usr/bin/env node
/**
 * Stage 4 — check the ARTEFACT, not the log.
 *
 * A recorder that prints "RECORDED 480s" proves nothing: the browser can sit on an error
 * page for eight minutes and still produce a well-formed video. So probe the file, measure
 * the audio, and pull one frame per section for a human (or a vision model) to LOOK at.
 * The frames are the actual gate; everything above them is necessary and not sufficient.
 */
import { execFileSync } from "node:child_process";
import { readFileSync, mkdirSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";

const OUT = resolve(process.env.WT_OUT || ".walkthrough");
const MP4 = join(OUT, process.env.WT_BASENAME || "walkthrough.mp4");
const FRAMES = join(OUT, "verify");
const MIN_RMS = Number(process.env.WT_MIN_RMS || 0.01);

if (!existsSync(MP4)) {
  console.error("FAIL: no mp4 at " + MP4);
  process.exit(1);
}
mkdirSync(FRAMES, { recursive: true });

const sh = (c, a) => execFileSync(c, a, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
const ok = [];
const fail = [];

const info = JSON.parse(sh("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", MP4]));
const v = info.streams.find((s) => s.codec_type === "video");
const a = info.streams.find((s) => s.codec_type === "audio");
const duration = Number(info.format.duration);

(v ? ok : fail).push(v ? `video ${v.codec_name} ${v.width}x${v.height}` : "no video stream");
(a ? ok : fail).push(a ? `audio ${a.codec_name} ${a.sample_rate}Hz` : "no audio stream");
(duration > 10 ? ok : fail).push(`duration ${(duration / 60).toFixed(2)} min`);

// audio is speech, not silence
let rms = 0;
try {
  const stat = sh("sh", ["-c", `ffmpeg -v error -i '${MP4}' -f wav - 2>/dev/null | sox -t wav - -n stat 2>&1`]);
  rms = Number((stat.match(/RMS\s+amplitude:\s*([\d.]+)/) || [])[1] || 0);
} catch { /* leaves rms 0 -> fails below */ }
(rms > MIN_RMS ? ok : fail).push(`audio RMS ${rms.toFixed(4)} (floor ${MIN_RMS})`);

const assPath = join(OUT, "captions.ass");
const cues = existsSync(assPath)
  ? readFileSync(assPath, "utf8").split("\n").filter((l) => l.startsWith("Dialogue:")).length
  : 0;
(cues > 0 ? ok : fail).push(`${cues} caption cues`);

// one frame per section — beat offsets are measured from t0 and assembly already trimmed
// the pre-t0 pre-roll, so the mp4's t=0 IS t0. Do not subtract the prefix again here.
const tl = JSON.parse(readFileSync(join(OUT, "recorded-timeline.json"), "utf8"));
const shots = [];
for (const s of tl.sections) {
  const mid = (s.startSeconds + s.endSeconds) / 2;
  if (mid < 0 || mid > duration) continue;
  const png = join(FRAMES, `${s.id}.png`);
  sh("ffmpeg", ["-y", "-v", "error", "-ss", String(mid), "-i", MP4, "-frames:v", "1", png]);
  shots.push({ at: Number(mid.toFixed(1)), png });
}
(shots.length === tl.sections.length ? ok : fail).push(`${shots.length}/${tl.sections.length} section frames`);

const problems = tl.problems || [];
(problems.length === 0 ? ok : fail).push(`${problems.length} recorder problems`);

console.log("PASS:");
for (const o of ok) console.log("  ok  " + o);
if (fail.length) {
  console.log("ATTENTION:");
  for (const f of fail) console.log("  !!  " + f);
}
if (problems.length) {
  console.log("recorder problems:");
  for (const p of problems) console.log("  - " + p);
}
console.log("\nNow LOOK at these frames — this is the real gate:");
for (const s of shots) console.log(`  ${s.at}s  ${s.png}`);
process.exit(fail.length ? 1 : 0);
