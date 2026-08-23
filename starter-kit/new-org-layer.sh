#!/usr/bin/env bash
# new-org-layer.sh — create your organisation's Tier 2 layer from the template.
#
#   bash starter-kit/new-org-layer.sh <layer-name> <github-org/repo> [destination-dir] [display-name]
#
#   bash starter-kit/new-org-layer.sh dark-factory-acme acme/dark-factory-acme ~/Code "Acme"
#
# Creates <destination>/<layer-name> from starter-kit/templates/tier2-org, pins Tier 1
# (this repo) to a COMMIT SHA resolved right now, and writes the skill and hook list from
# the Tier 1 checkout this script runs in. Nothing is pushed and no remote is created —
# where your layer lives is your decision, not this script's.
#
# Why a generated list instead of "install everything upstream has": the lockfile is the
# authority for what gets installed. When Tier 1 adds a skill later, your layer takes it
# by a deliberate lockfile edit — not by surprise on the next install.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"          # .../starter-kit
T1_ROOT="$(dirname "$HERE")"                   # the Tier 1 checkout
TEMPLATE="$HERE/templates/tier2-org"

RED=''; GRN=''; YEL=''; OFF=''
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'; fi
die() { printf '%sFATAL%s %s\n' "$RED" "$OFF" "$1"; exit 1; }

NAME="${1:-}"
ORG_REPO="${2:-}"
DEST_DIR="${3:-$HOME}"
DISPLAY="${4:-}"

[ -n "$NAME" ] && [ -n "$ORG_REPO" ] || die "usage: bash starter-kit/new-org-layer.sh <layer-name> <github-org/repo> [destination-dir] [display-name]"
[ -d "$TEMPLATE" ] || die "template missing at $TEMPLATE"
command -v jq >/dev/null 2>&1 || die "jq is required"

# A name that is not a safe directory-and-repo name will bite later, in a shell quoting or
# URL context far from here. Reject it now, where the message can be clear.
case "$NAME" in
  *[!a-zA-Z0-9._-]*) die "layer name may contain only letters, digits, dot, underscore, hyphen — got '$NAME'" ;;
esac
case "$ORG_REPO" in
  */*) : ;;
  *) die "second argument must be a GitHub slug like acme/dark-factory-acme — got '$ORG_REPO'" ;;
esac
case "$ORG_REPO" in
  *[!a-zA-Z0-9._/-]*) die "repo slug may contain only letters, digits, dot, underscore, hyphen, slash — got '$ORG_REPO'" ;;
esac
[ -n "$DISPLAY" ] || DISPLAY="${ORG_REPO%%/*}"
case "$DISPLAY" in
  *[!a-zA-Z0-9._\ -]*) die "display name may contain only letters, digits, space, dot, underscore, hyphen — got '$DISPLAY'" ;;
esac

# Escape what is special in a sed REPLACEMENT: backslash, ampersand, and our delimiter.
# An unescaped & expands to the whole match, which corrupts silently rather than failing.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

TARGET="$DEST_DIR/$NAME"
[ -e "$TARGET" ] && die "$TARGET already exists — refusing to overwrite. Pick another name or remove it."

# Resolve Tier 1 to a COMMIT SHA now, rather than storing a branch name. A branch in a
# lockfile means upstream can move under you between installs. Resolving here makes the
# safe thing the default and costs you nothing: taking an update is still a one-line bump,
# it just happens when you choose instead of mid-task.
T1_REPO="OneDro1d/dark-factory"
T1_BRANCH="${T1_REF_BRANCH:-main}"
T1_REF=""
if command -v git >/dev/null 2>&1; then
  T1_REF="$(git ls-remote "https://github.com/$T1_REPO.git" "refs/heads/$T1_BRANCH" 2>/dev/null | cut -f1)"
fi
if [ -n "$T1_REF" ]; then
  T1_SOURCE="resolved from branch $T1_BRANCH on $(date -u +%Y-%m-%d)"
  printf '%s✓%s Tier 1 pinned to %s (%s)\n' "$GRN" "$OFF" "${T1_REF:0:12}" "$T1_BRANCH"
else
  # Falling back to the branch name is worse but still works. Say so plainly rather than
  # writing an unpinned ref and letting you discover it later.
  T1_REF="$T1_BRANCH"
  T1_SOURCE="UNRESOLVED — this is a branch name, not a pin. Replace it with a commit SHA."
  printf '%s!%s Could not reach %s to resolve a SHA.\n' "$YEL" "$OFF" "$T1_REPO"
  printf '  Left ref as the branch "%s". That works, but upstream can move under you.\n' "$T1_BRANCH"
  printf '  Fix when you have network:  git ls-remote https://github.com/%s.git refs/heads/%s\n' "$T1_REPO" "$T1_BRANCH"
fi

mkdir -p "$DEST_DIR" || die "cannot create $DEST_DIR"
cp -R "$TEMPLATE" "$TARGET" || die "copy failed"

# Build the skill and hook lists from the Tier 1 checkout this script runs in, so the
# generated lockfile starts complete and explicit rather than referencing "everything".
#
# The shape is the one every tier reads: an ARRAY of names is the declaration, and a
# matching *Sources MAP says where each one comes from. Both halves are written here
# together, because either alone installs nothing while still reading like a declaration
# — which is exactly what lock-verify L7 exists to catch.
SKILL_NAMES="$(
  for d in "$T1_ROOT/skills"/*/; do [ -d "$d" ] || continue; basename "$d"; done | jq -R . | jq -s '.'
)"
SKILL_SOURCES="$(
  printf '%s' "$SKILL_NAMES" | jq 'map({(.): ("upstream:dark-factory/skills/" + .)}) | add // {}'
)"
HOOK_NAMES="$(
  for f in "$T1_ROOT/hooks"/*; do [ -f "$f" ] || continue; basename "$f"; done | jq -R . | jq -s '.'
)"
HOOK_SOURCES="$(
  printf '%s' "$HOOK_NAMES" | jq 'map({(.): ("upstream:dark-factory/hooks/" + .)}) | add // {}'
)"

# Substitute org-level placeholders. Instance-level placeholders (__INSTANCE_NAME__,
# __AGENT_NAME__, __T2_REF__, __T2_REF_SOURCE__) are deliberately left in place — they
# belong to scripts/new-instance.sh in the generated layer, which substitutes them when a
# developer generates their Tier 3 instance.
NAME_ESC="$(sed_escape "$NAME")"
ORG_REPO_ESC="$(sed_escape "$ORG_REPO")"
DISPLAY_ESC="$(sed_escape "$DISPLAY")"
T1_REF_ESC="$(sed_escape "$T1_REF")"
T1_SOURCE_ESC="$(sed_escape "$T1_SOURCE")"

while IFS= read -r f; do
  sed -i.bak \
    -e "s|__ORG_LAYER_NAME__|$NAME_ESC|g" \
    -e "s|__ORG_REPO__|$ORG_REPO_ESC|g" \
    -e "s|__ORG_DISPLAY__|$DISPLAY_ESC|g" \
    -e "s|__T1_REF__|$T1_REF_ESC|g" \
    -e "s|__T1_REF_SOURCE__|$T1_SOURCE_ESC|g" \
    "$f" && rm -f "$f.bak"
done < <(find "$TARGET" -type f -not -path '*/.git/*')

# Fill the generated lists and source maps (jq, not sed — they are JSON, not text). The
# template's `$comment` inside each *Sources map is preserved: it is documentation, not an
# entry, and every reader skips `$`-prefixed keys.
LOCK="$TARGET/org.lock.json"
jq --argjson skn "$SKILL_NAMES" --argjson sks "$SKILL_SOURCES" \
   --argjson hkn "$HOOK_NAMES"  --argjson hks "$HOOK_SOURCES" \
  '.install.skills       = $skn
   | .install.skillSources = (.install.skillSources // {}) * $sks
   | .install.hooks        = $hkn
   | .install.hookSources  = (.install.hookSources // {}) * $hks' "$LOCK" > "$LOCK.tmp" || die "lockfile fill failed"
mv "$LOCK.tmp" "$LOCK"

chmod +x "$TARGET/install.sh" "$TARGET/scripts/new-instance.sh"

# git init and stage, but deliberately do NOT commit — read the tree before it becomes
# history.
if command -v git >/dev/null 2>&1; then
  git -C "$TARGET" init -q
  git -C "$TARGET" add -A
fi

SK_COUNT="$(printf '%s' "$SKILL_NAMES" | jq 'length')"
HK_COUNT="$(printf '%s' "$HOOK_NAMES"  | jq 'length')"
printf '\n%s✓%s created %s (%s skills, %s hooks from Tier 1)\n' "$GRN" "$OFF" "$TARGET" "$SK_COUNT" "$HK_COUNT"
cat <<EOF

Next:
  1. cd $TARGET
  2. Read README.md — what belongs in this layer and what belongs in an instance.
  3. Edit org.lock.json: prune skills your org does not want, add your own under skills/.
  4. bash install.sh --dry-run      inspect the plan
     bash install.sh                install
  5. Push to https://github.com/$ORG_REPO when you are happy — your developers clone THIS
     repo, never Tier 1 directly.
  6. Each developer then runs: bash scripts/new-instance.sh <their-instance-name>

Not done for you, on purpose:
  · No remote was created, nothing was committed. Review the tree first.
  · The lockfile lists Tier 1's full current skill set. Pruning it is a decision worth
    making deliberately, per skill, before your whole org inherits the lot.
EOF
