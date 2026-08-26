#!/usr/bin/env bash
# L5 must catch a skill that is INSTALLED but resolves outside this instance.
#
# The check being tested previously asked only "does the path exist". A skill installs as a
# symlink into a $LIVE shared by every instance on the machine, so existence proved nothing.
# The scenario that found it is reproduced literally in case 3: two instances installing
# into ONE $LIVE, second over first, both reporting LOCKED while one runs the other's
# skills.
#
# Both directions, every case. A check trusted only where it passes is not tested: case 1
# proves it can still pass, and cases 2-4 prove each way it must fail.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LV="$HERE/../lock-verify.sh"
[ -f "$LV" ] || { echo "FATAL: lock-verify.sh not found beside this test"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSED=0; FAILED=0

ok()   { PASSED=$((PASSED+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAILED=$((FAILED+1)); printf '  FAIL  %s\n' "$1"; }

# --- build an instance: a vendor tree, a lockfile, and a $LIVE it installs into ---------
mkinstance() {                       # mkinstance <dir> <skill-content-marker>
  local d="$1" marker="$2"
  mkdir -p "$d/vendor/up/skills/alpha" "$d/live/skills" "$d/live/hooks"
  printf '%s\n' "$marker" > "$d/vendor/up/skills/alpha/SKILL.md"
  cat > "$d/loom.lock.json" <<JSON
{
  "upstreams": { "up": { "repo": "example/up", "commit": "0000000000000000000000000000000000000000" } },
  "vendorDir": "vendor",
  "install": {
    "skills": ["alpha"],
    "skillSources": { "alpha": "up/skills/alpha" },
    "hooks": [],
    "hookSources": {}
  }
}
JSON
  ln -sfn "$d/vendor/up/skills/alpha" "$d/live/skills/alpha"
}

l5line() {                           # run lock-verify for <dir> and print only its L5 verdict
  local d="$1"
  # NOTE the ` +`: pass() prints two spaces after its label and drift() prints one. A grep
  # requiring two matched only the passing line, so every failure case came back EMPTY and
  # read as "no verdict" rather than "wrong verdict". Caught by running the test.
  ( cd "$d" && LOOM_LIVE="$d/live" bash "$LV" 2>&1 ) | grep -E '^(PASS|DRIFT) +L5' | head -1
}

echo "=== L5: a skill must resolve INTO the instance that declares it ==="

# 1. the ordinary case — still passes, or the check is useless
mkinstance "$TMP/a" "instance-A"
line="$(l5line "$TMP/a")"
case "$line" in
  PASS*) ok "correctly installed instance still PASSES  [$line]" ;;
  *)     bad "correct instance no longer passes: $line" ;;
esac

# 2. the canary the old check could not fail: repoint at a decoy with different content
mkdir -p "$TMP/decoy/alpha"
printf 'ENTIRELY DIFFERENT CONTENT\n' > "$TMP/decoy/alpha/SKILL.md"
ln -sfn "$TMP/decoy/alpha" "$TMP/a/live/skills/alpha"
line="$(l5line "$TMP/a")"
case "$line" in
  DRIFT*) ok "skill repointed at a decoy is caught       [$line]" ;;
  *)      bad "decoy NOT caught — this is the original defect: $line" ;;
esac
ln -sfn "$TMP/a/vendor/up/skills/alpha" "$TMP/a/live/skills/alpha"   # restore

# 3. the real scenario: two instances, ONE shared $LIVE, second installs over first
mkinstance "$TMP/b" "instance-B"
rm -rf "$TMP/b/live"; ln -sfn "$TMP/a/live" "$TMP/b/live"      # B shares A's live tree
ln -sfn "$TMP/b/vendor/up/skills/alpha" "$TMP/a/live/skills/alpha"   # B installed last
line="$(l5line "$TMP/a")"
case "$line" in
  DRIFT*) ok "instance A sees B's link in the shared live [$line]" ;;
  *)      bad "shared-live overwrite NOT caught: $line" ;;
esac
line="$(l5line "$TMP/b")"
case "$line" in
  PASS*) ok "instance B, which installed last, passes     [$line]" ;;
  *)     bad "B should pass — it owns the current link: $line" ;;
esac
ln -sfn "$TMP/a/vendor/up/skills/alpha" "$TMP/a/live/skills/alpha"   # restore

# 4. a declared source that does not exist is drift, not a silent pass
jq '.install.skillSources.alpha = "up/skills/nowhere"' "$TMP/a/loom.lock.json" > "$TMP/a/l.tmp"
mv "$TMP/a/l.tmp" "$TMP/a/loom.lock.json"
line="$(l5line "$TMP/a")"
case "$line" in
  DRIFT*) ok "source declared but absent is caught        [$line]" ;;
  *)      bad "absent source NOT caught: $line" ;;
esac

echo
printf '%d passed, %d failed\n' "$PASSED" "$FAILED"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASSED + FAILED))"
[ "$FAILED" -eq 0 ] || exit 1
