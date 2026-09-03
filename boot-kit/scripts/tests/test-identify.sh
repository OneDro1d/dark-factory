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

AWS='{"instance":"coder-eso-aws--loom","install":{"identity":{"deployment":"https://coder-dev02.aws.esosuite.net/","workspace":"Loom"}}}'
AZ='{"instance":"coder-eso-azure--loom","install":{"identity":{"deployment":"https://coder.aks-dev-scus.esosuite.net/","workspace":"Loom"}}}'
BARE='{"instance":"legacy","install":{"hooks":[]}}'

L_AWS="$(mklock aws "$AWS")"; L_AZ="$(mklock az "$AZ")"; L_BARE="$(mklock bare "$BARE")"

echo "=== A: a laptop reports as a laptop ==="
O="$(env -u CODER -u CODER_WORKSPACE_NAME -u CODER_AGENT_URL bash "$ID" 2>&1)"
contains "A: says laptop"            "laptop"   "$O"
absent   "A: no Coder deployment"    "workspace  :" "$O"

echo "=== B: inside a workspace, the DEPLOYMENT is what is reported ==="
O="$(CODER=true CODER_AGENT_URL=https://coder-dev02.aws.esosuite.net/ CODER_WORKSPACE_NAME=Loom bash "$ID" 2>&1)"
contains "B: says Coder workspace"   "Coder workspace" "$O"
contains "B: names the deployment"   "coder-dev02.aws" "$O"
contains "B: names the workspace"    "Loom"     "$O"
# ⚠️ THE POD NAME MUST NOT BE PRESENTED AS IDENTITY. It changes every restart.
contains "B: says the pod name is not usable identity" "NOT USED" "$O"

echo "=== C: the SAME workspace name on ANOTHER deployment is a different machine ==="
# ⛔ This is the live hazard: `Loom` exists on both. The name alone must not satisfy the check.
O="$(CODER=true CODER_AGENT_URL=https://coder.aks-dev-scus.esosuite.net/ CODER_WORKSPACE_NAME=Loom bash "$ID" --lock "$L_AWS" 2>&1)"; rc=$?
contains "C: refuses the AWS record on the Azure box" "DIFFERENT MACHINE" "$O"
contains "C: shows both sides"                        "you are" "$O"
if [ "$rc" -eq 3 ]; then ok "C: exits 3 so the installer can stop"
else bad "C: exits 3 so the installer can stop" "exit was $rc — a refusal that exits 0 is invisible"; fi

echo "=== D: the RIGHT record on the same box is accepted ==="
O="$(CODER=true CODER_AGENT_URL=https://coder.aks-dev-scus.esosuite.net/ CODER_WORKSPACE_NAME=Loom bash "$ID" --lock "$L_AZ" 2>&1)"; rc=$?
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

O="$(CODER=true CODER_AGENT_URL=https://coder-dev02.aws.esosuite.net/ CODER_WORKSPACE_NAME=Loom bash "$ID" --lock "$HOSTLOCK" 2>&1)"; rc=$?
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

echo "=== F: --match lists candidates and NEVER picks one ==="
mkdir -p "$T/instances/a" "$T/instances/b"
printf '%s\n' "$AWS" > "$T/instances/a/loom.lock.json"
printf '%s\n' "$AZ"  > "$T/instances/b/loom.lock.json"
O="$(CODER=true CODER_AGENT_URL=https://coder.aks-dev-scus.esosuite.net/ CODER_WORKSPACE_NAME=Loom bash "$ID" --match "$T/instances" 2>&1)"
contains "F: names the matching record"     "instances/b" "$O"
absent   "F: does not name the other one"   "instances/a" "$O"
# ⚠️ NO AUTO-SELECT. Reporting a candidate is help; acting on it is the defect.
absent   "F: does not install anything"     "install"     "$O"

echo "=== G: no match is reported as a LIMIT, not as proof ==="
O="$(CODER=true CODER_AGENT_URL=https://nowhere/ CODER_WORKSPACE_NAME=ghost bash "$ID" --match "$T/instances" 2>&1)"
contains "G: says nothing matched"          "no declared instance matches" "$O"
contains "G: and says that is not proof"    "not proof"                    "$O"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
