#!/usr/bin/env bash
# rehydrate.sh — lockfile -> working machine. The restore leg of Tier 3.
#
# Reads loom.lock.json, fetches each upstream at its PINNED commit into vendor/, then
# installs the declared skills and hooks into ~/.claude.
#
# TWO CONSTRAINTS THIS EXISTS TO HANDLE
#
# 1. TWO GIT IDENTITIES. One account gets 404 — not 403 — on the other org's repos, so it
#    cannot even see them. This switches per upstream and always switches back, including
#    on failure. That is why naive `git submodule update --recursive` cannot be used.
#
# 2. THE BOOTSTRAP PROBLEM. On a workspace reset ~/.claude is wiped before credentials
#    exist, so vendor/ doubles as an OFFLINE cache: --offline installs from whatever is
#    already vendored and never touches the network.
#
# Usage:
#   bash rehydrate.sh                 fetch at pins, then install
#   bash rehydrate.sh --offline       install from existing vendor/ only
#   bash rehydrate.sh --dry-run       print the plan, change nothing
#
# NOT handled (documented rather than silently skipped):
#   - claude.ai-hosted MCP connectors (e.g. the ESO hub) are ACCOUNT-level, not in
#     ~/.claude.json. Sign in on the machine; no lockfile can restore them.
#   - `gh auth login` itself, plugin marketplaces, and any compiled binary.
set -uo pipefail

LOCK="loom.lock.json"
OFFLINE=0; DRY=0
for a in "$@"; do
  case "$a" in
    --offline) OFFLINE=1 ;;
    --dry-run) DRY=1 ;;
  esac
done
[ -f "$LOCK" ] || { echo "FATAL: no $LOCK here"; exit 1; }
command -v jq >/dev/null || { echo "FATAL: jq required"; exit 1; }

ROOT="$(pwd)"
VENDOR="$ROOT/$(jq -r '.vendorDir // "vendor"' "$LOCK")"
LIVE="${LOOM_LIVE:-$HOME/.claude}"
ORIG_ACCT=""
command -v gh >/dev/null 2>&1 && ORIG_ACCT="$(gh auth status 2>&1 | awk '/Active account: true/{found=1} /account /{if(!a)a=$NF} END{print a}')"

# Resolve a *Sources value to an absolute path on this machine.
#
#   local:<path>     relative to ROOT — the directory holding the lockfile, i.e. THIS
#                    instance repo. Without it an instance cannot own a skill or hook at
#                    all: it has to put its own file in some other repo and vendor it back.
#   upstream:<path>  relative to vendorDir. The explicit spelling of the bare form.
#   <path>           relative to vendorDir. The legacy bare form, and still the majority
#                    of every existing lockfile — it keeps working, unchanged, forever.
#
# ROOT is the lockfile's directory, NOT this script's. That distinction is the whole
# reason `local:` is safe here: a vendored copy of this script, run from an instance
# root, still resolves `local:` into the INSTANCE. A script that derived its root from
# its own file location would resolve it into the vendor cache — the wrong tree, and
# silently so.
resolve_src() {
  case "$1" in
    local:*)    printf '%s/%s' "$ROOT" "${1#local:}" ;;
    upstream:*) printf '%s/%s' "$VENDOR" "${1#upstream:}" ;;
    *)          printf '%s/%s' "$VENDOR" "$1" ;;
  esac
}

# A source that climbs out of the tree it names is rejected, never normalised. `local:`
# makes this reachable for the first time: before it, every source was confined to
# vendorDir by construction.
src_escapes() { case "$1" in *..*) return 0 ;; *) return 1 ;; esac; }

say() { printf '%s\n' "$1"; }
act() { if [ "$DRY" -eq 1 ]; then printf 'would  %s\n' "$1"; else printf '%s\n' "$1"; fi; }

# Always return to the original identity, even if we die mid-fetch. Leaving the wrong
# account active silently breaks every later push.
restore_acct() {
  if [ -n "$ORIG_ACCT" ] && command -v gh >/dev/null 2>&1; then
    gh auth switch --user "$ORIG_ACCT" >/dev/null 2>&1 || true
  fi
}
trap restore_acct EXIT

mkdir -p "$VENDOR"

say "=== rehydrate ==="
say "lock=$LOCK vendor=$VENDOR live=$LIVE offline=$OFFLINE dry=$DRY"
say ""

# ---- 1. upstreams ------------------------------------------------------------
while read -r name; do
  [ -n "$name" ] || continue
  repo="$(jq -r --arg n "$name" '.upstreams[$n].repo' "$LOCK")"
  commit="$(jq -r --arg n "$name" '.upstreams[$n].commit' "$LOCK")"
  acct="$(jq -r --arg n "$name" '.upstreams[$n].account' "$LOCK")"
  dest="$VENDOR/$name"

  if [ "$OFFLINE" -eq 1 ]; then
    if [ -d "$dest" ]; then say "offline  $name (using cached vendor/)"
    else say "MISSING  $name — not cached, and --offline forbids fetching"; fi
    continue
  fi

  if command -v gh >/dev/null 2>&1 && [ -n "$acct" ] && [ "$acct" != "null" ]; then
    act "identity -> $acct"
    [ "$DRY" -eq 0 ] && gh auth switch --user "$acct" >/dev/null 2>&1
  fi

  if [ -d "$dest/.git" ]; then
    act "fetch    $name ($repo)"
    if [ "$DRY" -eq 0 ]; then
      git -C "$dest" fetch --quiet origin 2>/dev/null || say "  WARN fetch failed for $name"
    fi
  else
    act "clone    $name ($repo)"
    if [ "$DRY" -eq 0 ]; then
      gh repo clone "$repo" "$dest" -- --quiet 2>/dev/null || say "  WARN clone failed for $name"
    fi
  fi

  if [ "$DRY" -eq 0 ] && [ -d "$dest/.git" ]; then
    if git -C "$dest" checkout --quiet "$commit" 2>/dev/null; then
      say "  pinned $name -> ${commit:0:8}"
    else
      say "  WARN  $name could not check out ${commit:0:8}"
    fi
  fi
done < <(jq -r '.upstreams | keys[]' "$LOCK")

restore_acct
say ""

# ---- 2. install skills -------------------------------------------------------
# Symlink, never copy. A copy is a parallel store, and parallel stores drift — which is
# the whole reason this tier exists.
say "== skills =="
mkdir -p "$LIVE/skills"

# OVERRIDES. This instance's declarations install LAST, on top of whatever an earlier
# layer -- an org layer delegated to by install.sh, or simply a previous install from a
# different source -- already put here. Instance wins, by design: the more specific layer
# is the one that should. The point of counting them is that it is said out loud. A
# SILENT override is how tiers rot: the org fixes a skill, installs the fix successfully,
# and this machine keeps the old copy forever with nothing anywhere reporting a
# difference. Reported in --dry-run too, where it is a prediction and writes nothing.
OVERRIDE=0

while read -r s; do
  [ -n "$s" ] || continue
  src="$(jq -r --arg s "$s" '.install.skillSources[$s] // empty' "$LOCK")"
  [ -n "$src" ] || { say "  WARN $s has no skillSources entry"; continue; }
  if src_escapes "$src"; then say "  REFUSED $s ($src climbs out of its tree)"; continue; fi
  abs="$(resolve_src "$src")"
  if [ ! -d "$abs" ]; then say "  MISS $s ($src not present)"; continue; fi
  # Compared by TARGET, not by existence. A skill this same lockfile installed on the
  # previous run is already a link to exactly this path, and reporting that as an
  # override would fire on every re-install -- a warning that is wrong every second time
  # is one people learn to skip, which costs more than it ever reports.
  if [ -e "$LIVE/skills/$s" ] && [ "$(readlink "$LIVE/skills/$s" 2>/dev/null)" != "$abs" ]; then
    say "  OVERRIDE $s replaces a copy installed here before this instance"
    OVERRIDE=$((OVERRIDE+1))
  fi
  act "  link $s -> $src"
  if [ "$DRY" -eq 0 ]; then
    rm -rf "$LIVE/skills/$s"
    ln -s "$abs" "$LIVE/skills/$s"
  fi
done < <(jq -r '(.install.skills // [])[]' "$LOCK")

# ---- 3. install hooks --------------------------------------------------------
# Hooks are COPIED, not symlinked: they must survive a wipe of the disk the links
# would live on, and __HOME__ has to be rehydrated per machine.
say ""
say "== hooks =="
mkdir -p "$LIVE/hooks"
while read -r h; do
  [ -n "$h" ] || continue
  src="$(jq -r --arg h "$h" '.install.hookSources[$h] // empty' "$LOCK")"
  [ -n "$src" ] || { say "  WARN $h has no hookSources entry"; continue; }
  if src_escapes "$src"; then say "  REFUSED $h ($src climbs out of its tree)"; continue; fi
  abs="$(resolve_src "$src")"
  if [ ! -f "$abs" ]; then say "  MISS $h ($src not present)"; continue; fi
  # A hook is COPIED, so its mere presence proves nothing: this instance's own previous
  # run left a file at exactly this path. Existence alone would therefore report an
  # override on every re-install -- which is the shape of the check to avoid, because a
  # warning that is wrong every second time trains the reader past the one that is right.
  # Content is what distinguishes "we wrote this" from "another layer wrote this", and
  # two layers installing byte-identical text override nothing in effect.
  rendered="$(sed "s|__HOME__|$HOME|g" "$abs")"
  if [ -f "$LIVE/hooks/$h" ] && [ "$rendered" != "$(cat "$LIVE/hooks/$h")" ]; then
    say "  OVERRIDE $h replaces a different copy installed here before this instance"
    OVERRIDE=$((OVERRIDE+1))
  fi
  act "  copy $h <- $src"
  if [ "$DRY" -eq 0 ]; then
    printf '%s\n' "$rendered" > "$LIVE/hooks/$h"
    chmod +x "$LIVE/hooks/$h"
  fi
done < <(jq -r '(.install.hooks // [])[]' "$LOCK")

say ""
say "== summary =="
# Printed on every run, including zero. "No overrides" and "nobody looked" are different
# facts, and a line that appears only when something is wrong cannot tell them apart.
say "  $OVERRIDE override(s) — a declaration here replacing something an earlier layer installed"
say ""
say "NEXT: bash <vendor>/dark-factory/boot-kit/scripts/lock-verify.sh"
say "Manual, not restorable from a lockfile: gh auth login · claude.ai MCP connectors · plugin marketplaces"
