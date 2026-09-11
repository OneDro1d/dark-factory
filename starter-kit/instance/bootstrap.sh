#!/usr/bin/env bash
# bootstrap.sh — turn this template into YOUR instance directory, once.
#
# Run it from a clone of the public repo. It creates a new directory that is yours to
# keep and to commit somewhere private, fills the lockfile template with the values it
# can resolve NOW, and stops. It installs nothing: install.sh does that, and keeping the
# two apart is what makes install.sh re-runnable.
#
#   bash starter-kit/instance/bootstrap.sh <instance-name> [target-dir] [--kit <name>]...
#
# --kit selects a bundle from kits/ and writes its skills and hooks into the lockfile.
# Repeat it to compose. Without it the instance ships with an EMPTY skill list, which stays
# a valid choice: an empty list is honest, and a default set nobody chose is the thing this
# repo refuses to ship elsewhere. `--kit list` prints what is available.
#
# Defaults target-dir to ../<instance-name>, i.e. a sibling of this repo, so that the
# generated instance is never inside the checkout it was generated from. An instance
# nested in its own upstream gets committed to that upstream by the first careless
# `git add -A`, and nothing about the layout warns you first.
#
# WHAT IT RESOLVES, AND WHY IT RESOLVES IT NOW
#   - the Tier-1 commit SHA, from the remote, at this moment. A branch name in a lockfile
#     means upstream can move between two installs of the "same" instance.
#   - platform + home, so df-preflight can tell which machine a lockfile describes when
#     one checkout carries several.
# Anything it cannot resolve is written as a LOUD placeholder, never as a plausible
# default. A wrong value that looks right survives much longer than a missing one.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'FATAL: %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$1"; }

# ⚠️ --kit is parsed OUT of the positional arguments before they are read, so that it may
# appear anywhere on the command line. A flag that only works in one position is a flag people
# report as broken.
KITS=""
POS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kit)
      shift
      [ $# -gt 0 ] || die "--kit needs a kit name (try: --kit list)"
      KITS="$KITS $1"
      ;;
    --kit=*) KITS="$KITS ${1#--kit=}" ;;
    --) shift; while [ $# -gt 0 ]; do POS="$POS $1"; shift; done; break ;;
    -*) die "unknown option: $1" ;;
    *)  POS="$POS $1" ;;
  esac
  shift
done
# shellcheck disable=SC2086
set -- $POS

# `--kit list` before anything is validated or created: it is a query, not a bootstrap.
case " $KITS " in
  *" list "*)
    python3 "$SELF/../../boot-kit/scripts/kit-resolve.py" --list \
      --root "$(cd "$SELF/../.." && pwd)"
    exit 0
    ;;
esac

NAME="${1:-}"
[ -n "$NAME" ] || die "usage: bash bootstrap.sh <instance-name> [target-dir] [--kit <name>]..."
case "$NAME" in
  *[!a-zA-Z0-9._-]*) die "instance name may hold only letters, digits, dot, underscore, hyphen" ;;
esac

TARGET="${2:-$(cd "$SELF/../.." && pwd)/../$NAME}"
mkdir -p "$(dirname "$TARGET")" 2>/dev/null || true
TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"

[ -e "$TARGET" ] && die "$TARGET already exists — refusing to write over an existing instance"

# ---- resolve the requested kits, BEFORE creating anything --------------------
# ⚠️ RESOLVED FIRST ON PURPOSE. A kit that names a missing skill must fail while the only thing
# at stake is an error message. Resolving after mkdir leaves a half-built instance directory
# behind on failure, and a half-built instance is worse than none: it exists, so the next run
# refuses to overwrite it, and the user is stuck with a directory that looks finished.
KIT_JSON=""
if [ -n "${KITS// /}" ]; then
  command -v python3 >/dev/null 2>&1 || die "--kit needs python3 on PATH"
  RESOLVER="$SELF/../../boot-kit/scripts/kit-resolve.py"
  [ -f "$RESOLVER" ] || die "kit resolver missing: $RESOLVER"
  # shellcheck disable=SC2086
  KIT_JSON="$(python3 "$RESOLVER" $KITS --root "$(cd "$SELF/../.." && pwd)")" \
    || die "could not resolve kit(s):$KITS"
  say "kits      resolved:$KITS"
fi

for b in git jq; do
  command -v "$b" >/dev/null 2>&1 || die "$b is required and is not on PATH"
done

# ---- resolve the Tier-1 pin, from the remote, right now ----------------------
T1_URL="https://github.com/OneDro1d/dark-factory.git"
T1_COMMIT=""
T1_SOURCE=""
if T1_COMMIT="$(git ls-remote "$T1_URL" refs/heads/main 2>/dev/null | awk 'NR==1{print $1}')" && [ -n "$T1_COMMIT" ]; then
  T1_SOURCE="resolved from $T1_URL refs/heads/main at bootstrap time"
else
  # Offline is a legitimate state, and it is not the same as "there is no pin". Fall back
  # to the checkout this script was run from, and SAY which it was -- a pin whose origin
  # is unrecorded is a pin nobody can re-derive.
  if T1_COMMIT="$(git -C "$SELF" rev-parse HEAD 2>/dev/null)" && [ -n "$T1_COMMIT" ]; then
    T1_SOURCE="LOCAL HEAD of the checkout bootstrap ran from — the remote was unreachable. Confirm this commit exists on the remote before relying on it."
    say "WARN  could not reach $T1_URL — pinning the local HEAD instead"
  else
    T1_COMMIT="__T1_COMMIT__"
    T1_SOURCE="UNRESOLVED — no remote and no local git history. Fill this in by hand."
    say "WARN  could not resolve any Tier-1 commit; the lockfile ships an unresolved placeholder"
  fi
fi

PLATFORM="$(uname -s)"
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- write the instance ------------------------------------------------------
mkdir -p "$TARGET" || die "could not create $TARGET"

TPL="$SELF/loom.lock.json.template"
[ -f "$TPL" ] || die "template missing: $TPL"

# jq, not sed: the values carry slashes and quotes, and a sed substitution that produces
# invalid JSON fails at the NEXT tool rather than here, where the cause is visible.
jq \
  --arg name "$NAME" \
  --arg created "$CREATED" \
  --arg platform "$PLATFORM" \
  --arg home "$HOME" \
  --arg commit "$T1_COMMIT" \
  --arg src "$T1_SOURCE" \
  --arg coderoot "$HOME/code" \
  '
   .instance.name          = $name
 | .instance.createdAt     = $created
 | .machine.platform       = $platform
 | .machine.home           = $home
 | .codeRoot               = $coderoot
 | .upstreams["dark-factory"].commit     = $commit
 | .upstreams["dark-factory"]["$refSource"] = $src
  ' "$TPL" > "$TARGET/loom.lock.json" || die "could not render the lockfile"

# ⚠️ MERGED, NOT OVERWRITTEN. The template's `hooks` already names df-instance-start.sh with a
# matching hookSources entry, and that pairing is what the installer requires: a name with no
# source is a declaration the installer cannot resolve. So the kit's lists are UNIONED onto the
# template's and the source maps are merged, with the template's own entries kept — the template
# knows something about its own hook that a generic kit does not.
if [ -n "$KIT_JSON" ]; then
  printf '%s' "$KIT_JSON" > "$TARGET/.kit-resolution.json"
  jq -s '
      .[0] as $lock | .[1] as $kit
    | $lock
    | .install.skills       = (($lock.install.skills // []) + $kit.skills       | unique_by(.))
    | .install.hooks        = (($lock.install.hooks  // []) + $kit.hooks        | unique_by(.))
    | .install.skillSources = ($kit.skillSources + ($lock.install.skillSources // {}))
    | .install.hookSources  = ($kit.hookSources  + ($lock.install.hookSources  // {}))
    | .install["$kitResolution"] = ("bootstrapped from kits/: " + ($kit.resolvedFrom | join(" -> "))
        + ". Regenerate with boot-kit/scripts/kit-resolve.py. This line records WHICH bundle these"
        + " names came from -- without it a later reader cannot tell a curated set from a hand-edited"
        + " one, and the two need different treatment when the kit changes upstream.")
    ' "$TARGET/loom.lock.json" "$TARGET/.kit-resolution.json" > "$TARGET/loom.lock.json.tmp" \
    && mv "$TARGET/loom.lock.json.tmp" "$TARGET/loom.lock.json" \
    || die "could not merge the kit resolution into the lockfile"
  rm -f "$TARGET/.kit-resolution.json" "$TARGET/loom.lock.json.tmp"
fi

cp "$SELF/install.sh" "$TARGET/install.sh"
chmod +x "$TARGET/install.sh"

cp "$SELF/dot-gitignore.template" "$TARGET/.gitignore" 2>/dev/null || true

# The post-install validation prompt. COPIED INTO THE INSTANCE, not left in the upstream: a
# machine is validated by the person standing at it, and a document that lives only in the public
# repo is one more thing they have to know to go and find. It is the last step of the install and
# it ships with the kit.
cp "$SELF/VALIDATE-INSTALL.md" "$TARGET/VALIDATE-INSTALL.md" 2>/dev/null \
  || say "WARN  could not copy VALIDATE-INSTALL.md — this instance ships with no way to prove it works"

# The runbook, and the kit's own page. ⛔ ADDED 2026-09-11: until then bootstrap copied NEITHER
# START-HERE.md nor AUTHENTICATION.md, so every kit it made pointed its reader back at this public
# repo for the steps that make the kit theirs. A person tells their agent "read START-HERE.md and
# execute it" in the KIT, so the file has to be in the kit. It is the same file in every kit, byte
# for byte, which is why nothing kit-specific lives in it: that goes in KIT.md, rendered here.
for f in START-HERE.md AUTHENTICATION.md; do
  cp "$SELF/$f" "$TARGET/$f" 2>/dev/null || say "WARN  could not copy $f — the instance ships without it"
done
KIT_LABEL="no kit — an empty skill list"
# shellcheck disable=SC2086
[ -n "${KITS// /}" ] && KIT_LABEL="$(printf 'kits/%s ' $KITS | sed 's/ $//; s/ / + /g')"
if [ -f "$SELF/KIT.md.template" ]; then
  # sed is safe for the same reason as CLAUDE.md below: the name is validated, and every kit
  # name has already been resolved to a directory under kits/.
  sed -e "s|__INSTANCE_NAME__|$NAME|g" -e "s|__KITS__|$KIT_LABEL|g" "$SELF/KIT.md.template" > "$TARGET/KIT.md" \
    || say "WARN  could not render KIT.md"
else
  say "WARN  KIT.md.template missing — the instance ships with no page saying what it is for"
fi

# The instance's project instructions. Rendered, not copied: it carries the instance name,
# and it ships as a .template so that a file named CLAUDE.md never sits in the kit itself --
# a harness would auto-load it into sessions ABOUT the kit and inject instructions meant for
# an instance. sed is safe here where it was not for the lockfile: the only substitution is
# a name already validated to hold no shell or regex metacharacters.
if [ -f "$SELF/CLAUDE.md.template" ]; then
  sed "s|__INSTANCE_NAME__|$NAME|g" "$SELF/CLAUDE.md.template" > "$TARGET/CLAUDE.md" \
    || say "WARN  could not render CLAUDE.md"
else
  say "WARN  CLAUDE.md.template missing — the instance ships with no project instructions"
fi

# The boot-kit templates you MERGE by hand: harness settings, the hub config, the output
# style. Copied, not installed -- each of them lands in a file shared with everything else
# you run, and a script that rewrites those silently deletes another tool's configuration.
# The session hook is deliberately NOT copied here: it is declared in the lockfile and
# installed from the vendored upstream, so there is one store of it and nothing to drift.
mkdir -p "$TARGET/boot-kit"
for f in README.md settings.template.json mcp.template.json output-style.md; do
  cp "$SELF/boot-kit/$f" "$TARGET/boot-kit/$f" 2>/dev/null || say "WARN  could not copy boot-kit/$f"
done

# ---- the instance's own test harness -----------------------------------------
# ⛔ ADDED 2026-09-08, AND ITS ABSENCE WAS A MEASURED GAP ACROSS THE WHOLE FLEET. This
# template has shipped `boot-kit/scripts/run-tests.sh`, `boot-kit/tests/` and
# `.github/workflows/gate.yml` since 2026-08-31 — and bootstrap.sh copied NONE of them, so
# every instance ever minted came out with no runner, no suites and no CI. Measured on six
# live records: one had them (added by hand, months later) and five had zero.
#
# ⚠️ AND A TIER-1 SUITE WAS GREEN THROUGHOUT. `test-instance-ci.sh` asserts "the kit ships
# both halves" — and it is right, because it measures THIS DIRECTORY. Nothing measured what
# the MINT produces. That is the same defect as the installer step that never reached an
# existing machine: a check aimed at the template rather than at the thing the template
# makes. `test-bootstrap-ships-tests.sh` now runs bootstrap.sh for real and reads the OUTPUT.
#
# ⚠️ The workflow is copied to `.github/workflows/gate.yml` in the INSTANCE, where it is that
# repo's own CI. It runs the instance's suites and deliberately never runs install.sh: a CI
# runner is not the machine the instance records, so a green tick there means the record is
# well-formed, never that the install works. Only lock-verify on the target machine says that.
#
# ⛔ TWO TEST DIRECTORIES, AND COPYING THE WRONG ONE MAKES EVERY NEW KIT RED ON DAY ONE.
#   boot-kit/tests/           tests OF THIS TEMPLATE. They stay here. `test-boot-kit.sh`
#                             asserts `boot-kit/hooks/df-instance-start.sh` is present — true
#                             in the template, FALSE in a minted instance, where the hook is
#                             deliberately not copied because the lockfile declares it and the
#                             installer takes it from the vendored upstream (one store, no
#                             drift). Measured 2026-09-08: shipping that suite made a fresh
#                             mint fail its own gate immediately, on a correct instance.
#   boot-kit/instance-tests/  tests that SHIP, and that assert things TRUE OF A RECORD. They
#                             land in the instance as boot-kit/tests/, which is where its own
#                             runner looks.
# The split is a directory rather than a naming convention on purpose: a convention is a rule
# somebody has to remember at the moment of writing a new suite, and this one would fail
# silently in the direction that looks green here and red on someone else's machine.
mkdir -p "$TARGET/boot-kit/scripts" "$TARGET/boot-kit/tests" "$TARGET/.github/workflows"
cp "$SELF/boot-kit/scripts/run-tests.sh" "$TARGET/boot-kit/scripts/run-tests.sh" 2>/dev/null \
  || say "WARN  could not copy boot-kit/scripts/run-tests.sh — this instance has no test runner"
chmod +x "$TARGET/boot-kit/scripts/run-tests.sh" 2>/dev/null
TEST_N=0
for t in "$SELF"/boot-kit/instance-tests/test-*.sh; do
  [ -f "$t" ] || continue
  cp "$t" "$TARGET/boot-kit/tests/" 2>/dev/null || { say "WARN  could not copy ${t##*/}"; continue; }
  chmod +x "$TARGET/boot-kit/tests/${t##*/}" 2>/dev/null
  TEST_N=$((TEST_N + 1))
done
cp "$SELF/.github/workflows/gate.yml" "$TARGET/.github/workflows/gate.yml" 2>/dev/null \
  || say "WARN  could not copy .github/workflows/gate.yml — this instance has no CI"
# Said out loud, with the count. "Shipped a test harness" and "shipped zero suites" both
# leave a tests/ directory behind, and only one of them is worth anything.
say "  test harness: run-tests.sh + $TEST_N suite(s) + .github/workflows/gate.yml"
[ "$TEST_N" -eq 0 ] && say "WARN  zero suites copied — the runner treats that as a HARD FAILURE, by design"

mkdir -p "$TARGET/.df/missions" "$TARGET/handoffs" "$TARGET/sessions"

# The worked example mission. Copied rather than generated, and copied with a FIXED id, so
# that every instance's first run is the same run and a report from one is comparable with
# a report from another. It is confined to its own directory by its own HARD-STOPS.md --
# that confinement is the whole reason it is safe to ship enabled.
EXAMPLE_ID="EXAMPLE-FIRST-RUN"
if [ -d "$SELF/example-mission" ]; then
  mkdir -p "$TARGET/.df/missions/$EXAMPLE_ID"
  cp "$SELF/example-mission"/*.md "$TARGET/.df/missions/$EXAMPLE_ID/" \
    || say "WARN  could not copy the example mission"
else
  say "WARN  example-mission/ missing -- the instance ships with no worked example"
fi

# A notepad is identified by holding this file: df-preflight walks up from $PWD looking
# for it to decide WHICH REPOS a mission is about. Ship it empty rather than omit it --
# absent, every mission silently scopes to nothing and every repo probe is skipped.
cat > "$TARGET/repos.manifest.json" <<'MANIFEST'
{
  "$comment": "The repos THIS objective drives. Identity is the `remote`, never a path: a stale path that happens to exist elsewhere on the machine resolves silently to the wrong tree, and nothing about a wrong-but-present directory looks wrong. Empty is a valid, honest starting state.",
  "repos": []
}
MANIFEST

say ""
say "=== instance created ==="
say "  $TARGET"
say ""
say "  lockfile   loom.lock.json      (pinned: ${T1_COMMIT:0:8})"
say "  pin source $T1_SOURCE"
say ""
say "NEXT — open Claude Code in $TARGET and tell it:"
say ""
say "    Read START-HERE.md and execute it."
say ""
say "  It makes the directory a private repo of yours (step 2A), adds this machine's record under"
say "  instances/ (step 3), installs it (step 4), walks you through the sign-ins (step 5) and"
say "  validates the result (step 6). Fill in KIT.md as you go: it is what the next person reads."
if [ -z "$KIT_JSON" ]; then
  say ""
  say "  ⚠️ no --kit: the skill list is EMPTY. Re-run with --kit <name> (bash bootstrap.sh --kit list),"
  say "     or list the skills you want in loom.lock.json before installing."
fi
say ""
say "  Once installed, the worked example proves the loop with no hub and no network:"
say "    df-mission start $EXAMPLE_ID --profile default --max-iter 5 --max-usd 5"
say ""
say "NOT DONE BY THIS SCRIPT, and not doable by any script:"
say "  - git hosting login"
say "  - your MCP hub URL and bearer token (boot-kit/mcp.template.json)"
say "  - registering hooks in your settings.json (boot-kit/settings.template.json)"
say "  - selecting the output style (boot-kit/output-style.md)"
say ""
say "  Read boot-kit/README.md: it says which of those is automatable and which is not,"
say "  and why the three that are not will stay that way."
