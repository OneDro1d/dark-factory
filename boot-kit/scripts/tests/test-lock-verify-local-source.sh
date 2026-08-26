#!/usr/bin/env bash
# test-lock-verify-local-source.sh — L5 must resolve `local:` the way the INSTALLERS do.
#
# THE DEFECT, measured 2026-08-26 on two live AWS/ESO Coder workspaces. `install.sh
# --lock=instances/<name>/loom.lock.json` completed correctly: it linked
# each `local:`-sourced skill at <repo>/skills/<name>, which is where those files are and
# where every installer in the estate resolves `local:skills/<name>` to — `readlink` on the
# machine confirms it. The verifier that install.sh then runs reported:
#
#   DRIFT L5 installed but pointing OUTSIDE this instance:
#     <skill> -> declared source does not exist:
#       <repo>/instances/coder-eso-aws--loom/skills/<skill>
#     another instance sharing this LOOM_LIVE installed over these links.
#
# The remedy it printed was wrong too: nothing had installed over anything.
#
# ⚠️ The two skills are named in the ticket, not here. They are that lane's own `local:`
# content, and Tier 1 does not carry a lane's skill names — a rule this repo enforces over
# its own tracked tree (test-stance-skill-tiering.sh R3), and which caught THIS FILE the
# moment it was committed. The defect is about resolution, so the fixture below uses a
# neutral `alpha` and loses nothing by it.
#
# lock-verify sets ROOT to the LOCKFILE'S OWN DIRECTORY (line 47) and resolves `local:`
# against it. For the root lockfile that IS the repo root and the two agree, which is why
# nobody saw it. Name an instance lockfile and they diverge — and the instance convention
# is exactly what `--lock` exists to serve.
#
# WHAT THE INSTALLERS ACTUALLY DO, all four checked rather than assumed:
#   loom-storage/install.sh:198              local:*) "$(pwd)/..."   pwd = the repo root
#   loom_storage-ESO/install.sh:148          local:*) "$(pwd)/..."   pwd = the repo root
#   tier2-org/install.sh:142                 local:*) "$ROOT/..."    ROOT = the repo root
#   dark-factory-onedroid/install.sh:142     local:*) "$ROOT/..."    ROOT = the repo root
# Four readers, one meaning: `local:` is relative to the REPO, never to the lockfile.
#
# Worse than a wrong answer, this is a wrong answer in the SAFE-LOOKING direction of the
# pair. lock-verify's other resolution defect this month made it print PASS about a machine
# nobody asked about; this one prints DRIFT about a machine that is correct. A false DRIFT
# does not hide a problem, but it does something almost as expensive: it makes the one
# verdict that should mean "this instance is right" mean nothing on every instance.
#
# The vendor base is a SEPARATE question and stays per-instance: each instance directory
# carries a committed `vendor` symlink back to the repo-root cache precisely so that
# vendorDir resolves from there. Only `local:` moves.
#
# Usage: bash boot-kit/scripts/tests/test-lock-verify-local-source.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = cannot run
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LV="${LOCK_VERIFY:-$HERE/../lock-verify.sh}"
[ -f "$LV" ] || { echo "missing $LV"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to find: $2" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "did NOT expect: $2" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lvlocal.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT

# --- a repo shaped like a real Tier-3 instance repo -----------------------------------
# repo/
#   install.sh                     <- the marker that says "this is the repo root"
#   skills/alpha/SKILL.md          <- local: content lives HERE, at the root
#   vendor/                        <- the cache both lockfiles share
#   instances/one/loom.lock.json   <- the per-instance record
#   instances/one/vendor -> ../../vendor
REPO="$WORK/repo"
mkdir -p "$REPO/skills/alpha" "$REPO/vendor" "$REPO/instances/one"
printf '# alpha\n' > "$REPO/skills/alpha/SKILL.md"
printf '#!/usr/bin/env bash\n# marker only\n' > "$REPO/install.sh"
ln -s ../../vendor "$REPO/instances/one/vendor"

cat > "$REPO/instances/one/loom.lock.json" <<'JSON'
{
  "instance": "one",
  "vendorDir": "vendor",
  "upstreams": {},
  "install": {
    "skills": ["alpha"],
    "skillSources": { "alpha": "local:skills/alpha" },
    "hooks": [],
    "hookSources": {}
  }
}
JSON

# The live tree an installer would have produced: the link points at the REPO-ROOT skill.
LIVE="$WORK/live"; mkdir -p "$LIVE/skills" "$LIVE/hooks"
ln -s "$REPO/skills/alpha" "$LIVE/skills/alpha"

run() { LOOM_LIVE="$LIVE" bash "$LV" --lock="$1" 2>&1; }

echo "=== L5 accepts what the installer produced ==="
OUT="$(run "$REPO/instances/one/loom.lock.json")"
# A1 is the whole ticket: a correct install must not be reported as drifted.
absent   "A1 L5 does not report DRIFT on a correct instance install" "DRIFT L5" "$OUT"
contains "A2 L5 passes"  "PASS  L5" "$OUT"
absent   "A3 no 'declared source does not exist' for the local: skill" \
         "declared source does not exist" "$OUT"
absent   "A4 the instance directory is not used as the local: base" \
         "instances/one/skills/alpha" "$OUT"

echo "=== and still FAILS on a genuinely mispointed link ==="
# Without this the fix could be 'stop checking local: skills', which passes A1 by blinding
# L5 rather than by resolving correctly. A validator never shown failing is not evidence.
mkdir -p "$WORK/elsewhere/alpha"
printf '# not ours\n' > "$WORK/elsewhere/alpha/SKILL.md"
rm "$LIVE/skills/alpha"
ln -s "$WORK/elsewhere/alpha" "$LIVE/skills/alpha"
OUT="$(run "$REPO/instances/one/loom.lock.json")"
contains "B1 a link into another tree is still DRIFT" "DRIFT L5" "$OUT"
contains "B2 and it says where the link actually goes" "resolves to" "$OUT"

echo "=== and still FAILS when the declared local: source is really absent ==="
rm "$LIVE/skills/alpha"
ln -s "$REPO/skills/alpha" "$LIVE/skills/alpha"
mv "$REPO/skills/alpha" "$REPO/skills/alpha-moved"
OUT="$(run "$REPO/instances/one/loom.lock.json")"
contains "C1 a missing local: source is still DRIFT" "DRIFT L5" "$OUT"
mv "$REPO/skills/alpha-moved" "$REPO/skills/alpha"

echo "=== the ROOT lockfile keeps behaving exactly as before ==="
# The case that has always worked, asserted so the fix cannot regress it. Here the
# lockfile IS at the repo root, so the old rule and the new one agree.
cp "$REPO/instances/one/loom.lock.json" "$REPO/loom.lock.json"
rm "$LIVE/skills/alpha"
ln -s "$REPO/skills/alpha" "$LIVE/skills/alpha"
OUT="$(run "$REPO/loom.lock.json")"
absent   "D1 root lockfile: no DRIFT on a correct install" "DRIFT L5" "$OUT"
contains "D2 root lockfile: L5 passes" "PASS  L5" "$OUT"

echo "=== vendorDir stays anchored to the LOCKFILE, not to the repo ==="
# Only `local:` moves. Each instance dir carries a committed `vendor` symlink so the
# vendor base is deliberately per-instance; widening that too would be a different bug.
OUT="$(run "$REPO/instances/one/loom.lock.json")"
contains "E1 vendor is reported under the instance directory" "instances/one/vendor" "$OUT"

echo "=== no repo marker above the lockfile: fall back, do not crash ==="
# A lockfile with no installer in any ancestor. The old behaviour (lockfile's own dir) is
# the only sane base left, and it must degrade to that rather than walking to /.
BARE="$WORK/bare"; mkdir -p "$BARE/skills/alpha" "$BARE/vendor"
printf '# alpha\n' > "$BARE/skills/alpha/SKILL.md"
cp "$REPO/instances/one/loom.lock.json" "$BARE/loom.lock.json"
rm "$LIVE/skills/alpha"
ln -s "$BARE/skills/alpha" "$LIVE/skills/alpha"
OUT="$(run "$BARE/loom.lock.json")"
absent   "F1 no marker: resolves against the lockfile's own directory" "DRIFT L5" "$OUT"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every case above" from "asserted nothing" -- both exit 0 -- so the count is
# DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
