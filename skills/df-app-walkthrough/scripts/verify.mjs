#!/usr/bin/env node
/**
 * Stage 4 — check the ARTEFACT, not the log.
 *
 * A recorder that prints "RECORDED 480s" proves nothing: the browser can sit on an error
 * page for eight minutes and still produce a well-formed video. So probe the file, measure
 * the audio, and pull one frame per section for a human (or a vision model) to LOOK at.
 * The frames are the actual gate; everything above them is necessary and not sufficient.
 */
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, mkdirSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";

const OUT = resolve(process.env.WT_OUT || ".walkthrough");
const MP4 = join(OUT, process.env.WT_BASENAME || "walkthrough.mp4");
const FRAMES = join(OUT, "verify");
const MIN_RMS = Number(process.env.WT_MIN_RMS || 0.01);
// The defaults catch defects, not taste: too quiet to hear or loud enough to hurt, a clipped
// peak, a stretch of black where the page never painted.
const LUFS_MIN = Number(process.env.WT_LUFS_MIN || -24);
const LUFS_MAX = Number(process.env.WT_LUFS_MAX || -12);
const TP_MAX = Number(process.env.WT_TP_MAX || 0);
const BLACK_SECONDS = Number(process.env.WT_BLACK_SECONDS || 1);

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

// RMS proves there is sound; it says nothing about whether a viewer can hear it, or whether it
// clips. EBU R128 integrated loudness and true peak do. ffmpeg reports both on stderr, and the
// summary comes last, so take the last match. A value that could not be measured fails.
// ⚠️ `ran` is the load-bearing part, not the stderr. A probe that never executed emits no
// matches, and "no matches" is indistinguishable from a clean result unless the exit status is
// read: missing ffmpeg, an unreadable file, a stream map that matches nothing and a renamed
// filter all look exactly like "nothing wrong here". An absence is only evidence when the thing
// that would have reported a presence is known to have run.
const ffStderr = (args) => {
  const r = spawnSync("ffmpeg", ["-hide_banner", "-nostats", ...args], { encoding: "utf8", maxBuffer: 1 << 28 });
  return { ran: r.status === 0, why: r.error ? r.error.message : `ffmpeg exit ${r.status}`, stderr: r.stderr || "" };
};
const lastNumber = (text, re) => { const m = [...text.matchAll(re)]; return m.length ? Number(m[m.length - 1][1]) : NaN; };
if (a) {
  const r128 = ffStderr(["-i", MP4, "-map", "0:a:0", "-af", "ebur128=peak=true", "-f", "null", "-"]);
  const lufs = lastNumber(r128.stderr, /I:\s+(-?[\d.]+) LUFS/g);
  const tp = lastNumber(r128.stderr, /Peak:\s+(-?[\d.]+) dBFS/g);
  (lufs >= LUFS_MIN && lufs <= LUFS_MAX ? ok : fail).push(Number.isFinite(lufs) ? `loudness ${lufs} LUFS (window ${LUFS_MIN}..${LUFS_MAX})` : `loudness could not be measured (${r128.why})`);
  (tp <= TP_MAX ? ok : fail).push(Number.isFinite(tp) ? `true peak ${tp} dBTP (ceiling ${TP_MAX})` : `true peak could not be measured (${r128.why})`);
}

// a well-formed file can still be black for a minute: the app never painted, or a navigation
// failed and the recorder kept going
const bd = ffStderr(["-i", MP4, "-map", "0:v:0", "-vf", `blackdetect=d=${BLACK_SECONDS}:pix_th=0.10`, "-an", "-f", "null", "-"]);
const black = [...bd.stderr.matchAll(/black_start:([\d.]+) black_end:([\d.]+)/g)].map((m) => `${Number(m[1]).toFixed(1)}-${Number(m[2]).toFixed(1)}s`);
(bd.ran && black.length === 0 ? ok : fail).push(
  !bd.ran ? `black detection did not run, so no verdict (${bd.why})`
    : black.length ? `black for ${BLACK_SECONDS}s or more at ${black.join(", ")}`
      : `no black stretch of ${BLACK_SECONDS}s or more`);

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
