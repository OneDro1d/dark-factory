#!/usr/bin/env bash
# test-source-resolution.sh — one shape for `install`, proven at both ends of it.
#
# WHY THIS EXISTS. Three readings of `install.skills` were live at once:
#
#   the engine        (rehydrate.sh, lock-verify.sh)   array of names + a *Sources map,
#                                                      values resolved under vendorDir ONLY
#   the org template  (templates/*/install.sh)         a MAP of name -> "upstream:"/"local:"
#   a reference kit   (its own installer)              the engine's array + the org's
#                                                      "local:" vocabulary
#
# The third is the convergence, and it was already running before anyone chose it. The
# engine's structure won because the verifier reads it and every existing lockfile carries
# it; the org template's vocabulary won because without it an instance cannot own a hook or
# a skill at all -- it has to push its own file into some other repo and vendor it back.
#
# Two claims are load-bearing and are asserted directly rather than reasoned about:
#
#   1. `local:` resolves against the LOCKFILE's directory, not against the script's. A
#      vendored copy of rehydrate.sh, run from an instance root, must still resolve
#      `local:` into the INSTANCE. Every case here plants a DECOY at the same relative
#      path inside vendor/, so "it found the right file" cannot be satisfied by the wrong
#      one -- the assertion is on file CONTENT, never on exit status.
#   2. The array+map pair can express states a single map could not: a name with no
#      source, and a source with no name. Both install nothing and both read as a
#      declaration. lock-verify L7 is what buys that guarantee back.
#
# Usage: bash boot-kit/scripts/tests/test-source-resolution.sh
# Exit:  0 = every case behaves   1 = at least one does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
REHYDRATE="$SCRIPTS/rehydrate.sh"
LOCKVERIFY="$SCRIPTS/lock-verify.sh"
for f in "$REHYDRATE" "$LOCKVERIFY"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/srcresolve.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

contains() { case "$3" in *"$2"*) PASS=$((PASS+1)); echo "  ok   $1" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL $1 -- '$2' not in output" ;; esac; }
absent()  { case "$3" in *"$2"*) FAIL=$((FAIL+1)); echo "  FAIL $1 -- '$2' unexpectedly in output" ;;
  *) PASS=$((PASS+1)); echo "  ok   $1" ;; esac; }
eq()      { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1";
  else FAIL=$((FAIL+1)); echo "  FAIL $1 -- expected '$2', got '$3'"; fi; }

# ---------------------------------------------------------------------------
# A scratch instance. `--offline` everywhere: the network is not under test and a
# suite that needs it is a suite that goes red for the wrong reason.
#
# DECOYS. Every `local:` source has a same-named file at the same relative path inside
# vendor/, carrying different content. If resolution ever falls back to vendorDir the
# install still SUCCEEDS -- so success proves nothing and only the content does.
# ---------------------------------------------------------------------------
mk_instance() { # mk_instance <dir> <install-json>
  local d="$1" ins="$2"
  mkdir -p "$d/vendor/up/skills/from-vendor" "$d/vendor/up/hooks" \
           "$d/boot-kit/hooks" "$d/boot-kit/skills/owned-here" \
           "$d/vendor/up/boot-kit/hooks" "$d/vendor/up/boot-kit/skills/owned-here"
  echo 'VENDORED SKILL' > "$d/vendor/up/skills/from-vendor/SKILL.md"
  echo 'VENDORED HOOK'  > "$d/vendor/up/hooks/shared.sh"
  echo 'OWNED BY THE INSTANCE' > "$d/boot-kit/skills/owned-here/SKILL.md"
  printf 'MINE home=__HOME__\n'  > "$d/boot-kit/hooks/mine.sh"
  # the decoys, reachable only if `local:` is resolved under vendorDir
  echo 'DECOY SKILL FROM VENDOR' > "$d/vendor/up/boot-kit/skills/owned-here/SKILL.md"
  echo 'DECOY HOOK FROM VENDOR'  > "$d/vendor/up/boot-kit/hooks/mine.sh"
  cat > "$d/loom.lock.json" <<JSON
{ "vendorDir": "vendor",
  "upstreams": { "up": { "repo": "example/up", "commit": "0000000000000000000000000000000000000000" } },
  "install": $ins }
JSON
}

run_rehydrate() { # run_rehydrate <dir> [script-path]
  local d="$1" script="${2:-$REHYDRATE}"
  ( cd "$d" && LOOM_LIVE="$d/live" bash "$script" --offline 2>&1 )
}

# ===========================================================================
echo "== 1. the three source forms, decided by content =="
# ===========================================================================
I1="$WORK/i1"
mk_instance "$I1" '{
  "skills": ["from-vendor","explicit-up","owned-here"],
  "skillSources": {
    "$comment": "documentation, not an entry",
    "from-vendor": "up/skills/from-vendor",
    "explicit-up": "upstream:up/skills/from-vendor",
    "owned-here":  "local:boot-kit/skills/owned-here"
  },
  "hooks": ["shared.sh","mine.sh"],
  "hookSources": {
    "shared.sh": "up/hooks/shared.sh",
    "mine.sh":   "local:boot-kit/hooks/mine.sh"
  }
}'
OUT1="$(run_rehydrate "$I1")"
contains "bare source is linked"          "link from-vendor" "$OUT1"
contains "upstream: source is linked"     "link explicit-up" "$OUT1"
contains "local: source is linked"        "link owned-here"  "$OUT1"
eq "bare skill resolves into vendor"      "VENDORED SKILL"        "$(cat "$I1/live/skills/from-vendor/SKILL.md" 2>/dev/null)"
eq "upstream: skill resolves into vendor" "VENDORED SKILL"        "$(cat "$I1/live/skills/explicit-up/SKILL.md" 2>/dev/null)"
eq "local: skill resolves into the INSTANCE, not the decoy" \
                                          "OWNED BY THE INSTANCE" "$(cat "$I1/live/skills/owned-here/SKILL.md" 2>/dev/null)"
eq "bare hook resolves into vendor"       "VENDORED HOOK"         "$(cat "$I1/live/hooks/shared.sh" 2>/dev/null)"
eq "local: hook resolves into the INSTANCE, not the decoy" \
                                          "MINE home=$HOME"       "$(cat "$I1/live/hooks/mine.sh" 2>/dev/null)"
absent "a \$comment key is not treated as a skill" "\$comment" "$OUT1"

# ===========================================================================
echo "== 2. a VENDORED engine still resolves local: into the instance =="
# ===========================================================================
# This is the claim the whole scheme rests on. rehydrate.sh derives ROOT from `pwd` --
# the lockfile's directory -- not from its own path. Run the copy that lives INSIDE
# vendor/ and the answer must not change. A script that derived its root from its own
# location would resolve `local:` into the vendor cache and silently install the decoy.
I2="$WORK/i2"
mk_instance "$I2" '{
  "skills": ["owned-here"],
  "skillSources": { "owned-here": "local:boot-kit/skills/owned-here" },
  "hooks": [], "hookSources": {}
}'
mkdir -p "$I2/vendor/up/boot-kit/scripts"
cp "$REHYDRATE" "$I2/vendor/up/boot-kit/scripts/rehydrate.sh"
OUT2="$(run_rehydrate "$I2" "$I2/vendor/up/boot-kit/scripts/rehydrate.sh")"
eq "vendored engine still picks the instance copy" \
   "OWNED BY THE INSTANCE" "$(cat "$I2/live/skills/owned-here/SKILL.md" 2>/dev/null)"

# ===========================================================================
echo "== 3. refusals =="
# ===========================================================================
I3="$WORK/i3"
mk_instance "$I3" '{
  "skills": ["climber"],
  "skillSources": { "climber": "local:../../etc" },
  "hooks": ["hclimb.sh"],
  "hookSources": { "hclimb.sh": "up/../../../etc/hosts" }
}'
OUT3="$(run_rehydrate "$I3")"
contains "a local: source climbing out is REFUSED" "REFUSED climber" "$OUT3"
contains "a bare source climbing out is REFUSED"   "REFUSED hclimb.sh" "$OUT3"
absent   "a refused skill is not linked"           "link climber"    "$OUT3"
eq "nothing was installed for a refused skill" "" "$(ls "$I3/live/skills" 2>/dev/null)"

# a source that simply is not there is reported and skipped, never guessed at
I4="$WORK/i4"
mk_instance "$I4" '{
  "skills": ["ghost"], "skillSources": { "ghost": "local:boot-kit/skills/nope" },
  "hooks": [], "hookSources": {}
}'
OUT4="$(run_rehydrate "$I4")"
contains "an absent local: source is MISSed, not invented" "MISS ghost" "$OUT4"

# ===========================================================================
echo "== 4. lock-verify L7 -- both directions =="
# ===========================================================================
# L1-L6 will legitimately report drift on a scratch instance (nothing is really
# vendored at a real commit), so the assertions are on the L7 LINES, not on the
# overall verdict. Asserting the verdict here would pass for the wrong reason.
l7_lines() { ( cd "$1" && LOOM_LIVE="$1/live" bash "$LOCKVERIFY" 2>&1 | grep -E 'L7|declared with no|has a .*Sources entry' ); }

I5="$WORK/i5"; mk_instance "$I5" '{
  "skills": ["from-vendor"],
  "skillSources": { "$comment": "doc", "from-vendor": "up/skills/from-vendor" },
  "hooks": [], "hookSources": { "$comment": "doc" } }'
run_rehydrate "$I5" >/dev/null
L7A="$(l7_lines "$I5")"
contains "L7 passes when both directions agree" "L7 every declaration has a source" "$L7A"
absent   "a \$comment key does not trip L7"     "\$comment"                          "$L7A"

I6="$WORK/i6"; mk_instance "$I6" '{
  "skills": ["from-vendor","orphan-name"],
  "skillSources": { "from-vendor": "up/skills/from-vendor" },
  "hooks": [], "hookSources": {} }'
L7B="$(l7_lines "$I6")"
contains "L7 catches a name with no source"    "orphan-name declared with no skillSources entry" "$L7B"
contains "a name with no source is DRIFT"      "DRIFT"                                           "$L7B"

I7="$WORK/i7"; mk_instance "$I7" '{
  "skills": [],
  "skillSources": { "stranded": "up/skills/from-vendor" },
  "hooks": [], "hookSources": {} }'
L7C="$(l7_lines "$I7")"
contains "L7 catches a source with no name" "stranded has a skillSources entry but is not declared" "$L7C"

I8="$WORK/i8"; mk_instance "$I8" '{
  "skills": [], "skillSources": {},
  "hooks": ["gone.sh"], "hookSources": {} }'
L7D="$(l7_lines "$I8")"
contains "L7 covers hooks as well as skills" "gone.sh declared with no hookSources entry" "$L7D"

# ===========================================================================
echo "== 5. the legacy bare form is untouched =="
# ===========================================================================
# Every lockfile in existence uses it, so this is the case that must never move.
I9="$WORK/i9"; mk_instance "$I9" '{
  "skills": ["from-vendor"], "skillSources": { "from-vendor": "up/skills/from-vendor" },
  "hooks": ["shared.sh"],    "hookSources":  { "shared.sh": "up/hooks/shared.sh" } }'
OUT9="$(run_rehydrate "$I9")"
eq "legacy bare skill still resolves"  "VENDORED SKILL" "$(cat "$I9/live/skills/from-vendor/SKILL.md" 2>/dev/null)"
eq "legacy bare hook still resolves"   "VENDORED HOOK"  "$(cat "$I9/live/hooks/shared.sh" 2>/dev/null)"
absent "no refusal fires on the legacy form" "REFUSED" "$OUT9"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
