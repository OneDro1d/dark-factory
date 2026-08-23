#!/usr/bin/env bash
# install.sh — lockfile -> working machine. Re-runnable, and honest about what it skipped.
#
# Run from inside your instance directory (the one bootstrap.sh generated).
#
#   bash install.sh              fetch at the pins, install, verify
#   bash install.sh --offline    install from whatever is already vendored; touch no network
#   bash install.sh --dry-run    print the plan, change nothing
#
# ORDER, AND WHY IT IS THIS ORDER
#   0  preconditions        fail here, where the cause is one line, not three steps later
#   1  fetch Tier 1         the only fetch this script does itself, and the reason is
#                           bootstrap: every later step is code that lives INSIDE Tier 1,
#                           so something dependency-free has to go and get it first
#   2  materialise engine   copy the engine to boot-kit/scripts/ HERE. The engine resolves
#                           its kit root two levels up from itself, so left in vendor/ it
#                           would resolve to the vendored copy of Tier 1 and read that
#                           repo's facts as this instance's
#   3  rehydrate            hand the remaining upstreams, skills and hooks to Tier 1's own
#                           rehydrate.sh -- one implementation, not two that drift
#   4  PATH                 df-mission has to be reachable; installed-but-unreachable is
#                           not installed, and it fails much later, as "unknown command"
#   5  verify               lock-verify.sh, which is the only thing entitled to say LOCKED
#   6  print the gaps       every run, so a green install is never read as a complete setup
#
# EXIT: 0 installed and LOCKED · 1 a precondition failed · 2 installed but NOT locked.
# 2 is deliberately not 0 and not 1: the install ran, and the result does not match the
# lockfile. Collapsing that into success is how an instance ships half-configured.
set -uo pipefail

OFFLINE=0; DRY=0
for a in "$@"; do
  case "$a" in
    --offline) OFFLINE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$a" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="$ROOT/loom.lock.json"

say()  { printf '%s\n' "$1"; }
step() { printf '\n== %s ==\n' "$1"; }
die()  { printf 'FATAL: %s\n' "$1" >&2; exit 1; }
act()  { if [ "$DRY" -eq 1 ]; then printf 'would  %s\n' "$1"; else printf '%s\n' "$1"; fi; }

# ---- 0. preconditions --------------------------------------------------------
step "preconditions"
[ -f "$LOCK" ] || die "no loom.lock.json in $ROOT — run bootstrap.sh first"
for b in git jq; do
  command -v "$b" >/dev/null 2>&1 || die "$b is required and is not on PATH"
done
python3 --version >/dev/null 2>&1 || say "WARN  python3 not found — the preflight and the prompt renderer will not run"
say "ok    lockfile, git, jq"

# A placeholder that survived bootstrap is a value nobody supplied. Naming them here is
# cheap; discovering them as a clone of the wrong commit is not.
UNFILLED="$(grep -oE '__[A-Z_]+__' "$LOCK" | sort -u | tr '\n' ' ')"
[ -n "$UNFILLED" ] && say "WARN  unresolved placeholders still in the lockfile: $UNFILLED"

VENDOR_REL="$(jq -r '.vendorDir // "vendor"' "$LOCK")"
VENDOR="$ROOT/$VENDOR_REL"
T1_NAME="dark-factory"
T1_URL="$(jq -r --arg n "$T1_NAME" '.upstreams[$n].url // empty' "$LOCK")"
T1_REPO="$(jq -r --arg n "$T1_NAME" '.upstreams[$n].repo // empty' "$LOCK")"
T1_COMMIT="$(jq -r --arg n "$T1_NAME" '.upstreams[$n].commit // empty' "$LOCK")"
[ -n "$T1_REPO" ] || die "the lockfile declares no '$T1_NAME' upstream — nothing to install from"
[ -n "$T1_URL" ] && T1_URL="$T1_URL" || T1_URL="https://github.com/$T1_REPO.git"

# ---- 1. fetch Tier 1 ---------------------------------------------------------
step "tier 1 ($T1_REPO @ ${T1_COMMIT:0:8})"
T1="$VENDOR/$T1_NAME"
if [ "$OFFLINE" -eq 1 ]; then
  [ -d "$T1/.git" ] || die "--offline, and $T1 is not cached — there is nothing to install from"
  say "offline  using the cached checkout as-is"
else
  # Plain git over https on purpose: the public method must install with git alone. A
  # hosting CLI is only needed for PRIVATE upstreams, and rehydrate.sh handles those in
  # step 3, where the identity question actually arises.
  mkdir -p "$VENDOR"
  if [ -d "$T1/.git" ]; then
    act "fetch    $T1_NAME"
    [ "$DRY" -eq 0 ] && { git -C "$T1" fetch --quiet origin || say "  WARN fetch failed — falling back to what is already here"; }
  else
    act "clone    $T1_NAME <- $T1_URL"
    [ "$DRY" -eq 0 ] && { git clone --quiet "$T1_URL" "$T1" || die "clone failed: $T1_URL"; }
  fi
  if [ "$DRY" -eq 0 ] && [ -d "$T1/.git" ]; then
    case "$T1_COMMIT" in
      ""|__*__) say "  WARN  no resolved pin — leaving the checkout on its default branch, which WILL move under you" ;;
      *) git -C "$T1" checkout --quiet "$T1_COMMIT" 2>/dev/null \
           && say "  pinned ${T1_COMMIT:0:8}" \
           || die "commit ${T1_COMMIT:0:8} is not in $T1_REPO — the pin is wrong, or it was never pushed" ;;
    esac
  fi
fi

ENGINE_SRC="$T1/boot-kit/scripts"
[ "$DRY" -eq 1 ] || [ -d "$ENGINE_SRC" ] || die "$ENGINE_SRC missing — the pinned commit does not carry the engine"

# ---- 2. materialise the engine at THIS kit root ------------------------------
step "engine"
ENGINE_DST="$ROOT/boot-kit/scripts"
act "copy     boot-kit/scripts/ <- $VENDOR_REL/$T1_NAME/boot-kit/scripts/"
if [ "$DRY" -eq 0 ]; then
  mkdir -p "$ENGINE_DST"
  # Copy, not symlink. The engine's own root is derived from where the FILE sits, so a
  # symlinked script that resolves back into vendor/ resolves to the wrong root.
  # Everything here is regenerated on every install, so it is a cache, not an edit surface.
  rm -rf "$ENGINE_DST"
  mkdir -p "$ENGINE_DST"
  cp -R "$ENGINE_SRC/." "$ENGINE_DST/" || die "could not copy the engine"
  rm -rf "$ENGINE_DST/__pycache__"
  # Never ship the maintainer's own gate config into an instance: it is gitignored
  # upstream precisely because it is not generic, and a copied one silently answers a
  # question it was never asked about this instance.
  rm -f "$ENGINE_DST/landmarks.conf"
  chmod +x "$ENGINE_DST"/*.sh "$ENGINE_DST"/*.py "$ENGINE_DST/df-mission" 2>/dev/null || true
  cat > "$ROOT/boot-kit/scripts/.generated" <<GEN
Generated by install.sh from $T1_REPO @ $T1_COMMIT
Do not edit anything in this directory: the next install overwrites it.
To change the engine, change it upstream and bump the pin in loom.lock.json.
GEN
  say "ok    $(find "$ENGINE_DST" -maxdepth 1 -type f | wc -l | tr -d ' ') files"
fi

# ---- 3. rehydrate the rest ---------------------------------------------------
step "upstreams, skills, hooks"
REHYDRATE="$ENGINE_DST/rehydrate.sh"
if [ "$DRY" -eq 1 ]; then
  say "would  delegate to boot-kit/scripts/rehydrate.sh"
elif [ -f "$REHYDRATE" ]; then
  RFLAGS=""
  [ "$OFFLINE" -eq 1 ] && RFLAGS="--offline"
  ( cd "$ROOT" && bash "$REHYDRATE" $RFLAGS ) || say "WARN  rehydrate reported a problem — read its output above, it names each one"
else
  say "WARN  no rehydrate.sh in the pinned engine — skills and hooks were NOT installed"
fi

# ---- 4. PATH -----------------------------------------------------------------
step "df-mission on PATH"
# Overridable for the same reason rehydrate.sh takes LOOM_LIVE: a test that has to write
# into the real ~/.local/bin is a test nobody runs twice.
BINDIR="${LOOM_BIN:-$HOME/.local/bin}"
if [ "$DRY" -eq 1 ]; then
  say "would  link $BINDIR/df-mission"
elif [ -f "$ENGINE_DST/df-mission" ]; then
  mkdir -p "$BINDIR"
  ln -sf "$ENGINE_DST/df-mission" "$BINDIR/df-mission"
  say "ok    $BINDIR/df-mission"
  case ":$PATH:" in
    *":$BINDIR:"*) ;;
    # Installed-but-unreachable is not installed, and its failure mode -- "command not
    # found" at the moment you first need it -- points at the wrong thing.
    *) say "WARN  $BINDIR is not on your PATH. df-mission is installed and will not resolve."
       say "      add it to your shell profile, then open a new shell." ;;
  esac
else
  say "WARN  df-mission not present in the pinned engine"
fi

# ---- 5. verify ---------------------------------------------------------------
step "verify"
RC=0
if [ "$DRY" -eq 1 ]; then
  say "would  run boot-kit/scripts/lock-verify.sh"
elif [ -f "$ENGINE_DST/lock-verify.sh" ]; then
  ( cd "$ROOT" && bash "$ENGINE_DST/lock-verify.sh" --lock "$LOCK" ) || RC=2
else
  say "WARN  no lock-verify.sh in the pinned engine — this install is UNVERIFIED"
  RC=2
fi

# ---- 6. what no installer can do ---------------------------------------------
step "not restorable from a lockfile"
jq -r '(.notRestorable // {}) | to_entries[] | select(.key | startswith("$") | not) | "  - \(.key): \(.value)"' "$LOCK"
say ""
say "  Read AUTHENTICATION.md before pointing this at a hub."

[ "$DRY" -eq 1 ] && exit 0
exit "$RC"
