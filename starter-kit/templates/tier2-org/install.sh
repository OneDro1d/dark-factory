#!/usr/bin/env bash
# install.sh — install the __ORG_DISPLAY__ shared agent environment from org.lock.json.
#
# SELF-CONTAINED BY DESIGN. This is the only file you need to run. Clone the repo, run
# this, and you have the skills and hooks in place.
#
#   Fresh machine:   git clone <this repo> && cd <it> && bash install.sh
#   Inspect first:   bash install.sh --dry-run
#   No network:      bash install.sh --offline      (uses an existing vendor/)
#
# What it does:
#   1. Reads org.lock.json — the authority for WHAT gets installed.
#   2. Fetches Tier 1 (OneDro1d/dark-factory) into vendor/ at its PINNED commit.
#   3. Symlinks every locked skill into ~/.claude/skills.
#   4. Copies every locked hook into ~/.claude/hooks, rehydrating __HOME__.
#   5. Verifies the result, then prints what it CANNOT do for you.
#
# Direction of authority: org.lock.json > this script > anything you remember.
set -uo pipefail

cd "$(dirname "$0")" || exit 1
LOCK="org.lock.json"
DRY=0; OFFLINE=0; SKIP_VERIFY=0

for a in "$@"; do
  case "$a" in
    --dry-run)    DRY=1 ;;
    --offline)    OFFLINE=1 ;;
    --no-verify)  SKIP_VERIFY=1 ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *)            printf 'unknown option: %s (try --help)\n' "$a"; exit 2 ;;
  esac
done

RED=''; GRN=''; YEL=''; OFF=''
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'; fi
ok()   { printf '%s✓%s %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '%s!%s %s\n' "$YEL" "$OFF" "$1"; }
die()  { printf '%sFATAL%s %s\n' "$RED" "$OFF" "$1"; exit 1; }
step() { printf '\n== %s\n' "$1"; }

[ -f "$LOCK" ] || die "no $LOCK in $(pwd) — run this from the repo root."

# ---- 0. prerequisites -------------------------------------------------------
step "0. prerequisites"
for c in git jq; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required but not on PATH."
done
ok "git, jq present"
command -v python3 >/dev/null 2>&1 || warn "python3 not found — some hooks need it at runtime."

# The MCP namespace cannot be detected from here — the tools live in the agent session,
# not in this process. So state it as a question the operator must answer, rather than
# silently installing an environment whose most important assumption is unverified.
printf '\n%sBEFORE you rely on this install%s — confirm which MCP namespace this machine uses:\n' "$YEL" "$OFF"
jq -r '.mcpNote // empty' "$LOCK" | fold -s -w 88 | sed 's/^/  /'

REPO="$(jq -r '.repo // "unknown"' "$LOCK")"
VENDOR="$(jq -r '.vendorDir // "vendor"' "$LOCK")"
LIVE="${CLAUDE_HOME:-$HOME/.claude}"
printf '\nrepo   : %s\nvendor : %s\nlive   : %s\n' "$REPO" "$VENDOR" "$LIVE"
[ "$DRY" -eq 1 ] && warn "DRY RUN — nothing will be written."

# ---- 1. upstreams -----------------------------------------------------------
# Tier 1 is fetched, never vendored into git. The pinned commit in the lockfile is the
# source of truth; vendor/ is a rebuildable cache.
step "1. upstream (Tier 1) at its pinned commit"
FETCH_FAIL=0
[ "$DRY" -eq 0 ] && mkdir -p "$VENDOR"

while read -r name; do
  [ -n "$name" ] || continue
  url="$(jq -r --arg n "$name" '.upstreams[$n].repo'   "$LOCK")"
  pin="$(jq -r --arg n "$name" '.upstreams[$n].commit' "$LOCK")"
  dest="$VENDOR/$name"

  if [ "$OFFLINE" -eq 1 ]; then
    if [ -d "$dest/.git" ]; then ok "$name (cached)"; else warn "$name MISSING and --offline given"; FETCH_FAIL=1; fi
    continue
  fi
  if [ "$DRY" -eq 1 ]; then
    printf '   would fetch %-16s %s @ %s\n' "$name" "$url" "${pin:0:8}"
    continue
  fi

  if [ -d "$dest/.git" ]; then
    git -C "$dest" fetch --quiet origin 2>/dev/null || warn "fetch failed for $name — will try the cached commit"
  else
    # Public repo: a plain clone is enough. gh is used only as a fallback so this still
    # works from a machine whose git credential helper is not set up.
    if ! git clone --quiet "https://github.com/$url.git" "$dest" 2>/dev/null; then
      if command -v gh >/dev/null 2>&1 && gh repo clone "$url" "$dest" -- --quiet 2>/dev/null; then
        :
      else
        warn "could not clone $url"
        warn "   Note: GitHub returns 404 (not 403) for anything an identity cannot see,"
        warn "   so a proxy or routing problem presents as 'does not exist' rather than"
        warn "   'permission denied'. Do not conclude the pinned commit is wrong from that."
        FETCH_FAIL=1
        continue
      fi
    fi
  fi

  if git -C "$dest" checkout --quiet "$pin" 2>/dev/null; then
    ok "$name @ ${pin:0:8}"
  else
    warn "$name could not check out ${pin:0:8}."
    warn "   If the fetch succeeded but checkout fails, suspect an upstream HISTORY"
    warn "   REWRITE before suspecting a typo — a rewritten repo serves new objects and"
    warn "   the old pin exists nowhere. git -C $dest log --oneline settles it."
    FETCH_FAIL=1
  fi
done < <(jq -r '.upstreams | keys[]' "$LOCK")

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

# ---- 2. skills --------------------------------------------------------------
# SYMLINKED, not copied. A copy is a parallel store, and parallel stores drift — which is
# the whole reason the tiers exist. Editing this repo updates the live skill immediately,
# which is also what makes customising practical.
step "2. skills -> $LIVE/skills (symlinks)"
[ "$DRY" -eq 0 ] && mkdir -p "$LIVE/skills"
SK_OK=0; SK_MISS=0; SK_PEND=0

while read -r s; do
  [ -n "$s" ] || continue
  src="$(source_for skills "$s")"
  if [ -z "$src" ]; then
    warn "$s: declared in install.skills with no entry in install.skillSources — installs nothing"
    SK_MISS=$((SK_MISS+1)); continue
  fi
  if src_escapes "$src"; then
    warn "$s: source '$src' climbs out of the tree it names — refused, not normalised"
    SK_MISS=$((SK_MISS+1)); continue
  fi
  abs="$(resolve_src "$src")"
  # In a dry run vendor/ is legitimately empty, so an absent upstream skill is expected,
  # not a fault. Reporting it as missing would make the dry run cry wolf dozens of times
  # and train the reader to skim past the warnings that DO matter.
  if [ ! -d "$abs" ]; then
    case "$src:$DRY" in local:*) : ;; *:1) SK_PEND=$((SK_PEND+1)); continue ;; esac
    warn "$s: not present at ${src}"; SK_MISS=$((SK_MISS+1)); continue
  fi
  if [ "$DRY" -eq 1 ]; then SK_OK=$((SK_OK+1)); continue; fi

  # Only replace what we own, and never silently. A machine may mix these links with
  # skills installed by other means; clobbering one without saying so causes real
  # regressions.
  if [ -L "$LIVE/skills/$s" ]; then
    cur="$(readlink "$LIVE/skills/$s")"
    [ "$cur" != "$abs" ] && warn "repointing $s (was $cur)"
  elif [ -d "$LIVE/skills/$s" ]; then
    warn "replacing a plain-directory copy of $s with a link"
  fi
  rm -rf "$LIVE/skills/$s"
  ln -s "$abs" "$LIVE/skills/$s"
  SK_OK=$((SK_OK+1))
done < <(declared skills)
while read -r o; do
  [ -n "$o" ] || continue
  warn "$o: has an install.skillSources entry but is NOT in install.skills — installs nothing, and still reads like a declaration"
  SK_MISS=$((SK_MISS+1))
done < <(orphan_sources skills)
if [ "$DRY" -eq 1 ]; then
  ok "$SK_OK local skills resolved, $SK_PEND would come from the upstream fetch, $SK_MISS missing"
else
  ok "$SK_OK skills linked, $SK_MISS missing"
fi

# ---- 3. hooks ---------------------------------------------------------------
# COPIED, not symlinked. Two reasons: __HOME__ has to be rehydrated per machine, and on a
# cloud dev environment ~/.claude often sits on a disk that a workspace reset wipes, so a
# symlink target there would vanish with it.
step "3. hooks -> $LIVE/hooks (copies, __HOME__ rehydrated)"
[ "$DRY" -eq 0 ] && mkdir -p "$LIVE/hooks"
HK_OK=0; HK_MISS=0; HK_PEND=0

while read -r h; do
  [ -n "$h" ] || continue
  src="$(source_for hooks "$h")"
  if [ -z "$src" ]; then
    warn "$h: declared in install.hooks with no entry in install.hookSources — installs nothing"
    HK_MISS=$((HK_MISS+1)); continue
  fi
  if src_escapes "$src"; then
    warn "$h: source '$src' climbs out of the tree it names — refused, not normalised"
    HK_MISS=$((HK_MISS+1)); continue
  fi
  abs="$(resolve_src "$src")"
  if [ ! -f "$abs" ]; then
    case "$src:$DRY" in local:*) : ;; *:1) HK_PEND=$((HK_PEND+1)); continue ;; esac
    warn "$h: not present at ${src}"; HK_MISS=$((HK_MISS+1)); continue
  fi
  if [ "$DRY" -eq 0 ]; then
    sed "s|__HOME__|$HOME|g" "$abs" > "$LIVE/hooks/$h"
    chmod +x "$LIVE/hooks/$h"
  fi
  HK_OK=$((HK_OK+1))
done < <(declared hooks)
while read -r o; do
  [ -n "$o" ] || continue
  warn "$o: has an install.hookSources entry but is NOT in install.hooks — installs nothing, and still reads like a declaration"
  HK_MISS=$((HK_MISS+1))
done < <(orphan_sources hooks)
if [ "$DRY" -eq 1 ]; then
  ok "$HK_OK local hooks resolved, $HK_PEND would come from the upstream fetch, $HK_MISS missing"
else
  ok "$HK_OK hooks installed, $HK_MISS missing"
fi

# ---- 4. verify --------------------------------------------------------------
# Checks the RESULT on disk, not what the script believes it did.
if [ "$SKIP_VERIFY" -eq 0 ] && [ "$DRY" -eq 0 ]; then
  step "4. verify"
  V_FAIL=0

  want_sk="$(jq -r '(.install.skills // []) | length' "$LOCK")"
  have_sk=0
  while read -r s; do
    [ -n "$s" ] || continue
    if [ -e "$LIVE/skills/$s" ]; then have_sk=$((have_sk+1)); else warn "V1 missing skill: $s"; V_FAIL=1; fi
  done < <(declared skills)
  [ "$have_sk" -eq "$want_sk" ] && ok "V1 all $want_sk locked skills present" || { warn "V1 $have_sk/$want_sk skills present"; V_FAIL=1; }

  want_hk="$(jq -r '(.install.hooks // []) | length' "$LOCK")"
  have_hk=0
  while read -r h; do
    [ -n "$h" ] || continue
    if [ -x "$LIVE/hooks/$h" ]; then have_hk=$((have_hk+1)); else warn "V2 missing or non-executable hook: $h"; V_FAIL=1; fi
  done < <(declared hooks)
  [ "$have_hk" -eq "$want_hk" ] && ok "V2 all $want_hk locked hooks executable" || { warn "V2 $have_hk/$want_hk hooks ready"; V_FAIL=1; }

  # A symlink that resolves nowhere is worse than an absent one: the skill silently does
  # not load, and nothing says so. Checked with -L/-e rather than find -xtype: BSD find
  # (macOS) has no -xtype, so there the find errored to stderr and the empty pipe counted
  # 0 — a check that could never fail on a Mac.
  dangling=0
  for _l in "$LIVE/skills"/*; do
    if [ -L "$_l" ] && [ ! -e "$_l" ]; then dangling=$((dangling+1)); fi
  done
  [ "$dangling" -eq 0 ] && ok "V3 no dangling skill symlinks" || { warn "V3 $dangling dangling symlink(s)"; V_FAIL=1; }

  # A hook still containing the placeholder was copied without substitution and will fail
  # at runtime with a confusing path error.
  if grep -rl '__HOME__' "$LIVE/hooks" >/dev/null 2>&1; then
    warn "V4 a hook still contains __HOME__ — substitution did not run"; V_FAIL=1
  else
    ok "V4 no unsubstituted __HOME__ placeholders"
  fi

  if [ "$V_FAIL" -eq 0 ]; then
    printf '\n%s=== VERIFIED — this machine matches org.lock.json ===%s\n' "$GRN" "$OFF"
  else
    printf '\n%s=== NOT VERIFIED — read the warnings above before relying on this ===%s\n' "$RED" "$OFF"
  fi
fi

# ---- what this CANNOT do ----------------------------------------------------
# Printed every run, so a green install is never mistaken for a complete setup.
step "MANUAL — not restorable from a lockfile"
jq -r '.notRestorable | to_entries[] | select(.key|startswith("$")|not) | "  · \(.key) — \(.value)"' "$LOCK" 2>/dev/null

cat <<'EOF'

  Next, on this machine:
    1. CONFIRM YOUR MCP NAMESPACE FIRST. List the tools in your agent session and
       check. If it is ambiguous or nothing resolves, ASK — do not guess.
    2. Register the hooks — merge the hook entries into ~/.claude/settings.json
       (see hooks/README.md; merge into existing arrays, do not overwrite).
    3. Start a NEW session. Hooks and MCP manifests are read once at session start,
       so nothing you just installed is visible in a session that is already running.
EOF

if [ "$FETCH_FAIL" -ne 0 ]; then
  printf '\n%sThe upstream did not resolve.%s Skills from Tier 1 are missing.\n' "$RED" "$OFF"
  exit 1
fi

if [ "$DRY" -eq 1 ]; then
  printf '\n%sdry run complete%s — nothing was written. Re-run without --dry-run to install.\n' "$YEL" "$OFF"
else
  printf '\n%sinstall complete%s — %s\n' "$GRN" "$OFF" "$REPO"
fi
