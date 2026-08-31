#!/usr/bin/env bash
# test-instance-org-delegate.sh — the instance kit's OPTIONAL org layer, end to end.
#
# WHAT THIS PINS. `starter-kit/instance/install.sh` gained a step 2a: if the lockfile
# declares `org.upstream`, fetch that layer at its pin and run ITS installer BEFORE this
# instance's own declarations are installed on top. Three properties carry the whole
# design and none of them is visible in an exit status:
#
#   1. ABSENT BY DEFAULT. With no `org.upstream`, step 2a runs nothing at all. That is
#      the property that makes this safe to land in a generator without re-minting the
#      machines the generator already produced — so it is asserted, not assumed.
#   2. THE LIVE DIRECTORY HAS TWO SPELLINGS. This kit's engine reads LOOM_LIVE; the
#      org-layer templates read CLAUDE_HOME. An install that resolves one and passes the
#      other hands the delegated layer a default of the real ~/.claude while the caller
#      believes it redirected the install. Every case below sets ONLY CLAUDE_HOME, and
#      the fake layer records both variables as it saw them, so a regression that drops
#      the bridge shows up as a value and not as a crash.
#   3. OVERRIDES ARE REPORTED, AND ONLY THE REAL ONES. The instance installs last and
#      wins; rehydrate.sh says so per name. The failure mode being guarded here is not a
#      missing warning but a WRONG one: a check on mere existence fires on every
#      re-install, and a warning that is wrong every second time trains the reader past
#      the one that is right. Case H re-runs the identical install and asserts the
#      instance's own hook is NOT reported, while the layer-owned one still is.
#
# The fixtures are local: a fake Tier 1 (the real engine, copied) and a fake org layer
# whose installer is four lines. Nothing here touches the network or the real ~/.claude.
#
# Usage: bash starter-kit/instance/tests/test-instance-org-delegate.sh
# Exit:  0 = every case behaves   1 = at least one does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"                 # starter-kit/instance
T1SRC="$(cd "$KIT/../.." && pwd)"             # the Tier 1 checkout
INSTALLER="$KIT/install.sh"
ENGINE="$T1SRC/boot-kit/scripts"
for f in "$INSTALLER" "$ENGINE/rehydrate.sh"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/orgdeleg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

contains() { case "$3" in *"$2"*) PASS=$((PASS+1)); echo "  ok   $1" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL $1 -- '$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) FAIL=$((FAIL+1)); echo "  FAIL $1 -- '$2' unexpectedly in output" ;;
  *) PASS=$((PASS+1)); echo "  ok   $1" ;; esac; }
eq()       { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1";
  else FAIL=$((FAIL+1)); echo "  FAIL $1 -- expected '$2', got '$3'"; fi; }
slurp()    { cat "$1" 2>/dev/null || printf '<<no such file: %s>>' "$1"; }

# ---------------------------------------------------------------------------
# mk_instance <dir>  — a runnable instance whose Tier 1 and org layer are already
# vendored, so every case runs with --offline and touches no network.
#
# vendor/dark-factory/.git is an EMPTY DIRECTORY on purpose. `install.sh --offline`
# tests for that path and then runs no git command against it, which is exactly the
# documented offline contract; a real repo here would add a second of setup per case and
# assert nothing extra.
# ---------------------------------------------------------------------------
mk_instance() {
  local d="$1"
  mkdir -p "$d/vendor/dark-factory/.git" "$d/vendor/orglayer" \
           "$d/boot-kit/skills/mine" "$d/boot-kit/hooks" "$d/live/skills" "$d/live/hooks"
  cp -R "$ENGINE" "$d/vendor/dark-factory/boot-kit-scripts-tmp"
  mkdir -p "$d/vendor/dark-factory/boot-kit"
  mv "$d/vendor/dark-factory/boot-kit-scripts-tmp" "$d/vendor/dark-factory/boot-kit/scripts"
  cp "$INSTALLER" "$d/install.sh"

  echo 'INSTANCE COPY' > "$d/boot-kit/skills/mine/SKILL.md"
  printf 'my own hook, home=__HOME__\n' > "$d/boot-kit/hooks/my-own.sh"

  # The fake org layer. It records the environment it was handed — the assertion that
  # matters is a VALUE, not an exit status — and installs one skill and one hook of its
  # own, so the instance has something real to override.
  cat > "$d/vendor/orglayer/install.sh" <<'ORG'
#!/usr/bin/env bash
set -u
LIVE="${CLAUDE_HOME:-$HOME/.claude}"
{ printf 'CLAUDE_HOME=%s\n' "${CLAUDE_HOME:-<unset>}"
  printf 'LOOM_LIVE=%s\n'   "${LOOM_LIVE:-<unset>}"
  printf 'ARGS=%s\n'        "$*"
  printf 'PWD=%s\n'         "$(pwd)"; } > "$LIVE/.org-ran"
mkdir -p "$LIVE/skills/shared-skill" "$LIVE/hooks"
echo 'ORG COPY' > "$LIVE/skills/shared-skill/SKILL.md"
printf 'org hook\n' > "$LIVE/hooks/shared.sh"
ORG
  chmod +x "$d/vendor/orglayer/install.sh"
  mkdir -p "$d/skills/shared-skill"
  echo 'INSTANCE COPY' > "$d/skills/shared-skill/SKILL.md"
  printf 'instance hook\n' > "$d/boot-kit/hooks/shared.sh"
}

# A lockfile with the org block filled in by argument, so each case differs in exactly
# the field it is about.
mk_lock() { # mk_lock <dir> <org-json>
  local d="$1" org="$2"
  jq -n --argjson org "$org" '{
    vendorDir: "vendor",
    upstreams: {
      "dark-factory": { repo: "OneDro1d/dark-factory", url: "https://example.invalid/x.git", commit: "" },
      "orglayer":     { repo: "example/org-layer", commit: "" }
    },
    org: $org,
    install: {
      skills: ["mine", "shared-skill"],
      skillSources: { "mine": "local:boot-kit/skills/mine", "shared-skill": "local:skills/shared-skill" },
      hooks: ["my-own.sh", "shared.sh"],
      hookSources: { "my-own.sh": "local:boot-kit/hooks/my-own.sh", "shared.sh": "local:boot-kit/hooks/shared.sh" }
    },
    notRestorable: {}
  }' > "$d/loom.lock.json"
}

# run <dir> [flags...] — CLAUDE_HOME ONLY. LOOM_LIVE is deliberately never exported by
# the caller: if install.sh stops bridging the two spellings, the org layer and the
# engine start writing to $HOME/.claude and these cases fail on content, not on error.
run() {
  local d="$1"; shift
  ( cd "$d" && CLAUDE_HOME="$d/live" LOOM_BIN="$d/bin" bash install.sh --offline "$@" 2>&1 )
}

echo "=== A. no org block: step 2a runs nothing ==="
A="$WORK/a"; mk_instance "$A"; mk_lock "$A" '{"upstream":"","installer":"install.sh"}'
OUT="$(run "$A")"
contains "A1 the step reports the skip in words"  "no org layer declared" "$OUT"
eq       "A2 the org installer never ran"         "absent" "$([ -f "$A/live/.org-ran" ] && echo present || echo absent)"
contains "A3 the instance's own skill still installs" "INSTANCE COPY" "$(slurp "$A/live/skills/mine/SKILL.md")"

echo "=== B. org declared: fetch is skipped offline, the layer is RUN, and gets both spellings ==="
B="$WORK/b"; mk_instance "$B"; mk_lock "$B" '{"upstream":"orglayer","installer":"install.sh"}'
OUT="$(run "$B")"
contains "B1 the delegation is announced with the path it runs" "vendor/orglayer/install.sh" "$OUT"
eq       "B2 the org installer ran"               "present" "$([ -f "$B/live/.org-ran" ] && echo present || echo absent)"
contains "B3 the layer saw CLAUDE_HOME"           "CLAUDE_HOME=$B/live" "$(slurp "$B/live/.org-ran")"
contains "B4 the layer saw LOOM_LIVE — the bridge" "LOOM_LIVE=$B/live"  "$(slurp "$B/live/.org-ran")"
contains "B5 --offline is passed through"         "ARGS=--offline"      "$(slurp "$B/live/.org-ran")"
contains "B6 the engine wrote to the SAME live dir" "my own hook"       "$(slurp "$B/live/hooks/my-own.sh")"

echo "=== C. org.upstream names something that is not an upstream ==="
C="$WORK/c"; mk_instance "$C"; mk_lock "$C" '{"upstream":"nosuchlayer","installer":"install.sh"}'
OUT="$(run "$C")"; RC=$?
contains "C1 it refuses and names the key"        "not a key of .upstreams" "$OUT"
eq       "C2 nothing was installed after the refusal" "absent" "$([ -e "$C/live/skills/mine" ] && echo present || echo absent)"

echo "=== D. an installer path that climbs out of the layer ==="
D="$WORK/d"; mk_instance "$D"; mk_lock "$D" '{"upstream":"orglayer","installer":"../../evil.sh"}'
OUT="$(run "$D")"
contains "D1 refused, not normalised"             "refused, not normalised" "$OUT"
eq       "D2 the org installer never ran"         "absent" "$([ -f "$D/live/.org-ran" ] && echo present || echo absent)"

echo "=== E. the layer is there and its installer is not ==="
E="$WORK/e"; mk_instance "$E"; mk_lock "$E" '{"upstream":"orglayer","installer":"bootstrap.sh"}'
OUT="$(run "$E")"
contains "E1 it dies naming the missing entry point" "declares no bootstrap.sh" "$OUT"
eq       "E2 the instance's declarations did NOT install on top of nothing" "absent" \
         "$([ -e "$E/live/skills/mine" ] && echo present || echo absent)"

echo "=== F/G. the instance wins, and the override is reported ==="
F="$WORK/f"; mk_instance "$F"; mk_lock "$F" '{"upstream":"orglayer","installer":"install.sh"}'
OUT="$(run "$F")"
contains "F1 the skill override is reported by name" "OVERRIDE shared-skill" "$OUT"
contains "F2 the instance's copy is the one live"    "INSTANCE COPY" "$(slurp "$F/live/skills/shared-skill/SKILL.md")"
contains "G1 the hook override is reported by name"  "OVERRIDE shared.sh"    "$OUT"
contains "G2 the instance's hook is the one live"    "instance hook" "$(slurp "$F/live/hooks/shared.sh")"
contains "F3 the count is printed even so"           "override(s)"   "$OUT"

echo "=== H. re-run: only the REAL overrides are reported the second time ==="
# The canary for the check itself. `my-own.sh` is a hook no other layer touches, so on
# the second install it exists with byte-identical content — an existence check would
# report it and be wrong. `shared.sh` is rewritten by the org layer on every run, so it
# must still be reported: without that half, a check that reports nothing at all passes
# this case too.
OUT2="$(run "$F")"
absent   "H1 the instance's own hook is NOT re-reported" "OVERRIDE my-own.sh" "$OUT2"
contains "H2 the layer-owned hook still is"             "OVERRIDE shared.sh" "$OUT2"

echo "=== I. --dry-run delegates to nothing ==="
I="$WORK/i"; mk_instance "$I"; mk_lock "$I" '{"upstream":"orglayer","installer":"install.sh"}'
OUT="$(run "$I" --dry-run)"
contains "I1 it says what it would run"   "would  run" "$OUT"
eq       "I2 and ran nothing"             "absent" "$([ -f "$I/live/.org-ran" ] && echo present || echo absent)"

echo ""
echo "$PASS passed, $FAIL failed"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
