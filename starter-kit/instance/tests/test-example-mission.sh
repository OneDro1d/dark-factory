#!/usr/bin/env bash
# test-example-mission.sh — the worked example must reach a first iteration, and must be
# unable to touch anything outside itself.
#
# Run:  bash starter-kit/instance/tests/test-example-mission.sh
# Exit: 0 all pass · 1 at least one failed. Prints a literal count, because a suite that
# reports "ok" without saying how many assertions ran cannot be told from one that ran none.
#
# WHY THIS EXISTS. The example mission is the one artefact shipped in a state where it will
# be RUN, unattended, on a machine nobody here has seen. Two things therefore have to be
# true of it before it ships, and neither is visible by reading it:
#
#   1. `df-mission` must be able to find it. That resolution walks up from $PWD looking for
#      repos.manifest.json and then expects .df/missions/<id>/MISSION.md underneath. Get the
#      copy destination wrong by one directory and `df-mission start` dies with "frame the
#      mission first" -- pointing at authoring, not at the installer that misplaced it.
#   2. Its confinement must be stated where the iteration reads it. The rendered prompt
#      names a notepad-root MAP.md and handoffs/; if HARD-STOPS.md does not override that,
#      an obedient iteration writes outside the directory and the example is no longer safe
#      to ship enabled.
#
# What this suite does NOT do: launch an iteration. That spends money, needs a model, and
# would make the suite untrustworthy in exactly the place it matters. It asserts the
# PRECONDITIONS df-mission itself checks, using df-mission, and it asserts them in both
# directions -- a check never run against the input it must catch is not known to work.
#
# Everything happens under a temp root. Nothing here reads or writes the running machine's
# config, and no supervisor is ever started.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"
REPO="$(cd "$KIT/../.." && pwd)"
EX="$KIT/example-mission"
ID="EXAMPLE-FIRST-RUN"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }

command -v jq  >/dev/null 2>&1 || { printf 'jq is required to run these tests\n'  >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'git is required to run these tests\n' >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '\n== the kit ships the frame ==\n'

for f in MISSION.md HARD-STOPS.md TICKETS.md; do
  if [ -s "$EX/$f" ]; then ok "example-mission/$f is present and non-empty"
  else bad "example-mission/$f is present and non-empty" "expected at $EX/$f"; fi
done

printf '\n== the frame overrides the standing template, in writing ==\n'

# The iteration prompt is generic and names a tracker. If the example does not say what to
# use instead, an iteration either invents one or stalls.
if grep -q 'TICKETS.md' "$EX/MISSION.md"; then
  ok "MISSION.md names TICKETS.md as this mission's tracker"
else
  bad "MISSION.md names TICKETS.md as this mission's tracker" "no substitute tracker named"
fi

# Confinement must live in HARD-STOPS.md specifically: that is the file df-render-prompt
# inlines into the prompt verbatim. Stated only in MISSION.md it is one indirection away.
if grep -qi 'inside this mission directory' "$EX/HARD-STOPS.md"; then
  ok "HARD-STOPS.md confines writes to the mission directory"
else
  bad "HARD-STOPS.md confines writes to the mission directory" "no confinement rule found"
fi

for pat in 'No git operations' 'No network' 'No outbound message'; do
  if grep -qi "$pat" "$EX/HARD-STOPS.md"; then ok "HARD-STOPS.md forbids: $pat"
  else bad "HARD-STOPS.md forbids: $pat" "not stated"; fi
done

printf '\n== the frame carries no credential and no host ==\n'

# Same two rules the hub page is held to, for the same reason: this frame is copied into
# every instance and read by a headless iteration, so anything host-shaped in it is
# something a stranger's loop would trust.
if grep -rInE '^[^`]*https?://' "$EX" >"$TMP/urls.txt" 2>&1; then
  bad "no absolute URL in the example frame" "$(head -2 "$TMP/urls.txt")"
else
  ok "no absolute URL in the example frame"
fi

if grep -rInE 'Bearer[[:space:]]+[A-Za-z0-9._-]{8,}' "$EX" >"$TMP/tok.txt" 2>&1; then
  bad "no bearer literal in the example frame" "$(head -2 "$TMP/tok.txt")"
else
  ok "no bearer literal in the example frame"
fi

printf '\n== bootstrap installs it where df-mission looks ==\n'

OUT="$TMP/out.txt"
if bash "$KIT/bootstrap.sh" probe-example "$TMP/inst" >"$OUT" 2>&1; then
  ok "bootstrap.sh exits 0"
else
  bad "bootstrap.sh exits 0" "$(tail -3 "$OUT")"
fi

MDIR="$TMP/inst/.df/missions/$ID"
if [ -s "$MDIR/MISSION.md" ]; then
  ok "the example lands at .df/missions/$ID/MISSION.md"
else
  bad "the example lands at .df/missions/$ID/MISSION.md" "not at $MDIR"
fi
for f in HARD-STOPS.md TICKETS.md; do
  if [ -s "$MDIR/$f" ]; then ok "$f came with it"; else bad "$f came with it"; fi
done

# The notepad marker has to sit ABOVE the mission for df-mission's upward walk to stop in
# the right place. Without it the walk runs to / and rescopes to the kit root.
if [ -f "$TMP/inst/repos.manifest.json" ]; then
  ok "repos.manifest.json sits above it, so the notepad walk terminates at the instance"
else
  bad "repos.manifest.json sits above it" "df-mission would resolve a different notepad"
fi

if grep -q "df-mission start $ID" "$OUT"; then
  ok "bootstrap tells the reader how to run it"
else
  bad "bootstrap tells the reader how to run it" "$(tail -5 "$OUT")"
fi

printf '\n== df-mission itself resolves it — asserted with df-mission, not by inspection ==\n'

# `status` reads exactly the path `start` would launch against, and starts nothing. Running
# it from inside the instance exercises the real upward walk rather than a re-implementation
# of it here, which would pass while the real one failed.
DFM="$REPO/boot-kit/scripts/df-mission"
if [ -x "$DFM" ] || [ -f "$DFM" ]; then
  # `env -u NOTEPAD` is not tidiness. df-mission honours an inherited $NOTEPAD ahead of the
  # upward walk, and the supervisor EXPORTS it -- so this suite run from inside a running
  # mission would silently probe that mission's notepad instead of the temp instance and
  # report the example missing. Found exactly that way. Clearing it is what makes the next
  # assertion about the walk rather than about whoever launched the shell.
  ST="$TMP/status.txt"
  ( cd "$TMP/inst" && env -u NOTEPAD bash "$DFM" status "$ID" ) >"$ST" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && grep -q "mission   $ID" "$ST"; then
    ok "df-mission status resolves the example by walking up from the instance"
  else
    bad "df-mission status resolves the example by walking up from the instance" "rc=$rc $(head -2 "$ST")"
  fi

  # The other route in, and the one the supervisor actually uses: $NOTEPAD set explicitly.
  # Asserted separately because the two can diverge -- a copy destination that satisfies the
  # walk can still be wrong for an explicitly-scoped notepad, and vice versa.
  ST3="$TMP/status3.txt"
  ( cd / && NOTEPAD="$TMP/inst" bash "$DFM" status "$ID" ) >"$ST3" 2>&1
  rc3=$?
  if [ "$rc3" -eq 0 ] && grep -q "mission   $ID" "$ST3"; then
    ok "df-mission status resolves it via an explicit \$NOTEPAD, as the supervisor passes it"
  else
    bad "df-mission status resolves it via an explicit \$NOTEPAD" "rc=$rc3 $(head -2 "$ST3")"
  fi

  # The negative: the same command against an id that was never installed must fail. If it
  # succeeded, the checks above would pass for a mission that does not exist.
  ST2="$TMP/status2.txt"
  ( cd "$TMP/inst" && env -u NOTEPAD bash "$DFM" status NO-SUCH-MISSION ) >"$ST2" 2>&1
  rc2=$?
  if [ "$rc2" -ne 0 ]; then
    ok "df-mission status fails for an id that was never installed"
  else
    bad "df-mission status fails for an id that was never installed" "rc=0 — the checks above prove nothing"
  fi
else
  bad "df-mission is present in the repo" "expected at $DFM"
fi

printf '\n== and it reports the absence instead of inventing one ==\n'

# Copy the kit, remove the example, and prove the WARN branch fires. On a copy, so a
# failing test can never damage the real kit.
SBX="$TMP/sandbox"
cp -R "$KIT" "$SBX" 2>/dev/null
rm -rf "$SBX/example-mission"
OUT2="$TMP/out2.txt"
bash "$SBX/bootstrap.sh" probe-example "$TMP/noex" >"$OUT2" 2>&1

if grep -q 'WARN.*example-mission' "$OUT2"; then
  ok "a missing example is reported, not skipped"
else
  bad "a missing example is reported, not skipped" "$(tail -3 "$OUT2")"
fi

if [ -e "$TMP/noex/.df/missions/$ID/MISSION.md" ]; then
  bad "no example is invented when the source is gone"
else
  ok "no example is invented when the source is gone"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
