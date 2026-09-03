#!/usr/bin/env bash
# identify.sh — WHICH MACHINE IS THIS, and does the lockfile you named agree?
#
# ⛔ WHY THIS EXISTS. An instance repo holds one record per machine and `--lock` picks which.
# Nothing checked that the record you named describes the machine you are on, so naming the
# wrong one installed another machine's environment and reported `RESULT: LOCKED`.
#
# ⚠️ AND THE WRONG ANSWER CAN LOOK RIGHT. Measured 2026-09-03: an ESO estate runs workspaces
# called `Loom` and `loom-neptune-arm` on TWO Coder deployments. Same names, different machines.
# A reader matching the workspace name picks a plausible row, gets LOCKED, and has installed a
# machine they are not on. Every other wrong-install trap at least looks odd; that one does not.
#
# WHAT THIS DOES NOT DO
# ---------------------
# ⚠️ **IT NEVER PICKS THE LOCKFILE FOR YOU.** Inferring identity and acting on the inference is
# the failure this whole layer exists to prevent -- it would turn a visible wrong choice into an
# invisible one. It REPORTS what it sees, and REFUSES when a lockfile's declared identity
# contradicts the machine. Choosing stays a human act; only the contradiction is automated.
#
# THE FINGERPRINT IS MEASURED, NOT GUESSED
# ----------------------------------------
# Probed inside a live Coder workspace 2026-09-03, because the obvious signal is the wrong one:
#
#   ⚠️ `hostname` IS USELESS ON CODER. It returns the Kubernetes pod name
#      (`coder-<uuid>-<replicaset>-<pod>`), which CHANGES ON EVERY RESTART. A fingerprint built
#      on it identifies nothing and is different tomorrow.
#
#   CODER=true                 -> this is a workspace, not a laptop
#   CODER_AGENT_URL            -> the DEPLOYMENT. The only thing separating two workspaces
#                                 that share a name across deployments.
#   CODER_WORKSPACE_NAME       -> the workspace
#   otherwise                  -> a laptop: hostname (stable there) + uname -s
#
# usage:
#   identify.sh                          print the fingerprint
#   identify.sh --lock <lockfile>        also CHECK it against that lockfile's install.identity
#   identify.sh --match <instances-dir>  list which declared instances match this machine
#
# exit: 0 = agrees, or nothing to disagree with   3 = the lockfile describes another machine
set -uo pipefail

MODE=print
LOCK=""
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lock)  MODE=check; LOCK="${2:-}"; shift 2 ;;
    --lock=*) MODE=check; LOCK="${1#--lock=}"; shift ;;
    --match) MODE=match; DIR="${2:-}"; shift 2 ;;
    --match=*) MODE=match; DIR="${1#--match=}"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) printf 'FATAL unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# ---- the fingerprint -------------------------------------------------------
KIND="laptop"; DEPLOY=""; WORKSPACE=""; HOSTID="$(hostname 2>/dev/null || echo unknown)"
if [ "${CODER:-}" = "true" ] || [ -n "${CODER_WORKSPACE_NAME:-}" ]; then
  KIND="coder"
  DEPLOY="${CODER_AGENT_URL:-<unset>}"
  WORKSPACE="${CODER_WORKSPACE_NAME:-<unset>}"
  # ⚠️ Deliberately NOT reported: the pod hostname (changes every restart) and
  # CODER_AGENT_TOKEN (a live credential -- never print an env var by pattern-matching its
  # VALUE; the name itself is the thing that must be excluded).
  HOSTID="(pod name — not stable, not used)"
fi
ARCH="$(uname -m 2>/dev/null || echo unknown)"
OS="$(uname -s 2>/dev/null || echo unknown)"

say() { printf '%s\n' "$1"; }

say "== 0. which machine is this?"
if [ "$KIND" = "coder" ]; then
  say "   kind       : Coder workspace"
  say "   deployment : $DEPLOY"
  say "   workspace  : $WORKSPACE"
  # ⚠️ SAID OUT LOUD, because `hostname` is the first thing anyone reaches for and it is the
  # wrong signal here: it returns the Kubernetes pod name and changes on every restart. A
  # reader who does not know that will build a fingerprint on it and be wrong tomorrow.
  say "   hostname   : NOT USED — it is the k8s pod name and is not stable across restarts"
else
  say "   kind       : laptop / bare host"
  say "   hostname   : $HOSTID"
fi
say "   platform   : $OS $ARCH"

[ "$MODE" = "print" ] && exit 0

command -v jq >/dev/null || { say "   (jq absent — cannot check a lockfile)"; exit 0; }

# ---- does a lockfile's DECLARED identity match? ----------------------------
# install.identity is OPTIONAL. A lockfile that declares none cannot be checked, and that is
# reported as UNKNOWN -- never as agreement. ⚠️ `unknown` is not `ok`: every record predates
# this field, so treating silence as a match would make the check vacuous on the entire fleet.
check_one() {
  local lf="$1" quiet="${2:-}"
  local d w
  d="$(jq -r '.install.identity.deployment // empty' "$lf" 2>/dev/null)"
  w="$(jq -r '.install.identity.workspace  // empty' "$lf" 2>/dev/null)"
  local h
  h="$(jq -r '.install.identity.hostname   // empty' "$lf" 2>/dev/null)"

  if [ -z "$d$w$h" ]; then
    [ -n "$quiet" ] || {
      say "   ⚠️ this lockfile declares no install.identity — CANNOT be checked."
      say "      Add one so the next person cannot install the wrong machine:"
      if [ "$KIND" = "coder" ]; then
        say "        \"identity\": { \"deployment\": \"$DEPLOY\", \"workspace\": \"$WORKSPACE\" }"
      else
        say "        \"identity\": { \"hostname\": \"$HOSTID\" }"
      fi
    }
    return 2
  fi

  # ⚠️ THE KIND IS PART OF THE IDENTITY, and the first version ignored it. A record declaring
  # `deployment`/`workspace` describes a CODER workspace; one declaring only `hostname`
  # describes a bare host. Comparing only the fields that match the CURRENT kind meant a Coder
  # record checked on a laptop found nothing to compare and returned AGREEMENT.
  #
  # Caught by running it, not by the suite: cases C and D both had a Coder machine on both
  # sides, so the cross-kind case — the one that actually bites — was never exercised.
  # **A check that can only disagree with things of its own type agrees with everything else.**
  if [ "$KIND" = "coder" ]; then
    [ -z "$d$w" ] && return 1      # a host-only record, on a workspace
    [ -n "$d" ] && [ "$d" != "$DEPLOY" ] && return 1
    [ -n "$w" ] && [ "$w" != "$WORKSPACE" ] && return 1
  else
    [ -n "$d$w" ] && return 1      # a workspace record, on a bare host
    [ -n "$h" ] && [ "$h" != "$HOSTID" ] && return 1
  fi
  return 0
}

if [ "$MODE" = "check" ]; then
  [ -f "$LOCK" ] || { say "FATAL: no lockfile at $LOCK"; exit 2; }
  check_one "$LOCK"; rc=$?
  case "$rc" in
    0) say "   ✓ the lockfile's declared identity matches this machine" ; exit 0 ;;
    2) exit 0 ;;
    1)
      say ""
      say "⛔ THIS LOCKFILE DESCRIBES A DIFFERENT MACHINE."
      say "   lockfile : $LOCK"
      say "   it says  : deployment=$(jq -r '.install.identity.deployment // "-"' "$LOCK") workspace=$(jq -r '.install.identity.workspace // "-"' "$LOCK") hostname=$(jq -r '.install.identity.hostname // "-"' "$LOCK")"
      if [ "$KIND" = "coder" ]; then
        say "   you are  : deployment=$DEPLOY workspace=$WORKSPACE"
      else
        say "   you are  : hostname=$HOSTID"
      fi
      say ""
      say "   Installing it would put another machine's environment here and report success."
      say "   Pick the right --lock, or mint a record for THIS machine."
      exit 3 ;;
  esac
fi

if [ "$MODE" = "match" ]; then
  [ -d "$DIR" ] || { say "FATAL: no such directory $DIR"; exit 2; }
  n=0
  for lf in "$DIR"/*/loom.lock.json "$DIR"/*.lock.json; do
    [ -f "$lf" ] || continue
    if check_one "$lf" quiet; then
      say "   MATCHES: $lf"
      n=$((n + 1))
    fi
  done
  if [ "$n" -eq 0 ]; then
    say "   no declared instance matches this machine."
    say "   ⚠️ That is not proof none exists — a record with no install.identity cannot match."
  fi
  exit 0
fi
