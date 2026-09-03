#!/usr/bin/env bash
# test-lock-verify-l8-l9-hooks.sh — the hook directory must be checked in BOTH directions,
# and a declared hook must be on duty, not merely on disk.
#
# Case D15 names this estate's engram hooks as its substring fixture, because a trap fixture
# built from a placeholder proves nothing about the collision that actually happened. Engram
# is the memory store those hooks serve; what it is and how to reach it is documented in
# exactly one place: [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
#
# WHY THIS EXISTS. L2 asks "is every vendored dir declared?" and catches unprovenanced
# content. Nothing asked the same question of $LIVE/hooks. So a hook could be hand-copied
# onto a machine, hand-wired into settings.json, work perfectly for months, and appear in no
# lockfile — installed by nothing, restored by nothing, and reported by nothing.
#
# Measured across the reference estate on 2026-08-28/29, four machines: every one of the five
# instance records declared THE SAME FIVE HOOKS, exactly this repo's own hooks/ set.
# Everything a human added since was undeclared — 13 on the laptop, 8 / 10 / 7 on the three
# workspaces, and on the laptop 3 of the 4 SessionStart entries, including the one supplying
# the agent's identity. L1..L7 printed LOCKED throughout.
#
# The second half is worse because it looks fine. install.sh COPIES hooks and never touches
# settings.json, so a hook can be declared, installed, hash-verified and INERT. That was hit
# twice in one day on two workspaces: hook present, gate green, behaviour absent.
#
# THE CONTRACT UNDER TEST IS THAT EACH LAYER CAN FAIL. A layer that cannot fail is the exact
# defect this pair exists to fix — verify-kit passed for weeks with 15 mandated skills gone.
# So every case below is paired: a fixture that MUST drift and a control that MUST NOT, on
# the same machinery. The assertions read the [L8]/[L9] blocks, never the exit code — a
# scratch instance drifts on L3/L6 by design (nothing vendored), so a suite keyed on rc
# would be measuring that instead. Same discipline as test-lock-verify-l7-shape.sh.
#
# RED BASELINE: 15 of 24 fail against the unfixed script, 24 pass after. The other 9 pass
# VACUOUSLY when the layers do not exist — they are `absent` assertions, and an empty block
# contains nothing, so they cannot distinguish "no drift" from "no layer". They are kept
# because after the fix they are the over-correction guards (C1, C2, D4, D6, D8, D9-a), and
# they are named here so nobody reads 9/24 green on an unfixed tree as partial coverage.
#
# Usage: bash boot-kit/scripts/tests/test-lock-verify-l8-l9-hooks.sh
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lvl89.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# mk <case> <install-json> — a lockfile plus its own private $LIVE tree.
# Each case gets an ISOLATED LOOM_LIVE. Pointing them at one shared directory is how the
# first draft made two cases pass by contaminating each other.
mk() {
  mkdir -p "$WORK/$1" "$WORK/$1/live/hooks"
  jq -n --argjson inst "$2" '{vendorDir:"vendor",upstreams:{},install:$inst}' \
    > "$WORK/$1/loom.lock.json"
}
hook()     { printf '#!/bin/sh\nexit 0\n' > "$WORK/$1/live/hooks/$2"; chmod +x "$WORK/$1/live/hooks/$2"; }
settings() { printf '%s\n' "$3" > "$WORK/$1/live/$2"; }

# run <case> <layer-tag> — echo just that layer's block
run() {
  ( cd "$WORK/$1" && LOOM_LIVE="$WORK/$1/live" bash "$LV" --lock=loom.lock.json 2>&1 ) \
    | sed -n "/^\[$2\]/,/^$/p"
}

WIRED_A='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"'"$WORK"'/CASE/live/hooks/a.sh"}]}]}}'

echo "=== L8: the reverse direction for hooks ==="

# D1 — the defect itself: a hook on disk that the lock does not name.
mk d1 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
hook d1 a.sh
hook d1 rogue.sh
settings d1 settings.json "${WIRED_A//CASE/d1}"
O="$(run d1 L8)"
contains "D1 undeclared hook is reported"        "rogue.sh"        "$O"
contains "D1 undeclared hook is DRIFT"           "DRIFT"           "$O"
absent   "D1 the declared hook is not accused"   " a.sh"           "$O"

# C1 — the control. Same machinery, nothing undeclared. MUST NOT drift on L8.
mk c1 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
hook c1 a.sh
settings c1 settings.json "${WIRED_A//CASE/c1}"
O="$(run c1 L8)"
absent   "C1 clean hook dir does not drift on L8" "DRIFT"          "$O"
contains "C1 says how many it checked"            "PASS"           "$O"

# D2 — backups are skipped but COUNTED. Silently dropping them would let a real hook hide
# behind a naming accident, and would make the denominator unauditable. The reference
# laptop carried 20 such files beside 16 real hooks.
mk d2 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
hook d2 a.sh
hook d2 a.sh.bak.20260802
hook d2 old.sh.retired-2026-06-02
settings d2 settings.json "${WIRED_A//CASE/d2}"
O="$(run d2 L8)"
absent   "D2 a .bak is not called an undeclared hook"      "a.sh.bak" "$O"
absent   "D2 a .retired- is not called an undeclared hook" "old.sh"   "$O"
contains "D2 but the skip count is stated"                 "skipped 2 non-hook" "$O"

# D3 — a hook DIRECTORY (a plugin's hook suite) counts. agent-notepad and handoff-auto are
# directories on the reference laptop and were two of the thirteen findings.
mk d3 '{"skills":[],"skillSources":{},"hooks":[],"hookSources":{}}'
mkdir -p "$WORK/d3/live/hooks/some-plugin"
settings d3 settings.json '{"hooks":{}}'
O="$(run d3 L8)"
contains "D3 an undeclared hook DIRECTORY is reported"     "some-plugin" "$O"

# D3b — but a directory whose CONTENTS are declared is NOT undeclared. A plugin hook suite
# is declared under nested names and the parent dir is never itself a lockfile entry.
# Found by declaring a real one: all five hooks correctly declared, the directory still
# reported, and a finding that cannot be resolved is a finding people learn to skip.
mk d3b '{"skills":[],"skillSources":{},"hooks":["suite/hooks/a.sh"],"hookSources":{"suite/hooks/a.sh":"upstream:x/hooks/a.sh"}}'
mkdir -p "$WORK/d3b/live/hooks/suite/hooks"
printf '#!/bin/sh\nexit 0\n' > "$WORK/d3b/live/hooks/suite/hooks/a.sh"
settings d3b settings.json '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${HOME}/.claude/hooks/suite/hooks/a.sh"}]}]}}'
O="$(run d3b L8)"
absent   "D3b a directory whose contents are declared is not flagged" "suite" "$O"

# D3c — and the guard is not a blanket pass for directories: an undeclared sibling of a
# declared suite must still be reported, or D3b would have bought silence, not accuracy.
mkdir -p "$WORK/d3b/live/hooks/other-suite"
O="$(run d3b L8)"
contains "D3c an undeclared sibling directory is still reported" "other-suite" "$O"

# D4 — no hooks directory at all is a fact, not a failure.
mk d4 '{"skills":[],"skillSources":{},"hooks":[],"hookSources":{}}'
rmdir "$WORK/d4/live/hooks"
settings d4 settings.json '{"hooks":{}}'
O="$(run d4 L8)"
absent   "D4 absent hooks dir does not drift"              "DRIFT"       "$O"

echo ""
echo "=== L9: declared is not the same as on duty ==="

# D5 — THE INERT HOOK. Declared, installed, hash-verifiable, wired nowhere. This is the
# case that shipped twice in one day with a green gate.
mk d5 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
hook d5 a.sh
settings d5 settings.json '{"hooks":{}}'
O="$(run d5 L9)"
contains "D5 an unwired declared hook is reported" "a.sh"   "$O"
contains "D5 an unwired declared hook is DRIFT"    "DRIFT"  "$O"
contains "D5 the report says it is inert"          "inert"  "$O"

# C2 — control: the same hook, wired. MUST NOT drift.
O="$(run c1 L9)"
absent   "C2 a wired declared hook does not drift"  "DRIFT" "$O"

# D6 — wired only in settings.local.json. The estate's workspaces carry both files; reading
# only settings.json would report a FALSE drift here, which empties the verdict that is
# supposed to mean "this instance is right".
mk d6 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
hook d6 a.sh
settings d6 settings.json '{"hooks":{}}'
settings d6 settings.local.json "${WIRED_A//CASE/d6}"
O="$(run d6 L9)"
absent   "D6 settings.local.json counts as wiring" "DRIFT"  "$O"

# D7 — the other direction: a chain naming a file that is not there. Breaks every session,
# on every fire, and nothing else in L1..L8 looks at it.
mk d7 '{"skills":[],"skillSources":{},"hooks":[],"hookSources":{}}'
settings d7 settings.json '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${HOME}/.claude/hooks/NO-SUCH-HOOK-xyzzy.sh"}]}]}}'
O="$(run d7 L9)"
contains "D7 a wired-but-absent hook path is reported" "NO-SUCH-HOOK-xyzzy" "$O"
contains "D7 a wired-but-absent hook path is DRIFT"    "DRIFT"              "$O"

# D8 — a command carrying ARGUMENTS is still resolvable. Splitting on the first token is the
# whole reason this works; without it every argument-bearing chain would read as a ghost.
mk d8 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
hook d8 a.sh
settings d8 settings.json '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"'"$WORK"'/d8/live/hooks/a.sh --profile onedroid"}]}]}}'
O="$(run d8 L9)"
absent   "D8 arguments do not make a real hook a ghost" "DRIFT" "$O"

# D9 — the escape hatch works, and cannot be used anonymously.
mk d9 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"},"hooksUnwired":{"a.sh":"a helper the session-start hook calls, never an event chain"}}'
hook d9 a.sh
settings d9 settings.json '{"hooks":{}}'
O="$(run d9 L9)"
absent   "D9 a reasoned exception does not drift"   "DRIFT"        "$O"
contains "D9 but the exception is still printed"    "a helper the session-start hook calls"   "$O"

mk d10 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"},"hooksUnwired":{"a.sh":""}}'
hook d10 a.sh
settings d10 settings.json '{"hooks":{}}'
O="$(run d10 L9)"
contains "D10 an exception with no reason is DRIFT" "DRIFT"        "$O"
contains "D10 and says the reason is the point"     "NO reason"    "$O"

# D11 — no settings file at all. NOTHING is wired; that is not a pass. An absent settings
# file means the event chains do not exist, not that they are empty.
mk d11 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
hook d11 a.sh
O="$(run d11 L9)"
contains "D11 absent settings is DRIFT, not a pass"  "DRIFT"        "$O"

# D12 — settings.json that is not valid JSON. Claude Code cannot read it, so nothing is
# wired; reporting PASS here would be the most convincing wrong answer of the set.
mk d12 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
hook d12 a.sh
settings d12 settings.json '{"hooks": THIS IS NOT JSON'
O="$(run d12 L9)"
contains "D12 unparseable settings is DRIFT" "DRIFT" "$O"

echo ""
echo "=== L9: 'wired nowhere' has TWO causes and only one of them is a kit defect ==="

# ⚠️ MEASURED ON THE POLAND CODER, 2026-09-03. L9 reported mission-completeness-gate.py inert
# and offered exactly two remedies: hand-wire it, or record it in install.hooksUnwired. But
# boot-kit/config/settings.json.template ALREADY wired it — the box's live settings.json was
# simply older than the declaration. Nothing was missing from the kit.
#
# Recording an exception there would have been an active lie: hooksUnwired asserts a hook is
# DELIBERATELY inert, and the template says the opposite. **A remedy that clears the drift by
# writing down something false is worse than the drift.**
tmpl() { mkdir -p "$WORK/$1/boot-kit/config"; printf '%s\n' "$2" \
         > "$WORK/$1/boot-kit/config/settings.json.template"; }

# D13 — the template wires it, the live settings do not. A STALE MACHINE, not a broken kit.
mk d13 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
hook d13 a.sh
settings d13 settings.json '{"hooks":{}}'
tmpl d13 '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"__HOME__/.claude/hooks/a.sh"}]}]}}'
O="$(run d13 L9)"
contains "D13 a stale live settings.json is still DRIFT"      "DRIFT"           "$O"
contains "D13 the report names the template as the remedy"    "settings template" "$O"
contains "D13 it points at the template path"                 "settings.json.template" "$O"
# ⚠️ and it must STEER AWAY from the wrong remedy, not merely omit it
contains "D13 it forbids recording a false exception"         "DO NOT record"   "$O"
absent   "D13 it does not offer the hand-wire remedy here"    "WIRED NOWHERE"   "$O"

# D14 — control: a template exists and does NOT wire it. Still the plain inert case.
mk d14 '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
hook d14 a.sh
settings d14 settings.json '{"hooks":{}}'
tmpl d14 '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"__HOME__/.claude/hooks/other.sh"}]}]}}'
O="$(run d14 L9)"
contains "D14 a template that omits it is still WIRED NOWHERE" "WIRED NOWHERE"  "$O"
absent   "D14 and is not excused as a stale machine"           "settings template" "$O"

# D15 — ⚠️ THE SUBSTRING TRAP, THIRD APPEARANCE IN THIS ESTATE. A template naming
# `engram-pre-compact.sh` must NOT excuse a declared `pre-compact.sh`: it ends with the same
# characters. Every command in a settings chain is a PATH, so requiring the `/` costs nothing
# and closes it. The audit's class-2 check was bitten by exactly this.
mk d15 '{"skills":[],"skillSources":{},"hooks":["pre-compact.sh"],"hookSources":{"pre-compact.sh":"upstream:x/hooks/pre-compact.sh"}}'
hook d15 pre-compact.sh
settings d15 settings.json '{"hooks":{}}'
tmpl d15 '{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"__HOME__/.claude/hooks/engram-pre-compact.sh"}]}]}}'
O="$(run d15 L9)"
contains "D15 a same-ending template entry does NOT excuse it" "WIRED NOWHERE" "$O"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
# The runner reports a suite UNMEASURED (and fails it) without this line, and VACUOUS on 0.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
