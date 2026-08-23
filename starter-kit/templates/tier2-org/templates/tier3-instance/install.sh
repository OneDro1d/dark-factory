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

# --- BEGIN shared install-source reader (keep BYTE-IDENTICAL across the tier templates) ---
# Every tier reads `install` the way the engine does, so a lockfile means one thing
# wherever it is read:
#
#   install.<kind>         an ARRAY of names   — the declaration
#   install.<kind>Sources  a MAP name->source  — where each one comes from
#
#   local:<path>     resolved against the LOCKFILE's directory — this repo. Without it a
#                    layer cannot own a skill or a hook at all: it would have to push its
#                    own file into some other repo and vendor it back.
#   upstream:<path>  resolved against vendorDir. The explicit spelling of the default.
#   <path>           resolved against vendorDir. The legacy bare form, unchanged.
#
# ROOT is the LOCKFILE's directory, never this script's. That distinction is the whole
# safety of `local:`: a copy of this installer run from a different root must still mean
# THAT root, not the tree the copy happens to sit in. The failure it prevents is silent by
# construction — the wrong file installs successfully.
#
# This block is duplicated rather than shared because each tier template has to stand
# alone in a fresh clone with nothing vendored yet. The duplication is not left to
# goodwill: starter-kit/tests/test-org-layer-shape.sh asserts the two copies are
# byte-identical, so drift between them is a test failure, not a discovery.
ROOT="$(pwd)"

resolve_src() {
  case "$1" in
    local:*)    printf '%s/%s'    "$ROOT" "${1#local:}" ;;
    upstream:*) printf '%s/%s/%s' "$ROOT" "$VENDOR" "${1#upstream:}" ;;
    *)          printf '%s/%s/%s' "$ROOT" "$VENDOR" "$1" ;;
  esac
}

# A source that climbs out of the tree it names is refused, never normalised.
src_escapes() { case "$1" in *..*) return 0 ;; *) return 1 ;; esac; }

# The old shape was a single MAP keyed by name. It is REFUSED, not read: an installer that
# understands both shapes forever is exactly how a third reading appears. The fix is one
# command, so the refusal names it and installs nothing.
lock_shape_guard() {
  local kind t
  for kind in skills hooks; do
    t="$(jq -r --arg k "$kind" '.install[$k] | type' "$LOCK" 2>/dev/null)"
    case "$t" in
      array|null) ;;
      object) die "install.$kind in $LOCK is a MAP — that is the old shape, from before
   names and sources were split. Convert it once, then re-run this installer:

     python3 <dark-factory checkout>/boot-kit/scripts/df-lock-migrate.py --lock $LOCK --apply

   Nothing was installed." ;;
      *) die "install.$kind in $LOCK has unexpected type '$t' — expected an array." ;;
    esac
  done
}

# `skills` pairs with `skillSources`, `hooks` with `hookSources` — the stem is SINGULAR.
# Derived by rule rather than spelled per call site, so the two cannot drift apart.
smap_key()   { printf '%sSources' "${1%s}"; }
declared()   { jq -r --arg k "$1" '(.install[$k] // []) | .[]' "$LOCK"; }
source_for() { jq -r --arg m "$(smap_key "$1")" --arg n "$2" '(.install[$m] // {})[$n] // empty' "$LOCK"; }

# A name with no source and a source with no name both install NOTHING while still
# reading like a declaration. The array+map pair can express each; a single map could
# express neither, which is the one advantage the old shape had. It is bought back here.
orphan_sources() {
  jq -r --arg k "$1" --arg m "$(smap_key "$1")" '.install as $i
      | (($i[$m] // {}) | keys[])
      | select(startswith("$") | not)
      | . as $n
      | select(([(($i[$k]) // [])[]] | index($n)) == null)' "$LOCK"
}
# --- END shared install-source reader ---

lock_shape_guard

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
  src="$(source_for skills "$s")"
  if [ -z "$src" ]; then
    warn "$s: declared in install.skills with no entry in install.skillSources — installs nothing"
    continue
  fi
  if src_escapes "$src"; then
    warn "$s: source '$src' climbs out of the tree it names — refused, not normalised"
    continue
  fi
  abs="$(resolve_src "$src")"
  [ -d "$abs" ] || { warn "skill $s: nothing at $src"; continue; }
  if [ -e "$LIVE/skills/$s" ] && [ "$(readlink "$LIVE/skills/$s" 2>/dev/null)" != "$abs" ]; then
    warn "$s OVERRIDES a Tier 2 skill — intended? A silent override is how tiers rot."
    OVERRIDE=$((OVERRIDE+1))
  fi
  if [ "$DRY" -eq 0 ]; then
    rm -rf "$LIVE/skills/$s"; ln -s "$abs" "$LIVE/skills/$s"
  fi
  LOCAL_SK=$((LOCAL_SK+1))
done < <(declared skills)
while read -r o; do
  [ -n "$o" ] || continue
  warn "$o: has an install.skillSources entry but is NOT in install.skills — installs nothing, and still reads like a declaration"
done < <(orphan_sources skills)

while read -r h; do
  [ -n "$h" ] || continue
  src="$(source_for hooks "$h")"
  if [ -z "$src" ]; then
    warn "$h: declared in install.hooks with no entry in install.hookSources — installs nothing"
    continue
  fi
  if src_escapes "$src"; then
    warn "$h: source '$src' climbs out of the tree it names — refused, not normalised"
    continue
  fi
  abs="$(resolve_src "$src")"
  [ -f "$abs" ] || { warn "hook $h: nothing at $src"; continue; }
  [ -f "$LIVE/hooks/$h" ] && { warn "$h OVERRIDES a Tier 2 hook — intended?"; OVERRIDE=$((OVERRIDE+1)); }
  if [ "$DRY" -eq 0 ]; then
    sed "s|__HOME__|$HOME|g" "$abs" > "$LIVE/hooks/$h"; chmod +x "$LIVE/hooks/$h"
  fi
  LOCAL_HK=$((LOCAL_HK+1))
done < <(declared hooks)
while read -r o; do
  [ -n "$o" ] || continue
  warn "$o: has an install.hookSources entry but is NOT in install.hooks — installs nothing, and still reads like a declaration"
done < <(orphan_sources hooks)

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
