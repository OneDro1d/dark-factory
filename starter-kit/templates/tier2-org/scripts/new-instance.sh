#!/usr/bin/env bash
# new-instance.sh — create your own Tier 3 instance repo from the template.
#
#   bash scripts/new-instance.sh <instance-name> [destination-dir] [agent-name]
#
#   bash scripts/new-instance.sh my-agent
#   bash scripts/new-instance.sh my-agent ~/Code
#
# Creates <destination>/<instance-name> from templates/tier3-instance, substitutes the
# placeholders, and git-inits it. Nothing is pushed and no remote is created — where your
# instance lives is your decision, not this script's.
#
# The agent name is deliberately OPTIONAL and deliberately not defaulted. Naming the agent
# is its own step, and it belongs to the agent — see the instance's README. Pass one only
# if you already know it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
TEMPLATE="$ROOT/templates/tier3-instance"
LOCK="$ROOT/org.lock.json"

RED=''; GRN=''; YEL=''; OFF=''
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'; fi
die() { printf '%sFATAL%s %s\n' "$RED" "$OFF" "$1"; exit 1; }

NAME="${1:-}"
DEST_DIR="${2:-$HOME}"
AGENT="${3:-}"

[ -n "$NAME" ] || die "usage: bash scripts/new-instance.sh <instance-name> [destination-dir] [agent-name]"
[ -d "$TEMPLATE" ] || die "template missing at $TEMPLATE"
[ -f "$LOCK" ] || die "no org.lock.json at $ROOT — run this from inside your Tier 2 layer"
command -v jq >/dev/null 2>&1 || die "jq is required"

# A name that is not a safe directory-and-repo name will bite later, in a shell quoting or
# URL context far from here. Reject it now, where the message can be clear.
case "$NAME" in
  *[!a-zA-Z0-9._-]*) die "instance name may contain only letters, digits, dot, underscore, hyphen — got '$NAME'" ;;
esac

# The agent name reaches several places with different rules: a sed replacement, a JSON
# string, and `export AGENT_NAME=`. Rather than escape for each, keep it to characters
# that are safe in all of them. An empty name is fine — that is the unnamed default.
case "$AGENT" in
  *[!a-zA-Z0-9._\ -]*) die "agent name may contain only letters, digits, space, dot, underscore, hyphen — got '$AGENT'" ;;
esac

# Escape what is special in a sed REPLACEMENT: backslash, ampersand, and our delimiter.
# An unescaped `&` expands to the whole match, which corrupts silently rather than failing.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

TARGET="$DEST_DIR/$NAME"
[ -e "$TARGET" ] && die "$TARGET already exists — refusing to overwrite. Pick another name or remove it."

mkdir -p "$DEST_DIR" || die "cannot create $DEST_DIR"
cp -R "$TEMPLATE" "$TARGET" || die "copy failed"

# Resolve the Tier 2 ref to a COMMIT SHA now, rather than storing a branch name.
#
# A branch in an instance lockfile means upstream can move under you between installs — and
# a release branch moves most while it is still under review, which is exactly when new
# people are onboarding. Resolving here makes the safe thing the default and costs the
# developer nothing: taking an update is still a one-line bump, it just happens when they
# choose instead of mid-task.
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

# Substitute placeholders. The agent name is left EMPTY when not supplied — it is not
# defaulted to the instance name, because a name that arrived by default is not a chosen
# one, and the installer should keep asking until someone decides.
NAME_ESC="$(sed_escape "$NAME")"
AGENT_ESC="$(sed_escape "$AGENT")"
T2_REF_ESC="$(sed_escape "$T2_REF")"
T2_SOURCE_ESC="$(sed_escape "$T2_SOURCE")"

while IFS= read -r f; do
  sed -i.bak "s|__INSTANCE_NAME__|$NAME_ESC|g; s|__AGENT_NAME__|$AGENT_ESC|g; s|__T2_REF__|$T2_REF_ESC|g; s|__T2_REF_SOURCE__|$T2_SOURCE_ESC|g" "$f" && rm -f "$f.bak"
done < <(find "$TARGET" -type f -not -path '*/.git/*')

chmod +x "$TARGET/install.sh"

# git init and stage, but deliberately do NOT commit — the developer should read the tree
# before it becomes history.
if command -v git >/dev/null 2>&1; then
  git -C "$TARGET" init -q
  git -C "$TARGET" add -A
fi

printf '\n%s✓%s created %s\n' "$GRN" "$OFF" "$TARGET"
cat <<EOF

Next:
  1. cd $TARGET
  2. Read README.md — it explains what belongs here and what belongs in Tier 2.
  3. bash install.sh --dry-run      inspect the plan
     bash install.sh                install
  4. Confirm your MCP namespace, register the hooks, start a NEW session.

Not done for you, on purpose:
  · No remote was created. Decide where this lives — a personal repo is fine, but if it
    ends up somewhere shared, remember it is YOUR doctrine, not the team's.
  · Nothing was committed. Review the tree first, then commit when you are happy.
EOF

if [ -z "$AGENT" ]; then
  cat <<'EOF'

  · Your agent is UNNAMED, on purpose. Naming it is a step of its own, and it belongs
    to the agent rather than to you: start a session and ask it to choose one.
    Then set agentName in instance.lock.json and export AGENT_NAME.
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
