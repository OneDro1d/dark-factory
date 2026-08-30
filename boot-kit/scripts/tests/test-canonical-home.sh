#!/usr/bin/env bash
# test-canonical-home.sh — the canonical-home gate must be able to FAIL.
#
# WHY THIS IS A SUITE AND NOT A NAMED CI STEP. `tests/README.md` says a suite is enrolled
# by EXISTING, and explains that the hand-maintained list of checks is the thing that rots —
# until 2026-08-26 the workflow named one suite and the other 22 ran only when somebody
# typed the path. A named step for this gate would recreate exactly that. So it enrols by
# glob like everything else.
#
# WHAT IT PROTECTS. `canonical-home.py` enforces "one artifact, one home" — a rule the
# reference estate agreed in writing THREE times (2026-06-22, 2026-08-02, 2026-08-03) and
# drifted from after each one, ending with twelve skills installed where three would do. The
# gate is the fourth attempt, expressed as something that fails instead of something that is
# read. That only holds while the gate can still fail.
#
# The estate has already shipped a gate that could not: `publish-gate.sh` reported CLEAN on
# a planted canary with three separate bugs behind it, and the lesson recorded at the time —
# "a gate that cannot fail is worse than none, it suppresses the caution its absence would
# prompt" — is the whole reason this file exists.
#
# The gate's own `--self-test` plants the canary and asserts both directions. This suite
# runs it and adds the assertions a self-test cannot make about itself: that the canary is
# genuinely load-bearing, and that the exit codes are distinct.
#
# Usage: bash boot-kit/scripts/tests/test-canonical-home.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
GATE="${CANONICAL_HOME:-$SCRIPTS/canonical-home.py}"
[ -f "$GATE" ] || { echo "missing $GATE"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/canon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. the gate's own canary ------------------------------------------------
OUT="$(python3 "$GATE" --self-test 2>&1)"
RC=$?
contains "S1 self-test reports PASS"                "SELFTEST PASS"   "$OUT"
# The canary header proves the planted case actually RAN; the failure string proves it was
# caught, so it must be ABSENT. Asserting on the failure string being present was the first
# draft's mistake — it would have passed only when the gate was broken.
contains "S1 the canary case ran"                   "--- canary:"     "$OUT"
absent   "S1 the canary was caught"                 "WAS NOT CAUGHT"  "$OUT"
if [ "$RC" -eq 0 ]; then ok "S1 self-test exits 0"; else bad "S1 self-test exits 0" "got $RC"; fi

# ---- 2. exit codes are distinct ---------------------------------------------
# A gate whose failure and success both exit 0 is unusable in CI, and that is not
# something the self-test can assert about itself from the inside.
mk() { # mk <file> <json>
  printf '%s' "$2" > "$WORK/$1"
}
mk clean-a.json '{"instance":"a","install":{"skills":["x"],"skillSources":{"x":"up/skills/x"}}}'
mk clean-b.json '{"instance":"b","install":{"skills":["x"],"skillSources":{"x":"up/skills/x"}}}'
mk dirty-b.json '{"instance":"b","install":{"skills":["x"],"skillSources":{"x":"other/skills/x"}}}'

python3 "$GATE" "$WORK/clean-a.json" "$WORK/clean-b.json" >/dev/null 2>&1
RC_CLEAN=$?
python3 "$GATE" "$WORK/clean-a.json" "$WORK/dirty-b.json" >/dev/null 2>&1
RC_DIRTY=$?
if [ "$RC_CLEAN" -eq 0 ]; then ok "S2 same supplier in two instances exits 0"; else bad "S2 same supplier exits 0" "got $RC_CLEAN"; fi
if [ "$RC_DIRTY" -eq 1 ]; then ok "S2 two suppliers exits 1"; else bad "S2 two suppliers exits 1" "got $RC_DIRTY"; fi

# ---- 3. the over-correction guard, which is the one that nearly shipped wrong -
# Two INSTANCES installing the same skill from the same repo is the tier model working
# exactly as designed — instances compose, they do not own. The first draft of this gate
# keyed on the instance label and would have fired on every shared skill on the fleet. A
# gate whose findings are all false gets turned off within a week, so this case matters
# more than the failure case.
OUT="$(python3 "$GATE" "$WORK/clean-a.json" "$WORK/clean-b.json" 2>&1)"
absent   "S3 instances composing the same skill is NOT a finding" "FAIL  D1" "$OUT"
contains "S3 and it says how many it checked"                     "PASS  D1" "$OUT"

# ---- 3b. `local:` resolves to the REPO, not to the instance ------------------
# The second over-correction, and it produced SIX false findings out of seven on the first
# real cross-estate run. An org layer OWNS a skill (`local:skills/x`) and an instance
# VENDORS that same file by the layer's name (`the-layer/skills/x`). One source, one home.
# Reporting it as two accuses the tier model of the defect it exists to prevent — and six
# false findings in a seven-finding report is a gate nobody reads a second time.
mk org.json  '{"repo":"org/the-layer","install":{"skills":["x"],"skillSources":{"x":"local:skills/x"}}}'
mk inst.json '{"instance":"m1","install":{"skills":["x"],"skillSources":{"x":"the-layer/skills/x"}}}'
OUT="$(python3 "$GATE" "$WORK/org.json" "$WORK/inst.json" 2>&1)"
absent   "S3b layer-owns + instance-vendors is ONE home"    "FAIL  D1" "$OUT"

# ...and the real fork it must STILL catch: a different repo owning the same name locally.
# Without this, the fix above could have been "never report local:" — which would have
# silenced the one genuine finding the real run surfaced.
mk fork.json '{"repo":"org/other-repo","install":{"skills":["x"],"skillSources":{"x":"local:skills/x"}}}'
OUT="$(python3 "$GATE" "$WORK/org.json" "$WORK/fork.json" 2>&1)"
contains "S3b a second repo owning it locally IS two homes" "FAIL  D1" "$OUT"

# ---- 4. the old MAP lockfile shape must be SEEN, not read as empty -----------
# A lockfile in the shape the installers refuse still declares intent. Reporting "0 skills"
# for it would render a broken record as a clean one.
mk map-a.json '{"instance":"m","install":{"skills":{"x":"up/skills/x"}}}'
OUT="$(python3 "$GATE" "$WORK/map-a.json" 2>&1)"
absent   "S4 a MAP-shaped lockfile does not read as empty" "skills    : 0" "$OUT"

# ---- 5. the overlap metric itself, which shipped WRONG and produced a wrong remedy ----
# Measured 2026-08-30 on a real pair. `trilix-cold-start-generator` scored 4/32 against its
# Tier-1 namesake and the gate said "UNRELATED — rename". Both halves were artefacts of the
# metric:
#
#   a) the Tier-1 skill EMBEDS the documents it generates as fenced templates, so 12 of its
#      32 "headings" were its OUTPUT, not its structure — they inflate the denominator and
#      can never match a variant whose generated templates differ;
#   b) the variant inserts one step, so `Step 2: Generate CLAUDE.md` became `Step 3: …` and
#      exact string matching called every later section different.
#
# Corrected, the same pair reads 9/14 = 64% — a fork. And the wrong verdict was not merely
# imprecise: RENAME was proposed for two skills whose trigger phrases are byte-identical,
# which is the `sc-audit` / `smart-contract-auditor` defect that a whole PR was spent
# retiring. Renaming cannot change which sentences match.
mkskill() { # mkskill <root> <name> <desc> <body>
  mkdir -p "$WORK/$1/$2"
  printf -- '---\nname: %s\ndescription: %s\n---\n\n%s\n' "$2" "$3" "$4" > "$WORK/$1/$2/SKILL.md"
}

# A parent whose headings are mostly inside a fenced template it generates.
mkskill roots gen 'Generates docs. Triggers on "bootstrap", "cold start".' \
'## When to Use
## Analysis Process
### Step 1: Recon
### Step 2: Generate CLAUDE.md

```markdown
# CLAUDE.md
## Project Overview
## Architecture
## Testing
## Deployment
```

### Step 3: Validate'
# The variant: same shape, one step inserted, so every later ordinal shifts.
mkskill roots org-gen 'Generates docs for Org. Triggers on "bootstrap", "cold start".' \
'## When to Use
## Analysis Process
### Step 1: Recon
### Step 2: Check House Rules
### Step 3: Generate CLAUDE.md
### Step 4: Validate'

mk ov.json '{"instance":"m","install":{"skills":["gen","org-gen"],"skillSources":{"gen":"up/skills/gen","org-gen":"local:skills/org-gen"}}}'
OUT="$(python3 "$GATE" "$WORK/ov.json" --skills-root r="$WORK/roots" 2>&1)"
# The parent has 5 real headings and 5 more inside the fenced CLAUDE.md template. A
# denominator of 5 is therefore the proof that the fence was stripped; 10 would mean it
# was not, and would drag the percentage to half of the truth.
contains "S5 fenced template headings are excluded from the denominator" "5/5 headings" "$OUT"
contains "S5 renumbered sections still match — verdict is FORK"  "FORK — strip to a delta" "$OUT"
# Assert on the VERDICT text, not the bare word: "UNRELATED" also appears in the standing
# legend below the table, so an `absent` on the word alone fails against correct output.
# That is the same over-broad-assertion mistake this suite's S1 comment already records.
absent   "S5 the fork is NOT given the rename verdict"  "UNRELATED — rename" "$OUT"

# ---- 6. a rename is never proposed over a shared trigger set ------------------
# Structure may genuinely say "unrelated". Triggers can still say "they collide anyway",
# and then RENAME is a remedy that cannot touch the defect. This pair shares no heading at
# all and every trigger phrase.
mkskill roots2 alpha 'Does alpha. Triggers on "run the thing", "do it".' \
'## Purpose
## Steps'
mkskill roots2 org-alpha 'Does org alpha. Triggers on "run the thing", "do it".' \
'## Completely
## Different
## Structure'
mk trig.json '{"instance":"m","install":{"skills":["alpha","org-alpha"],"skillSources":{"alpha":"up/skills/alpha","org-alpha":"local:skills/org-alpha"}}}'
OUT="$(python3 "$GATE" "$WORK/trig.json" --skills-root r="$WORK/roots2" 2>&1)"
contains "S6 a trigger collision is named"                 "TRIGGER COLLISION" "$OUT"
contains "S6 it says rename does not fix it"               "rename does NOT fix" "$OUT"
contains "S6 the shared phrases are printed for the reader" "shared triggers:"  "$OUT"

# CONTROL — genuinely unrelated, and NO shared triggers. This must still say rename, or the
# fix above has simply deleted the unrelated verdict rather than narrowing it.
mkskill roots3 beta 'Does beta. Triggers on "beta phrase".' \
'## Purpose
## Steps'
mkskill roots3 org-beta 'Does org beta. Triggers on "totally other phrase".' \
'## Completely
## Different
## Structure'
mk notrig.json '{"instance":"m","install":{"skills":["beta","org-beta"],"skillSources":{"beta":"up/skills/beta","org-beta":"local:skills/org-beta"}}}'
OUT="$(python3 "$GATE" "$WORK/notrig.json" --skills-root r="$WORK/roots3" 2>&1)"
contains "S6 control: no shared triggers still yields rename" "UNRELATED — rename" "$OUT"
absent   "S6 control: not reported as a trigger collision"    "TRIGGER COLLISION"  "$OUT"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
