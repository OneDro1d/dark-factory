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
