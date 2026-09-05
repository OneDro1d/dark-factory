#!/usr/bin/env bash
# test-audit-kit-gaps.sh — the fleet gap detector must refuse to pass vacuously.
#
# ⚠️ THIS SUITE EXISTS BECAUSE THE DETECTOR SHIPPED WITH TWO OF THE BUGS IT HUNTS, and both
# were caught by DISBELIEVING A ZERO rather than by reading the code:
#
#   1. it looked for the settings template at ONE path, so a kit without one was SKIPPED
#      silently and counted clean. Five kits reported no findings; three had never been read.
#   2. it matched hook names by BASENAME, so `agent-notepad/hooks/pre-compact.sh` counted as
#      wired because the template contained `engram-pre-compact.sh` — same ending.
#
# Both are the same shape as the defects it is built to find: a check that answers "fine"
# without having looked. So the cases below are mostly about the DETECTOR'S OWN honesty, not
# about the fleet.
#
# Engram is the memory store the audited kits name. What it is and how to reach it is
# documented in exactly one place:
# [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
T1="$(cd "$SELF/../../.." && pwd)"
AUDIT="$T1/boot-kit/scripts/audit-kit-gaps.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== A: present, and refuses to guess ==="
if [ -f "$AUDIT" ]; then ok "A: audit exists"; else bad "A: audit exists" "not promoted"; fi

# ⚠️ NO ARGUMENTS MUST NOT MEAN "SCAN A DEFAULT LIST". A default would be one machine's
# layout, and an audit that scans nothing while exiting 0 is worse than no audit.
if python3 "$AUDIT" >/dev/null 2>&1; then
  bad "A: refuses to run with no kit roots" "exited 0 having scanned nothing"
else
  ok "A: refuses to run with no kit roots"
fi

# ⚠️ CAPTURE FIRST, THEN MATCH. `python3 "$AUDIT" | grep -q` under `set -o pipefail` takes
# python's deliberate exit 2 as the PIPELINE's status, so a correct refusal reads as a failed
# assertion. The script was right and the test was wrong — the same caller-vs-callee shape as
# the VR7 link-check bug, reproduced inside the suite written to catch such things.
USAGE_OUT="$(python3 "$AUDIT" 2>&1 || true)"
case "$USAGE_OUT" in *usage:*) ok "A: prints usage" ;;
  *) bad "A: prints usage" "a refusal with no instruction is just a failure" ;; esac

echo "=== B: a kit declaring hooks with NO settings template is a FINDING, not a skip ==="
K="$TMP/no-template"
mkdir -p "$K"
cat > "$K/loom.lock.json" <<'JSON'
{ "instance": "t-no-template", "vendorDir": "vendor",
  "install": { "hooks": ["a.sh"], "hookSources": { "a.sh": "local:hooks/a.sh" } } }
JSON
OUT="$(python3 "$AUDIT" "$K" 2>&1)"
case "$OUT" in *"NO settings template"*) ok "B: absence of a template is reported" ;;
  *) bad "B: absence of a template is reported" "silently skipped — the original bug" ;; esac

echo "=== C: hook matching is by FULL declared name, not by basename ==="
K2="$TMP/substring"
mkdir -p "$K2/boot-kit/config"
cat > "$K2/loom.lock.json" <<'JSON'
{ "instance": "t-substring", "vendorDir": "vendor",
  "install": { "hooks": ["np/hooks/pre-compact.sh"],
               "hookSources": { "np/hooks/pre-compact.sh": "local:x" } } }
JSON
# the template wires a DIFFERENT hook whose name ENDS with the same characters
cat > "$K2/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": { "PreCompact": [ { "matcher": "", "hooks": [
  { "type": "command", "command": "__HOME__/.claude/hooks/engram-pre-compact.sh" } ] } ] } }
JSON
OUT2="$(python3 "$AUDIT" "$K2" 2>&1)"
case "$OUT2" in *"np/hooks/pre-compact.sh"*) ok "C: substring near-miss is still reported" ;;
  *) bad "C: substring near-miss is still reported" \
        "engram-pre-compact.sh swallowed pre-compact.sh — the original bug" ;; esac

echo "=== D: a recorded decision is not a finding ==="
# ⚠️ The third state. A hook wired on ONE machine and deliberately absent from a template
# several instances share is neither "in the template" nor "inert". Reporting it forever is a
# false alarm, and the audit committed exactly that against its own fleet.
K3="$TMP/per-instance"
mkdir -p "$K3/boot-kit/config"
cat > "$K3/loom.lock.json" <<'JSON'
{ "instance": "t-per-instance", "vendorDir": "vendor",
  "install": { "hooks": ["solo.sh"], "hookSources": { "solo.sh": "local:x" },
               "$perInstanceWiring": "solo.sh is wired on this machine only, on purpose." } }
JSON
cat > "$K3/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": {} }
JSON
OUT3="$(python3 "$AUDIT" "$K3" 2>&1)"
case "$OUT3" in *"solo.sh: declared"*)
    bad "D: \$perInstanceWiring silences the finding" "reported an already-recorded decision" ;;
  *) ok "D: \$perInstanceWiring silences the finding" ;; esac

echo "=== E: prose ABOUT a dangling reference is not a dangling reference ==="
# Same rule test-binding-invokes-generics learned: match the instruction, not the warning.
K4="$TMP/prose"
mkdir -p "$K4"
cat > "$K4/loom.lock.json" <<'JSON'
{ "instance": "t-prose", "vendorDir": "vendor", "install": { "skills": [] } }
JSON
printf 'It used to open Skill(gone-skill) and that was a dangling reference.\n' \
  > "$K4/START-HERE.md"
OUT4="$(python3 "$AUDIT" "$K4" 2>&1)"
case "$OUT4" in *"cites Skill(gone-skill)"*)
    bad "E: prose about a dangling ref is exempt" "flagged the warning as the defect" ;;
  *) ok "E: prose about a dangling ref is exempt" ;; esac

# ...but a real instruction still is one
printf 'Load Skill(gone-skill) before you start.\n' > "$K4/START-HERE.md"
OUT5="$(python3 "$AUDIT" "$K4" 2>&1)"
case "$OUT5" in *"cites Skill(gone-skill)"*) ok "E: a real instruction is still reported" ;;
  *) bad "E: a real instruction is still reported" "the exemption swallowed the rule" ;; esac

echo "=== F: a declared source that DOES NOT EXIST is a finding, not a skip ==="
# ⚠️ THIS IS THE POLAND CASE, 2026-09-03, AND THE AUDIT MISSED IT LIVE. Two hooks were
# declared `local:boot-kit/hooks/engram-{pre-compact,stop}.sh` after those files were deleted
# in a promotion to Tier 1 that repointed only the SIBLING root lockfile. install.sh printed
# `2 missing`; this audit printed 0 findings, because class 1 opened with
# `if not os.path.exists(f): continue` — it skipped the dead source to hunt a subtler one.
K5="$TMP/dead-source"
mkdir -p "$K5/boot-kit/config"
cat > "$K5/loom.lock.json" <<'JSON'
{ "instance": "t-dead-source", "vendorDir": "vendor",
  "install": { "hooks": ["ghost.sh"],
               "hookSources": { "ghost.sh": "local:boot-kit/hooks/ghost.sh" },
               "hooksUnwired": { "ghost.sh": "not the point of this fixture" } } }
JSON
cat > "$K5/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": {} }
JSON
OUT6="$(python3 "$AUDIT" "$K5" 2>&1)"
case "$OUT6" in *"ghost.sh -> local:boot-kit/hooks/ghost.sh DOES NOT EXIST"*)
    ok "F: dead local: source is reported" ;;
  *) bad "F: dead local: source is reported" "silently skipped — the Poland bug" ;; esac

# and it must be COUNTED, not merely mentioned
case "$OUT6" in *"TOTAL: 0"*)
    bad "F: dead source counts toward TOTAL" "printed but not counted — a zero that lies" ;;
  *) ok "F: dead source counts toward TOTAL" ;; esac

# a source that DOES exist must stay silent
mkdir -p "$K5/boot-kit/hooks"
printf '#!/bin/bash\n' > "$K5/boot-kit/hooks/ghost.sh"
OUT7="$(python3 "$AUDIT" "$K5" 2>&1)"
case "$OUT7" in *"DOES NOT EXIST"*)
    bad "F: a present source is silent" "false positive on a file that is right there" ;;
  *) ok "F: a present source is silent" ;; esac

echo "=== G: an UNVENDORED upstream is UNKNOWN, never a defect ==="
# ⚠️ The verdict that must not collapse. A kit that has never been installed has no vendor/
# tree, so every `upstream:` source in it is unresolvable — and calling that a dangling
# reference prints a failure to PROBE as a fact about the WORLD. df-preflight keeps ok /
# drift / unknown apart for this reason; the audit now does too.
K6="$TMP/unvendored"
mkdir -p "$K6/boot-kit/config"
cat > "$K6/loom.lock.json" <<'JSON'
{ "instance": "t-unvendored", "vendorDir": "vendor",
  "install": { "hooks": ["up.sh"],
               "hookSources": { "up.sh": "upstream:dark-factory/hooks/up.sh" },
               "hooksUnwired": { "up.sh": "not the point of this fixture" } } }
JSON
cat > "$K6/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": {} }
JSON
OUT8="$(python3 "$AUDIT" "$K6" 2>&1)"
case "$OUT8" in *"NOT PROBED / NOT APPLICABLE"*) ok "G: unvendored upstream is named" ;;
  *) bad "G: unvendored upstream is named" "a silent unknown is the class-4 defect itself" ;; esac
case "$OUT8" in *"TOTAL: 0"*) ok "G: unknown is NOT counted as a finding" ;;
  *) bad "G: unknown is NOT counted as a finding" "an unprobed kit reported as broken" ;; esac

# ...but once the upstream IS vendored, a missing file inside it is a real finding
mkdir -p "$K6/vendor/dark-factory/hooks"
OUT9="$(python3 "$AUDIT" "$K6" 2>&1)"
case "$OUT9" in *"up.sh -> upstream:dark-factory/hooks/up.sh DOES NOT EXIST"*)
    ok "G: vendored-but-absent is a real finding" ;;
  *) bad "G: vendored-but-absent is a real finding" \
        "the unknown exemption swallowed the rule it guards" ;; esac

echo "=== H: a STALE vendor checkout is not a dead source ==="
# ⚠️ THE BUG CLASS 4 SHIPPED WITH, CAUGHT THE SAME HOUR. The first version resolved every
# upstream: source against the local vendor WORKING TREE, so this laptop's <a sibling instance repo>
# — vendor at 22e7064 while its lockfiles pin 6ebfbdc0, because this machine never installs
# those instances — produced 18 findings for files that all exist at the pin.
#
# The installer FETCHES AT THE PIN. It never reads whatever is checked out. So the question
# is "is it in the tree at the pinned commit", which `git cat-file -e <pin>:<path>` answers
# no matter where HEAD is. Reporting a stale checkout as a defect is a failure to PROBE
# printed as a fact about the WORLD — the same collapse case G guards, one level in.
K7="$TMP/stale-vendor"
mkdir -p "$K7/boot-kit/config" "$K7/vendor/dark-factory/hooks"
cat > "$K7/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": {} }
JSON
V="$K7/vendor/dark-factory"
git -C "$V" init -q
git -C "$V" config user.email t@example.invalid
git -C "$V" config user.name t
printf '#!/bin/bash\n' > "$V/hooks/at-pin.sh"
git -C "$V" add -A
git -C "$V" commit -qm pinned
PIN="$(git -C "$V" rev-parse HEAD)"
# now move the working tree PAST the pin, deleting the file — exactly a stale checkout
git -C "$V" rm -q "hooks/at-pin.sh"
git -C "$V" commit -qm "later commit without the file"

python3 - "$K7/loom.lock.json" "$PIN" <<'PY'
import json, sys
json.dump({
    "instance": "t-stale-vendor", "vendorDir": "vendor",
    "upstreams": {"dark-factory": {"commit": sys.argv[2]}},
    "install": {
        "hooks": ["at-pin.sh", "never-existed.sh"],
        "hookSources": {
            "at-pin.sh": "upstream:dark-factory/hooks/at-pin.sh",
            "never-existed.sh": "upstream:dark-factory/hooks/never-existed.sh"},
        "hooksUnwired": {"at-pin.sh": "not the point",
                         "never-existed.sh": "not the point"}}},
    open(sys.argv[1], "w"), indent=2)
PY

OUTA="$(python3 "$AUDIT" "$K7" 2>&1)"
case "$OUTA" in *"at-pin.sh ->"*)
    bad "H: present-at-pin is silent though absent from the tree" \
        "reported a stale checkout as a dead source — the 18 false positives" ;;
  *) ok "H: present-at-pin is silent though absent from the tree" ;; esac

# ...and the rule it guards must survive: absent AT THE PIN is still a real finding
case "$OUTA" in *"never-existed.sh -> upstream:dark-factory/hooks/never-existed.sh DOES NOT EXIST"*)
    ok "H: absent-at-pin is still reported" ;;
  *) bad "H: absent-at-pin is still reported" "the staleness exemption swallowed the rule" ;; esac

# ...and a pin this checkout has never fetched is UNKNOWN, not dead
python3 - "$K7/loom.lock.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["upstreams"]["dark-factory"]["commit"] = "0" * 40
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
OUTB="$(python3 "$AUDIT" "$K7" 2>&1)"
case "$OUTB" in *"is not present in this checkout"*) ok "H: an unfetched pin is UNKNOWN" ;;
  *) bad "H: an unfetched pin is UNKNOWN" "guessed at a commit it does not have" ;; esac
case "$OUTB" in *"TOTAL: 0"*) ok "H: an unfetched pin counts as no findings" ;;
  *) bad "H: an unfetched pin counts as no findings" "an unprobeable kit reported as broken" ;; esac

echo "=== I: a kit path CONTAINING 'vendor' is still audited ==="
# ⚠️ FOUND BY ACCIDENT, BY CASE H'S OWN FIXTURE DIRECTORY BEING NAMED `stale-vendor`.
# The lockfile glob filtered with `if "vendor/" not in p` against the ABSOLUTE path, so any
# kit under a directory merely CONTAINING "vendor" was dropped from the audit entirely:
# nothing scanned, TOTAL: 0, exit 0. Third instance in this file of a cheap test standing in
# for the real one — the class-2 basename match and the class-4 silent skip are the same
# mistake in different clothes. `vendor` is a PATH SEGMENT, never a substring.
K8="$TMP/my-vendor/kit"
mkdir -p "$K8"
cat > "$K8/loom.lock.json" <<'JSON'
{ "instance": "t-vendor-in-path", "vendorDir": "vendor",
  "install": { "hooks": ["ghost.sh"],
               "hookSources": { "ghost.sh": "local:ghost.sh" },
               "hooksUnwired": { "ghost.sh": "not the point" } } }
JSON
OUTC="$(python3 "$AUDIT" "$K8" 2>&1)"
case "$OUTC" in *"ghost.sh -> local:ghost.sh DOES NOT EXIST"*)
    ok "I: a kit under a *vendor* directory is still scanned" ;;
  *) bad "I: a kit under a *vendor* directory is still scanned" \
        "substring filter swallowed the whole kit — scanned nothing, exited clean" ;; esac

# ...and a lockfile genuinely INSIDE the vendor tree is still skipped
mkdir -p "$K8/vendor/dark-factory"
cat > "$K8/vendor/dark-factory/loom.lock.json" <<'JSON'
{ "instance": "t-should-be-skipped", "install": { "hooks": [] } }
JSON
OUTD="$(python3 "$AUDIT" "$K8" 2>&1)"
case "$OUTD" in *"t-should-be-skipped"*)
    bad "I: a lockfile inside vendor/ is still skipped" "audited a vendored kit as its own" ;;
  *) ok "I: a lockfile inside vendor/ is still skipped" ;; esac

echo "=== J: class 2 is a TIER-3 question and must not fire on a TIER-2 layer ==="
# ⚠️ A layer is never installed to a machine — an instance lockfile composes it, and the
# settings template belongs to that instance. Measured 2026-09-03: the second estate's recipe
# lives in its minted kit at <a personal kit>/boot-kit/settings.template.json, and neither
# org.lock.json nor <sibling-org-layer>.lock.json carries one. Demanding a template there demands a
# file the tier model says must not be there. The discriminator is `instance`: an instance
# lockfile names one machine, a layer names none.
K9="$TMP/layer"
mkdir -p "$K9"
cat > "$K9/org.lock.json" <<'JSON'
{ "orgLayer": "t-layer", "vendorDir": "vendor",
  "install": { "hooks": ["a.sh"], "hookSources": { "a.sh": "local:hooks/a.sh" } } }
JSON
OUTE="$(python3 "$AUDIT" "$K9" 2>&1)"
case "$OUTE" in *"NO settings template"*)
    bad "J: a layer is exempt from class 2" "demanded a Tier-3 file from a Tier-2 layer" ;;
  *) ok "J: a layer is exempt from class 2" ;; esac

# ⚠️ AND THE EXEMPTION MUST BE ANNOUNCED. A silent skip is the class-4 defect, which this
# file has now committed three times; an exemption nobody can see is indistinguishable from
# a check that never ran.
case "$OUTE" in *"TIER-2 LAYER"*) ok "J: the exemption is printed, not silent" ;;
  *) bad "J: the exemption is printed, not silent" "skipped a check without saying so" ;; esac

# ...and the classes that DO apply to a layer still apply: its sources must resolve
case "$OUTE" in *"a.sh -> local:hooks/a.sh DOES NOT EXIST"*)
    ok "J: class 4 still applies to a layer" ;;
  *) bad "J: class 4 still applies to a layer" "the tier exemption swallowed every check" ;; esac

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
