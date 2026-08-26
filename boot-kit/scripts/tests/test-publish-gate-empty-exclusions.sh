#!/usr/bin/env bash
# test-publish-gate-empty-exclusions.sh — prove an EMPTY exemption list cannot disarm a scan.
#
# publish-gate.sh builds P5_EXCL and P6_EXCL as bash ARRAYS from the landmark config, then
# expands them as "${P5_EXCL[@]}". Under `set -u`, bash 3.2 — which is /bin/bash on every
# macOS — treats that expansion on an EMPTY array as an unbound variable and aborts:
#
#     $ bash -c 'set -uo pipefail; A=(); echo "${A[@]}"'
#     bash: A[@]: unbound variable
#
# The expansion sits inside $(...), so the abort kills the substitution and the surrounding
# script keeps running with P5_OUT empty — and EMPTY OUTPUT IS THE CLEAN BRANCH. The gate
# then prints `PASS  P5 no secret-shaped strings` over a planted key.
#
# Why this is the worst shape of the bug rather than an edge case: the exemption lists are
# the one part of the config a reader is MEANT to leave out. Both the real gitignored
# landmarks.conf and the shipped landmarks.example.conf happen to declare non-empty lists,
# which is why nobody here has hit it — but the audience for this kit is a stranger who
# clones it and writes their own config with nothing to exempt. They get a gate whose
# secret check and personal-identifier check are both inert, reporting PASS.
#
# gate-selftest.sh cannot catch this: it sources the same config, so a config with no
# exemptions has no exemption bug for it to see.
#
# The canaries here are NEUTRAL NONSENSE, not realistic secrets, and the scratch configs
# define nonsense patterns to match them. The bug is in the array plumbing and is entirely
# independent of what the pattern says — while a committed test carrying a genuinely
# secret-SHAPED string would itself be the thing P5 exists to find. Same reasoning as
# test-gate-selftest.sh, which learned it the hard way.
#
# Everything runs in a SCRATCH repo under $TMPDIR. See ticket: an EMPTY P5_EXCLUDE
# silently disarms P5 and P6 on macOS.
#
# Usage: bash boot-kit/scripts/tests/test-publish-gate-empty-exclusions.sh
# Exit:  0 = all rules hold   1 = at least one does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
GATE_SRC="$SCRIPTS/publish-gate.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

[ -f "$GATE_SRC" ] || { echo "FAIL  publish-gate.sh does not exist at $GATE_SRC"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/emptyexcl.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A scratch repo carrying only the gate and two content files. `docs/planted.md` is where a
# canary goes; `docs/exempt.md` is the file the non-empty-exemption regression guards use.
mk_repo() {
  local d="$WORK/repo"
  rm -rf "$d"; mkdir -p "$d/boot-kit/scripts" "$d/docs"
  git init -q -b main "$d"
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name test
  cp "$GATE_SRC" "$d/boot-kit/scripts/publish-gate.sh"
  echo clean > "$d/docs/planted.md"
  echo clean > "$d/docs/exempt.md"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm base
  printf '%s' "$d"
}

write_conf() { cat > "$1/boot-kit/scripts/landmarks.conf"; }
run_gate()   { ( cd "$1" && bash boot-kit/scripts/publish-gate.sh 2>&1 ); }
plant()      { printf '%s\n' "$2" > "$1/docs/$3"; }

# Every pattern the gate requires, all nonsense. P5/P6 are the two under test; the rest are
# given patterns that match nothing in the scratch tree so they stay quiet and any P5/P6
# verdict is unambiguous.
conf_body() {
  cat <<'CONF'
P1_PATTERN='zzqxalfa'
P2_PATTERN='zzqxbravo'
P3_PATTERN='zzqxcharlie'
P4_PATTERN='zzqxdelta'
P5_PATTERN='zzqxfoxtrot'
P6_PATTERN='zzqxgolf'
P7_PATTERN='zzqxhotel'
CONF
}

# ── R1  P5 with the exemption list ABSENT still catches a planted canary ───────
D="$(mk_repo)"; { conf_body; } | write_conf "$D"
plant "$D" 'zzqxfoxtrot in a sentence' planted.md
OUT="$(run_gate "$D")"; RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qE '^FAIL +P5' \
  && ok "R1 P5 fires on a planted canary when P5_EXCLUDE is absent" \
  || bad "R1 P5 fires on a planted canary when P5_EXCLUDE is absent" "rc=$RC p5=$(printf '%s' "$OUT" | grep -E 'P5' | tr '\n' ' ')"

# ── R2  P6 with the exemption list ABSENT still catches a planted canary ───────
D="$(mk_repo)"; { conf_body; } | write_conf "$D"
plant "$D" 'zzqxgolf in a sentence' planted.md
OUT="$(run_gate "$D")"; RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qE '^FAIL +P6' \
  && ok "R2 P6 fires on a planted canary when P6_EXCLUDE is absent" \
  || bad "R2 P6 fires on a planted canary when P6_EXCLUDE is absent" "rc=$RC p6=$(printf '%s' "$OUT" | grep -E 'P6' | tr '\n' ' ')"

# ── R3  an explicitly EMPTY string is the same case as absent ──────────────────
# A reader with nothing to exempt is at least as likely to write P5_EXCLUDE='' as to omit
# the line. Both produce a zero-length array and must behave identically.
D="$(mk_repo)"; { conf_body; printf "P5_EXCLUDE=''\nP6_EXCLUDE=''\n"; } | write_conf "$D"
plant "$D" 'zzqxfoxtrot in a sentence' planted.md
OUT="$(run_gate "$D")"; RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qE '^FAIL +P5' \
  && ok "R3 P5 fires when P5_EXCLUDE is declared as an empty string" \
  || bad "R3 P5 fires when P5_EXCLUDE is declared as an empty string" "rc=$RC p5=$(printf '%s' "$OUT" | grep -E 'P5' | tr '\n' ' ')"

# ── R4  REGRESSION GUARD: a non-empty P5_EXCLUDE still exempts its named file ──
# The fix must make an empty list expand to NOTHING, not make every list expand to nothing.
# This rule is expected to be GREEN before the fix as well as after — it protects the
# behaviour that already works, and it is the assertion that would catch a "fix" that
# simply deleted the exemption feature.
D="$(mk_repo)"; { conf_body; printf "P5_EXCLUDE=':!docs/exempt.md'\n"; } | write_conf "$D"
plant "$D" 'zzqxfoxtrot in a sentence' exempt.md
OUT="$(run_gate "$D")"; RC=$?
printf '%s' "$OUT" | grep -qE '^PASS +P5' \
  && ok "R4 a non-empty P5_EXCLUDE still exempts the file it names" \
  || bad "R4 a non-empty P5_EXCLUDE still exempts the file it names" "rc=$RC p5=$(printf '%s' "$OUT" | grep -E 'P5' | tr '\n' ' ')"

# ── R5  REGRESSION GUARD: a non-empty P6_EXCLUDE still exempts its named file ──
D="$(mk_repo)"; { conf_body; printf "P6_EXCLUDE=':!docs/exempt.md'\n"; } | write_conf "$D"
plant "$D" 'zzqxgolf in a sentence' exempt.md
OUT="$(run_gate "$D")"; RC=$?
printf '%s' "$OUT" | grep -qE '^PASS +P6' \
  && ok "R5 a non-empty P6_EXCLUDE still exempts the file it names" \
  || bad "R5 a non-empty P6_EXCLUDE still exempts the file it names" "rc=$RC p6=$(printf '%s' "$OUT" | grep -E 'P6' | tr '\n' ' ')"

# ── R6  a clean tree with NO exemptions still PASSES ──────────────────────────
# The cheapest wrong fix is one that makes the scan fire unconditionally, which would turn
# R1-R3 green while destroying the gate. This pins the other direction: no canary planted,
# no exemptions declared, both classes must report PASS.
D="$(mk_repo)"; { conf_body; } | write_conf "$D"
OUT="$(run_gate "$D")"; RC=$?
printf '%s' "$OUT" | grep -qE '^PASS +P5' && printf '%s' "$OUT" | grep -qE '^PASS +P6' \
  && ok "R6 a clean tree with no exemptions declared still passes P5 and P6" \
  || bad "R6 a clean tree with no exemptions declared still passes P5 and P6" "rc=$RC out=$(printf '%s' "$OUT" | grep -E 'P5|P6' | tr '\n' ' ')"

# ── R7  STRUCTURAL: no config-derived array is expanded bare ───────────────────
# R1-R3 pin the two working-tree call sites that exist today. This pins the SHAPE, so a
# third scan added later with the same bare "${ARR[@]}" is caught by this suite rather than
# by a stranger. It also covers the --history call site, which R1-R3 do not exercise and
# where the same bug silently empties the P8 HISTORY scan.
#
# Detection is by ELIMINATION, not by matching the bad form directly: the guarded idiom
# ${P5_EXCL[@]+"${P5_EXCL[@]}"} CONTAINS the bare form "${P5_EXCL[@]}" as its own second
# half, so a naive grep for the bare form flags the fix as the bug. (Written that way
# first, and it stayed RED across a correct fix — the matcher could not tell them apart.)
# So: delete every COMPLETE guarded idiom, then any surviving array expansion is bare.
#
# Only arrays built FROM THE CONFIG are in scope: EXCL is a hardcoded five-element literal
# that cannot be empty, and demanding the guarded idiom there would be noise.
# Whole-line comments are removed first: the fix is DOCUMENTED at the array-construction
# site, and that comment necessarily quotes the bare form in order to warn against it. A
# comment cannot execute, so it cannot carry the bug — but it can carry the string. (A
# trailing comment on a code line keeps its code half, which is the behaviour wanted.)
# Comments are BLANKED, not deleted, so the reported line number is the real one in
# publish-gate.sh. Deleting them renumbers everything after the first comment, and a gate
# finding that cites a line the reader cannot find is worse than one that cites none.
STRIPPED="$(sed 's/^[[:space:]]*#.*//' "$GATE_SRC" \
            | sed -e 's/\${P5_EXCL\[@\]+"\${P5_EXCL\[@\]}"}//g' \
                  -e 's/\${P6_EXCL\[@\]+"\${P6_EXCL\[@\]}"}//g')"
BARE="$(printf '%s\n' "$STRIPPED" | grep -nE '\$\{(P5_EXCL|P6_EXCL)\[@\]' || true)"
[ -z "$BARE" ] \
  && ok "R7 no config-derived exemption array is expanded bare in publish-gate.sh" \
  || bad "R7 no config-derived exemption array is expanded bare in publish-gate.sh" "$(printf '%s' "$BARE" | tr '\n' ' ')"

echo ""
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
