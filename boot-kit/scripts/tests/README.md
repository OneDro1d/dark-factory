# Test suites

Every `test-*.sh` file in this repository is run by
[`../run-tests.sh`](../run-tests.sh), and the gate workflow runs that.

**A suite is enrolled by existing, and must declare what it measured.** There is no list
to add yourself to — commit the file and CI runs it. Four directories currently hold
suites:

- `boot-kit/scripts/tests/` — this one, the engine
- `starter-kit/tests/` — the org layer
- `starter-kit/instance/tests/` — the generated instance's docs
- `starter-kit/instance/boot-kit/tests/` — the instance's boot kit

## Why it works this way

Until 2026-08-26 the workflow named exactly one suite. The other 22 executed only when
somebody typed the path. Nothing would have reported it if one of them had started
failing — the same shape as every other defect this repo keeps finding: a check
maintained by memory, decaying quietly, and green-looking because absence produces no
signal.

The obvious repair — add the missing suites to the workflow — recreates the defect one
step later, because the list is the thing that rots. The ticket that filed this finding
enumerated the suites by hand and got it wrong in both directions: it omitted
`test-skill-frontmatter.sh`, which was on `main`, and counted a suite that existed only
in an unmerged branch. A glob cannot make that mistake.

## Writing a suite

- Resolve your own root from `BASH_SOURCE`; the runner does not set a working directory.
- Exit non-zero on failure. The runner derives its verdict from the tally of child exit
  codes, never from the last one.
- **Print `ASSERTIONS: <n>` — how many assertions you actually executed.** A suite that
  exits 0 without it is reported `UNMEASURED` and counted as a failure; one that declares
  `0` is reported `VACUOUS` and likewise fails. This is the second half of the contract
  and it is not optional. Emit it once, on the path the runner sees; if your suite drives
  sub-suites the LAST line wins.

  The reason it is declared rather than parsed: the suites here print their totals in six
  different formats. A runner that greps for a count would be a hand-written list of
  formats, which rots exactly like the hand-written list of suites the glob replaced —
  and until this existed, a suite that asserted nothing and a suite that asserted 44
  things both rendered as `PASS 0s`. Exit status is a proxy for having-been-checked, and
  a proxy decays without a signal.
- Leave the checkout clean. Build scratch trees under `TMPDIR` and remove them.
- If you drive `run-tests.sh` itself, pass `--root`. Without it, discovery falls back to
  the repo root, which contains your suite, and the run re-enters itself. The runner
  refuses that case rather than looping, and `test-run-tests.sh` asserts it does.

## What a green run does and does not prove

Six suites read the landmark config, and the real `landmarks.conf` is gitignored — so in
CI they run against `landmarks.example.conf` and exercise fewer pattern branches than
they do on a maintainer's machine. They pass in both configurations. A green run means
"no suite regressed under the configuration available", not "this branch is free of real
landmarks". The gate workflow reports which config it used, for the same reason.
