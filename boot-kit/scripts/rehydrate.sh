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
#   - anything in settings.json that is NOT a hook chain: `permissions` is a security
#     posture and `outputStyle` is the operator's UI. Section 4 reports a difference in
#     those and never applies it.
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

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(pwd)"
VENDOR="$ROOT/$(jq -r '.vendorDir // "vendor"' "$LOCK")"
LIVE="${LOOM_LIVE:-$HOME/.claude}"
# One stamp for the whole run, so everything a single rehydrate moves aside lands in ONE
# directory. Per-file stamps would scatter one event across several, and the operator
# recovering from it is looking for "what did that run take", not "what happened at 14:03:07".
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
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
  # TWO CASES, ONE `rm -rf`, AND THEY ARE NOT THE SAME RISK.
  #
  #   a symlink pointing somewhere else -> deleting it destroys NOTHING. The bytes live at
  #     the other end of the link and re-linking undoes it completely.
  #   a REAL directory -> deleting it destroys the only copy. If anyone had edited a skill
  #     in place, that work is gone with no backup and no trace.
  #
  # Both used to print the same OVERRIDE line, so the destructive case was indistinguishable
  # from the harmless one at a glance. Outside-installer feedback (24-27 Aug 2026, finding
  # 09) reported exactly this: "the right end state, invisibly reached", on two machines.
  # ⚠️ The SILENCE half of that report is already fixed — the OVERRIDE counter landed
  # 2026-08-31 in 2474db0, AFTER their install window, so they ran a rehydrate that said
  # nothing at all. What was still missing is that a printed line is not enough when the
  # operation is unrecoverable: content nobody can get back must be MOVED, not described.
  REPLACED=""
  if [ -e "$LIVE/skills/$s" ] || [ -L "$LIVE/skills/$s" ]; then
    if [ -L "$LIVE/skills/$s" ]; then
      if [ "$(readlink "$LIVE/skills/$s" 2>/dev/null)" != "$abs" ]; then
        say "  OVERRIDE $s repoints a symlink installed here before this instance (reversible — nothing deleted but a link)"
        OVERRIDE=$((OVERRIDE+1))
      fi
    else
      # Not a link. Whatever is here is the only copy of itself.
      REPLACED="$LIVE/.skills-replaced/$STAMP/$s"
      # KEEPS THE `OVERRIDE <name>` PREFIX. That token is the existing contract — the
      # instance-kit suites assert the override is reported BY NAME, and anything grepping
      # this output greps that word. The new information is appended, not substituted: a
      # correctness fix that silently renames a machine-readable token is a second breaking
      # change smuggled in beside the first.
      say "  OVERRIDE $s is a REAL directory, not a link — its contents exist nowhere else"
      say "           PRESERVED -> $REPLACED (deleted nothing)"
      say "           if you had local edits to this skill, they are in there"
      OVERRIDE=$((OVERRIDE+1))
    fi
  fi
  act "  link $s -> $src"
  if [ "$DRY" -eq 0 ]; then
    if [ -n "$REPLACED" ]; then
      # Kept OUTSIDE skills/ on purpose: a stray directory beside the real ones is a
      # directory the skill loader will try to read.
      mkdir -p "$(dirname "$REPLACED")"
      mv "$LIVE/skills/$s" "$REPLACED"
    else
      rm -rf "$LIVE/skills/$s"
    fi
    ln -s "$abs" "$LIVE/skills/$s"
  fi
done < <(jq -r '(.install.skills // [])[]' "$LOCK")

# ---- 2b. UN-DECLARING MUST UNINSTALL ----------------------------------------
# ⛔ Until 2026-09-04 it did not, and both machines proved it in one afternoon: a skill removed
# from Tier 1 AND from the lockfile left its symlink in $LIVE/skills, so every install afterwards
# reported DRIFT (L10: "resolves INTO this instance but is declared by nothing here"). The
# installer only ever ADDED — declaring installed, un-declaring did nothing.
#
# ⚠️ SYMLINKS ONLY, AND ONLY OURS. The section above already separates the two cases under one
# `rm -rf`: a symlink can go, losing nothing, because the bytes live at the other end; a REAL
# directory may be the only copy of somebody's edit. This prune refuses anything that is not a
# link, and refuses any link that does not point into THIS instance's tree — a machine carries
# other instances and a person's own hand-made links, and an installer that removed every
# undeclared link would delete other people's work and call it tidying.
#
# ⚠️ A DANGLING LINK IS THE COMMON CASE, so the test cannot be "does it resolve": the target was
# deleted with the retirement. Compare the LINK TEXT against this instance's root.
# ⚠️ $ROOT, not a path derived from $LOCK. rehydrate takes its instance from the CURRENT
# DIRECTORY and $LOCK is a RELATIVE filename, so `dirname "$LOCK"` is "." — right by coincidence
# and wrong the moment anyone passes a path. $ROOT is what every other step here already uses.
# ⚠️ TWO SPELLINGS OF ONE ROOT, and comparing only one made this prune a silent no-op.
# On macOS /var is a symlink to /private/var, so a link created from `mktemp`'s path carries
# /var/... while `pwd` reports /private/var/... . The same applies to any checkout under a
# symlinked home or mount. A path comparison that knows one spelling skips every link and reports
# success — the worst of the three outcomes, because it is indistinguishable from "nothing to do".
# The target may DANGLE (the retirement deleted it), so resolving the target is not available;
# resolving the ROOT both ways is.
# ⚠️ A PATH IS NOT A STRING. Measured on this machine, three spellings of one directory:
#     link text   /var/folders/…/T//run.XXX/inst/vendor/…   (TMPDIR's trailing slash, doubled)
#     pwd         /var/folders/…/T/run.XXX/inst             (collapsed)
#     pwd -P      /private/var/folders/…/T/run.XXX/inst     (/var is a symlink on macOS)
# A raw prefix test matched none of them, so the prune skipped every link and said nothing —
# indistinguishable from "there was nothing to prune". Repeated slashes are squeezed on both
# sides, and BOTH root spellings are kept because the target may DANGLE (the retirement deleted
# it), which rules out resolving the target itself.
squeeze_slashes() { printf '%s' "$1" | sed 's#//*#/#g'; }
INSTANCE_ROOT="$(squeeze_slashes "$ROOT")"
INSTANCE_ROOT_P="$(squeeze_slashes "$(cd "$ROOT" 2>/dev/null && pwd -P || printf '%s' "$ROOT")")"
PRUNED=0
if [ -d "$LIVE/skills" ]; then
  for link in "$LIVE"/skills/*; do
    [ -L "$link" ] || continue                       # never a real directory
    name="$(basename "$link")"
    target="$(readlink "$link" 2>/dev/null || true)"
    tnorm="$(squeeze_slashes "$target")"
    case "$tnorm" in
      "$INSTANCE_ROOT"/*|"$INSTANCE_ROOT_P"/*) ;;     # ours, in either spelling of the root
      *) continue ;;                                  # somebody else's link — not ours to touch
    esac
    if jq -e --arg s "$name" '((.install.skills // []) | index($s)) != null' "$LOCK" >/dev/null 2>&1; then
      continue                                        # still declared
    fi
    rm -f "$link"
    PRUNED=$((PRUNED + 1))
    if [ -e "$target" ]; then
      say "  UNLINKED $name (no longer declared; the content stays at $target)"
    else
      say "  UNLINKED $name (no longer declared, and its target is already gone)"
    fi
  done
fi
[ "$PRUNED" -eq 0 ] || say "  pruned $PRUNED undeclared skill link(s) belonging to this instance"

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

# ---- 4. wire the declared hooks into the live settings -------------------------
# ⛔ SECTION 3 COPIES HOOK FILES. NOTHING RUNS THEM until $LIVE/settings.json names each one
# in an event chain -- and until now no part of this estate's restore path did that. The
# instruction was prose in an installer's MANUAL section, so a machine restored by this
# script came back with every declared hook present, executable, hash-clean and INERT.
#
# ⚠️ THAT IS THE WORST OF THE FOUR STATES, because L1-L8 all pass on it. Measured on
# coder-eso-aws--loom-neptune-arm after a workspace reset wiped ~/.claude: 15 hooks
# declared, 8 wired. The restore leg is exactly where that gap gets created.
#
# The tool MERGES rather than copies: settings.json is the operator's file. It adds missing
# hook entries only, backs up first, never removes or reorders, never writes `permissions`
# or any other top-level key, and refuses on unparseable JSON. See wire-settings.py.
#
# ⚠️ THE TEMPLATE LIVES AT DIFFERENT PATHS ON DIFFERENT KITS and a single hardcoded path
# would skip silently on the others -- the defect this whole section removes, one level up.
# So the candidates are enumerated, and finding none is REPORTED, never assumed benign.
say ""
say "== 4. wire declared hooks into $LIVE/settings.json =="
WS="$SELFDIR/wire-settings.py"
TPL=""
for c in "$ROOT/boot-kit/config/settings.json.template" \
         "$ROOT/boot-kit/settings.template.json" \
         "$ROOT/boot-kit/config/settings.template.json" \
         "$ROOT/settings.json.template"; do
  [ -f "$c" ] && { TPL="$c"; break; }
done
if [ ! -f "$WS" ]; then
  say "  WARN  wire-settings.py not beside this script — hooks are INSTALLED but NOT WIRED"
elif [ -z "$TPL" ]; then
  say "  WARN  no settings template in this kit — nothing declares HOW to wire these hooks."
  say "        Every hook section 3 just installed is inert until a human wires it."
elif [ "$DRY" -eq 1 ]; then
  python3 "$WS" --template "$TPL" --live "$LIVE/settings.json" --home "$HOME" \
          --lock "$LOCK" --dry-run \
    || say "  WARN  wire-settings refused — see above"
else
  # ⚠️ --lock IS NOT OPTIONAL. The template is shared across instances; without
  # the lockfile this wires hooks THIS machine never installs, and the chain
  # then errors on every event. Measured on the Poland Coder, 2026-09-03.
  python3 "$WS" --template "$TPL" --live "$LIVE/settings.json" --home "$HOME" \
          --lock "$LOCK" \
    || say "  WARN  wire-settings refused — see above"
fi

say ""
say "== summary =="
# Printed on every run, including zero. "No overrides" and "nobody looked" are different
# facts, and a line that appears only when something is wrong cannot tell them apart.
say "  $OVERRIDE override(s) — a declaration here replacing something an earlier layer installed"
say ""
say "NEXT: bash <vendor>/dark-factory/boot-kit/scripts/lock-verify.sh"
say "Manual, not restorable from a lockfile: gh auth login · claude.ai MCP connectors · plugin marketplaces"
