#!/usr/bin/env bash
# new-instance.sh — create your own Tier 3 instance repo, from TIER 1's generator.
#
#   bash scripts/new-instance.sh <instance-name> [destination-dir] [agent-name] [--kit <name>]...
#
#   bash scripts/new-instance.sh my-agent
#   bash scripts/new-instance.sh my-agent ~/Code
#   bash scripts/new-instance.sh my-agent ~/Code "" --kit method-core --kit dev
#
# ⚠️ THIS SCRIPT NO LONGER OWNS AN INSTANCE TEMPLATE, AND THAT IS THE CHANGE.
# It used to copy `templates/tier3-instance/` — a full instance kit that every minted org
# layer carried its own copy of. That copy is gone. This script now runs Tier 1's own
# `starter-kit/instance/bootstrap.sh` out of the vendored tree this layer already pins, and
# then adds the ONE thing Tier 1 cannot know: which org layer the new instance belongs to.
#
# WHY (operator decision 2026-09-07: "T1", and "reduce dependencies, move as much to T1"):
#   - There were TWO Tier-3 generators. Tier 1's `starter-kit/instance/` is now a strict
#     SUPERSET of the copy that used to live here: it ships .github/, VALIDATE-INSTALL.md,
#     bootstrap.sh, tests/, boot-kit/, AUTHENTICATION.md, START-HERE.md, a worked example
#     mission, and the `kits/` bundle composition (--kit). The copy here shipped none of
#     those, and its `skills/` and `hooks/` were README placeholders.
#   - Tier 1's instance installer ALREADY delegates to an org layer (install.sh step 2a,
#     keyed on `org.upstream`, absent by default, covered by test-instance-org-delegate.sh).
#     That was the one capability the local copy had that Tier 1 was once missing. It is not
#     missing any more, so the copy had nothing left that was its own.
#   - A template copied into every layer at mint time and never compared again is a drift
#     surface by construction. `test-tier3-template-pin.sh` existed ONLY to police that
#     drift, and on the first layer it ran against, four of seven files differed — in BOTH
#     directions. Deleting the copy deletes the drift, which is strictly better than
#     detecting it.
#
# ⚠️ SO THIS SCRIPT NOW REQUIRES `install.sh` TO HAVE RUN. Tier 1 is fetched into vendor/ at
# the pinned commit by this layer's own installer; it is not vendored into git. That is a
# real new precondition and it is checked with a remedy, not assumed — the previous version
# needed no network and no install, and someone will hit this.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
LOCK="$ROOT/org.lock.json"

RED=''; GRN=''; YEL=''; OFF=''
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'; fi
die() { printf '%sFATAL%s %s\n' "$RED" "$OFF" "$1"; exit 1; }

# --kit is passed straight through to Tier 1's bootstrap. Parsed out first so it may appear
# anywhere, matching bootstrap.sh's own contract rather than inventing a stricter one here.
KIT_ARGS=""
POS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kit)   shift; [ $# -gt 0 ] || die "--kit needs a kit name (try: --kit list)"; KIT_ARGS="$KIT_ARGS --kit $1" ;;
    --kit=*) KIT_ARGS="$KIT_ARGS --kit ${1#--kit=}" ;;
    --) shift; while [ $# -gt 0 ]; do POS="$POS $1"; shift; done; break ;;
    -*) die "unknown option: $1" ;;
    *)  POS="$POS $1" ;;
  esac
  shift
done
# shellcheck disable=SC2086
set -- $POS

NAME="${1:-}"
DEST_DIR="${2:-$HOME}"
AGENT="${3:-}"

[ -n "$NAME" ] || die "usage: bash scripts/new-instance.sh <instance-name> [destination-dir] [agent-name] [--kit <name>]..."
[ -f "$LOCK" ] || die "no org.lock.json at $ROOT — run this from inside your Tier 2 layer"
command -v jq >/dev/null 2>&1 || die "jq is required"

# A name that is not a safe directory-and-repo name will bite later, in a shell quoting or
# URL context far from here. Reject it now, where the message can be clear.
case "$NAME" in
  *[!a-zA-Z0-9._-]*) die "instance name may contain only letters, digits, dot, underscore, hyphen — got '$NAME'" ;;
esac
# The agent name reaches a JSON string and `export AGENT_NAME=`. Keep it to characters safe
# in both. Empty is fine — that is the unnamed default, and it stays undefaulted.
case "$AGENT" in
  *[!a-zA-Z0-9._\ -]*) die "agent name may contain only letters, digits, space, dot, underscore, hyphen — got '$AGENT'" ;;
esac

VENDOR="$(jq -r '.vendorDir // "vendor"' "$LOCK")"
BOOTSTRAP="$ROOT/$VENDOR/dark-factory/starter-kit/instance/bootstrap.sh"
if [ ! -f "$BOOTSTRAP" ]; then
  die "Tier 1 is not vendored yet — no $BOOTSTRAP

  This script now stamps instances from TIER 1's generator instead of a copy kept here,
  so Tier 1 must be present at the commit this layer pins. Fetch it the normal way:

      bash install.sh            # fetches Tier 1 into $VENDOR/ at the pinned commit
      bash install.sh --offline  # if you already have a populated $VENDOR/

  Then re-run this script. (Nothing is wrong with your layer — this precondition is new
  as of 2026-09-07, when the duplicate instance template was removed.)"
fi

TARGET="$DEST_DIR/$NAME"
[ -e "$TARGET" ] && die "$TARGET already exists — refusing to overwrite. Pick another name or remove it."
mkdir -p "$DEST_DIR" || die "cannot create $DEST_DIR"

# ---- 1. Tier 1 stamps the instance -----------------------------------------
printf '\n== stamping from Tier 1 (%s)\n' "$VENDOR/dark-factory/starter-kit/instance"
# shellcheck disable=SC2086
bash "$BOOTSTRAP" "$NAME" "$TARGET" $KIT_ARGS || die "Tier 1's bootstrap.sh failed — read its output above"

INSTANCE_LOCK="$TARGET/loom.lock.json"
[ -f "$INSTANCE_LOCK" ] || die "bootstrap.sh did not produce $INSTANCE_LOCK — refusing to write an org block into a file that is not there"

# ---- 2. the one thing Tier 1 cannot know: which layer this belongs to -------
# Resolve the Tier 2 ref to a COMMIT SHA now, rather than storing a branch name. A branch in
# an instance lockfile means upstream can move under you between two installs of the "same"
# instance — and a release branch moves most while it is under review, which is exactly when
# new people onboard. Taking an update stays a one-line bump; it just happens when they choose.
T2_REPO="$(jq -r '.repo // empty' "$LOCK")"
[ -n "$T2_REPO" ] || die "org.lock.json has no .repo — set it to this layer's GitHub slug"
T2_BRANCH="${T2_REF_BRANCH:-main}"
T2_REF=""
if command -v git >/dev/null 2>&1; then
  T2_REF="$(git ls-remote "https://github.com/$T2_REPO.git" "refs/heads/$T2_BRANCH" 2>/dev/null | cut -f1)"
fi
if [ -n "$T2_REF" ]; then
  T2_SOURCE="resolved from branch $T2_BRANCH on $(date -u +%Y-%m-%d)"
  printf '%s✓%s Tier 2 pinned to %s (%s)\n' "$GRN" "$OFF" "${T2_REF:0:12}" "$T2_BRANCH"
else
  # Falling back to the branch name is worse but still works. Say so plainly rather than
  # writing an unpinned ref and letting the developer discover it later.
  T2_REF="$T2_BRANCH"
  T2_SOURCE="UNRESOLVED — this is a branch name, not a pin. Replace it with a commit SHA."
  printf '%s!%s Could not reach %s to resolve a SHA.\n' "$YEL" "$OFF" "$T2_REPO"
  printf '  Left ref as the branch "%s". That works, but upstream can move under you.\n' "$T2_BRANCH"
  printf '  Fix when you have network:  git ls-remote https://github.com/%s.git refs/heads/%s\n' "$T2_REPO" "$T2_BRANCH"
fi

# `org.upstream` is the key install.sh step 2a reads. Written with jq, not sed: the old
# script substituted __T2_REF__ into a template it shipped, and there is no such placeholder
# in Tier 1's lockfile — Tier 1 does not know org layers exist at stamp time, only at install
# time. Writing the structure directly is what lets Tier 1 stay ignorant of this layer.
TMP="$(mktemp "${TMPDIR:-/tmp}/newinst.XXXXXX")"
jq --arg repo "$T2_REPO" --arg ref "$T2_REF" --arg src "$T2_SOURCE" --arg agent "$AGENT" '
  .org.upstream = {repo: $repo, ref: $ref, "$refSource": $src}
  | .org["$comment"] = "The Tier-2 layer this instance belongs to. install.sh step 2a fetches it at this ref and runs ITS installer BEFORE this instance'"'"'s own declarations are installed on top, so the layer owns the shared skill and hook list and this lockfile never restates it. Remove this block and the instance installs from Tier 1 alone."
  | (if $agent != "" then .instance.agentName = $agent else . end)
' "$INSTANCE_LOCK" > "$TMP" || die "could not write the org block into $INSTANCE_LOCK"
mv "$TMP" "$INSTANCE_LOCK"
printf '%s✓%s org.upstream -> %s @ %s\n' "$GRN" "$OFF" "$T2_REPO" "${T2_REF:0:12}"

# git init and stage, but deliberately do NOT commit — the developer should read the tree
# before it becomes history.
if command -v git >/dev/null 2>&1; then
  git -C "$TARGET" init -q
  git -C "$TARGET" add -A
fi

printf '\n%s✓%s created %s\n' "$GRN" "$OFF" "$TARGET"
cat <<EOF

This instance was stamped from Tier 1's generator and bound to THIS layer. Tier 1's own
bootstrap printed its next steps above; the layer-specific part is:

  · install.sh will fetch $T2_REPO at the pin above and run its installer FIRST,
    then install this instance's own declarations on top. The layer owns the shared list.
  · Read README.md — it explains what belongs here and what belongs in Tier 2.

Not done for you, on purpose:
  · No remote was created. Decide where this lives — a personal repo is fine, but if it
    ends up somewhere shared, remember it is YOUR doctrine, not the team's.
  · Nothing was committed. Review the tree first, then commit when you are happy.
EOF

if [ -z "$AGENT" ]; then
  cat <<'EOF'

  · Your agent is UNNAMED, on purpose. Naming it is a step of its own, and it belongs
    to the agent rather than to you: start a session and ask it to choose one.
    Then set instance.agentName in loom.lock.json and export AGENT_NAME.
    A name that arrived by default is not a chosen one.
EOF
else
  printf '\n  · Agent name set to "%s". export AGENT_NAME=%s to use it now.\n' "$AGENT" "$AGENT"
fi

cat <<'EOF'

  Whatever the agent calls itself, that name NEVER becomes a release, an image tag, or a
  ticket fixVersion. Those use the application name plus semver. This is an operations
  rule learned the hard way, not a preference: a release named after an agent tells a
  human nothing about what shipped.
EOF
