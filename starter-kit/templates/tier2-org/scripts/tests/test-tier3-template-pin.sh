#!/usr/bin/env bash
# test-tier3-template-pin.sh — this layer's tier-3 template IS Tier 1's, at the pin, with
# only the org placeholders resolved. Nothing else.
#
# WHY THIS SUITE EXISTS
#   `templates/tier3-instance/` is not something an org layer wrote. It is
#   `starter-kit/new-org-layer.sh`'s OUTPUT, copied in when the layer was minted and never
#   compared since. Tier 1 pins its template against its own output in one run — the only
#   pair its CI can see. A layer minted months ago, in another repo, edited since, is
#   invisible to it. So the check has to live HERE, on the side that drifts.
#
#   ⚠️ Measured on the first layer it was run against (2026-09-01): four of seven files
#   differed, and the drift ran in BOTH directions. One file — the README — was AHEAD of
#   Tier 1, naming a refusal and a converter the template had lost. A check that only ever
#   copies down would have destroyed that silently. If this suite goes red, look at WHICH
#   side is better before regenerating anything.
#
#   The pin is the point. Comparing against Tier 1's `main` would go red every time Tier 1
#   moves, which trains the reader to ignore it. It compares against the commit
#   `org.lock.json` actually declares, so red means THIS layer disagrees with the tree it
#   claims to be built from.
#
# TIER 1 IS SUPPLIED, NEVER FETCHED
#   $DF_T1_DIR, else vendor/dark-factory. This suite does no network I/O: the sibling
#   suites in this directory are network-free by design, and a test that quietly clones is
#   a test whose dependency nobody can see in the workflow that runs it. Wire it in CI with
#   an explicit checkout — see .github/workflows/gate.yml.
#
#   ⚠️ WITHOUT A TIER 1 TREE THE COMPARISON DOES NOT RUN, and this suite says so on its own
#   line rather than reporting a green it did not earn. What it can still check locally, it
#   checks. "Could not compare" and "compared and matched" are different states and are
#   printed as different states.
#
# RUNS IN TWO TREES, deliberately, because this file ships in both:
#   · an org layer (has org.lock.json)        -> the full comparison
#   · Tier 1 itself (has the template)        -> the template-side properties
#   Neither -> exit 2. It branches explicitly rather than skipping, which is the same
#   choice test-repo-shape.sh made next door and for the same reason.
#
# RUN:  bash scripts/tests/test-tier3-template-pin.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# ⚠️ THE TOKEN NAMES ARE BUILT, NEVER WRITTEN WHOLE. This file ships inside the Tier-1
# template that new-org-layer.sh stamps out, and that generator rewrites every occurrence of
# these three tokens in every file it copies — this one included. Written literally, a
# minted layer would receive a suite whose own leftover check looks for the org's own NAME
# instead of a placeholder: passing forever, on every layer, while checking nothing. A
# gate's vocabulary is indistinguishable from a violation. Measured, not theorised — the
# assertion that a minted layer carries this file byte-identical went RED on exactly this.
T_LAYER="__ORG_""LAYER_NAME__"
T_REPO="__ORG_""REPO__"
T_DISPLAY="__ORG_""DISPLAY__"
T_INSTANCE="__INSTANCE_""NAME__"

TPL_REL="starter-kit/templates/tier2-org/templates/tier3-instance"

command -v jq >/dev/null 2>&1 || { echo "test-tier3-template-pin: jq is required"; exit 2; }

echo "test-tier3-template-pin: $REPO"

# ---------------------------------------------------------------------------
# THE TEMPLATE ITSELF — inside Tier 1, this file's repo root is the tier2-org template,
# which HAS an org.lock.json and therefore looks exactly like a layer. It is not one: its
# values are still placeholders. Told apart by reading them rather than by the file's
# presence — the same mistake as reporting an override because a path exists.
# ---------------------------------------------------------------------------
IS_TEMPLATE=0
if [ -f "$REPO/org.lock.json" ]; then
  case "$(jq -r '.orgLayer // ""' "$REPO/org.lock.json" 2>/dev/null)" in
    *__ORG_*) IS_TEMPLATE=1 ;;
  esac
fi
if [ "$IS_TEMPLATE" -eq 1 ] || { [ ! -f "$REPO/org.lock.json" ] && [ -d "$REPO/$TPL_REL" ]; }; then
  echo "  mode: the template itself — asserting the template side, not a layer"
  if [ -d "$REPO/$TPL_REL" ]; then SRC="$REPO/$TPL_REL"; else SRC="$REPO/templates/tier3-instance"; fi
  N="$(find "$SRC" -type f | wc -l | tr -d ' ')"
  [ "$N" -gt 0 ] && pass "S1 the tier-3 template ships files ($N)" || fail "S1 the tier-3 template ships no files"
  if grep -rq "$T_LAYER\|$T_REPO\|$T_DISPLAY" "$SRC" 2>/dev/null; then
    pass "S2 the template still carries its org placeholders"
  else
    fail "S2 the template has no org placeholder left — it has been resolved in place, and every layer minted from it will carry one org's name"
  fi
  if grep -rq "$T_INSTANCE" "$SRC" 2>/dev/null; then
    pass "S3 the template still carries its instance placeholders"
  else
    fail "S3 the instance placeholder is gone — new-instance.sh would have nothing left to fill"
  fi
  # The self-check the RED assertion earned: this file must not contain a literal org token,
  # or the generator will substitute the gate's own vocabulary on the way out.
  # ⚠️ The pattern is the assembled variables, never the literal tokens. Written literally,
  # the grep's own pattern text would be a match inside this very file and S4 would fail
  # forever — measured, on the first run. A self-check has to be spelled in something the
  # thing it checks for cannot contain.
  if grep -q "$T_LAYER\|$T_REPO\|$T_DISPLAY" "$0"; then
    fail "S4 this suite spells an org token literally — the generator will rewrite it and the leftover check will pass forever while checking nothing"
  else
    pass "S4 this suite's own token names survive the generator"
  fi
  echo
  echo "$PASS passed, $FAIL failed"
  echo "ASSERTIONS: $((PASS + FAIL))"
  [ "$FAIL" -eq 0 ]
  exit
fi

# ---------------------------------------------------------------------------
# AN ORG LAYER — the comparison this suite exists for.
# ---------------------------------------------------------------------------
LOCK="$REPO/org.lock.json"
T3="$REPO/templates/tier3-instance"
[ -f "$LOCK" ] || { echo "test-tier3-template-pin: neither an org layer nor a Tier 1 checkout"; exit 2; }
[ -d "$T3" ]   || { echo "test-tier3-template-pin: no templates/tier3-instance"; exit 2; }

PIN="$(jq -r '.upstreams["dark-factory"].commit // empty' "$LOCK")"
LAYER_NAME="$(jq -r '.orgLayer   // empty' "$LOCK")"
ORG_DISPLAY="$(jq -r '.orgDisplay // empty' "$LOCK")"
ORG_REPO="$(jq -r '.repo         // empty' "$LOCK")"
for v in PIN LAYER_NAME ORG_DISPLAY ORG_REPO; do
  eval "val=\${$v}"
  [ -n "$val" ] || { echo "test-tier3-template-pin: org.lock.json has no $v"; exit 2; }
done
echo "  mode: org layer — Tier 1 pin $PIN"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/t3pin.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- local checks, which need nothing but this repo -------------------------
LEFTOVER="$(grep -rl "$T_LAYER\|$T_REPO\|$T_DISPLAY" "$T3" 2>/dev/null | wc -l | tr -d ' ')"
[ "$LEFTOVER" -eq 0 ] && pass "T5 no org placeholder survives in this layer's copy" \
  || fail "T5 $LEFTOVER file(s) still carry an org placeholder — the mint half-ran, and whoever clones this gets a raw placeholder in their own README"
KEPT="$(grep -rl "$T_INSTANCE" "$T3" 2>/dev/null | wc -l | tr -d ' ')"
[ "$KEPT" -gt 0 ] && pass "T6 the instance-level placeholders are still standing ($KEPT files)" \
  || fail "T6 the instance placeholder resolved too early — new-instance.sh has nothing left to fill, and every developer would mint the same instance name"

# --- the comparison, which needs Tier 1 -------------------------------------
T1DIR=""
if [ -n "${DF_T1_DIR:-}" ] && [ -d "${DF_T1_DIR}/.git" ]; then
  T1DIR="$DF_T1_DIR"; SOURCE="DF_T1_DIR"
elif [ -d "$REPO/vendor/dark-factory/.git" ]; then
  T1DIR="$REPO/vendor/dark-factory"; SOURCE="vendor/dark-factory"
fi

# The comparison needs a tree this suite will not fetch, so the wiring that supplies it is
# itself asserted — as CONTENT, in the workflow file, not as a fact about the environment
# the suite happens to be running in. An environment assertion would pass on a laptop and
# fail inside another suite's scratch fixture, which is the "passes only on the machine
# that wrote it" defect this estate has already shipped once.
WF="$REPO/.github/workflows/gate.yml"
if [ -f "$WF" ]; then
  if grep -q "DF_T1_DIR" "$WF"; then
    pass "W1 the CI gate supplies a Tier 1 tree (DF_T1_DIR)"
  else
    fail "W1 .github/workflows/gate.yml does not supply DF_T1_DIR — CI would run the local checks, print COMPARISON NOT RUN, and stay green while the comparison stopped happening"
  fi
  # ⚠️ AND IT MUST LAND OUTSIDE THE WORKSPACE. run-tests.sh enrols a suite by EXISTENCE, so
  # a Tier 1 tree checked out inside the repo is discovered as this repo's own tests.
  # MEASURED once, in CI: 45 suites instead of 3, Tier 1's whole suite run as if it were
  # the layer's — green, and a Tier 1 failure would have reddened this gate for something
  # that is not this repo's.
  if grep -q "runner.temp" "$WF"; then
    pass "W2 the Tier 1 tree lands outside the workspace"
  else
    fail "W2 gate.yml does not fetch Tier 1 into RUNNER_TEMP — a tree inside the workspace is discovered by the suite runner as this repo's own tests"
  fi
fi

if [ -z "$T1DIR" ]; then
  echo "  ⚠️  COMPARISON NOT RUN — no Tier 1 tree. Set DF_T1_DIR or run install.sh first."
  echo "     The local checks above ran. The pinned comparison did NOT, and this line is"
  echo "     here so that is never mistaken for a match."
elif ! git -C "$T1DIR" cat-file -e "$PIN^{commit}" 2>/dev/null; then
  echo "  ⚠️  COMPARISON NOT RUN — $SOURCE does not contain the pinned commit $PIN."
  echo "     Fetch it, or check the pin: a pin no reachable tree contains is a dead pin,"
  echo "     which is a finding in its own right and not something this suite can settle."
else
  echo "  Tier 1 from: $SOURCE"
  mkdir -p "$WORK/tpl"
  git -C "$T1DIR" archive "$PIN" "$TPL_REL" 2>/dev/null | tar -x -C "$WORK/tpl" 2>/dev/null
  SRC="$WORK/tpl/$TPL_REL"
  if [ ! -d "$SRC" ]; then
    fail "T1 the tier-3 template exists at the pin — $TPL_REL is absent at $PIN"
  else
    resolve() {
      sed -e "s|$T_LAYER|$LAYER_NAME|g" \
          -e "s|$T_REPO|$ORG_REPO|g" \
          -e "s|$T_DISPLAY|$ORG_DISPLAY|g" "$1"
    }
    N=0; DRIFT=0; MISSING=0
    while IFS= read -r rel; do
      N=$((N+1))
      if [ ! -f "$T3/$rel" ]; then
        MISSING=$((MISSING+1)); echo "     absent here: $rel"; continue
      fi
      if ! diff -q <(resolve "$SRC/$rel") "$T3/$rel" >/dev/null 2>&1; then
        DRIFT=$((DRIFT+1)); echo "     drift: $rel"
      fi
    done < <(cd "$SRC" && find . -type f | sed -e "s:^\./::" | sort)
    EXTRA=0
    while IFS= read -r rel; do
      [ -f "$SRC/$rel" ] || { EXTRA=$((EXTRA+1)); echo "     not in the template: $rel"; }
    done < <(cd "$T3" && find . -type f | sed -e "s:^\./::" | sort)

    # The oracle needs its own control: a walk that matches nothing compares zero files and
    # reports zero drift, which is green and meaningless.
    [ "$N" -gt 0 ]      && pass "T1 the template at the pin ships files ($N)" || fail "T1 the template at the pin ships no files — every check below would be vacuous"
    [ "$MISSING" -eq 0 ] && pass "T2 every template file exists here" || fail "T2 $MISSING template file(s) missing here"
    [ "$DRIFT"   -eq 0 ] && pass "T3 every file matches the template with only the org placeholders resolved" || fail "T3 $DRIFT file(s) drifted from the pinned template"
    [ "$EXTRA"   -eq 0 ] && pass "T4 nothing here that the template does not ship" || fail "T4 $EXTRA file(s) here that no generator produces"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
