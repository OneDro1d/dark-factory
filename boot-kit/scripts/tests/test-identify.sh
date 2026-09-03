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
