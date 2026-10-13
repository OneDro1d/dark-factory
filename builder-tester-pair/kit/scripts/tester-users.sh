#!/usr/bin/env bash
# tester-users.sh — TEMPORARY: run the tester agent(s) in the SAME workspace as the builder, as separate Linux users.
# The real design is two workspaces; this is the closest stand-in until the tester workspace exists. Run by the OWNER
# (needs sudo), never by an agent.
#
#   bash tester-users.sh [--dry-run]       create/refresh the tester users + group for every pair.yaml listed
#   PAIR_CONFIGS="a/pair.yaml b/pair.yaml" bash tester-users.sh       (default: all /user/shared/pairs/*/pair.yaml)
#
# For each pair.yaml it reads  tester.user  (Linux user)  tester.uid  tester.agent_home  paths.ledger  and:
#   * creates the user with a FIXED uid (so a pod rebuild + re-run finds the home folder still owned correctly)
#   * home = tester.agent_home, mode 700: the builder (user `coder`) cannot list or read it
#   * adds the builder user and the tester to group `pairshare`; the pair's shared_root is group-writable (setgid), so
#     the hand-over ledger and specs work, while the tester's HOME stays private
# Honest limits: the builder agents also run with this account's passwordless sudo; the kit's pair-guard blocks
# sudo/su for the builder role (guard.block_privilege_escalation), but a guard under the same account catches mistakes,
# not a deliberate bypass. Moving the tester to its own workspace removes that: see docs/SETUP.md "Moving the tester".
# Users live in /etc/passwd of the pod and vanish when the pod is rebuilt: re-run this script (idempotent).
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
run() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
BUILDER_USER="${BUILDER_USER:-$(id -un)}"
GROUP=pairshare
CONFS="${PAIR_CONFIGS:-$(ls /user/shared/pairs/*/pair.yaml 2>/dev/null | tr '\n' ' ')}"
[ -n "$CONFS" ] || { echo "no pair.yaml found (set PAIR_CONFIGS)"; exit 1; }

getent group "$GROUP" >/dev/null || run sudo groupadd "$GROUP"
run sudo usermod -aG "$GROUP" "$BUILDER_USER"

for cfg in $CONFS; do
  get() { PAIR_CONFIG="$cfg" python3 "$KIT/kit/lib/pairconf.py" get "$1" 2>/dev/null || true; }
  U="$(get tester.user)"; UID_="$(get tester.uid)"; H="$(get tester.agent_home)"; ROOT="$(get paths.shared_root)"
  if [ -z "$U" ] || [ -z "$UID_" ] || [ -z "$H" ]; then echo "skip $cfg: tester.user / tester.uid / tester.agent_home not all set"; continue; fi
  case "$U" in "$BUILDER_USER"|root) echo "refuse: tester.user must not be $U"; exit 1 ;; esac
  echo "== $U (uid $UID_) home $H   [$cfg]"
  if id "$U" >/dev/null 2>&1; then echo "user $U exists"; else
    run sudo useradd --uid "$UID_" --home-dir "$H" --no-create-home --shell /bin/bash --gid "$GROUP" "$U"; fi
  run sudo usermod -aG "$GROUP" "$U"
  run sudo mkdir -p "$H"
  run sudo chown "$U:$GROUP" "$H"
  run sudo chmod 700 "$H"
  # shared root: group-writable + setgid so files either side creates stay usable by both
  run sudo chgrp -R "$GROUP" "$ROOT"
  run sudo chmod -R g+rwX "$ROOT"
  run sudo find "$ROOT" -type d -exec chmod g+s {} +
done
echo "done. Group membership applies to NEW sessions: start the agents (or log in) afresh."
