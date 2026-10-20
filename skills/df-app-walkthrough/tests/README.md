# df-app-walkthrough test suites

Six suites, enrolled by existing — `boot-kit/scripts/run-tests.sh` globs `test-*.sh` across
the whole repo, so nothing had to be added to a list.

| suite | subject | needs |
|---|---|---|
| `test-walkthrough-actions.sh` | `lib/actions.mjs`, `lib/session.mjs` | node |
| `test-walkthrough-verify.sh` | `verify.mjs` | node, ffmpeg |
| `test-walkthrough-assemble.sh` | `assemble.mjs` | node, ffmpeg |
| `test-walkthrough-stages.sh` | `build-narration.mjs`, `record-walkthrough.mjs`, `check-prereqs.sh` | node, ffmpeg |
| `test-walkthrough-mutations.sh` | **all five others** | node, ffmpeg, python3, chromium |
| `test-walkthrough-browser.sh` | the drawn cursor, click placement, resolution against real layout, `recordVideo` | node, **chromium**, Playwright's own ffmpeg, ffprobe |

The first five need no browser, no network, no app and no TTS model. The sixth needs a real
Chromium by definition — it exists for the things a stub cannot settle — and it **skips with
a declared `COVERAGE:` line** when the browser is absent, or **refuses** when
`WT_TESTS_REQUIRE_FULL=1` says a degraded run is unacceptable. The gate sets that variable
and installs the browser, so removing the install step turns the gate RED instead of quietly
dropping 41 assertions. Both directions of that interlock are proven by
`bin/prove-browser-interlock.sh` in the `notepad-onedroid-dark-factory` notepad: 11/11.

## ⛔ The gate installs ffmpeg, and it has to — read this before removing that step

**MEASURED 2026-10-05 on the GitHub runner: it ships no ffmpeg.** Four of these five suites
therefore took their degraded paths and the gate was **green at a fraction of the coverage** —
verify 20 → 2 assertions, assemble 26 → 2, stages 39 → 21, mutations 36 → 21. Among the 15
mutants that did not run was **`the #224 black-frame defect, restored`**: the regression guard
for a defect that actually shipped. It was guarded on a maintainer's laptop and nowhere that
enforces anything.

⚠️ **And the shrinkage was invisible.** Each suite prints a `COVERAGE:` line naming exactly
what it skipped — but `run-tests.sh` captures a child's output and shows it only on
**failure**, so on a pass that declaration never reaches the log. The only visible signal was
the assertion count, and a reader would have to already know the full number to notice.
*"Declared, not silent" was true of the suite and false of the system it reports into.*
**Declaring a gap only helps where the reader will actually look.**

Two things now stop it recurring:

1. `gate.yml` installs ffmpeg before running the suites (not sox — see below).
2. **`WT_TESTS_REQUIRE_FULL=1`**, set for the gate job: a suite that would degrade **refuses**
   instead, exits 1 and names the missing tool. Remove the install step and the gate goes red
   rather than shrinking by 90% and still ticking. Locally the variable is unset, so a
   contributor without ffmpeg still gets a useful partial run, with the `COVERAGE:` line they
   *will* see because they ran the suite directly.

Both directions of that interlock are proven — it must refuse when set, and must still pass
degraded when unset, since one that always refuses is equally broken. The prover is
`bin/prove-walkthrough-interlock.sh` in the `notepad-onedroid-dark-factory` notepad: 8/8, and
the degraded counts it reproduces match the CI log exactly.

## Why there is a mutation suite

The other four are ~190 green assertions, and **a green suite carries no information until
you have watched it go red on an input it must catch.** `test-walkthrough-mutations.sh`
applies 35 one-line defects to copies under `TMPDIR` and requires each to be caught *by the
assertion that names it* — a mutant that merely crashes a driver is reported `WRONG-FAIL`,
not a win. The repo makes this argument twice already: `gate-selftest.sh` runs first in CI
for the same reason, and the `ASSERTIONS:` contract in `run-tests.sh` exists because
"asserted 44 things" and "asserted nothing" both exit 0.

It is sharper here than usual. This skill shipped **seven scripts with no tests at all**,
and the defect that got through in #224 was an all-clear that *could not fail*: a black-frame
probe that never ran emitted no matches, and "no matches" scored identically to "nothing
wrong". An all-black twelve-second video was accepted by the check written to catch it.
`the #224 black-frame defect, restored` is a mutant in that suite, so the regression is
permanently guarded.

Three defects were found **in these suites** by that mutation run, which is the argument for
it in miniature:

- an assertion on the ripple animation that could not fail, because a `Set`-backed
  `classList` stub cannot express *re-triggering* — the class is already present;
- one unexpected throw silently deleting every later assertion in a driver file, including
  the assertion written to catch the mutant that caused the throw (now `t.step`);
- a `grep` without `--` reading `-ss` and `-map` as its own options, reporting a broken
  harness as four defects in `assemble.mjs`.

## What the browser suite covers, and why it is a separate file

`test-walkthrough-browser.sh` exists because the four items below used to be the first entry
in the "NOT covered" list, with the honest reason *"a suite that needed Chromium would not
run in the gate"*. It runs there now, so they are covered: the cursor installs into a real
document and **comes back on its own after an SPA replaces the body** (the `setInterval`
re-install claim, untestable against a stub), `glideTo` lands on the element's real layout
centre, the browser's own `clientX/clientY` for the dispatched click **match the pixel the
cursor was drawn at**, the ripple **re-triggers** on a second click at the same point, a
same-named control resolves inside the **visible** tabpanel, `nameFlags: ""` is
case-sensitive against a real accessible name, card bullets render as text and the card's
stylesheet lands in `<head>`, and `recordVideo` writes a webm that `ffprobe` decodes.

⛔ **And one case points the other way: `stub-fidelity`.** Roughly 190 assertions in the
node-only suites rest on `stub-page.mjs` failing the way Playwright fails, and nothing
checked that against a browser. It now asserts the two behaviours the stub models —
`waitFor({visible})` rejects on a hidden element, `boundingBox` resolves to `null` for
`display:none` — plus `glideTo`'s null contract. If Playwright ever changes either, those
suites would keep passing against a stub that models nothing: the quietest way a green suite
can go hollow.

⚠️ **Two of its ten cases could not fail when first written, and ablation is what found
that.** Deleting the visible-tabpanel preference from `scopeFor` SURVIVED, because `resolve`
*also* takes the first visible match — so the fixture now carries a visible decoy of the same
name outside any panel, which is what separates the two behaviours. And removing
`glideTo`'s `.catch(() => null)` SURVIVED, because `boundingBox()` on `display:none`
*resolves* to null rather than rejecting; an **ambiguous** locator is what makes it reject,
so that is the input now used.

⛔ **Those two fixes are only load-bearing while something keeps checking them**, so all ten
mutants live in `test-walkthrough-mutations.sh` rather than in a one-off ablation script —
each required to be caught *by the assertion that names it*. Two of them declare the
enclosing `t.step` label on purpose: the defect makes the page throw, so the step attributes
the throw and the inner assertion never runs to be named. Declaring the inner label would
score `WRONG-FAIL` forever, which is that mechanism working — it refuses to credit a catch it
cannot attribute.

## What these suites do NOT cover — declared, not implied
- **A real app.** The browser suite drives `file://` fixtures, not a running application, so
  nothing here exercises auth against a live app, an SPA's own routing, or a page that is
  still loading when a beat fires. Those remain the operator's end-to-end run.
- **The real TTS.** `build-narration.mjs` runs against a stub voice that emits a genuine
  2-second wav. The pacing arithmetic is therefore measured for real against real `ffprobe`
  output; the synthesis is not exercised at all.
- **The real encode.** `assemble.mjs`'s final `ffmpeg` is stubbed, so that libass actually
  burns the captions in and the mux produces a playable file is unproven here.
  `check-prereqs.sh` asserts the `subtitles` filter is present, and `verify.mjs` checks the
  resulting artefact — between them that is the cover, and it is indirect.
- **The recording loop.** `record-walkthrough.mjs` is covered for its two preconditions
  only. The loop that times beats against measured offsets, and turns a thrown beat into a
  recorded `problem`, needs a browser.
- **A real walkthrough.** Nothing here proves the tool produces a *good* video. That
  judgement is `verify.mjs`'s extracted frames, and its own header says so: the frames are
  the actual gate, and everything above them is necessary and not sufficient.

## Two environment notes that changed what was measured

- **sox is stubbed in `test-walkthrough-verify.sh` for every case**, and that is not
  convenience. sox is absent on many machines, including the one these were written on and the
  GitHub runner. Without the stub, `verify.mjs`'s RMS check fails for a reason unrelated to
  the case under test and *every* run exits 1 — during the #224 review that nearly got
  attributed to the black-frame defect. The RMS branch gets its own case, with a stub that
  reports silence, and a further case with no sox at all. **sox is deliberately not installed
  in CI**, so those paths stay exercised.
  ⚠️ The no-sox case runs with `PATH` set to **exactly** one scratch directory, not prepended
  to the inherited one. The first version prepended, so "sox is missing" was true only because
  this machine happens to lack sox — **the assertion measured the machine, not `verify.mjs`,
  and would have failed on any box with sox installed.** It is now paired with a mirror case
  where sox *is* reachable and the floor passes; the pair is the control, since either case
  alone would pass against broken scoping.
- **`session.mjs` reads `WT_AUTH` at module load**, so `test-walkthrough-actions.sh` runs
  one node process per auth mode and scrubs every `WT_*`/`CLERK_*` variable around each.
  Two modes in one process would mean the second ran under the first one's constant and
  passed for the wrong reason.

The `CLERK_SECRET_KEY` / `CLERK_USER_ID` values in these suites are obvious non-secrets and
`fetch` is stubbed inside the case, so nothing leaves the machine; they exist only to get
past a presence check.
