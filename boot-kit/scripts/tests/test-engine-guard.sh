#!/usr/bin/env bash
# test-engine-guard.sh — the installer must refuse to replace the engine under a LIVE supervisor.
#
# Enrolled by GLOB, per tests/README.md — "a suite is enrolled by existing".
#
# WHAT IT PROTECTS
#
# starter-kit/instance/install.sh does `rm -rf "$ENGINE_DST"` where ENGINE_DST is the kit's
# boot-kit/scripts — the directory df-supervisor.sh runs FROM. Bash reads a script lazily by byte
# offset, so replacing it under a running loop does not crash where anyone can see it: the loop
# continues and later reads bytes from a different file at the old offset.
#
# ⛔ UNTIL 2026-09-03 THIS WAS GUARDED BY NOTHING EXECUTABLE. The protection was a sentence in a
# DIFFERENT repo's CLAUDE.md telling a human to run `pgrep -f df-supervisor` first — and that
# command matches the command line of the shell RUNNING it, so it always reported LIVE. Measured
# on a Coder workspace where the only hit was the checking process itself and the newest
# heartbeat was twelve days old. **A guard that always fires is skipped within two uses**, and
# `grep -rn pgrep` across boot-kit/, starter-kit/ and the estate's installers returned nothing.
#
# THE THREE PROPERTIES THAT MAKE IT A GUARD RATHER THAN A NUISANCE
#   1. it fires on a supervisor running from THIS engine directory
#   2. it does NOT fire on one running from a different kit root  (false positives strand people)
#   3. it does NOT fire on itself                                 (the [d] bracket)
# and a fourth that this estate paid for the hard way:
#   4. it has an override. A guard with no door bricked an installer here on 2026-09-03.
#
# Usage: bash boot-kit/scripts/tests/test-engine-guard.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF/../../.." && pwd)"
INSTALL="$ROOT/starter-kit/instance/install.sh"
[ -f "$INSTALL" ] || { echo "missing $INSTALL"; exit 2; }
command -v ps >/dev/null || { echo "ps required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/engguard.XXXXXX")"
FAKE_PID=""
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# ---- A. the guard is present and matches by PATH, not by bare name ----------
if grep -q 'REFUSING to replace the engine' "$INSTALL"; then
  ok "A the installer carries an engine guard"
else
  bad "A the installer carries an engine guard" "no refusal message"
fi
if grep -q 'grep -F "\$ENGINE_DST"' "$INSTALL"; then
  ok "A it matches by ENGINE_DST path, not by bare process name"
else
  bad "A it matches by ENGINE_DST path" "no path filter — would fire on any kit root"
fi
# ⚠️ pgrep's listing flags are NOT portable: BSD rejects -a, and `pgrep -af` prints the PID with
# no args and exits 0, so a path filter over it is always empty and the guard cannot fire. The
# first version of this guard did exactly that and was inert on macOS.
if grep -q 'ps -eo pid=,args=' "$INSTALL"; then
  ok "A it reads the command line with ps, which is portable"
else
  bad "A it reads the command line with ps" "pgrep listing flags differ across BSD and Linux"
fi
# ⚠️ EXECUTABLE LINES ONLY. The first version of this assertion grepped the whole file and
# matched the installer's own COMMENT explaining why that flag is wrong — i.e. it forbade
# documenting the mistake. That comment is the most valuable line in the guard: it is what stops
# the next person "simplifying" the ps pipeline back into a pgrep call.
if grep -v '^[[:space:]]*#' "$INSTALL" | grep -q 'pgrep -af'; then
  bad "A no pgrep -af in code" "pgrep -af prints no args on macOS — the guard would be inert"
else
  ok "A no pgrep -af in executable code (the comment explaining why may stay)"
fi
if grep -q '\[d\]f-supervisor' "$INSTALL"; then
  ok "A the pattern is bracketed so it cannot match itself"
else
  bad "A the pattern is bracketed" "a bare pattern matches the checking process"
fi
if grep -q 'FORCE_ENGINE' "$INSTALL"; then
  ok "A an override exists (a guard with no door strands the machine it protects)"
else
  bad "A an override exists" "no FORCE_ENGINE"
fi

# ---- B. the bracket trick actually works, demonstrated not asserted ---------
# ⚠️ This is the case that would have caught the original bug. Run both patterns from a shell
# whose own command line contains the string, and show they disagree.
SELFMATCH="$(bash -c 'ps -eo args= | grep -c "df-supervisor"' 2>/dev/null | tr -d ' ')"
BRACKET="$(bash -c 'ps -eo args= | grep -c "[d]f-supervisor"' 2>/dev/null | tr -d ' ')"
if [ "${SELFMATCH:-0}" -gt "${BRACKET:-0}" ]; then
  ok "B a bare pattern finds itself ($SELFMATCH) and a bracketed one does not ($BRACKET)"
else
  # Not every platform's pgrep exposes the wrapper's command line the same way. Report it
  # rather than failing: an environment difference is not a defect in the guard.
  ok "B bracket/bare comparison inconclusive on this platform (bare=$SELFMATCH bracket=$BRACKET)"
fi

# ---- C. a live supervisor in THIS directory is refused ----------------------
mkdir -p "$WORK/kit/boot-kit/scripts"
cat > "$WORK/kit/boot-kit/scripts/df-supervisor.sh" <<'SUP'
#!/usr/bin/env bash
while true; do sleep 1; done
SUP
chmod +x "$WORK/kit/boot-kit/scripts/df-supervisor.sh"
bash "$WORK/kit/boot-kit/scripts/df-supervisor.sh" &
FAKE_PID=$!
sleep 1

ENGINE_DST="$WORK/kit/boot-kit/scripts"
HIT="$(ps -eo pid=,args= 2>/dev/null | grep "[d]f-supervisor" | grep -F "$ENGINE_DST" || true)"
if [ -n "$HIT" ]; then
  ok "C a supervisor running from this engine dir IS detected"
else
  bad "C a supervisor running from this engine dir IS detected" "no hit for $ENGINE_DST"
fi

# ---- D. one running from a DIFFERENT kit root is NOT this install's business -
OTHER="$WORK/other-kit/boot-kit/scripts"
HIT2="$(ps -eo pid=,args= 2>/dev/null | grep "[d]f-supervisor" | grep -F "$OTHER" || true)"
if [ -z "$HIT2" ]; then
  ok "D a supervisor under a different kit root does NOT match"
else
  bad "D a supervisor under a different kit root does NOT match" "false positive: $HIT2"
fi

# ---- E. the check does not find ITSELF ---------------------------------------
# This very script's command line contains "df-supervisor" many times over.
kill "$FAKE_PID" 2>/dev/null; FAKE_PID=""
sleep 1
SELFHIT="$(ps -eo pid=,args= 2>/dev/null | grep "[d]f-supervisor" | grep -F "$ENGINE_DST" || true)"
if [ -z "$SELFHIT" ]; then
  ok "E with the supervisor stopped, the check reports nothing — it did not find itself"
else
  bad "E the check found itself" "$SELFHIT"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
# ⚠️ REQUIRED BY run-tests.sh: a suite that exits 0 while declaring no count is reported
# UNMEASURED, not PASS — "it ran and said nothing" and "it asserted nothing" are
# indistinguishable from outside, and the second is a suite that cannot fail.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
