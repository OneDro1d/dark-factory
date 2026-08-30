#!/usr/bin/env bash
# test-lock-verify-l10-skills.sh — the skills directory must be checked in BOTH directions,
# and an undeclared skill must be ATTRIBUTED, not merely counted.
#
# WHY THIS EXISTS. L8 closed the reverse direction for hooks on 2026-08-29 and stopped there.
# Skills kept the identical blind spot for one more day:
#
#     L2   vendor dirs       -> declared?      content, both directions covered
#     L5   declared skills   -> installed?     ONE DIRECTION
#     L8   hooks on machine  -> declared?      the reverse, for hooks
#     ---  skills on machine -> declared?      DID NOT EXIST
#
# Measured 2026-08-30 while retiring the `sc-audit` / `smart-contract-auditor` duplicate:
# dropping the loser from install.skills left ~/.claude/skills/smart-contract-auditor as a
# LIVE SYMLINK into the vendor tree, declared by nothing, and lock-verify printed LOCKED.
# The skill still loads and still fires on its triggers. Case A1 below is that exact state.
#
# THE SECOND CONTRACT, AND THE ONE L8 CANNOT MEET. Hooks are COPIED, so nothing on disk
# records a hook's provenance and L8 can only print a set difference. Skills are installed
# as SYMLINKS, so an undeclared skill still carries where it came from — and the three ways
# it can be undeclared want three different remedies:
#
#   ORPHANED   resolves into THIS instance's vendor/ or repo -> declare it or unlink it
#   FOREIGN    resolves elsewhere; $LIVE is shared, another instance may own it -> read its lock
#   OPAQUE     a real directory, not a symlink; no provenance exists -> the L8 situation
#
# Collapsing those into one "undeclared" bucket is what makes a finding into noise, so the
# classification is under test, not just the detection. B-series proves a foreign skill is
# not reported as this instance's, which is the assertion that would fail if the ownership
# prefixes were ever compared loosely.
#
# THE CONTRACT UNDER TEST IS THAT THE LAYER CAN FAIL. A layer that cannot fail is the exact
# defect it exists to fix — verify-kit passed for weeks with 15 mandated skills gone. Every
# case is paired: a fixture that MUST drift and a control that MUST NOT, on the same
# machinery. Assertions read the [L10] block, never the exit code — a scratch instance
# drifts on L3/L6 by design (nothing vendored), so a suite keyed on rc would measure that
# instead. Same discipline as test-lock-verify-l8-l9-hooks.sh.
#
# RED BASELINE, MEASURED: 23 of 31 fail against the pre-L10 script (origin/main at c073f54),
# 31 pass after. The other 8 pass VACUOUSLY when the layer does not exist — they are
# `absent` assertions, and an empty block contains nothing, so they cannot distinguish
# "not reported" from "no layer ran". They are kept because after the fix they are the
# over-correction guards, and they are named here so nobody reads 8/31 green on an unfixed
# tree as partial coverage: A1-e, A2-b, B1-d, D1-b, D1-c, D1-d, D2-b, D3-b.
#
# Reproduce the baseline:
#   git show <pre-L10-sha>:boot-kit/scripts/lock-verify.sh > /tmp/lv-old.sh
#   LOCK_VERIFY=/tmp/lv-old.sh bash boot-kit/scripts/tests/test-lock-verify-l10-skills.sh
#
# Usage: bash boot-kit/scripts/tests/test-lock-verify-l10-skills.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
LV="${LOCK_VERIFY:-$SCRIPTS/lock-verify.sh}"
[ -f "$LV" ] || { echo "missing $LV"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in block" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in block" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lvl10.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A tree OUTSIDE every fixture instance, standing in for another instance sharing $LIVE.
# It must not be under any case directory, or the ownership test would be measuring the
# temp-dir layout rather than the rule.
mkdir -p "$WORK/other-instance/vendor/pkg/skills/foreign-skill"

# mk <case> <install-json> — a lockfile, its own private $LIVE, a vendor tree, and the
# install.sh marker that makes REPO resolve to the case root (the same walk-up rule
# `local:` sources depend on). Each case gets an ISOLATED LOOM_LIVE: pointing them at one
# shared directory is how the L8 suite's first draft made cases pass by contaminating
# each other.
mk() {
  mkdir -p "$WORK/$1/live/skills" "$WORK/$1/vendor/pkg/skills" "$WORK/$1/local-skills"
  printf '#!/bin/sh\nexit 0\n' > "$WORK/$1/install.sh"
  jq -n --argjson inst "$2" '{vendorDir:"vendor",upstreams:{},install:$inst}' \
    > "$WORK/$1/loom.lock.json"
}
# vendored <case> <name> — content in this instance's vendor cache
vendored() { mkdir -p "$WORK/$1/vendor/pkg/skills/$2"; printf 'x\n' > "$WORK/$1/vendor/pkg/skills/$2/SKILL.md"; }
# localskill <case> <name> — content in this instance's repo, the `local:` case
localskill() { mkdir -p "$WORK/$1/local-skills/$2"; printf 'x\n' > "$WORK/$1/local-skills/$2/SKILL.md"; }
# link <case> <name> <target> — install it the way install.sh does
link() { ln -sfn "$3" "$WORK/$1/live/skills/$2"; }
# realdir <case> <name> — hand-copied content, no symlink, no provenance
realdir() { mkdir -p "$WORK/$1/live/skills/$2"; printf 'x\n' > "$WORK/$1/live/skills/$2/SKILL.md"; }

# run <case> — echo just the [L10] block
run() {
  ( cd "$WORK/$1" && LOOM_LIVE="$WORK/$1/live" bash "$LV" --lock=loom.lock.json 2>&1 ) \
    | sed -n "/^\[L10\]/,/^$/p"
}

DECL='{"skills":["kept"],"skillSources":{"kept":"upstream:pkg/skills/kept"},"hooks":[],"hookSources":{}}'
NONE='{"skills":[],"skillSources":{},"hooks":[],"hookSources":{}}'

echo "=== L10-A: ORPHANED — resolves into this instance, declared by nothing ==="

# A1 — the measured defect, reproduced: undeclare a skill, leave the symlink.
mk a1 "$DECL"
vendored a1 kept
vendored a1 smart-contract-auditor
link a1 kept "$WORK/a1/vendor/pkg/skills/kept"
link a1 smart-contract-auditor "$WORK/a1/vendor/pkg/skills/smart-contract-auditor"
O="$(run a1)"
contains "A1 undeclared skill is reported"              "smart-contract-auditor" "$O"
contains "A1 undeclared skill is DRIFT"                 "DRIFT"                  "$O"
contains "A1 classified as resolving INTO this instance" "resolves INTO"         "$O"
contains "A1 the remedy is named"                       "install.skillSources"   "$O"
absent   "A1 the declared skill is not reported"        "kept ->"                "$O"

# A2 — control: same tree, the skill declared. The layer must go quiet.
mk a2 '{"skills":["kept","smart-contract-auditor"],"skillSources":{"kept":"upstream:pkg/skills/kept","smart-contract-auditor":"upstream:pkg/skills/smart-contract-auditor"},"hooks":[],"hookSources":{}}'
vendored a2 kept
vendored a2 smart-contract-auditor
link a2 kept "$WORK/a2/vendor/pkg/skills/kept"
link a2 smart-contract-auditor "$WORK/a2/vendor/pkg/skills/smart-contract-auditor"
O="$(run a2)"
contains "A2 declaring it clears the finding"           "PASS"                   "$O"
absent   "A2 nothing is reported"                       "DRIFT"                  "$O"

# A3 — a `local:` skill in the repo, not the vendor cache. REPO is found by walking up to
# install.sh, so this is the ownership path a vendor-only prefix test would miss.
mk a3 "$NONE"
localskill a3 house-rule
link a3 house-rule "$WORK/a3/local-skills/house-rule"
O="$(run a3)"
contains "A3 repo-owned skill counts as this instance's" "resolves INTO"         "$O"
contains "A3 named"                                      "house-rule"            "$O"

# A4 — a symlink whose target is gone. Undeclared AND broken; it must not vanish from the
# report just because it resolves to nothing.
mk a4 "$NONE"
link a4 ghost "$WORK/a4/vendor/pkg/skills/never-existed"
O="$(run a4)"
contains "A4 dangling symlink is reported"              "ghost"                  "$O"
contains "A4 dangling symlink is named as such"         "dangling symlink"       "$O"
contains "A4 dangling symlink is DRIFT"                 "DRIFT"                  "$O"

echo "=== L10-B: FOREIGN — \$LIVE is shared, and that is not automatically a defect ==="

# B1 — another instance's skill in the shared $LIVE. Reported, but NOT as ours: the note
# must tell the reader to check that instance's lock before deleting.
mk b1 "$NONE"
link b1 foreign-skill "$WORK/other-instance/vendor/pkg/skills/foreign-skill"
O="$(run b1)"
contains "B1 foreign skill is reported"                 "foreign-skill"          "$O"
contains "B1 classified as OUTSIDE this instance"       "resolving OUTSIDE"      "$O"
contains "B1 the shared-\$LIVE caveat survives"          "shared by every instance" "$O"
absent   "B1 NOT misreported as this instance's"        "resolves INTO"          "$O"

echo "=== L10-C: OPAQUE — hand-copied, the limit L8 lives with ==="

# C1 — a real directory. No symlink means no provenance, so the layer must say it cannot
# attribute rather than guessing.
mk c1 "$NONE"
realdir c1 hand-copied
O="$(run c1)"
contains "C1 real directory is reported"                "hand-copied"            "$O"
contains "C1 classified as not-a-symlink"               "not a symlink"          "$O"
contains "C1 admits it cannot attribute"                "cannot say whose it is" "$O"

echo "=== L10-D: the denominator, and the empty cases ==="

# D1 — backups and dotfiles are excluded, COUNTED, and named by pattern. A skipped file
# that is never counted is how a real finding gets buried: the reference laptop carried 12
# backups beside 16 real hooks.
mk d1 "$NONE"
realdir d1 real-one
mkdir -p "$WORK/d1/live/skills/old.retired-20260101"
mkdir -p "$WORK/d1/live/skills/.DS_Store_dir"
printf 'x\n' > "$WORK/d1/live/skills/notes.bak"
O="$(run d1)"
contains "D1 the real entry is still reported"          "real-one"               "$O"
absent   "D1 .retired- is not reported"                 "old.retired-20260101"   "$O"
absent   "D1 dotfile is not reported"                   ".DS_Store_dir"          "$O"
absent   "D1 .bak is not reported"                      "notes.bak"              "$O"
contains "D1 the skipped count is disclosed"            "skipped 3"              "$O"

# D2 — no skills directory at all. A fact, not a claim, and worded so a reader grepping
# for the pass sentence can tell the check ran from the check being vacuous.
mk d2 "$NONE"
rmdir "$WORK/d2/live/skills"
O="$(run d2)"
contains "D2 absent skills dir is a stated non-check"   "nothing to check"       "$O"
absent   "D2 absent skills dir is not DRIFT"            "DRIFT"                  "$O"

# D3 — an empty skills directory passes with a zero count, and says so.
mk d3 "$NONE"
O="$(run d3)"
contains "D3 empty skills dir passes"                   "PASS"                   "$O"
absent   "D3 empty skills dir is not DRIFT"             "DRIFT"                  "$O"

# D4 — all three classes at once. They must be reported as three findings, because they
# have three remedies; one merged bucket is the failure this classification exists to stop.
mk d4 "$NONE"
vendored d4 mine
link d4 mine "$WORK/d4/vendor/pkg/skills/mine"
link d4 theirs "$WORK/other-instance/vendor/pkg/skills/foreign-skill"
realdir d4 copied
O="$(run d4)"
contains "D4 orphan class present"                      "resolves INTO"          "$O"
contains "D4 foreign class present"                     "resolving OUTSIDE"      "$O"
contains "D4 opaque class present"                      "not a symlink"          "$O"

echo ""
printf 'L10 skills-direction: %d ok, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
