#!/usr/bin/env bash
# bootstrap.sh — turn this template into YOUR instance directory, once.
#
# Run it from a clone of the public repo. It creates a new directory that is yours to
# keep and to commit somewhere private, fills the lockfile template with the values it
# can resolve NOW, and stops. It installs nothing: install.sh does that, and keeping the
# two apart is what makes install.sh re-runnable.
#
#   bash starter-kit/instance/bootstrap.sh <instance-name> [target-dir]
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

NAME="${1:-}"
[ -n "$NAME" ] || die "usage: bash bootstrap.sh <instance-name> [target-dir]"
case "$NAME" in
  *[!a-zA-Z0-9._-]*) die "instance name may hold only letters, digits, dot, underscore, hyphen" ;;
esac

TARGET="${2:-$(cd "$SELF/../.." && pwd)/../$NAME}"
mkdir -p "$(dirname "$TARGET")" 2>/dev/null || true
TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"

[ -e "$TARGET" ] && die "$TARGET already exists — refusing to write over an existing instance"

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

cp "$SELF/install.sh" "$TARGET/install.sh"
chmod +x "$TARGET/install.sh"

cp "$SELF/dot-gitignore.template" "$TARGET/.gitignore" 2>/dev/null || true

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
say "NEXT"
say "  read starter-kit/instance/START-HERE.md — the ten-minute path, with the checkpoints"
say "  cd $TARGET"
say "  \$EDITOR loom.lock.json     # set codeRoot / codeLayout, then list the skills and hooks you want"
say "  bash install.sh"
say "  df-mission start $EXAMPLE_ID --profile default --max-iter 5 --max-usd 5"
say "                             # the worked example: proves the loop, writes only inside"
say "                             # .df/missions/$EXAMPLE_ID/, needs no hub and no network"
say ""
say "NOT DONE BY THIS SCRIPT, and not doable by any script:"
say "  - git hosting login"
say "  - your MCP hub URL and bearer token (boot-kit/mcp.template.json)"
say "  - registering hooks in your settings.json (boot-kit/settings.template.json)"
say "  - selecting the output style (boot-kit/output-style.md)"
say ""
say "  Read boot-kit/README.md: it says which of those is automatable and which is not,"
say "  and why the three that are not will stay that way."
