---
name: df-app-walkthrough
description: Record a narrated, captioned product walkthrough video of a web app end-to-end with no human in the loop — synthesized voice-over, a real browser driven with a visible cursor, burned-in captions, assembled to mp4. Works against a public website or an authenticated app (Clerk session-ticket, or any Playwright storageState). Use when asked to record a demo, produce a walkthrough or product tour, make a screen recording of an app, narrate a UI, generate a demo video, or turn a demo script into a video. Triggers on "record a walkthrough", "make a demo video", "screen recording of the app", "product tour", "narrate the UI", "walkthrough video".
---

# Dark Factory — Autonomous App Walkthrough

## Overview

Produces a finished walkthrough video of a running web application without a person
speaking, clicking, or editing. Everything runs locally: a neural text-to-speech voice, a
headless browser, and ffmpeg. No recording SaaS, no upload, no API key — which is what
makes it usable on software you are not allowed to screen-share to a third party.

Four stages, each a script:

```
narration.json ──▶ build-narration ──▶ audio/*.wav + timing.json
                                              │
                                              ▼
                        record-walkthrough ──▶ raw .webm + recorded-timeline.json
                                              │
                                              ▼
                               assemble ──▶ walkthrough.mp4   ──▶ verify
```

This is a **producer** skill. Its natural upstream is a written demo script; its natural
downstream is `df-video-intake` (which turns a video back into text) — the two are inverses
and are useful in sequence when a recorded walkthrough must become requirements.

## When to use

- "Record a walkthrough / demo / product tour of this app."
- A written demo script exists and someone has to perform it, repeatedly, on every release.
- A UI needs a narrated artefact for people who will never be given access to it.
- Regression-by-eye: re-record on each release and compare.

## When not to use

- You need a person's own voice and improvisation — record that yourself.
- The thing being demonstrated is non-deterministic and slow (a long generation job). Narrate
  it over a card instead; see *Cards* below.

---

## The load-bearing idea: audio first, video paced to audio

You cannot know how long a sentence takes until it has been spoken. So the narration is
synthesized and **measured** before the browser opens, and the recorder holds each frame
until that line has finished.

The recorder then emits the offset each step **actually** landed at, and assembly places
audio and captions at those measured offsets rather than the planned ones. A step that runs
long becomes a slightly longer pause instead of desynchronising everything after it.

Recording first and stretching audio afterwards gives you either clipped speech or dead air.
Don't.

---

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| `node` ≥ 18 | drives the browser, orchestrates | your package manager |
| `ffmpeg` + `ffprobe` | caption burn-in, mux, probing | `apt install ffmpeg` / `brew install ffmpeg` |
| `sox` | builds the narration track | `apt install sox` / `brew install sox` |
| `python3` + `venv` | hosts the TTS engine | your package manager |
| a Chromium | the browser that gets recorded | system Chromium, or Playwright's |

Everything else is installed by the setup script into the skill directory:
`playwright-core`, **Playwright's own ffmpeg build**, `piper-tts`, and one voice model.

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/df-app-walkthrough}/scripts/setup.sh"
```

> **`playwright install ffmpeg` is not optional and is not a browser download.** Playwright
> does not encode video with your system ffmpeg — it pipes screencast frames to its own
> pinned build (~2 MB). Without it, `recordVideo` throws at `newPage()` with
> `Executable doesn't exist at .../ffmpeg-<n>/ffmpeg-linux`. The setup script fetches it.

Check an existing install at any time:

```bash
bash scripts/check-prereqs.sh
```

---

## Authentication

Set `WT_AUTH` to one of three modes. Nothing else in the pipeline changes.

### `none` — a public website
No credentials. The first step in your narration should be a `goto`.

### `clerk-ticket` — an app behind Clerk
Mints a short-lived sign-in ticket server-side and lets the app's own widget consume it, so
no cookie is forged and no password is typed.

```bash
export WT_AUTH=clerk-ticket
export CLERK_SECRET_KEY=sk_test_...     # backend key for the instance
export CLERK_USER_ID=user_...           # the account to appear as, on camera
export WT_APP=https://app.example.com
```

Two hard-won rules, both enforced by the shipped helper:

- **Wait for the redirect, not for a fixed number of seconds.** The widget consumes the
  ticket asynchronously and intermittently misses the first one. Sleeping "long enough"
  works until the run where it doesn't. The helper waits for the URL to leave the sign-in
  route and retries with a fresh ticket.
- **Never `goto` a full reload after signing in.** It drops the in-memory session on most
  SPA stacks and the guard bounces you back to sign-in. Navigate by clicking.

### `storage-state` — anything else
Bring a Playwright `storageState.json` produced however you like (including a one-time
headed login). Set `WT_STORAGE_STATE=/path/to/storageState.json`. This is the escape hatch
for auth this skill does not model.

> Whatever the mode: the account you sign in as **appears in the video**, usually in a
> header. Choose it deliberately, and check the display name renders the way you want before
> committing to a full take.

---

## Write the narration

One file describes the whole video. Copy `templates/narration.example.json` and edit.

Each **beat** is one spoken line plus the action performed while it is spoken:

```json
{
  "voice": "en_US-lessac-medium",
  "sections": [
    {
      "id": "intro",
      "title": "Cold open",
      "beats": [
        {
          "action": { "type": "goto", "url": "https://example.com" },
          "say": "This is the catalogue. Every record is independent.",
          "caption": "The catalogue — every record is independent."
        }
      ]
    }
  ]
}
```

**`say` and `caption` are deliberately separate.** `say` is tuned for the synthesizer —
spell acronyms out (`"S H A two fifty six"`, `"A P I"`) or they are mispronounced. `caption`
is tuned for reading (`"SHA-256"`, `"API"`). One string cannot do both jobs well.

### Action types

| `type` | Fields | Does |
|---|---|---|
| `none` | — | holds the current view (the default; most beats are this) |
| `goto` | `url` | full navigation. Safe before sign-in and on public sites; see the auth warning above |
| `click` | `role`+`name`, or `selector`; `nth` | glides the cursor, ripples, then clicks |
| `point` | same as click | glides the cursor **without** clicking — for "look at this" |
| `fill` | `selector`, `text` | types into a field |
| `select` | `selector`, optional `filter`, `option` | opens a combobox, optionally types to filter, picks an option |
| `scroll` | `dy` | scrolls the page |
| `card` | `title`, `bullets`, `reveal` | full-screen overlay card, revealing bullet *n* |
| `wait` | `ms` | explicit dwell |

`role`+`name` is preferred over `selector`: it survives restyling and matches what a user
sees. `name` is a regex.

Every action takes an optional `settle` (ms to wait after acting, default 1500) for views
that load asynchronously.

### Cards

`card` draws a full-screen panel **inside the live page**, and successive beats reveal one
bullet at a time. Use it for material with no good screen — architecture, caveats, a closing
summary — and for any step that is too slow or too non-deterministic to film honestly.

The overlay is injected into the page rather than replacing the document, so the session and
the SPA survive underneath and later beats can carry on clicking. Any subsequent
click/point/scroll removes it.

> If you find yourself narrating ninety seconds over a nearly empty screen, that is the
> signal to convert those beats to a card.

---

## Run it

```bash
export WT_APP=https://app.example.com
export WT_NARRATION=./narration.json
export WT_OUT=./.walkthrough

node scripts/build-narration.mjs     # synthesize + measure   (~1 min per 2 min of speech)
node scripts/record-walkthrough.mjs  # drive the app, capture (~= the video length)
node scripts/assemble.mjs            # captions + audio + mp4 (~1-2 min)
node scripts/verify.mjs              # check the artefact
```

Useful knobs: `WT_PAD_SECONDS` (breath between beats, default 1.0), `WT_WIDTH`/`WT_HEIGHT`
(default 1600×900), `WT_VOICE`, `CHROME_PATH`.

---

## Verify — check the artefact, not the log

`verify.mjs` deliberately does not trust the recorder's own report. A recorder can print
`RECORDED 480s` while the browser sat on an error page for eight minutes. So it checks:

- video and audio streams exist, with the expected geometry and a plausible duration;
- **audio RMS is above a floor** — proving the track is speech, not silence;
- the caption cue count matches the beat count;
- and it extracts **one frame per section** to `verify/`.

**Look at those frames.** That last step is the actual gate — everything above it is
necessary and not sufficient. If you are an agent, read them; you will catch a wrong page, a
spinner, an empty state, or a caption contradicting what is on screen, none of which any
probe detects.

A non-zero `problems` count in `recorded-timeline.json` means a step failed and the recording
continued without it. Read them before shipping the file.

---

## Ground the narration in the running app, not in the script document

The most valuable half hour in this whole process is reconnaissance **before** writing
narration: open the app, read the actual labels, count the actual records, click the feature
you are about to describe.

Demo scripts drift from the software faster than anyone updates them. Recording one verbatim
puts confident false statements on camera, in your voice, in a file that outlives the
correction. Observed drift, all from one real run: record counts that no longer matched, a
feature named one thing in the script and another in the UI, a field the script pointed at
that renders only when non-null, a screen described as doing something it does not do, and a
defect called out as outstanding that had already been fixed.

Treat every number and every noun in a demo script as unverified until you have read it off
the running application.

---

## Gotchas

- **Eagerly-rendered tab panels.** Many UI frameworks render every tab's contents and hide
  the inactive ones. A page-level selector then resolves against a *hidden* panel and returns
  plausible, wrong data — silently. Scope selectors to the visible panel. This produced a
  false "this feature returns nothing" reading during development that was nearly reported as
  a defect.
- **`recordVideo` has no mouse pointer.** It captures the page's own rendered frames, so a
  real cursor is invisible and the result reads as a slideshow. This skill draws its own
  cursor and click ripple, driven by a CSS transition rather than tweened from Node — smooth
  without a round-trip per frame.
- **The video starts before your first beat.** Recording begins at browser-context creation,
  which is before sign-in. The recorder measures that prefix and assembly trims it, so the
  login never appears. If you fork the scripts, keep that.
- **A backgrounded `cmd | tail` reports `tail`'s exit status.** A build or test you launch
  this way can look green while the real command was not even found.

---

## Safety

The recorder only reads. It clicks the steps you declare and nothing else — but *you* choose
those steps, so:

- **Do not script a destructive control.** If a feature is only reachable through a delete
  or publish gate, film the read-only view of the same information if one exists, and say on
  camera that nothing is being changed.
- **Prefer a non-production target.** If you must record production, keep every action to
  navigation and reading.
- **The signed-in identity, environment banners, and version strings are all on camera.**
  Check the first frame before recording eight more minutes.

---

## Resources

- `scripts/setup.sh` — one-shot install of the local toolchain.
- `scripts/check-prereqs.sh` — verifies an existing install and prints exact fixes.
- `scripts/build-narration.mjs` · `record-walkthrough.mjs` · `assemble.mjs` · `verify.mjs`.
- `scripts/lib/session.mjs` — auth modes + the drawn cursor.
- `scripts/lib/actions.mjs` — the action vocabulary.
- `templates/narration.example.json` — a runnable example against a public site.

Pairs with: `df-video-intake` (the inverse), `df-qa` (evidence discipline),
`df-adversary-gate` (verify the evidence, never the self-report).
