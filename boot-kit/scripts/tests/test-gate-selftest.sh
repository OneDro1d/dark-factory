#!/usr/bin/env bash
# test-gate-selftest.sh — prove gate-selftest.sh says how much of the config it pins.
#
# gate-selftest.sh plants every canary the landmark config DEFINES and asserts each class
# FIRES. That is a real property and it stays. What it has never said is how much of each
# class it actually reached: a pattern is an ALTERNATION OF BRANCHES, one canary proves one
# branch, and the score is printed per CLASS. On 2026-08-24 the real config held roughly 61
# branches pinned by 11 canaries and the tool printed `SELF-TEST PASSED — all 7 classes
# fire`. Deleting seventeen of P4's eighteen branches would not have moved that line.
#
# A scan that pins a sixth of what it covers looks IDENTICAL to one that pins all of it
# unless it says so. So the property under test here is not "more canaries" — 61 canaries
# is a maintenance burden that rots, and a canary per branch re-derives the config from
# itself, which is the original circularity. The property is that the NUMBER IS VISIBLE,
# and that it is visible on the summary line, where the reader who reads one line sees it.
#
# Everything runs in a SCRATCH repo under $TMPDIR with a synthetic landmark config. A test
# that proved this by planting a real landmark in the real repo would create the very
# condition the gate exists to detect.
#
# Usage: bash boot-kit/scripts/tests/test-gate-selftest.sh
# Exit:  0 = all rules hold   1 = at least one does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
GATE_SRC="$SCRIPTS/publish-gate.sh"
SELFTEST_SRC="$SCRIPTS/gate-selftest.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

[ -f "$SELFTEST_SRC" ] || { echo "FAIL  gate-selftest.sh does not exist at $SELFTEST_SRC"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Neutral nonsense tokens only. An earlier sibling suite used realistic canaries copied out
# of landmarks.example.conf and the REAL landmark config matched four of them, so adding
# the test made publish-gate FAIL on the repo. A committed test that carries
# landmark-SHAPED strings is itself a landmark; "pattern X matches canary X" is all the
# harness needs, and nonsense satisfies it while matching nobody's real pattern, ever.
# EVERY config written here declares P5_EXCLUDE and P6_EXCLUDE, and it is not decoration.
# publish-gate.sh expands "${P5_EXCL[@]}" under `set -u`, and bash 3.2 — the /bin/bash on
# every macOS — treats an EMPTY array expansion as an unbound variable. The subshell dies,
# $P5_OUT comes back empty, and the gate prints `PASS  P5 no secret-shaped strings` over a
# planted AWS key. So a config with no exemptions to declare silently disarms P5 and P6 on
# macOS. Found while writing this suite; the real config and landmarks.example.conf both
# happen to declare non-empty lists, which is why nobody has hit it — but the audience for
# this kit is a stranger writing their own config, with nothing to exempt. Raised as
# ticket 12881209203; it is publish-gate's bug, not this script's, and it is stepped
# around here rather than hidden. The pathspec below excludes a file that does not exist,
# so it changes nothing except the array's emptiness. Delete it when the fix lands.
mk_repo() {
  local d="$WORK/repo"
  rm -rf "$d"; mkdir -p "$d/boot-kit/scripts/tests" "$d/docs"
  git init -q -b main "$d"
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name test
  cp "$GATE_SRC"      "$d/boot-kit/scripts/publish-gate.sh"
  cp "$SELFTEST_SRC"  "$d/boot-kit/scripts/gate-selftest.sh"
  echo clean > "$d/docs/readme.md"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm base
  printf '%s' "$d"
}

write_conf() { cat > "$1/boot-kit/scripts/landmarks.conf"; }
run_st()     { ( cd "$1" && bash boot-kit/scripts/gate-selftest.sh "${@:2}" 2>&1 ); }

# Every class the gate scans must exist in any config we write, or publish-gate aborts on
# an unset variable before the self-test can report anything. FULL is the fully-pinned
# baseline: one branch per class, one canary per class, so coverage is 7 of 7.
conf_full() {
  write_conf "$1" <<'CONF'
P1_PATTERN='zzqxalfa'
P2_PATTERN='zzqxcharlie'
P3_PATTERN='zzqxdelta'
P4_PATTERN='zzqxecho'
P5_PATTERN='zzqxfoxtrot'
P6_PATTERN='zzqxgolf'
P7_PATTERN='zzqxhotel'
P1_CANARY='zzqxalfa in a sentence'
P2_CANARY='zzqxcharlie in a sentence'
P3_CANARY='zzqxdelta in a sentence'
P4_CANARY='zzqxecho in a sentence'
P5_CANARY='zzqxfoxtrot in a sentence'
P6_CANARY='zzqxgolf in a sentence'
P7_CANARY='zzqxhotel in a sentence'
P5_EXCLUDE=':!docs/.no-such-exemption.md'
P6_EXCLUDE=':!docs/.no-such-exemption.md'
CONF
}

echo "=== test-gate-selftest ==="
echo ""

# ── R1  a fully-pinned config reports full coverage and still exits 0 ──────────
D="$(mk_repo)"; conf_full "$D"
OUT="$(run_st "$D")"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE '7 of 7' \
  && ok "R1 a fully-pinned config reports 7 of 7 branches pinned, exit 0" \
  || bad "R1 a fully-pinned config reports 7 of 7 branches pinned, exit 0" "rc=$RC out=$(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"

# ── R2  branches no canary reaches are COUNTED and attributed to their class ───
# The defect itself. P4 below has four branches and one canary: three are unpinned, and
# the tool must say so rather than print a green class line.
D="$(mk_repo)"
write_conf "$D" <<'CONF'
P1_PATTERN='zzqxalfa'
P2_PATTERN='zzqxcharlie'
P3_PATTERN='zzqxdelta'
P4_PATTERN='zzqxecho|zzqxecho2|zzqxecho3|zzqxecho4'
P5_PATTERN='zzqxfoxtrot'
P6_PATTERN='zzqxgolf'
P7_PATTERN='zzqxhotel'
P1_CANARY='zzqxalfa in a sentence'
P2_CANARY='zzqxcharlie in a sentence'
P3_CANARY='zzqxdelta in a sentence'
P4_CANARY='zzqxecho in a sentence'
P5_CANARY='zzqxfoxtrot in a sentence'
P6_CANARY='zzqxgolf in a sentence'
P7_CANARY='zzqxhotel in a sentence'
P5_EXCLUDE=':!docs/.no-such-exemption.md'
P6_EXCLUDE=':!docs/.no-such-exemption.md'
CONF
OUT="$(run_st "$D")"
printf '%s' "$OUT" | grep -qE '^ *P4 .*4 branches' && printf '%s' "$OUT" | grep -qE '^ *P4 .*1 pinned' \
  && ok "R2 an under-pinned class reports its branch and pinned counts" \
  || bad "R2 an under-pinned class reports its branch and pinned counts" "$(printf '%s' "$OUT" | grep -E '^ *P4' | tr '\n' ' ')"

# ── R3  the SUMMARY line carries the aggregate — the whole point of the ticket ─
# A per-class table nobody scrolls to is the same defect one indent deeper. The line that
# says PASSED must itself say how much was pinned, or a reader who reads one line reads a
# claim the evidence does not support.
printf '%s' "$OUT" | grep -E 'SELF-TEST PASSED' | grep -qE '7 of 10' \
  && ok "R3 the SELF-TEST PASSED line carries the aggregate coverage (7 of 10)" \
  || bad "R3 the SELF-TEST PASSED line carries the aggregate coverage (7 of 10)" "$(printf '%s' "$OUT" | grep -E 'SELF-TEST' | tr '\n' ' ')"

# ── R4  branch counting is structural, not a naive split on '|' ────────────────
# `tr '|' '\n' | wc -l` is the obvious implementation and it is wrong in both directions
# that matter: a '|' inside a group is an alternation of the GROUP, and a '|' inside a
# bracket expression is a literal character. P1 below is TWO branches. A naive count says
# four, which inflates the denominator and makes coverage look worse than it is —
# a wrong number in the safe direction is still a wrong number, and it trains the reader
# to ignore the line.
D="$(mk_repo)"
write_conf "$D" <<'CONF'
P1_PATTERN='(^|[^A-Za-z])zzqxalfa($|[^A-Za-z])|[a|b]zzqxbravo'
P2_PATTERN='zzqxcharlie'
P3_PATTERN='zzqxdelta'
P4_PATTERN='zzqxecho'
P5_PATTERN='zzqxfoxtrot'
P6_PATTERN='zzqxgolf'
P7_PATTERN='zzqxhotel'
P1_CANARY=' zzqxalfa '
P2_CANARY='zzqxcharlie in a sentence'
P3_CANARY='zzqxdelta in a sentence'
P4_CANARY='zzqxecho in a sentence'
P5_CANARY='zzqxfoxtrot in a sentence'
P6_CANARY='zzqxgolf in a sentence'
P7_CANARY='zzqxhotel in a sentence'
P5_EXCLUDE=':!docs/.no-such-exemption.md'
P6_EXCLUDE=':!docs/.no-such-exemption.md'
CONF
OUT="$(run_st "$D")"
printf '%s' "$OUT" | grep -qE '^ *P1 .*2 branches' \
  && ok "R4 '|' inside a group and inside a bracket expression is not a top-level branch" \
  || bad "R4 '|' inside a group and inside a bracket expression is not a top-level branch" "$(printf '%s' "$OUT" | grep -E '^ *P1' | tr '\n' ' ')"

# ── R9  a POSIX class inside a bracket expression does not end the bracket ─────
# `[[:digit:]|x]` carries a second ']' that belongs to the class, not to the bracket. A
# splitter that closes on the first one ends the bracket early, and the '|' that follows
# reads as a top-level branch — one pattern counted as two. Nothing in this repo's config
# does that today. The counter IS the deliverable of this change, so it is correct rather
# than correct by luck.
D="$(mk_repo)"
write_conf "$D" <<'CONF'
P1_PATTERN='[[:digit:]|x]zzqxalfa'
P2_PATTERN='zzqxcharlie'
P3_PATTERN='zzqxdelta'
P4_PATTERN='zzqxecho'
P5_PATTERN='zzqxfoxtrot'
P6_PATTERN='zzqxgolf'
P7_PATTERN='zzqxhotel'
P1_CANARY='xzzqxalfa in a sentence'
P2_CANARY='zzqxcharlie in a sentence'
P3_CANARY='zzqxdelta in a sentence'
P4_CANARY='zzqxecho in a sentence'
P5_CANARY='zzqxfoxtrot in a sentence'
P6_CANARY='zzqxgolf in a sentence'
P7_CANARY='zzqxhotel in a sentence'
P5_EXCLUDE=':!docs/.no-such-exemption.md'
P6_EXCLUDE=':!docs/.no-such-exemption.md'
CONF
OUT="$(run_st "$D")"
printf '%s' "$OUT" | grep -qE '^ *P1 +1 branches' \
  && ok "R9 a POSIX class inside a bracket expression does not end the bracket early" \
  || bad "R9 a POSIX class inside a bracket expression does not end the bracket early" "$(printf '%s' "$OUT" | grep -E '^ *P1' | tr '\n' ' ')"

# ── R5  unpinned branches are identified by INDEX, never by VALUE ──────────────
# The landmark config is a list of the exact nouns that must not be published. A report
# that echoes an unpinned branch to say it is unpinned turns the instrument into the leak.
D="$(mk_repo)"
write_conf "$D" <<'CONF'
P1_PATTERN='zzqxalfa|zzqxsecretbranch'
P2_PATTERN='zzqxcharlie'
P3_PATTERN='zzqxdelta'
P4_PATTERN='zzqxecho'
P5_PATTERN='zzqxfoxtrot'
P6_PATTERN='zzqxgolf'
P7_PATTERN='zzqxhotel'
P1_CANARY='zzqxalfa in a sentence'
P2_CANARY='zzqxcharlie in a sentence'
P3_CANARY='zzqxdelta in a sentence'
P4_CANARY='zzqxecho in a sentence'
P5_CANARY='zzqxfoxtrot in a sentence'
P6_CANARY='zzqxgolf in a sentence'
P7_CANARY='zzqxhotel in a sentence'
P5_EXCLUDE=':!docs/.no-such-exemption.md'
P6_EXCLUDE=':!docs/.no-such-exemption.md'
CONF
OUT="$(run_st "$D")"
printf '%s' "$OUT" | grep -q 'zzqxsecretbranch' \
  && bad "R5 an unpinned branch is named by index, not printed" "the branch text appeared in the report" \
  || ok "R5 an unpinned branch is named by index, not printed"
printf '%s' "$OUT" | grep -qE '#2' \
  && ok "R5b the unpinned branch is identified by its index" \
  || bad "R5b the unpinned branch is identified by its index" "$(printf '%s' "$OUT" | grep -E '^ *P1' | tr '\n' ' ')"
OUT="$(run_st "$D" --show)"
printf '%s' "$OUT" | grep -q 'zzqxsecretbranch' \
  && ok "R5c --show unmasks for local operator use" \
  || bad "R5c --show unmasks for local operator use"

# ── R6  the class list comes from the CONFIG, not from a hardcoded P1..P7 ──────
# The same absence-shaped defect one level up. A class the config defines and the gate
# never scans protects nothing, and a self-test iterating its own hardcoded list cannot
# see it — it would report full coverage of seven classes while an eighth sat inert. The
# tool must discover P10 here and fail on it, because publish-gate does not scan P10.
D="$(mk_repo)"; conf_full "$D"
cat >> "$D/boot-kit/scripts/landmarks.conf" <<'CONF'
P10_PATTERN='zzqxindia'
P10_CANARY='zzqxindia in a sentence'
CONF
OUT="$(run_st "$D")"; RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'P10' \
  && ok "R6 a class the config defines but the gate never scans is caught, not skipped" \
  || bad "R6 a class the config defines but the gate never scans is caught, not skipped" "rc=$RC out=$(printf '%s' "$OUT" | grep -E 'P10|SELF-TEST' | tr '\n' ' ')"

# ── R7  a class with a pattern and NO canary is still an error ─────────────────
# Pre-existing behaviour. Coverage reporting must not soften it into "0 of N pinned",
# which reads as a measurement when it is an absence of one.
D="$(mk_repo)"
write_conf "$D" <<'CONF'
P1_PATTERN='zzqxalfa'
P2_PATTERN='zzqxcharlie'
P3_PATTERN='zzqxdelta'
P4_PATTERN='zzqxecho'
P5_PATTERN='zzqxfoxtrot'
P6_PATTERN='zzqxgolf'
P7_PATTERN='zzqxhotel'
P2_CANARY='zzqxcharlie in a sentence'
P3_CANARY='zzqxdelta in a sentence'
P4_CANARY='zzqxecho in a sentence'
P5_CANARY='zzqxfoxtrot in a sentence'
P6_CANARY='zzqxgolf in a sentence'
P7_CANARY='zzqxhotel in a sentence'
P5_EXCLUDE=':!docs/.no-such-exemption.md'
P6_EXCLUDE=':!docs/.no-such-exemption.md'
CONF
OUT="$(run_st "$D")"; RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qE 'ERROR +P1' \
  && ok "R7 a class with no canary is still an ERROR, not a 0-of-N coverage row" \
  || bad "R7 a class with no canary is still an ERROR, not a 0-of-N coverage row" "rc=$RC out=$(printf '%s' "$OUT" | grep -E 'P1|SELF-TEST' | tr '\n' ' ')"

# ── R8  the canary probe file is removed — the tree is clean afterwards ────────
D="$(mk_repo)"; conf_full "$D"
run_st "$D" >/dev/null
DIRTY="$(git -C "$D" status --porcelain --untracked-files=all | grep -v 'landmarks.conf' || true)"
[ -z "$DIRTY" ] \
  && ok "R8 the canary probe file is removed — the tree is clean afterwards" \
  || bad "R8 the canary probe file is removed — the tree is clean afterwards" "$DIRTY"

echo ""
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
