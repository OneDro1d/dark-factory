#!/usr/bin/env bash
# test-publish-gate-landmarks-env.sh — DF_LANDMARKS_CONF reads the real denylist IN PLACE from
# another checkout, so a git worktree (which has no gitignored landmarks.conf) can run the real
# gate and write the record the merge gate reads.
#
# Why this exists: the merge gate keys on a record the publish gate writes only when it ran
# with the REAL conf. A worktree run could only ever use the placeholder conf, so every PR head
# would have had to be re-verified from the main clone — or the real conf copied into each
# worktree, multiplying the one file that must never be published. Pointing at it is the fix.
#
# Rules under test:
#   R1  DF_LANDMARKS_CONF naming an existing file -> first line says `landmarks: landmarks.conf`
#       (counts as real), and the patterns in THAT file are the ones applied.
#   R2  DF_LANDMARKS_CONF naming a missing file -> falls through to the placeholder, and the
#       first line SAYS placeholder (a dangling override must not look like the real conf).
#   R3  With the real-conf override, a CLEAN run writes the registry record (via
#       DF_PUBLISH_GATE_REGISTRY) — the whole point of the override.
#
# Patterns here are nonsense, matching only planted nonsense — same discipline as the sibling
# gate suites: a committed test must not carry anything the gate exists to find.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
GATE_SRC="$SCRIPTS/publish-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lmenv.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/boot-kit/scripts" "$REPO/docs"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" remote add origin https://example.invalid/acme-org/acme-repo.git
cp "$GATE_SRC" "$REPO/boot-kit/scripts/publish-gate.sh"
cp "$SCRIPTS/landmarks.example.conf" "$REPO/boot-kit/scripts/landmarks.example.conf"
echo clean > "$REPO/docs/a.md"
git -C "$REPO" add -A >/dev/null; git -C "$REPO" commit -qm base

# the "other checkout's" real conf, OUTSIDE the scratch repo
ELSEWHERE="$WORK/elsewhere/landmarks.conf"; mkdir -p "$(dirname "$ELSEWHERE")"
cat > "$ELSEWHERE" <<'CONF'
P1_PATTERN='zzqxalfa'
P2_PATTERN='zzqxbravo'
P3_PATTERN='zzqxcharlie'
P4_PATTERN='zzqxdelta'
P5_PATTERN='zzqxfoxtrot'
P6_PATTERN='zzqxgolf'
P7_PATTERN='zzqxhotel'
P5_EXCLUDE=':!docs/none.md'
P6_EXCLUDE=':!docs/none.md'
P1_CANARY='zzqxalfa'
P2_CANARY='zzqxbravo'
P3_CANARY='zzqxcharlie'
P4_CANARY='zzqxdelta'
P5_CANARY='zzqxfoxtrot'
P6_CANARY='zzqxgolf'
P7_CANARY='zzqxhotel'
CONF
REG="$WORK/registry"

run() { ( cd "$REPO" && env DF_PUBLISH_GATE_REGISTRY="$REG" "$@" bash boot-kit/scripts/publish-gate.sh 2>&1 ); }

echo "== R1: override names an existing file -> real, and ITS patterns apply =="
O="$(run DF_LANDMARKS_CONF="$ELSEWHERE")"
FIRST="$(printf '%s\n' "$O" | head -1)"
[ "$FIRST" = "landmarks: landmarks.conf" ] && ok "R1 first line names the real conf" || bad "R1 first line" "$FIRST"
contains "R1 clean tree is CLEAN" "RESULT: CLEAN" "$O"
printf 'zzqxalfa\n' > "$REPO/docs/a.md"
O="$(run DF_LANDMARKS_CONF="$ELSEWHERE")"
contains "R1 a planted nonsense landmark from the OVERRIDE file is caught" "FINDINGS" "$O"
echo clean > "$REPO/docs/a.md"

echo "== R2: override names a missing file -> placeholder, and says so =="
O="$(run DF_LANDMARKS_CONF="$WORK/does-not-exist.conf")"
FIRST="$(printf '%s\n' "$O" | head -1)"
contains "R2 first line says PLACEHOLDER" "PLACEHOLDER" "$FIRST"

echo "== R3: the real-conf override writes the registry record =="
rm -rf "$REG"
O="$(run DF_LANDMARKS_CONF="$ELSEWHERE")"
contains "R3 CLEAN" "RESULT: CLEAN" "$O"
if [ -f "$REG/acme-org__acme-repo.json" ]; then ok "R3 registry record written for the slug"
else bad "R3 registry record written" "$(ls -R "$REG" 2>&1)"; fi
grep -q '"conf":"real"' "$REG/acme-org__acme-repo.json" 2>/dev/null && ok "R3 record says conf real" || bad "R3 record conf" "$(cat "$REG/acme-org__acme-repo.json" 2>&1)"
rm -rf "$REG"
O="$(run DF_LANDMARKS_CONF="$WORK/does-not-exist.conf")"
[ -f "$REG/acme-org__acme-repo.json" ] && bad "R3 placeholder run must NOT write a record" "written" || ok "R3 placeholder run writes no record"

echo
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
