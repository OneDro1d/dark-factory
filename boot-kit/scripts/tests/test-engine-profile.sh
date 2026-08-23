#!/usr/bin/env bash
# test-engine-profile.sh — prove the engine takes its default profile from the INSTANCE,
# never from a value baked into the engine itself.
#
# WHY THIS EXISTS. The engine is meant to be pinned: a kit declares a commit of this repo
# and installs the scripts from that pin, unmodified. A default that is hardcoded in the
# engine defeats that in the quietest possible way — the consumer edits the one line it
# disagrees with, and from then on it owns a fork rather than a pin. Measured on the day
# the engine was imported here: all six engine scripts had already diverged from the copy
# they were imported from, and `df-mission`'s hardcoded start profile was one of the
# differences. The fork begins with a single token.
#
# The seam under test is `df-mission profile`, a read-only subcommand that prints the
# resolved default and the source it came from. It starts nothing, so the resolution can
# be proven without launching a supervisor, spending a budget, or needing a model.
#
# Precedence asserted here, strongest first:
#   1. an explicit --profile flag        (start only; not this subcommand's business)
#   2. $DF_PROFILE in the environment
#   3. .defaultProfile in the notepad's lockfile
#   4. the built-in fallback, "default"
#
# Usage: bash boot-kit/scripts/tests/test-engine-profile.sh
# Exit:  0 = every case behaves   1 = at least one does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
ENGINE="$SCRIPTS/df-mission"
[ -x "$ENGINE" ] || { echo "df-mission not executable at $ENGINE"; exit 2; }

PASS=0; FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/engineprofile.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1 — expected '$2', got '$3'"; fi
}
contains() { # contains <label> <needle> <haystack>
  case "$3" in *"$2"*) PASS=$((PASS+1)); echo "  ok   $1" ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL $1 — '$2' not in '$3'" ;; esac
}

# A notepad is any directory carrying repos.manifest.json — that is the marker df-mission
# walks up for. Build one per case so the cases cannot contaminate each other.
mk_notepad() { # mk_notepad <dir> [lockfile-json]
  mkdir -p "$1"
  echo '{"repos":[]}' > "$1/repos.manifest.json"
  [ $# -ge 2 ] && printf '%s' "$2" > "$1/loom.lock.json"
  return 0
}

# Always run from INSIDE the notepad and with a clean environment: df-mission honours an
# inherited $NOTEPAD ahead of its upward walk, and this suite is expected to be run from
# inside a live mission, whose supervisor exports exactly that. A test that reads its
# launcher's environment measures the launcher.
run_profile() { # run_profile <notepad-dir>
  ( cd "$1" && env -u NOTEPAD -u DF_PROFILE bash "$ENGINE" profile 2>&1 )
}

echo "== 1. no lockfile at all — the built-in fallback, and it is not empty"
N="$WORK/n1"; mk_notepad "$N"
out="$(run_profile "$N")"
check "resolves to 'default'" "default" "$(printf '%s' "$out" | head -1)"
contains "names its source" "built-in" "$out"

echo "== 2. lockfile declares one — the instance wins over the built-in"
N="$WORK/n2"; mk_notepad "$N" '{"defaultProfile":"example-profile"}'
out="$(run_profile "$N")"
check "resolves to the declared value" "example-profile" "$(printf '%s' "$out" | head -1)"
contains "names the lockfile as source" "loom.lock.json" "$out"

echo "== 3. \$DF_PROFILE overrides the lockfile"
N="$WORK/n3"; mk_notepad "$N" '{"defaultProfile":"example-profile"}'
out="$(cd "$N" && env -u NOTEPAD DF_PROFILE=env-profile bash "$ENGINE" profile 2>&1)"
check "env beats lockfile" "env-profile" "$(printf '%s' "$out" | head -1)"
contains "names the environment as source" "DF_PROFILE" "$out"

echo "== 4. a lockfile with no defaultProfile key is not an error and not empty"
N="$WORK/n4"; mk_notepad "$N" '{"instance":"somewhere"}'
out="$(run_profile "$N")"
check "falls back to 'default'" "default" "$(printf '%s' "$out" | head -1)"

echo "== 5. a MALFORMED lockfile degrades to the fallback, it does not crash"
# An unparseable lockfile is an unknown, not a fact. Erroring out here would take the
# operator's brake offline over a stray comma; guessing a profile would be worse.
N="$WORK/n5"; mk_notepad "$N" '{"defaultProfile": '
out="$(run_profile "$N")"; rc=$?
check "still resolves to 'default'" "default" "$(printf '%s' "$out" | head -1)"
check "exit code is 0" "0" "$rc"

echo "== 6. an EMPTY defaultProfile is treated as undeclared, not as an empty profile"
# "" would render /-dark-factory in every prompt and preflight, which is a silent
# mis-target rather than a visible failure.
N="$WORK/n6"; mk_notepad "$N" '{"defaultProfile":""}'
out="$(run_profile "$N")"
check "falls back to 'default'" "default" "$(printf '%s' "$out" | head -1)"

echo "== 7. \$LOOM_LOCK is honoured, and ahead of the notepad's own lockfile"
# df-preflight honours LOOM_LOCK first. Two tools in one repo that resolve "which lockfile
# describes this machine" differently will each be right somewhere, and each will report
# the other machine's facts as this one's drift.
N="$WORK/n7"; mk_notepad "$N" '{"defaultProfile":"notepad-profile"}'
printf '%s' '{"defaultProfile":"pointed-profile"}' > "$WORK/elsewhere.lock.json"
out="$(cd "$N" && env -u NOTEPAD -u DF_PROFILE LOOM_LOCK="$WORK/elsewhere.lock.json" bash "$ENGINE" profile 2>&1)"
check "the pointed lockfile wins" "pointed-profile" "$(printf '%s' "$out" | head -1)"

echo "== 8. the no-jq fallback resolves the same value jq does"
# jq is present on most machines this runs on, so the fallback branch is the one that
# never gets exercised by accident — and an untested fallback is indistinguishable from a
# missing one until the day jq is absent.
N="$WORK/n8"; mk_notepad "$N" '{"instance":"x","defaultProfile":"nojq-profile","lanes":[]}'
BINS="$WORK/bin-nojq"; mkdir -p "$BINS"
for c in sed head cat bash env mktemp rm grep printf dirname readlink; do
  src="$(command -v "$c" 2>/dev/null)" && [ -n "$src" ] && ln -sf "$src" "$BINS/$c"
done
out="$(cd "$N" && env -u NOTEPAD -u DF_PROFILE PATH="$BINS" bash "$ENGINE" profile 2>&1)"
check "resolves without jq" "nojq-profile" "$(printf '%s' "$out" | head -1)"

echo "== 9. the engine carries NO hardcoded estate profile as its start default"
# The regression this whole file exists for: the moment someone edits the default in
# place, the consumer owns a fork and the pin is decorative.
line="$(grep -n 'local profile=' "$ENGINE" | head -1 | sed 's/^[0-9]*: *//')"
case "$line" in
  *'profile="$(resolve_default_profile'*) PASS=$((PASS+1)); echo "  ok   start default is resolved, not literal" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL start default is a literal: $line" ;;
esac

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
