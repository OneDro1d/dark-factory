#!/usr/bin/env bash
# test-repo-shape.sh — the structural invariants of this org layer, asserted rather than
# assumed. Network-free, writes nothing outside $TMPDIR, exits non-zero on any failure.
#
# WHY THIS SUITE EXISTS, and what it is honestly NOT
#   This repo is the Tier 2 org layer for the whole OneDroid fleet: `org.lock.json` is the
#   register that decides what every minted Tier 3 instance installs, and
#   `scripts/new-instance.sh` stamps `templates/tier3-instance/` out verbatim. Until the
#   change that added this file the repo had no `.github/` at all, so nothing here was
#   checked by anything except a human remembering to look.
#
#   ⚠️ Every assertion below is GREEN on the tree it was written against. None of them is
#   a defect assertion in the RED-first sense, and pretending otherwise would be the
#   dishonest kind of green. They are STRUCTURAL GUARDS: each one names a way this repo
#   could stop being a valid org layer without anything saying so. Their value is measured
#   the first time one goes RED, not today. The deliberately-broken control run recorded
#   on the ticket that added them is the evidence that they CAN go red — a gate that has
#   only ever been seen passing is not known to work.
#
#   This file is shipped in TWO places and is byte-identical in both: here, in the org
#   layer, and inside Tier 1 at `starter-kit/templates/tier2-org/scripts/tests/`, from
#   which every future org layer is minted. Keeping one text means `diff` is the check;
#   the only assertion that has to know which tree it is on is A3, and it branches
#   explicitly rather than skipping.
#
#   Deliberately NOT asserted here:
#     · the internal shape of `install.skills` / `install.hooks` — that is
#       `test-lock-shape.sh`'s subject, and duplicating it would give two files one owner.
#     · whether the Tier 1 pin is CURRENT — that needs the network. This suite asserts the
#       pin is a resolved SHA, which is a purely local property; currency is a different
#       check with a different failure mode.
#
# RUN:  bash scripts/tests/test-repo-shape.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "test-repo-shape: jq is required"; exit 2; }

echo "test-repo-shape: $REPO"

# --- A1..A3  the org lockfile --------------------------------------------------------
LOCK="$REPO/org.lock.json"
if [ -f "$LOCK" ]; then pass "A1a org.lock.json exists"; else fail "A1a org.lock.json is missing"; fi
if jq -e . "$LOCK" >/dev/null 2>&1; then pass "A1b org.lock.json is valid JSON"
else fail "A1b org.lock.json does not parse"; fi

for k in orgLayer repo vendorDir upstreams install notRestorable; do
  if jq -e --arg k "$k" 'has($k)' "$LOCK" >/dev/null 2>&1; then pass "A2 org.lock.json has .$k"
  else fail "A2 org.lock.json is missing top-level .$k"; fi
done

# A3 — TWO STATES, and each gets a positive assertion. This same file ships inside Tier 1
# at `starter-kit/templates/tier2-org/`, where it is discovered and run by Tier 1's own
# runner against the UN-MINTED template. A branch that merely SKIPPED that case would be an
# unmeasured row reported as a pass, so both states assert something:
#
#   TEMPLATE  — `new-org-layer.sh` has not run yet. Assert the placeholders are intact and
#     CONSISTENT. A resolved value committed back over the template is the same hazard as
#     A8 one tier up: every layer minted afterwards is frozen on one person's pin, and the
#     tree still parses and still installs.
#   MINTED    — assert the pin is a resolved 40-hex SHA, never a branch name.
#     `new-org-layer.sh` falls back to writing the BRANCH NAME when it cannot reach GitHub
#     and says so at generation time, but that message scrolls past while the lockfile keeps
#     working — and upstream then moves under every install, silently.
#
# ⚠️ THE STATE IS DETECTED BY A GLOB, NEVER BY THE LITERAL PLACEHOLDER TEXT, and that is
#    not a style choice. `new-org-layer.sh` substitutes placeholders with
#    `find "$TARGET" -type f | xargs sed -i` — over EVERY file it copies, which now includes
#    this one. A test that compares the pin against the placeholder token LITERALLY has its
#    own comparison string
#    rewritten to the minted SHA, so on a minted layer the test compares the pin against
#    itself, takes the TEMPLATE branch, and passes without ever checking that the pin is a
#    SHA. Measured: the first version of this file did exactly that and reported
#    "16 passed, 0 failed" on a minted layer while A3 was inert. The generator rewrites the
#    test that guards it — a probe must not share a channel with its subject. `__*__` is a
#    shell glob; sed's fixed-string patterns cannot match it.
ORGLAYER="$(jq -r '.orgLayer // ""' "$LOCK" 2>/dev/null)"
T1REF="$(jq -r '.upstreams["dark-factory"].commit // .upstreams["dark-factory"].ref // ""' "$LOCK" 2>/dev/null)"
case "$ORGLAYER" in
  __*__)
    echo "  --   A3 tree is the UN-MINTED template (.orgLayer is still a placeholder) — asserting placeholders instead"
    case "$T1REF" in
      __*__) pass "A3t template placeholders are intact and consistent (.orgLayer and the Tier 1 pin are both unsubstituted)" ;;
      "")    fail "A3t template has .orgLayer unsubstituted but NO Tier 1 pin at all" ;;
      *)     fail "A3t template has an unsubstituted .orgLayer but a RESOLVED Tier 1 pin ('$T1REF') — a real lockfile may have been committed over the template" ;;
    esac
    ;;
  *)
    case "$T1REF" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        pass "A3 Tier 1 pin is a resolved 40-hex SHA" ;;
      "")     fail "A3 no Tier 1 pin found under .upstreams[dark-factory]" ;;
      __*__)  fail "A3 Tier 1 pin is still a placeholder in a MINTED layer ('$T1REF') — new-org-layer.sh did not substitute it" ;;
      *)      fail "A3 Tier 1 pin is not a 40-hex SHA: '$T1REF' — new-org-layer.sh's UNRESOLVED fallback writes a branch name here" ;;
    esac
    ;;
esac

# --- A4..A6  the files a mint depends on ---------------------------------------------
for rel in install.sh scripts/new-instance.sh templates/tier3-instance/install.sh; do
  if [ -s "$REPO/$rel" ]; then pass "A4 $rel is present and non-empty"
  else fail "A4 $rel is missing or empty"; fi
done

# --- A7..A8  the tier-3 template ------------------------------------------------------
T3LOCK="$REPO/templates/tier3-instance/instance.lock.json"
if jq -e . "$T3LOCK" >/dev/null 2>&1; then pass "A7 tier3 instance.lock.json is valid JSON"
else fail "A7 tier3 instance.lock.json does not parse"; fi

# A8 — the template must still carry its PLACEHOLDERS. `scripts/new-instance.sh`
# substitutes `__T2_REF__` at mint time. If someone commits a real instance's resolved
# lockfile back over the template, every instance minted afterwards is frozen on one
# developer's pin and nothing reports it — the template still parses and still installs.
if grep -q '__T2_REF__' "$T3LOCK" 2>/dev/null; then
  pass "A8 tier3 template still carries __T2_REF__ (not a baked pin)"
else
  fail "A8 tier3 template has no __T2_REF__ — a resolved lockfile may have been committed over the template"
fi

# --- A9  the gate and its runner are one pair ----------------------------------------
# The half-move is the failure this catches: rename or relocate the runner, leave the
# workflow naming the old path, and CI fails loudly — but rename the runner and update
# only the workflow, and the suite that proves the repo's shape stops being discovered.
# Assert every `bash <path>` the workflow invokes actually resolves in this checkout.
WF="$REPO/.github/workflows/gate.yml"
if [ -f "$WF" ]; then
  pass "A9a .github/workflows/gate.yml exists"
  refs="$(grep -oE 'bash [A-Za-z0-9_./-]+\.sh' "$WF" | awk '{print $2}' | sort -u)"
  if [ -z "$refs" ]; then
    fail "A9b gate.yml invokes no shell script — the gate runs nothing"
  else
    missing=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ -f "$REPO/$p" ] || missing="$missing $p"
    done <<EOF
$refs
EOF
    if [ -z "$missing" ]; then pass "A9b every script gate.yml invokes exists:$(printf ' %s' $refs)"
    else fail "A9b gate.yml invokes paths that do not exist:$missing"; fi
  fi
else
  fail "A9a .github/workflows/gate.yml is missing — this repo has no CI"
fi

echo
echo "=== test-repo-shape: $PASS passed, $FAIL failed ==="

# The assertion-count contract read by run-tests.sh (see its header). Exit status alone
# cannot tell "asserted every case below" from "asserted nothing" — both exit 0 — so the
# count is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
