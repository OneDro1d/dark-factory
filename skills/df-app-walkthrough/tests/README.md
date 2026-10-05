# df-app-walkthrough test suites

Five suites, enrolled by existing — `boot-kit/scripts/run-tests.sh` globs `test-*.sh` across
the whole repo, so nothing had to be added to a list.

| suite | subject | needs |
|---|---|---|
| `test-walkthrough-actions.sh` | `lib/actions.mjs`, `lib/session.mjs` | node |
| `test-walkthrough-verify.sh` | `verify.mjs` | node, ffmpeg |
| `test-walkthrough-assemble.sh` | `assemble.mjs` | node, ffmpeg |
| `test-walkthrough-stages.sh` | `build-narration.mjs`, `record-walkthrough.mjs`, `check-prereqs.sh` | node, ffmpeg |
| `test-walkthrough-mutations.sh` | **the four above** | node, ffmpeg, python3 |

No suite needs a browser, a network, an app, or the TTS model. All seven scripts are
covered to the depth stated below.

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

## What these suites do NOT cover — declared, not implied

- **The browser.** `runAction` and the session helpers are driven through a recording stub
  (`lib/stub-page.mjs`). What a real Chromium adds — that a click lands on the pixel the
  cursor was drawn at, that an SPA re-renders the injected cursor, that `recordVideo` starts
  when assumed — is not tested here. The stub is built to fail the way Playwright fails
  (`waitFor` rejects on a hidden element, `boundingBox` resolves to null) so the tests
  measure the subject rather than the stub, but that is a mitigation, not coverage.
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
