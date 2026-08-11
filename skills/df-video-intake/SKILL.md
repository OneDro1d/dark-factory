---
name: df-video-intake
description: Parse a video (mp4/mov/webm) into a transcript + timestamped frames so Claude can consume it, then extract context — specifically Dark Factory requirements — from it. Use when given a recording, demo, app walkthrough, screen recording, or "video" to summarize or turn into requirements/specs; when asked to "watch", "process", "consume", or "transcribe" a video; or to extract requirements/context from a demo for a dark factory build (PO vision, data contracts, validation rules, test scenarios).
---

# Dark Factory — Video Intake

## Overview
Claude cannot read video or audio natively (the Read tool handles images, PDFs, and
notebooks only). This skill decomposes a video into things Claude *can* read — a
timestamped **transcript** and sampled **frames** — then guides turning that into
**Dark Factory requirements** via `df-product-owner` and `df-data-transform-lens`.

Two phases: **Intake** (mechanical, a script) → **Extract** (judgment, you + the DF skills).

## When to Use
- The user hands you a video/recording/demo/walkthrough and wants it summarized, documented, or turned into requirements.
- "Can you watch / process / consume / transcribe this video?"
- "Extract requirements from this demo recording for the dark factory build."
- A screen-recorded SME/customer walkthrough that should become a PO requirements package.

## Prerequisites
- `ffmpeg` (+ `ffprobe`) — `brew install ffmpeg` (macOS) / `apt install ffmpeg` (Debian).
- `whisper-cpp` — `brew install whisper-cpp` (provides the `whisper-cli` binary). The
  ggml model auto-downloads to `~/.cache/whisper-cpp` on first run and is reused after.
- On Apple Silicon whisper-cli uses Metal/GPU automatically (≈24 s for a 9-min clip).

If a tool is missing the script prints the exact install command and exits — install, then re-run.

---

## Phase 1 — Intake (run the script)

One command does probe → audio → transcript → frames:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/df-video-intake}/scripts/extract-video.sh" "<path/to/video.mp4>" [interval_seconds] [model]
```

- `interval_seconds` (default **12**) — one frame every N seconds. ~9 min → ~45 frames.
- `model` (default **small.en**) — `base.en` (faster, ~148 MB) · `small.en` (best
  quality/speed) · `medium.en` (slower, more accurate).

Output lands in `<video-dir>/<video-basename>-extract/`:
`probe.txt`, `audio.wav`, `transcript.txt`, `transcript.srt` (timestamped), `frames/iv_NNNN.jpg`.

**Frame ↔ time:** `iv_NNNN.jpg` ≈ `(NNNN-1) × interval` seconds in. This is the join key
back to the SRT.

### Why fixed-interval, not scene detection
For **screen recordings**, ffmpeg scene-change detection (`select='gt(scene,0.3)'`)
fails — the UI changes gradually (scrolling, inline edits), so it yields ~0 frames.
Fixed-interval sampling guarantees coverage and clean timestamp alignment. (Scene
detection is still fine for edited video with hard cuts — not the usual demo case.)

---

## Phase 2 — Extract (read, then turn into DF requirements)

1. **Read `transcript.txt` in full.** For a narrated demo it carries ~80% of the
   semantics and is cheap (text). The `.srt` gives you `[mm:ss]` timestamps to cite.
2. **Read frames selectively, guided by the transcript.** Each image costs context, so
   don't bulk-read all 45 — jump to the timestamps where the narration references a
   screen/state (`iv_NNNN ≈ time/interval`). The transcript says *intent*; the frame is
   *ground truth* (demos often narrate one thing while showing another — frames catch it).
3. **Invoke the DF lens + PO skills** — this skill ends where they begin:
   - `df-data-transform-lens` — name the data nodes (`origin`/`authority`/`governance`)
     and transforms (`pure|effect`) the demo reveals.
   - `df-product-owner` — produce **Vision + Requirements (data contracts + validation
     rules) + Test Scenarios** from the transcript+frames.
4. **Tag every claim** `Confirmed` (stated/shown) · `Inferred` · `Assumption` · `Open`.
   A demo is one person's narration — never silently promote a guess to a requirement.
5. **Cite evidence** inline: `[mm:ss]` for narration, `ivNNNN` for the frame that proves it.
6. **Flag effects** — any ask that sends/charges/notifies/writes-external or reads PHI
   (e.g. "test against a real chart") so the SA assigns idempotency + compensation.

### Output artifact convention
- Write the extraction as a **new, source-derived doc** next to the video (e.g.
  `requirements-docs/<name>-requirements-extraction.md`), with frontmatter marking it
  `status: source-derived (NOT canonical)`.
- **Do not silently mutate governed `docs/po/`** docs. If the repo already has a PO
  package, add a short "Relationship to existing docs/po" table mapping each extracted
  requirement to existing scenarios (Inferred), and offer a separate reconcile/gap-check.
- End with an **Open questions** list — the things a cold Solution Architect would need
  answered before designing (the `df-product-owner` exit-gate test).

---

## Verification
- [ ] `transcript.txt` is non-empty and coherent (skim `whisper.log` if not — bad audio,
      wrong model, or a non-English track needs a non-`.en` model).
- [ ] Frame count ≈ `duration / interval`; spot-read one mid frame for legibility.
- [ ] Every requirement in the output carries a tag + at least one `[mm:ss]`/`ivNNNN` cite.
- [ ] Effects and Open questions sections are present.

## Worked example
A ~9-minute product demo, run through this skill end to end (intake script →
transcript+frames → df-product-owner), yielded a dozen requirements and several
state-change test scenarios in PO format. Keep your own worked examples in your
organisation layer, next to the artifacts they cite.

## Troubleshooting
| Problem | Cause | Fix |
|---|---|---|
| `ffmpeg/whisper-cpp missing` | not installed | run the printed `brew install …` line |
| Transcript empty / garbled | non-English audio, or `.en` model on non-English | use `small` / `medium` (no `.en` suffix) |
| Too many / too few frames | interval wrong for length | pass a larger interval for long videos, smaller for short |
| Wrong/garbled words for jargon | acronyms/domain terms | normal — confirm against frames; keep a glossary, tag `Inferred`/`Open` |
| Frames unreadable (tiny text) | downscaled source | `zoom` into the frame region, or lower interval near the key moment |

## Resources
- `scripts/extract-video.sh` — the intake pipeline (executed, not loaded into context).
- Pairs with: `df-data-transform-lens`, `df-product-owner` (and downstream `df-solution-architect`).
