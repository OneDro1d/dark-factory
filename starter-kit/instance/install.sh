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
#   2a org layer           OPTIONAL, and skipped entirely unless the lockfile declares an
#                           `org.upstream`. Fetch that layer at its pin and run ITS
#                           installer. Before step 3 on purpose: layer order is
#                           precedence, so the org installs first and this instance's own
#                           declarations land on top of it
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
#
# Walk the JSON, do not grep the file. The lockfile's own prose EXPLAINS the placeholder
# convention and mentions __HOME__ by name, so a text scan reports the documentation as
# unfilled data -- a warning that is wrong on every correct lockfile, which is the fastest
# way to teach someone to skip reading warnings. Only leaf VALUES count, and keys starting
# with `$` are notes for the human, not fields.
UNFILLED="$(jq -r '
  [ paths(type == "string") as $p
    | select( [ $p[] | tostring | startswith("$") ] | any | not )
    | getpath($p)
    | select(test("^__[A-Z_]+__$")) ]
  | unique | join(" ")' "$LOCK" 2>/dev/null)"
[ -n "$UNFILLED" ] && say "WARN  unresolved placeholders still in the lockfile: $UNFILLED"

# ---- 0b. the lockfile SHAPE guard --------------------------------------------
# ⛔ PORTED IN 2026-09-07, AND ITS ABSENCE HERE WAS A REAL GAP — found only by merging the
# two Tier-3 generators. The org-layer's copy of this installer carried this guard; THIS
# file, the one the operator has now made canonical, did not. So the claim that Tier 1's
# generator was "a strict superset" was WRONG on exactly one thing, and it was a safety
# check. `test-lock-verify-l7-shape.sh` caught it the moment its fixture was repointed here:
# the installer ACCEPTED an `install.hooks` that lock-verify L7 REFUSES.
#
# ⚠️ THAT DIRECTION IS THE DANGEROUS ONE. That suite's own header states the contract: "a
# lockfile install.sh would refuse outright must not verify as LOCKED — a verifier more
# permissive than the installer is how 'in sync' comes to mean two different things in one
# estate." Here it ran the other way: the INSTALLER was more permissive than the verifier, so
# an old-shape lockfile installed cleanly and then verified as DRIFT forever, with the
# installer's silence implying the machine was fine.
#
# The old shape is a MAP where the split-out array + *Sources map now belongs. A map cannot
# express a name with no source or a source with no name — the two states that install
# nothing while still reading like a declaration — which is why the shape changed at all.
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
lock_shape_guard

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
  # Guarded: a --dry-run that creates the vendor directory has already changed the
  # machine, and "print the plan, change nothing" is the one promise the flag makes.
  [ "$DRY" -eq 0 ] && mkdir -p "$VENDOR"
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

# ⛔ REFUSE TO REPLACE THE ENGINE UNDER A LIVE SUPERVISOR.
# The block below does `rm -rf "$ENGINE_DST"`, and df-supervisor.sh runs FROM that directory.
# Bash reads a script lazily by byte offset, so replacing it mid-run does not crash the loop
# where you can see it — the loop later reads bytes from a different file at the old offset.
#
# ⚠️ This guard used to be a SENTENCE IN ANOTHER REPO telling a human to run
# `pgrep -f df-supervisor` first. Measured 2026-09-03: that command matches the command line of
# the shell RUNNING it, so it always reported LIVE, and a guard that always fires is skipped
# within two uses. Nothing executable implemented it anywhere.
#
# ⚠️ MATCHED BY PATH, NOT BY NAME. A supervisor running from a DIFFERENT kit root on this machine
# is none of this install's business, and blocking on it is a false positive that strands a safe
# install. The `[d]` bracket is what stops the check from finding itself.
# ⚠️ `ps`, NOT `pgrep`. Measured on Darwin against Linux: BSD pgrep rejects -a outright, and
# `pgrep -af` prints the PID with NO command line and exits 0 — so a path filter over its output
# is always empty and the guard can never fire. `pgrep -fl` prints full args on macOS and only
# the process NAME on Linux. `ps -eo pid=,args=` prints the full argument list on both.
# The first version of this guard used `pgrep -af` and was inert on macOS: a guard that never
# fires looks exactly like a machine that is safe, which is the worse of the two failures.
if [ "$DRY" -eq 0 ] && [ "${FORCE_ENGINE:-0}" -eq 0 ]; then
  LIVE_SUP="$(ps -eo pid=,args= 2>/dev/null | grep "[d]f-supervisor" | grep -F "$ENGINE_DST" || true)"
  if [ -n "$LIVE_SUP" ]; then
    say ""
    say "  REFUSING to replace the engine: a supervisor is running FROM this directory."
    say "    $ENGINE_DST"
    printf '      %s\n' "$LIVE_SUP"
    say ""
    say "  Replacing these files under a running loop corrupts it silently — bash reads a script"
    say "  lazily by byte offset, so the loop keeps going and later reads the wrong bytes."
    say ""
    say "  Stop the mission first:   df-mission stop <id>"
    say "  Or, if you know the loop is dead and the process is a leftover:"
    say "                            FORCE_ENGINE=1 bash install.sh ..."
    die "live supervisor in $ENGINE_DST"
  fi
fi

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

# ---- 2a. the org layer, if this instance declares one -------------------------
# OPTIONAL, and absent by default. With no `org.upstream` in the lockfile nothing in this
# section runs, which is the property that makes it safe to land in the generator without
# re-minting the machines the generator already produced: their lockfiles have no `org`
# block, so their install is the one they had.
#
# WHY DELEGATE RATHER THAN LIST. The org layer owns the org's skill and hook list.
# Re-listing it in this lockfile would be the second copy the tier split exists to
# prevent, and the copies drift in the direction nobody watches -- the machine's, where a
# stale entry reads as a machine that was never set up rather than as a list that fell
# behind. Vendoring the layer is not the same thing: a vendored layer is content this
# instance then has to decide what to do with. Delegating is letting the layer decide.
#
# WHY IT RUNS BEFORE STEP 3. Layer order IS precedence. The org installs first and this
# instance's declarations land on top, so a name declared in both resolves to the
# instance's copy -- the more specific layer wins, which is the rule everywhere else in
# this method. rehydrate.sh reports each one as it happens: a silent override is how tiers
# rot, because the org can then fix a skill, install the fix successfully, and leave this
# machine on the old copy with nothing anywhere reporting a difference.
step "org layer"
# Both spellings, because this kit's engine reads LOOM_LIVE and the org-layer templates
# read CLAUDE_HOME. Resolving only one here would hand the delegated installer a default
# of the real ~/.claude while a caller believed it had redirected the install -- a
# divergence that is invisible until something writes to the wrong home.
LIVE="${LOOM_LIVE:-${CLAUDE_HOME:-$HOME/.claude}}"
ORG_NAME="$(jq -r '.org.upstream // empty' "$LOCK")"
ORG_INSTALLER="$(jq -r '.org.installer // "install.sh"' "$LOCK")"
if [ -z "$ORG_NAME" ]; then
  say "none  no org layer declared — installing Tier 1 directly"
else
  # A name, not coordinates: the repo, the pin and the account are declared once, in
  # `upstreams`, and lock-verify already checks that map in both directions. A block that
  # named a repo of its own would be an upstream no verifier knows about.
  jq -e --arg n "$ORG_NAME" '.upstreams[$n]' "$LOCK" >/dev/null 2>&1 \
    || die "org.upstream names '$ORG_NAME', which is not a key of .upstreams — the layer has no coordinates here, so nothing can fetch it and nothing verifies it"
  case "$ORG_INSTALLER" in
    /*|*..*) die "org.installer '$ORG_INSTALLER' climbs out of the layer it names — refused, not normalised" ;;
  esac

  ORG_DIR="$VENDOR/$ORG_NAME"
  ORG_REPO="$(jq -r --arg n "$ORG_NAME" '.upstreams[$n].repo // empty' "$LOCK")"
  ORG_URL="$(jq -r --arg n "$ORG_NAME" '.upstreams[$n].url // empty' "$LOCK")"
  ORG_COMMIT="$(jq -r --arg n "$ORG_NAME" '.upstreams[$n].commit // empty' "$LOCK")"
  ORG_ACCT="$(jq -r --arg n "$ORG_NAME" '.upstreams[$n].account // empty' "$LOCK")"
  say "layer $ORG_NAME ($ORG_REPO)"

  if [ "$OFFLINE" -eq 1 ]; then
    [ -d "$ORG_DIR" ] || die "--offline, and $ORG_DIR is not cached — the declared org layer cannot be installed from nothing"
    say "offline  using the cached layer as-is"
  elif [ "$DRY" -eq 0 ]; then
    mkdir -p "$VENDOR"
    # An org layer is usually PRIVATE, so gh comes first and plain git is the fallback --
    # the reverse of step 1, where the public method must install with git alone.
    #
    # The identity switch is deliberately narrow. `gh` identity is ONE GLOBAL SCALAR with
    # no per-process form, so this switches, fetches, and switches straight back; a
    # process-local GH_TOKEN is the safer mechanism where you have one, and with it set
    # `gh auth switch` warns, changes nothing and exits 0 -- it fails open, so a machine
    # using GH_TOKEN is unaffected by these two lines either way.
    PRIOR_ACCT=""
    if command -v gh >/dev/null 2>&1 && [ -n "$ORG_ACCT" ]; then
      PRIOR_ACCT="$(gh auth status 2>&1 | awk '/account /{if(!a)a=$NF} END{print a}')"
      gh auth switch --user "$ORG_ACCT" >/dev/null 2>&1 || say "  WARN  could not switch to $ORG_ACCT — a private layer may 404, which reads as 'no such repo'"
    fi
    if [ -d "$ORG_DIR/.git" ]; then
      say "fetch    $ORG_NAME"
      git -C "$ORG_DIR" fetch --quiet origin || say "  WARN fetch failed — falling back to what is already here"
    else
      say "clone    $ORG_NAME <- $ORG_REPO"
      if command -v gh >/dev/null 2>&1; then
        gh repo clone "$ORG_REPO" "$ORG_DIR" -- --quiet 2>/dev/null \
          || git clone --quiet "${ORG_URL:-https://github.com/$ORG_REPO.git}" "$ORG_DIR" 2>/dev/null \
          || say "  WARN clone failed for $ORG_REPO — if the layer is private, check gh auth status"
      else
        git clone --quiet "${ORG_URL:-https://github.com/$ORG_REPO.git}" "$ORG_DIR" 2>/dev/null \
          || say "  WARN clone failed for $ORG_REPO — gh is not installed, so a private layer cannot be cloned here"
      fi
    fi
    [ -n "$PRIOR_ACCT" ] && gh auth switch --user "$PRIOR_ACCT" >/dev/null 2>&1
    # The pin is re-asserted by rehydrate.sh in step 3 for every upstream. It is asserted
    # HERE too because this step hands the layer CONTROL: an unpinned checkout would run
    # whatever its default branch says today, and that is the one upstream whose code
    # executes on this machine before anything has verified it.
    if [ -d "$ORG_DIR/.git" ]; then
      case "$ORG_COMMIT" in
        ""|__*__) say "  WARN  no resolved pin for $ORG_NAME — its installer will run from whatever its default branch holds today" ;;
        *) git -C "$ORG_DIR" checkout --quiet "$ORG_COMMIT" 2>/dev/null \
             && say "  pinned ${ORG_COMMIT:0:8}" \
             || die "commit ${ORG_COMMIT:0:8} is not in $ORG_REPO — the pin is wrong, or it was never pushed" ;;
      esac
    fi
  fi

  ORG_ENTRY="$ORG_DIR/$ORG_INSTALLER"
  if [ "$DRY" -eq 1 ]; then
    say "would  run $VENDOR_REL/$ORG_NAME/$ORG_INSTALLER"
  else
    # Not a warning. A lockfile that declares an org layer and cannot run it describes a
    # machine this install is not producing, and everything after this point would be a
    # true report about a false whole.
    [ -f "$ORG_ENTRY" ] || die "the layer declares no $ORG_INSTALLER at $VENDOR_REL/$ORG_NAME — nothing here can install the org's skills, and this instance's own declarations would install on top of nothing"
    OFLAGS=""
    [ "$OFFLINE" -eq 1 ] && OFLAGS="--offline"
    say "run      $VENDOR_REL/$ORG_NAME/$ORG_INSTALLER"
    ( cd "$ORG_DIR" && CLAUDE_HOME="$LIVE" LOOM_LIVE="$LIVE" bash "$ORG_INSTALLER" $OFLAGS ) \
      || say "WARN  the org layer's installer reported a problem — read its output above, it names each one"
  fi
fi

# ---- 3. rehydrate the rest ---------------------------------------------------
step "upstreams, skills, hooks"
REHYDRATE="$ENGINE_DST/rehydrate.sh"
if [ "$DRY" -eq 1 ]; then
  say "would  delegate to boot-kit/scripts/rehydrate.sh"
elif [ -f "$REHYDRATE" ]; then
  RFLAGS=""
  [ "$OFFLINE" -eq 1 ] && RFLAGS="--offline"
  # LOOM_LIVE is passed explicitly, not left to rehydrate's own default. Step 2a resolved
  # ONE live directory from either spelling and handed it to the org layer; if this step
  # then fell back to its own default, the two layers of a single install would write to
  # two different homes and each would report success.
  ( cd "$ROOT" && LOOM_LIVE="$LIVE" bash "$REHYDRATE" $RFLAGS ) || say "WARN  rehydrate reported a problem — read its output above, it names each one"
else
  say "WARN  no rehydrate.sh in the pinned engine — skills and hooks were NOT installed"
fi

# ---- 3b. plugins -> $LIVE/skills (personal skills-directory plugins) --------
# ADDED for M-KITV2 B15. `agent`/hooks/bin/monitors materialised into
# ~/.claude/skills/<name>/ with a .claude-plugin/plugin.json load AUTOMATICALLY, in
# every interactive session, as <name>@skills-dir -- no marketplace, no /plugin
# install, no `enabledPlugins` entry. That last part is measured, not assumed:
# kitv2/b4 ran the marketplace + project `enabledPlugins` path against real headless
# launches and it delivered NOTHING to `-p` or `-p --setting-sources project` -- no
# hooks, no bin, no monitors, no agent, and no error on stdout, stderr or --debug. A
# headless worker cannot tell it is ungoverned on that path. This step exists because
# the ONLY path measured to work at all is a materialised copy under $LIVE/skills/.
# Headless workers do not use this step -- they get the same plugin content through
# --plugin-dir, launched by df-worker (also kitv2/b4: GREEN on both headless modes).
#
# ONE PIN. The plugin is materialised from THIS lockfile's own dark-factory pin, never
# from a marketplace sha declared beside it -- moving the plugin forward is moving the
# T1 pin, and there is no second version number that can drift out of step with it.
#
# ONLY `upstream:<path>` IS ACCEPTED. `local:` or a bare path would materialise an
# unpinned, unaudited tree under the exact banner the paragraph above just asserted
# ("one pin") -- refused, not accommodated.
#
# DEST MUST RESOLVE UNDER $LIVE/skills/. That is the one directory the personal
# skills-directory loader scans (docs: "a .claude-plugin/plugin.json under
# ~/.claude/skills/<name>/ loads in every project"); the lockfile spells it
# "~/.claude/skills/<name>" literally, and this step is the only place that expands
# the `~` -- against $LIVE, which is overridable (LOOM_LIVE) for exactly the reason
# BINDIR is below: a test that has to write into the real ~/.claude is a test nobody
# runs twice. Anything not spelled under that literal prefix is refused rather than
# written somewhere a human did not choose.
#
# A REFUSED PLUGIN DOES NOT ABORT THE INSTALL — the other steps still run, and this
# is a plugin-by-plugin loop, not an all-or-nothing gate — but it DOES cost the exit
# code: RC follows the same "installed but NOT locked" contract lock-verify uses
# below, so a refusal is never silently swallowed into a green run.
step "plugins"
RC=0
PLUG_N="$(jq -r '(.install.plugins // []) | length' "$LOCK")"
if [ "$PLUG_N" -eq 0 ]; then
  say "plugins: none declared"
else
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    PNAME="$(jq -r '.name // empty' <<<"$p")"
    PSRC="$(jq -r '.source // empty' <<<"$p")"
    PDEST="$(jq -r '.dest // empty' <<<"$p")"
    [ -n "$PNAME" ] || PNAME="<unnamed>"
    case "$PSRC" in
      upstream:*) SRC_REL="${PSRC#upstream:}" ;;
      *) say "  REFUSED plugin $PNAME: source '$PSRC' is not upstream:<path>"
         RC=2; continue ;;
    esac
    case "$PDEST" in
      "~/.claude/skills/"*) PDEST_ABS="$LIVE/skills/${PDEST#\~/.claude/skills/}" ;;
      *) say "  REFUSED plugin $PNAME: dest '$PDEST' is outside ~/.claude/skills/"
         RC=2; continue ;;
    esac
    PSRC_ABS="$T1/$SRC_REL"
    if [ "$DRY" -eq 1 ]; then
      say "  would materialise plugin $PNAME <- $SRC_REL -> $PDEST_ABS"
      continue
    fi
    if [ ! -f "$PSRC_ABS/.claude-plugin/plugin.json" ]; then
      say "  REFUSED plugin $PNAME: no .claude-plugin/plugin.json at $SRC_REL"
      RC=2; continue
    fi
    mkdir -p "$(dirname "$PDEST_ABS")"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "$PSRC_ABS/" "$PDEST_ABS/" \
        || { say "  REFUSED plugin $PNAME: rsync failed"; RC=2; continue; }
    else
      rm -rf "$PDEST_ABS"
      mkdir -p "$PDEST_ABS"
      cp -R "$PSRC_ABS/." "$PDEST_ABS/" \
        || { say "  REFUSED plugin $PNAME: copy failed"; RC=2; continue; }
    fi
    say "  plugin $PNAME: materialised from ${T1_COMMIT:0:8} -> $PDEST_ABS"
  done < <(jq -c '(.install.plugins // [])[]' "$LOCK")
fi

# ---- 3c. marketplace plugins -> `claude plugin install` ----------------------
# ADDED 2026-09-08. THIRD-PARTY plugins from a Claude Code MARKETPLACE — playwright and its
# kind. Operator ask: "is there a way of automatically install 3rd party plugins?"
#
# ⛔ THIS IS A DIFFERENT MECHANISM FROM 3b ABOVE AND THE TWO MUST NOT BE READ AS SIBLINGS.
# 3b materialises a COPY of a plugin that lives INSIDE the Tier-1 pin, so it moves only when
# the pin moves and lock-verify L11 can diff it byte-for-byte against its source. This step
# shells out to a CLI that fetches code this estate does not host, cannot diff, and — the
# part that decides the whole design — cannot pin.
#
# ⛔ THERE IS NO VERSION ARGUMENT. MEASURED 2026-09-08 against the real CLI, not assumed:
# `claude plugin install <plugin>` accepts `--config`, `--scope` and `-y`, and NOTHING that
# selects a version. It installs LATEST, on every machine, every time. A pin that cannot be
# expressed is not a pin, and a lockfile that implies one it cannot enforce is worse than a
# lockfile that admits the gap.
#
# OPERATOR DECISION 2026-09-08, option A of two: automate it anyway, and RECORD THE RESOLVED
# VERSION into `probed.marketplacePlugins`, so that what LATEST meant on the day this machine
# installed is written down and lock-verify L14 can see it move afterwards. Option B — leave
# these a human step — was rejected because a human typing the same command gets the same
# unpinned latest, just slower and with nothing recorded.
#
# ⚠️ THIS STEP CAUSES ~/.claude/settings.json TO BE EDITED, AND IT IS THE ONE STEP THAT DOES.
# MEASURED in an isolated CLAUDE_CONFIG_DIR: `plugin marketplace add` writes
# `extraKnownMarketplaces` and `plugin install` writes `enabledPlugins`, both into the
# user-scope settings.json. `notRestorable` says this installer "places hook files, it does
# not edit your settings" — that stays true of THIS SCRIPT, which still writes nothing there;
# the edit is made by Claude Code's own CLI through its own merge path. Say it out loud
# anyway, because the operator who read that line will otherwise meet the change by surprise.
#
# ⚠️ THE MARKETPLACE MUST BE ADDED FIRST, INCLUDING THE OFFICIAL ONE. MEASURED on a fresh
# config dir: `plugin marketplace list --json` returns `[]` and an install of
# `playwright@claude-plugins-official` fails with "not found in marketplace" until
# `plugin marketplace add anthropics/claude-plugins-official` has run. A new machine is
# exactly that fresh config dir, so `marketplaceSource` is how an entry becomes installable
# there rather than only on the laptop it was authored on.
#
# BOTH CLI CALLS ARE IDEMPOTENT AND EXIT 0 ON A SECOND RUN — measured: "already installed"
# and "already on disk". So this step is re-runnable like every other one here.
#
# A REFUSED ENTRY DOES NOT ABORT THE INSTALL, on the same contract as 3b: the loop continues
# and RC carries the refusal into the exit code, so it is never swallowed into a green run.
step "marketplace plugins"
MP_N="$(jq -r '(.install.marketplacePlugins // []) | length' "$LOCK")"
if [ "$MP_N" -eq 0 ]; then
  # ⛔ SAY HOW, NOT JUST "NONE". Operator request 2026-09-08. "none declared" is a true
  # sentence that teaches nobody anything: a reader has no way to know this kit CAN install
  # their /plugin choices, so third-party plugins stay a per-machine ritual that quietly
  # differs on every box — the exact drift a lockfile exists to remove. The recipe prints on
  # every install with none declared, because "why doesn't my new machine have playwright" is
  # a question people ask while looking at this output.
  say "marketplace plugins: none declared"
  say ""
  say "  This kit CAN install them for you — playwright, context7, whatever you reach for."
  say "  Add an entry to install.marketplacePlugins in $LOCK, then re-run this installer:"
  say ""
  say '      { "name": "playwright",'
  say '        "marketplace": "claude-plugins-official",'
  say '        "marketplaceSource": "anthropics/claude-plugins-official" }'
  say ""
  say "  Both names come straight off the machine you already set up by hand:"
  say "      claude plugin list --json               \"id\" is <name>@<marketplace>"
  say "      claude plugin marketplace list --json   the source to add it from"
  say "  marketplaceSource is not optional in practice: a machine that has never been told"
  say "  about a marketplace knows NONE of them — the official one included — and the install"
  say "  fails with \"not found in marketplace\" without it."
  say ""
  say "  ⚠️ THIS PINS WHICH PLUGINS EVERY MACHINE GETS, NEVER WHICH VERSION."
  say "     'claude plugin install' takes no version argument, so every machine installs"
  say "     LATEST. That is the honest limit of the mechanism and nothing here can work"
  say "     around it. What this kit does instead: it records the version each machine"
  say "     actually resolved into probed.marketplacePlugins, and lock-verify L14 tells you"
  say "     when that version has moved underneath you. Visible drift, not prevented drift."
  say ""
else
  # Overridable for the same reason LOOM_LIVE and LOOM_BIN are: a suite that has to shell out
  # to the real `claude` — and mutate the real ~/.claude/settings.json to prove a point — is a
  # suite nobody runs twice. lock-verify spells the same idea LOCK_VERIFY_CLAUDE_BIN.
  MP_CLAUDE="${DF_CLAUDE_BIN:-claude}"
  if ! command -v "$MP_CLAUDE" >/dev/null 2>&1; then
    say "  REFUSED every marketplace plugin: '$MP_CLAUDE' is not on PATH"
    say "        nothing else can install these — there is no fetch path that is not the CLI"
    RC=2
  else
    MP_PROBED='{}'
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      MNAME="$(jq -r '.name // empty' <<<"$m")"
      MMKT="$(jq -r '.marketplace // empty' <<<"$m")"
      MSRC="$(jq -r '.marketplaceSource // empty' <<<"$m")"
      MSCOPE="$(jq -r '.scope // "user"' <<<"$m")"
      if [ -z "$MNAME" ] || [ -z "$MMKT" ]; then
        say "  REFUSED marketplace plugin '${MNAME:-<unnamed>}': needs both name and marketplace"
        RC=2; continue
      fi
      # ONLY `user` IS ACCEPTED. `project` and `local` write into a PROJECT's settings, so a
      # machine installer would be reaching into one checkout and calling that the machine's
      # state — and lock-verify, which asks the CLI about this machine, would never see it.
      if [ "$MSCOPE" != "user" ]; then
        say "  REFUSED marketplace plugin $MNAME: scope '$MSCOPE' — only 'user' is accepted here"
        RC=2; continue
      fi
      MID="$MNAME@$MMKT"
      if [ "$DRY" -eq 1 ]; then
        [ -n "$MSRC" ] && say "  would add marketplace $MMKT <- $MSRC"
        say "  would install $MID (scope user, whatever LATEST is at that moment — no pin exists)"
        continue
      fi
      if [ -n "$MSRC" ]; then
        if ! MPOUT="$("$MP_CLAUDE" plugin marketplace add "$MSRC" 2>&1)"; then
          say "  REFUSED $MID: could not add marketplace '$MMKT' from '$MSRC'"
          printf '%s\n' "$MPOUT" | tail -3 | while IFS= read -r l; do say "        $l"; done
          RC=2; continue
        fi
      fi
      if ! MIOUT="$("$MP_CLAUDE" plugin install "$MID" -y --scope user 2>&1)"; then
        say "  REFUSED $MID: install failed"
        printf '%s\n' "$MIOUT" | tail -3 | while IFS= read -r l; do say "        $l"; done
        RC=2; continue
      fi
      # ASK THE CLI WHAT IT ACTUALLY DID, rather than believing the success line. `plugin list
      # --json` is the same surface lock-verify L14 reads, so the record written here and the
      # check made later cannot disagree about where the truth lives.
      MP_LIVE="$("$MP_CLAUDE" plugin list --json 2>/dev/null \
        | jq -c --arg id "$MID" 'map(select(.id == $id)) | .[0] // empty' 2>/dev/null)"
      if [ -z "$MP_LIVE" ]; then
        say "  WARN  $MID: install reported success but the plugin is absent from"
        say "        '$MP_CLAUDE plugin list --json' — nothing recorded, so nothing verifiable"
        RC=2; continue
      fi
      MVER="$(jq -r '.version // "unknown"' <<<"$MP_LIVE")"
      MPATH="$(jq -r '.installPath // ""' <<<"$MP_LIVE")"
      # INSTALLED IS NOT ENABLED. Measured on this laptop: `plugin list --json` shows entries
      # with "enabled": false — installed, on disk, loading nothing. A fresh install comes up
      # enabled, so this is a repair for a machine where someone disabled it, not the norm.
      if [ "$(jq -r '.enabled // false' <<<"$MP_LIVE")" != "true" ]; then
        "$MP_CLAUDE" plugin enable "$MID" >/dev/null 2>&1 \
          || say "  WARN  $MID: installed but DISABLED, and 'plugin enable' failed — it loads nothing"
      fi
      MP_PROBED="$(jq -c --arg id "$MID" --arg v "$MVER" --arg p "$MPATH" \
        '.[$id] = {version: $v, installPath: $p}' <<<"$MP_PROBED")"
      say "  $MID: installed, version $MVER"
      say "        ^ this is LATEST as of now, NOT a pin — recorded so L14 can see it move"
    done < <(jq -c '(.install.marketplacePlugins // [])[]' "$LOCK")

    # WRITE THE RESOLVED VERSIONS BACK INTO THE LOCKFILE. This is the first thing install.sh
    # writes to its own lockfile, and it is deliberate: `probed` is the section whose own
    # $comment says "WRITTEN BY TOOLS, not by you", and a resolved version is a MEASUREMENT,
    # not a declaration. It belongs beside the other measured machine facts, in the one file
    # that is this machine's record — not in a receipt file beside it, which would be the
    # second copy of a fact this whole tier exists to prevent.
    #
    # A failure to write is a WARN, never fatal: the plugins ARE installed by this point, and
    # aborting would leave a machine changed and unreported. But the warning must say what is
    # lost — without the record, L14 can see that a plugin is present and can say nothing at
    # all about whether its version moved.
    if [ "$DRY" -eq 0 ] && [ "$MP_PROBED" != "{}" ]; then
      MP_TMP="$LOCK.mp.$$"
      if jq --argjson mp "$MP_PROBED" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '.probed = ((.probed // {})
                        | .marketplacePlugins = $mp
                        | .marketplacePluginsResolvedAt = $at)' \
            "$LOCK" > "$MP_TMP" 2>/dev/null && mv "$MP_TMP" "$LOCK"; then
        say "  recorded resolved versions -> probed.marketplacePlugins in $LOCK"
        say "  ⚠️ COMMIT THAT FILE. It is the only written record of what LATEST meant today;"
        say "     uncommitted, the next machine has no baseline and L14 has nothing to compare."
      else
        rm -f "$MP_TMP"
        say "  WARN  could not write probed.marketplacePlugins into $LOCK"
        say "        the versions above are UNRECORDED — L14 will report them unknown, not ok"
      fi
    fi
  fi
fi

# ---- 4. PATH -----------------------------------------------------------------
step "df-mission and df-preflight on PATH"
# Overridable for the same reason rehydrate.sh takes LOOM_LIVE: a test that has to write
# into the real ~/.local/bin is a test nobody runs twice.
#
# df-preflight is linked beside df-mission because of where it is RUN FROM. The preflight
# scopes a mission to the notepad above the cwd (its repos.manifest.json) and reads the
# machine from the kit its own file lives in. Documented as `<notepad>/boot-kit/scripts/
# df-preflight.py`, an agent in a notepad that is not the kit looks there, finds nothing,
# and reports "no df-preflight in this notepad" -- measured 2026-09-05 on a Coder
# workspace. On PATH it is one command from any notepad, and the script resolves its kit
# through the link (realpath). VALIDATE-INSTALL.md has expected `command -v df-preflight`
# since it was written; this is the step that makes that line true.
BINDIR="${LOOM_BIN:-$HOME/.local/bin}"
if [ "$DRY" -eq 1 ]; then
  say "would  link $BINDIR/df-mission and $BINDIR/df-preflight"
else
  for pair in "df-mission:df-mission" "df-preflight:df-preflight.py"; do
    name="${pair%%:*}"; file="${pair#*:}"
    if [ -f "$ENGINE_DST/$file" ]; then
      mkdir -p "$BINDIR"
      ln -sf "$ENGINE_DST/$file" "$BINDIR/$name"
      say "ok    $BINDIR/$name"
    else
      say "WARN  $file not present in the pinned engine"
    fi
  done
  case ":$PATH:" in
    *":$BINDIR:"*) ;;
    # Installed-but-unreachable is not installed, and its failure mode -- "command not
    # found" at the moment you first need it -- points at the wrong thing.
    *) say "WARN  $BINDIR is not on your PATH. df-mission is installed and will not resolve."
       say "      add it to your shell profile, then open a new shell." ;;
  esac
fi

# ---- 5. verify ---------------------------------------------------------------
step "verify"
# RC is initialised in the "plugins" step above, not here: a refused plugin must
# already have set it to 2 before this line, and re-zeroing it here would silently
# forgive that refusal the moment lock-verify itself happens to pass.
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

# ---- 7. the install is not finished until something has RUN ------------------
# ⚠️ Everything above proves files were COPIED and that the tree matches the lockfile. None of it
# proves the machinery WORKS. A hook command that does not exist FAILS OPEN — nothing blocks and
# nothing errors. A hook installed but named in no settings.json is inert. Both are invisible to
# every check in section 5, because those check declarations against disk, and disk is exactly
# what is fine in both cases.
#
# ⚠️ NOT GATED ON $RC, on purpose. An install that ends in drift is precisely when someone most
# needs telling that files-in-place is not the same as working.
step "validate — THE INSTALL IS NOT DONE UNTIL YOU RUN THIS"
if [ -f "$ROOT/VALIDATE-INSTALL.md" ]; then
  # ⚠️ WORDED THIS LOUDLY ON PURPOSE, 2026-09-08. A new operator installed a fresh Coder and
  # reported that "the install session hasn't mentioned anything about the final test prompt,
  # so a new user wouldn't even be aware of it". The step DID print — as four quiet lines among
  # eighty. A validation step nobody notices is a validation step nobody runs.
  say ""
  say "  ┌─────────────────────────────────────────────────────────────────────────────┐"
  say "  │  NEXT STEP, and it is not optional:                                          │"
  say "  │                                                                             │"
  say "  │    1. cd into this kit directory                                            │"
  say "  │    2. start a NEW agent session there  (a fresh 'claude', NOT /clear)        │"
  say "  │    3. paste VALIDATE-INSTALL.md as the first prompt                          │"
  say "  └─────────────────────────────────────────────────────────────────────────────┘"
  say ""
  say "     $ROOT/VALIDATE-INSTALL.md"
  say ""
  say "  WHY A NEW SESSION, AND WHY /clear WILL NOT DO: the skills, hooks and plugin this run"
  say "  just placed are read by the harness when a session STARTS. The session you are in now"
  say "  began before they existed and cannot see them — validating in it fails every check for"
  say "  the wrong reason, which looks exactly like a broken install."
  say ""
  say "  WHY THE DIRECTORY MATTERS: that document runs entirely inside this one and writes"
  say "  nothing outside it. Its last step is a teardown that removes every artefact it created"
  say "  and then PROVES the tree is clean."
  say ""
  say "  WHAT IT IS FOR: everything above proves files were COPIED and match the lockfile. None"
  say "  of it proves the machinery WORKS — a hook command that does not exist FAILS OPEN, and"
  say "  nothing blocks and nothing errors. That document exercises the machinery instead of"
  say "  looking for it: it makes the identity check disagree on purpose, feeds a gate two"
  say "  different inputs, and asks what a headless worker can actually see."
else
  say "  WARN  no VALIDATE-INSTALL.md in this kit. Nothing here proves the install WORKS,"
  say "        only that files were copied. Fetch it from the starter kit before trusting this."
fi

[ "$DRY" -eq 1 ] && exit 0
exit "$RC"
