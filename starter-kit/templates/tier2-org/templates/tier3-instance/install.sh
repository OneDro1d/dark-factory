#!/usr/bin/env bash
# install.sh — install THIS Tier 3 instance.
#
#   bash install.sh              install
#   bash install.sh --dry-run    show the plan, write nothing
#   bash install.sh --offline    reinstall from an existing vendor/, no network
#
# What it does, in order:
#   1. Fetches Tier 2 (the shared __ORG_DISPLAY__ environment) at the ref in
#      instance.lock.json.
#   2. DELEGATES to Tier 2's installer, which brings Tier 1 and installs the shared
#      skills and hooks. Your instance never re-lists them — one copy, no drift.
#   3. Layers YOUR skills and hooks on top, reporting any that override a shared one.
#
# Authority: instance.lock.json > this script > anything you remember.
set -uo pipefail

cd "$(dirname "$0")" || exit 1
LOCK="instance.lock.json"
DRY=0; OFFLINE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --offline) OFFLINE=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$a"; exit 2 ;;
  esac
done

RED=''; GRN=''; YEL=''; OFF=''
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'; fi
ok()   { printf '%s✓%s %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '%s!%s %s\n' "$YEL" "$OFF" "$1"; }
die()  { printf '%sFATAL%s %s\n' "$RED" "$OFF" "$1"; exit 1; }
step() { printf '\n== %s\n' "$1"; }

[ -f "$LOCK" ] || die "no $LOCK here — run this from your instance repo root."
for c in git jq; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done

INSTANCE="$(jq -r '.instance // "unnamed"' "$LOCK")"
AGENT="$(jq -r '.agentName // empty' "$LOCK")"
VENDOR="$(jq -r '.vendorDir // "vendor"' "$LOCK")"
LIVE="${CLAUDE_HOME:-$HOME/.claude}"

printf 'instance : %s\nagent    : %s\nlive     : %s\n' "$INSTANCE" "${AGENT:-<unset>}" "$LIVE"
case "$INSTANCE" in *__INSTANCE_NAME[_]_*) warn "instance name is still the template placeholder — edit $LOCK" ;; esac
[ "$DRY" -eq 1 ] && warn "DRY RUN — nothing will be written"

# The namespace cannot be detected from a shell: the tools live in the agent session, not
# in this process. So ask, rather than install an environment whose most important
# assumption is unverified.
printf '\n%sBEFORE you rely on this install%s — confirm which MCP namespace this machine uses.\n' "$YEL" "$OFF"
printf '  There is no single prefix: the name depends on how each machine connects, and two\n'
printf '  people in the same org can see different names in the same week. List the tools in\n'
printf '  YOUR session and check. If ambiguous or nothing resolves, ASK — do not guess.\n'

# ---- 1. Tier 2 --------------------------------------------------------------
step "1. Tier 2 (the shared __ORG_DISPLAY__ environment)"
T2_NAME="$(jq -r '.upstreams | keys[0]' "$LOCK")"
T2_REPO="$(jq -r --arg n "$T2_NAME" '.upstreams[$n].repo' "$LOCK")"
T2_REF="$(jq -r  --arg n "$T2_NAME" '.upstreams[$n].ref'  "$LOCK")"
T2_DIR="$VENDOR/$T2_NAME"

if [ "$OFFLINE" -eq 1 ]; then
  [ -d "$T2_DIR/.git" ] && ok "$T2_NAME (cached)" || die "$T2_NAME missing and --offline given"
elif [ "$DRY" -eq 1 ]; then
  printf '   would fetch %s @ %s\n' "$T2_REPO" "$T2_REF"
else
  mkdir -p "$VENDOR"
  if [ -d "$T2_DIR/.git" ]; then
    git -C "$T2_DIR" fetch --quiet origin || warn "fetch failed — trying the cached ref"
  else
    gh repo clone "$T2_REPO" "$T2_DIR" -- --quiet 2>/dev/null \
      || git clone --quiet "https://github.com/$T2_REPO.git" "$T2_DIR" \
      || die "could not clone $T2_REPO — if Tier 2 is private, check you are authenticated (gh auth status)"
  fi
  # A ref may be a branch or a commit. Try the remote-tracking form first so a branch
  # name picks up the fetch, then fall back to a literal commit.
  git -C "$T2_DIR" checkout --quiet "origin/$T2_REF" 2>/dev/null \
    || git -C "$T2_DIR" checkout --quiet "$T2_REF" 2>/dev/null \
    || die "could not check out '$T2_REF'. If upstream rewrote history, a pinned commit can vanish — check: git -C $T2_DIR log --oneline"
  ok "$T2_NAME @ $T2_REF ($(git -C "$T2_DIR" rev-parse --short HEAD))"
fi

# ---- 2. delegate ------------------------------------------------------------
# Tier 2 owns the shared skill and hook list. Re-implementing it here would create the
# second copy this tier split exists to prevent.
step "2. delegating to Tier 2's installer"
if [ "$DRY" -eq 1 ]; then
  printf '   would run: bash %s/install.sh\n' "$T2_DIR"
else
  T2_ARGS=""
  [ "$OFFLINE" -eq 1 ] && T2_ARGS="--offline"
  CLAUDE_HOME="$LIVE" bash "$T2_DIR/install.sh" $T2_ARGS || warn "Tier 2 installer reported problems — read its output above"
fi

# ---- 3. your additions ------------------------------------------------------
step "3. your instance additions"
LOCAL_SK=0; LOCAL_HK=0; OVERRIDE=0

while read -r s; do
  [ -n "$s" ] || continue
  src="$(jq -r --arg s "$s" '.install.skills[$s]' "$LOCK")"
  abs="$(pwd)/$src"
  [ -d "$abs" ] || { warn "skill $s: nothing at $src"; continue; }
  if [ -e "$LIVE/skills/$s" ] && [ "$(readlink "$LIVE/skills/$s" 2>/dev/null)" != "$abs" ]; then
    warn "$s OVERRIDES a Tier 2 skill — intended? A silent override is how tiers rot."
    OVERRIDE=$((OVERRIDE+1))
  fi
  if [ "$DRY" -eq 0 ]; then
    rm -rf "$LIVE/skills/$s"; ln -s "$abs" "$LIVE/skills/$s"
  fi
  LOCAL_SK=$((LOCAL_SK+1))
done < <(jq -r '(.install.skills // {}) | keys[]' "$LOCK")

while read -r h; do
  [ -n "$h" ] || continue
  src="$(jq -r --arg h "$h" '.install.hooks[$h]' "$LOCK")"
  [ -f "$src" ] || { warn "hook $h: nothing at $src"; continue; }
  [ -f "$LIVE/hooks/$h" ] && { warn "$h OVERRIDES a Tier 2 hook — intended?"; OVERRIDE=$((OVERRIDE+1)); }
  if [ "$DRY" -eq 0 ]; then
    sed "s|__HOME__|$HOME|g" "$src" > "$LIVE/hooks/$h"; chmod +x "$LIVE/hooks/$h"
  fi
  LOCAL_HK=$((LOCAL_HK+1))
done < <(jq -r '(.install.hooks // {}) | keys[]' "$LOCK")

ok "$LOCAL_SK instance skill(s), $LOCAL_HK instance hook(s), $OVERRIDE override(s)"

# ---- 4. what this cannot do -------------------------------------------------
step "MANUAL — not restorable from a lockfile"
jq -r '.notRestorable | to_entries[] | select(.key|startswith("$")|not) | "  · \(.key) — \(.value)"' "$LOCK" 2>/dev/null

# The case patterns spell the placeholders with a [_] so the template-generation sed
# (which replaces the plain spelling) cannot rewrite the checks themselves.
case "$AGENT" in
'' | __AGENT_NAME[_]_)
  # Deliberately unresolved rather than defaulted. The installer keeps asking, because a
  # name that arrived by default was never chosen by anyone.
  cat <<'INNER'

  ── Your agent has not named itself yet ──────────────────────────────────────
  This is a real step, and it is the agent's to take, not yours.

  Start a session and ask it to choose a name for itself. Then:
    1. set  "agentName": "<chosen>"  in instance.lock.json
    2. export AGENT_NAME=<chosen>
    3. re-run this installer

  Why it is worth a step: the name is how you will address each other for as long
  as this instance lives. A default is not a choice.

  The one hard constraint: that name NEVER becomes a release, an image tag, or a
  ticket fixVersion. Those use the application name plus semver — a release named
  after an agent tells a human nothing about what shipped.
  ─────────────────────────────────────────────────────────────────────────────
INNER
  ;;
*)
  printf '\n  Set your agent name so the boot banner uses it:\n    export AGENT_NAME=%s\n' "$AGENT"
  ;;
esac
cat <<'EOF'

  Then:
    1. Confirm your MCP namespace (see the note at the top).
    2. Register the hooks — merge the hook entries into ~/.claude/settings.json
       (see Tier 2's hooks/README.md; merge into existing arrays, do not overwrite).
    3. Start a NEW session. Hooks and MCP manifests are read once, at session start.
EOF

if [ "$DRY" -eq 1 ]; then
  printf '\n%sdry run complete%s — nothing written.\n' "$YEL" "$OFF"
else
  printf '\n%sinstance ready%s — %s\n' "$GRN" "$OFF" "$INSTANCE"
fi
