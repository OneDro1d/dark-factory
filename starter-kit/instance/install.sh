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
step "validate — files in place is not the same as working"
if [ -f "$ROOT/VALIDATE-INSTALL.md" ]; then
  say "  paste $ROOT/VALIDATE-INSTALL.md into a FRESH session on this machine."
  say "  It exercises the machinery instead of looking for it: it makes the identity check"
  say "  disagree on purpose, feeds a gate two different inputs, and asks what a headless"
  say "  worker can actually see — which is not what this session can see."
else
  say "  WARN  no VALIDATE-INSTALL.md in this kit. Nothing here proves the install WORKS,"
  say "        only that files were copied. Fetch it from the starter kit before trusting this."
fi

[ "$DRY" -eq 1 ] && exit 0
exit "$RC"
