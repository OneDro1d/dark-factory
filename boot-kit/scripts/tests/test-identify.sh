#!/usr/bin/env bash
# test-identify.sh — naming the wrong --lock must stop being a silent wrong install.
#
# ⛔ WHY THIS EXISTS. `--lock` picks which machine's record to install and NOTHING checked that
# the record describes the machine you are on. Measured 2026-09-03: an ESO estate runs
# workspaces called `Loom` and `loom-neptune-arm` on TWO Coder deployments. Same names,
# different machines — so the wrong `--lock` matches the workspace name exactly and reports
# `RESULT: LOCKED` about a machine you are not on.
#
# ⚠️ THE FINGERPRINT IS MEASURED AND THE OBVIOUS SIGNAL IS THE WRONG ONE. `hostname` inside a
# Coder workspace returns the Kubernetes POD NAME, which changes on every restart. Probed live
# before this was designed. The stable pair is CODER_AGENT_URL (the deployment) plus
# CODER_WORKSPACE_NAME.
#
# ⚠️ EVERY CASE HERE IS ALSO ABOUT WHAT IT REFUSES TO DO. It must never choose a lockfile: an
# inferred identity acted upon turns a visible wrong choice into an invisible one, which is the
# defect this layer exists to remove.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
ID="$SELF/../identify.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ident.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mklock() { printf '%s\n' "$2" > "$T/$1.json"; printf '%s' "$T/$1.json"; }

# ⚠️ THE HOSTNAMES BELOW ARE SYNTHETIC, AND THAT IS LOAD-BEARING.
# This repo is PUBLIC. Earlier fixtures here named two real ESO control planes; the publish gate
# flags that class, and #91 had already replaced a real deployment_id in this same file for the
# same reason. **The measurement belongs in the private instance record; the public repo gets the
# SHAPE.** What is under test is that two DIFFERENT deployments refuse and one MATCHING deployment
# passes — any two distinct URLs prove that, and `.example` is reserved by RFC 2606 so these can
# never resolve to a real host.
# Do not "make these realistic". Realism here is the defect.
AWS='{"instance":"coder-eso-aws--loom","install":{"identity":{"deployment":"https://coder.cloud-a.example/","workspace":"Loom"}}}'
AZ='{"instance":"coder-eso-azure--loom","install":{"identity":{"deployment":"https://coder.cloud-b.example/","workspace":"Loom"}}}'
BARE='{"instance":"legacy","install":{"hooks":[]}}'

L_AWS="$(mklock aws "$AWS")"; L_AZ="$(mklock az "$AZ")"; L_BARE="$(mklock bare "$BARE")"

echo "=== A: a laptop reports as a laptop ==="
O="$(env -u CODER -u CODER_WORKSPACE_NAME -u CODER_AGENT_URL bash "$ID" 2>&1)"
contains "A: says laptop"            "laptop"   "$O"
absent   "A: no Coder deployment"    "workspace  :" "$O"

echo "=== B: inside a workspace, the DEPLOYMENT is what is reported ==="
O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-a.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" 2>&1)"
contains "B: says Coder workspace"   "Coder workspace" "$O"
contains "B: names the deployment"   "cloud-a.example" "$O"
contains "B: names the workspace"    "Loom"     "$O"
# ⚠️ THE POD NAME MUST NOT BE PRESENTED AS IDENTITY. It changes every restart.
contains "B: says the pod name is not usable identity" "NOT USED" "$O"

echo "=== C: the SAME workspace name on ANOTHER deployment is a different machine ==="
# ⛔ This is the live hazard: `Loom` exists on both. The name alone must not satisfy the check.
O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-b.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" --lock "$L_AWS" 2>&1)"; rc=$?
contains "C: refuses the AWS record on the Azure box" "DIFFERENT MACHINE" "$O"
contains "C: shows both sides"                        "you are" "$O"
if [ "$rc" -eq 3 ]; then ok "C: exits 3 so the installer can stop"
else bad "C: exits 3 so the installer can stop" "exit was $rc — a refusal that exits 0 is invisible"; fi

echo "=== D: the RIGHT record on the same box is accepted ==="
O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-b.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" --lock "$L_AZ" 2>&1)"; rc=$?
contains "D: confirms the match" "matches this machine" "$O"
if [ "$rc" -eq 0 ]; then ok "D: exits 0"; else bad "D: exits 0" "exit was $rc"; fi

echo "=== D2: CROSS-KIND — a Coder record on a laptop, and a laptop record on a Coder ==="
# ⛔ THE CASE THE FIRST VERSION GOT WRONG, and the suite did not catch because C and D both had
# a Coder machine on BOTH sides. On a laptop it compared only `hostname`; a Coder record has
# none, so there was nothing to compare and "no mismatch" was returned as AGREEMENT.
# Found by running the real thing against a real record, not by reading the code.
#
# ⚠️ **A check that can only disagree with things of its own type agrees with everything else.**
HOSTLOCK="$(mklock host '{"instance":"a-laptop","install":{"identity":{"hostname":"some-laptop.local"}}}')"

O="$(env -u CODER -u CODER_WORKSPACE_NAME -u CODER_AGENT_URL bash "$ID" --lock "$L_AWS" 2>&1)"; rc=$?
contains "D2: a Coder record is refused on a laptop" "DIFFERENT MACHINE" "$O"
if [ "$rc" -eq 3 ]; then ok "D2: and exits 3"; else bad "D2: and exits 3" "exit was $rc"; fi

O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-a.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" --lock "$HOSTLOCK" 2>&1)"; rc=$?
contains "D2: a laptop record is refused on a Coder box" "DIFFERENT MACHINE" "$O"
if [ "$rc" -eq 3 ]; then ok "D2: and exits 3 there too"; else bad "D2: and exits 3 there too" "exit was $rc"; fi

echo "=== D3: a host record survives the .local suffix and a case change ==="
# ⛔ THIS REFUSED THE AUTHOR'S OWN LAPTOP, LIVE. `hostname` on macOS follows the NETWORK: it
# returned `MacBook-Air-3.local` when the record was written and `Mac` an hour later, so the
# check blocked the CORRECT install — worse than the gap it closes.
#
# The fix reads `scutil --get LocalHostName` (the Bonjour name, unchanged by joining a network)
# and NORMALISES both sides: `.local` is the mDNS suffix, not part of the name. Without that
# normalisation the fix would have invalidated every record it was meant to protect.
#
# ⚠️ The lesson had already been written FOR CODER and applied to only half the problem.
# **A rule learned on one platform is not a fact about the other.**
#
# The fixture is built from THIS machine's own id, uppercased and suffixed, so the case is
# meaningful on any host rather than only on the author's.
MYHOST="$(env -u CODER bash "$ID" | sed -n 's/^   host       : \([^ ]*\).*/\1/p')"
if [ -n "$MYHOST" ]; then
  UP="$(printf '%s' "$MYHOST" | tr '[:lower:]' '[:upper:]')"
  SUF="$(mklock suffixed "{\"instance\":\"a-laptop\",\"install\":{\"identity\":{\"hostname\":\"${UP}.local\"}}}")"
  O="$(env -u CODER -u CODER_WORKSPACE_NAME -u CODER_AGENT_URL bash "$ID" --lock "$SUF" 2>&1)"
  contains "D3: .local suffix + case change still matches" "matches this machine" "$O"
else
  bad "D3: could not read this machine's host id" "the print path changed shape"
fi

# ...and a genuinely different host must STILL be refused — normalisation must not blur names
OTHER="$(mklock other '{"instance":"elsewhere","install":{"identity":{"hostname":"some-other-box.local"}}}')"
O="$(env -u CODER -u CODER_WORKSPACE_NAME -u CODER_AGENT_URL bash "$ID" --lock "$OTHER" 2>&1)"; rc=$?
contains "D3: a different host is still refused" "DIFFERENT MACHINE" "$O"
if [ "$rc" -eq 3 ]; then ok "D3: and still exits 3"; else bad "D3: and still exits 3" "exit $rc"; fi

echo "=== E: a lockfile with NO identity is UNKNOWN, never agreement ==="
# ⚠️ Every record on the fleet predates this field. Treating silence as a match would make the
# check vacuous everywhere at once — the exact shape of defect this repo keeps finding.
O="$(CODER=true CODER_AGENT_URL=https://x/ CODER_WORKSPACE_NAME=y bash "$ID" --lock "$L_BARE" 2>&1)"; rc=$?
contains "E: says it cannot be checked" "CANNOT be checked" "$O"
absent   "E: does NOT claim a match"    "matches this machine" "$O"
# ...and it must not block: an unknown is not a drift.
if [ "$rc" -eq 0 ]; then ok "E: does not block the install"
else bad "E: does not block the install" "exit $rc — an unknown that blocks fires on the whole fleet"; fi
# ...and it must hand over the exact line to paste
contains "E: offers the identity block to add" '"deployment"' "$O"

echo "=== H: --declare writes a MEASURED identity, and never overwrites one ==="
# ⛔ WHY THIS EXISTS, and it is structural rather than an oversight: a kit is minted BEFORE the
# machine it will run on exists. loom-annabel's record was created with an empty agentName and
# the note "the agent names itself, on first run" — there was no machine to measure. So a fresh
# kit CANNOT ship with install.identity, and the guard stays inert on it until somebody stands
# at the machine. Measured 2026-09-03: 4 of 10 records declared — the 4 anyone has run.
#
# ⚠️ WRITING IT STAYS AN EXPLICIT ACT. It records THE MACHINE YOU ARE ON into THE RECORD YOU
# NAMED — not an inference, since naming the record IS the assertion. But a WRONG assertion gets
# cemented here: a recoverable mistake becomes a probed-looking record. Hence: print before
# write, refuse to overwrite, never implied by a plain install.
FRESH="$(mklock fresh '{"instance":"fresh-kit","install":{"hooks":[]}}')"
O="$(env -u CODER -u CODER_WORKSPACE_NAME -u CODER_AGENT_URL bash "$ID" --declare "$FRESH" 2>&1)"
contains "H: prints what it will write BEFORE writing" "will write into" "$O"
contains "H: says to commit and push it"               "COMMIT AND PUSH" "$O"
if [ -n "$(jq -r '.install.identity.hostname // empty' "$FRESH")" ]; then
  ok "H: an identity was written"
else bad "H: an identity was written" "nothing landed in the lockfile"; fi
# the note must say it was MEASURED — a record that cannot say where its value came from is the
# looks-probed-and-is-not failure this whole feature exists to prevent
contains "H: the written note says MEASURED" "MEASURED" "$(cat "$FRESH")"

# ...and the record must now satisfy the check it was written for
O="$(env -u CODER -u CODER_WORKSPACE_NAME -u CODER_AGENT_URL bash "$ID" --lock "$FRESH" 2>&1)"
contains "H: the new identity matches this machine" "matches this machine" "$O"

# ⚠️ NEVER OVERWRITE. An existing identity was written by someone standing at a machine;
# replacing it silently would let one box quietly claim another's record.
O="$(env -u CODER -u CODER_WORKSPACE_NAME -u CODER_AGENT_URL bash "$ID" --declare "$FRESH" 2>&1)"; rc=$?
contains "H: a second --declare REFUSES" "refusing to overwrite" "$O"
if [ "$rc" -eq 3 ]; then ok "H: and exits 3"; else bad "H: and exits 3" "exit $rc"; fi

echo "=== I: deploymentId beats the URL, because the URL is not deployment-unique ==="
# ⛔ REPORTED FROM A LIVE CODER WORKSPACE and verified against three separate control planes.
# `CODER_AGENT_URL` there is the IN-CLUSTER service address, which ANY workspace co-located with
# its control plane reports, on ANY deployment. Two workspaces on DIFFERENT deployments can
# therefore declare the SAME url+name and be indistinguishable: exactly the collision this guard
# exists to catch, sailing through it.
#
# `deployment_id` (unauthenticated GET /api/v2/buildinfo) is per-CONTROL-PLANE, so the
# in-cluster and public spellings of one deployment return the SAME id while two deployments
# never do.
#
# ⚠️ THE IDENTIFIERS BELOW ARE SYNTHETIC, AND THAT IS LOAD-BEARING. The first version of this
# suite used a REAL deployment id and the publish gate rejected it (P4: private infrastructure
# identifiers; P8: already reachable from a remote branch) — in a PUBLIC repo. Real values
# belong in the private instance record; **the public repo gets the SHAPE.** What is under test
# is that two DIFFERENT ids refuse and one MATCHING id passes; which ids an estate happens to
# own proves nothing extra.
INCLUSTER="http://coder.coder.svc.cluster.local/"
# ⚠️ NOT UUID-SHAPED, DELIBERATELY. P4 flags the SHAPE, and it is right not to try telling
# a synthetic id from a real one — a gate that judged intent would be guessing. The test
# needs two DISTINCT strings, not realistic ones.
FAKE_ID_A="deployment-id-alpha-for-tests"

# ⚠️ The probe cannot run in these fixtures (no server), so DEPLOY_ID is empty — which is itself
# the case worth asserting: an unprobeable id must FALL BACK to the URL, never refuse.
CLASH="$(mklock clash "{\"instance\":\"other-cloud\",\"install\":{\"identity\":{\"deployment\":\"$INCLUSTER\",\"workspace\":\"neptune\",\"deploymentId\":\"$FAKE_ID_A\"}}}")"
O="$(CODER=true CODER_AGENT_URL="$INCLUSTER" CODER_WORKSPACE_NAME=neptune bash "$ID" --lock "$CLASH" 2>&1)"; rc=$?
contains "I: an unprobeable id falls back to the URL, does not refuse" "matches this machine" "$O"
if [ "$rc" -eq 0 ]; then ok "I: and exits 0"; else bad "I: and exits 0" "exit $rc — a network blip must not block"; fi

# a record whose declared URL differs is still refused, id or no id
DIFF="$(mklock diffurl "{\"instance\":\"elsewhere\",\"install\":{\"identity\":{\"deployment\":\"https://somewhere-else/\",\"workspace\":\"neptune\"}}}")"
O="$(CODER=true CODER_AGENT_URL="$INCLUSTER" CODER_WORKSPACE_NAME=neptune bash "$ID" --lock "$DIFF" 2>&1)"; rc=$?
contains "I: a different declared URL is still refused" "DIFFERENT MACHINE" "$O"
if [ "$rc" -eq 3 ]; then ok "I: and exits 3"; else bad "I: and exits 3" "exit $rc"; fi

# ⚠️ an unprobeable id must SAY so — a silent fall back to a weaker check is the same defect
# one level down
O="$(CODER=true CODER_AGENT_URL="$INCLUSTER" CODER_WORKSPACE_NAME=x bash "$ID" 2>&1)"
contains "I: an unprobeable id is reported as unknown" "could not probe" "$O"
contains "I: and warns the URL may not be unique" "may not be deployment-unique" "$O"

echo "=== J: a COPIED measurement is refused, even when the values match ==="
# ⛔ THE CASE THE WHOLE FEATURE EXISTS FOR, and the one a value-comparison cannot catch.
# Provenance used to be a free-text $note reading "MEASURED on the machine". `cp -R` copies that
# sentence verbatim onto a box nobody measured, and it then reads MORE authoritative than a blank
# field — so it stops the next reader from checking. Flagged in the ESO install report 2026-09-03.
#
# ⚠️ THE VALUES HERE MATCH THIS MACHINE EXACTLY. That is deliberate: the usual way a copied
# record arises is `cp -R` between two workspaces on ONE deployment, where deployment and
# workspace legitimately agree. A check that compares values passes it. What does not pass is the
# record's own claim about WHAT IT WAS MEASURED FOR.
COPIED="$(mklock copied '{"instance":"box-b","install":{"identity":{
  "deployment":"https://coder.cloud-a.example/","workspace":"Loom",
  "origin":{"how":"measured","on":"2026-09-04","by":"identify.sh --declare","forInstance":"box-a"}}}}')"
O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-a.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" --lock "$COPIED" 2>&1)"; rc=$?
contains "J: refuses a measurement taken for another instance" "MEASURED FOR A DIFFERENT INSTANCE" "$O"
contains "J: names both instances"                             "box-a" "$O"
contains "J: says how to fix it by MEASURING"                  "--declare" "$O"
if [ "$rc" -eq 3 ]; then ok "J: exits 3"; else bad "J: exits 3" "exit $rc — a refusal that exits 0 is invisible"; fi

echo "=== J2: the SAME record, once its provenance names itself, is accepted ==="
# Proves the refusal is about provenance and not about the values, which are byte-identical here.
OWNED="$(mklock owned '{"instance":"box-a","install":{"identity":{
  "deployment":"https://coder.cloud-a.example/","workspace":"Loom",
  "origin":{"how":"measured","on":"2026-09-04","by":"identify.sh --declare","forInstance":"box-a"}}}}')"
O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-a.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" --lock "$OWNED" 2>&1)"; rc=$?
contains "J2: an own measurement is accepted" "matches this machine" "$O"
if [ "$rc" -eq 0 ]; then ok "J2: exits 0"; else bad "J2: exits 0" "exit $rc"; fi

echo "=== J3: the instance name is read in BOTH shapes ==="
# ⚠️ `.instance` is a bare string in older records and an object with `.name` in current ones.
# Reading one shape only is exactly what left loom-delia unmarked and three weeks behind.
OBJ="$(mklock objshape '{"instance":{"name":"box-b","kind":"instance"},"install":{"identity":{
  "deployment":"https://coder.cloud-a.example/","workspace":"Loom",
  "origin":{"how":"measured","on":"2026-09-04","forInstance":"box-a"}}}}')"
O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-a.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" --lock "$OBJ" 2>&1)"; rc=$?
contains "J3: object-shaped instance is read too" "MEASURED FOR A DIFFERENT INSTANCE" "$O"
if [ "$rc" -eq 3 ]; then ok "J3: and exits 3"; else bad "J3: and exits 3" "exit $rc"; fi

echo "=== J4: ABSENT provenance is a NOTE, never a refusal ==="
# ⚠️ Every record on the fleet predates this field. Blocking on absence would fire fleet-wide on
# day one and be trained past within a day — the same reason install.identity itself arms
# gradually. Absence is `unknown`; only a positive contradiction refuses.
NOPROV="$(mklock noprov '{"instance":"box-a","install":{"identity":{
  "deployment":"https://coder.cloud-a.example/","workspace":"Loom"}}}')"
O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-a.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" --lock "$NOPROV" 2>&1)"; rc=$?
contains "J4: says provenance is undeclared" "declares no identity provenance" "$O"
contains "J4: and says that is not a failure" "Not a failure" "$O"
if [ "$rc" -eq 0 ]; then ok "J4: and still exits 0"; else bad "J4: and still exits 0" "exit $rc"; fi

echo "=== J5: how=measured with no forInstance is reported, not silently trusted ==="
# The one field that makes a copy detectable is the one that would be missing.
HALF="$(mklock half '{"instance":"box-a","install":{"identity":{
  "deployment":"https://coder.cloud-a.example/","workspace":"Loom",
  "origin":{"how":"measured","on":"2026-09-04"}}}}')"
O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-a.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" --lock "$HALF" 2>&1)"
contains "J5: names the missing field" "no origin.forInstance" "$O"

echo "=== J6: --declare RECORDS what it measured for ==="
# Without this the schema is just a second thing for cp -R to copy.
DECL="$(mklock todeclare '{"instance":"declared-box","install":{}}')"
env -u CODER -u CODER_WORKSPACE_NAME -u CODER_AGENT_URL bash "$ID" --declare "$DECL" >/dev/null 2>&1
FOR="$(jq -r '.install.identity.origin.forInstance // "MISSING"' "$DECL" 2>/dev/null)"
HOW="$(jq -r '.install.identity.origin.how // "MISSING"' "$DECL" 2>/dev/null)"
if [ "$FOR" = "declared-box" ]; then ok "J6: origin.forInstance is the record's own instance"
else bad "J6: origin.forInstance is the record's own instance" "got '$FOR'"; fi
if [ "$HOW" = "measured" ]; then ok "J6: origin.how is measured"; else bad "J6: origin.how is measured" "got '$HOW'"; fi

# ...and that freshly declared record must now pass its own provenance check
O="$(env -u CODER -u CODER_WORKSPACE_NAME -u CODER_AGENT_URL bash "$ID" --lock "$DECL" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "J6: and the record it wrote passes its own check"
else bad "J6: and the record it wrote passes its own check" "exit $rc: $O"; fi

echo "=== F: --match lists candidates and NEVER picks one ==="
mkdir -p "$T/instances/a" "$T/instances/b"
printf '%s\n' "$AWS" > "$T/instances/a/loom.lock.json"
printf '%s\n' "$AZ"  > "$T/instances/b/loom.lock.json"
O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-b.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" --match "$T/instances" 2>&1)"
contains "F: names the matching record"     "instances/b" "$O"
absent   "F: does not name the other one"   "instances/a" "$O"
# ⚠️ NO AUTO-SELECT. Reporting a candidate is help; acting on it is the defect.
absent   "F: does not install anything"     "install"     "$O"

echo "=== K: --match sees the REPO-ROOT record, not just instances/* ==="
# ⛔ The candidate set is "the repo root + instances/*", which is what df-preflight has always
# documented. --match scanned instances/* alone, so on a repo whose OWN machine is recorded at
# the root — the documented layout, not an accident — it answered "no declared instance matches
# this machine". A FALSE NEGATIVE ON IDENTITY, from the tool whose whole job is identity, and a
# reader following START-HERE would conclude their machine is undeclared and mint a duplicate.
# Measured 2026-09-04 on the laptop, whose root record carries a fully measured install.identity.
#
# ⚠️ THE ROOT RECORD GETS ITS OWN DEPLOYMENT, AND THAT IS THE WHOLE TEST.
# The first version of this case wrote the AWS record to the root and probed with the AWS
# identity, then asserted the output contained "loom.lock.json". It PASSED AGAINST THE
# PRE-FIX CODE — because instances/a holds that same record, so the old scan matched THAT
# and printed a path ending in the same filename. An inert test that reads as coverage.
# A third, unique deployment makes the root record the ONLY thing that can match, so the
# assertion can no longer be satisfied from instances/.
ROOT_REC='{"instance":"the-root-machine","install":{"identity":{"deployment":"https://coder.cloud-root.example/","workspace":"Loom"}}}'
printf '%s\n' "$ROOT_REC" > "$T/loom.lock.json"
O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-root.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" --match "$T/instances" 2>&1)"
# ⚠️ ASSERT ON "A RECORD MATCHED", NOT ON THE PATH STRING. The first attempt compared against
# "$T/loom.lock.json" and failed against the FIXED code too: $TMPDIR ends in a slash so $T
# carries a doubled one, and the tool prints the `pwd -P` form, which also resolves
# /var -> /private/var on macOS. Three spellings of one path, and the test was measuring the
# spelling rather than the behaviour. `absent instances/` below already proves WHICH record
# it was, so the path text buys nothing and costs a false failure.
contains "K: the ROOT record is found when scanning instances/" "MATCHES:" "$O"
absent   "K: and it is NOT reported as unmatched"               "no declared instance matches" "$O"
absent   "K: no instances/ record is claimed to match"          "instances/" "$O"

# ⚠️ DEDUPE BY REAL PATH. `instances/../loom.lock.json` and `loom.lock.json` are one file;
# counting it twice turns one machine into "2 records match" — which reads as exactly the
# ambiguity this check exists to DETECT, so the bug would masquerade as a finding.
# ⚠️ Honest note: this assertion does NOT discriminate against the pre-fix code (which had
# nothing to dedupe). It guards the fix from regressing, and is recorded as that, not as
# evidence the bug existed.
O="$(CODER=true CODER_AGENT_URL=https://coder.cloud-root.example/ CODER_WORKSPACE_NAME=Loom bash "$ID" --match "$T" 2>&1)"
HITS="$(printf '%s\n' "$O" | grep -c 'MATCHES:')"
if [ "$HITS" = "1" ]; then ok "K: the root record is counted ONCE when \$DIR is the root"
else bad "K: the root record is counted ONCE when \$DIR is the root" "got $HITS MATCHES lines"; fi
rm -f "$T/loom.lock.json"

echo "=== G: no match is reported as a LIMIT, not as proof ==="
O="$(CODER=true CODER_AGENT_URL=https://nowhere/ CODER_WORKSPACE_NAME=ghost bash "$ID" --match "$T/instances" 2>&1)"
contains "G: says nothing matched"          "no declared instance matches" "$O"
contains "G: and says that is not proof"    "not proof"                    "$O"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
