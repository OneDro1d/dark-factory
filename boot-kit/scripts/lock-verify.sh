#!/usr/bin/env bash
# lock-verify.sh — is this instance actually what its lockfile says it is?
#
# The whole point of Tier 3: an instance repo holds a LOCKFILE, not content. `vendor/` is a
# generated cache. This asserts the cache matches the lock, so "in sync" stops meaning
# "the cache agrees with itself" — the exact failure that hid two hooks for two days.
#
#   L1  every upstream in the lock is present in vendor/
#   L2  every vendor/ dir is declared in the lock       (the reverse direction)
#   L3  each vendored upstream sits at the PINNED commit
#   L4  each lane's git identity is available
#   L5  every skill/hook the lock says to install is installed on the machine
#   L6  every pin is reachable from a branch on the REMOTE
#   L7  every declared skill/hook names a source, and every source names a declaration
#       — and the lockfile is in the shape the installers accept, not the old MAP they refuse
#
# Usage: bash lock-verify.sh [--lock <path> | --lock=<path>]
# Exit:  0 ok · 1 drift · 2 bad arguments
set -uo pipefail

LOCK="loom.lock.json"
# ARG LOOP, ADDED 2026-08-26. This was one positional line — `[ "${1:-}" = "--lock" ] &&
# LOCK="${2:?...}"` — which read only $1, only the space form, and had no else-branch. Every
# other spelling was DROPPED, and dropping it was not an error: `--lock=instances/x/…` left
# LOCK at the root lockfile and the script then went on to print L1..L7 verdicts about a
# machine the operator had not asked about. A wrong install is visible; a wrong PASS is what
# stops the operator looking. The `=` form is the one the estate's own docs teach one line
# above the lock-verify line (instances/README.md), so the repo taught the syntax that failed.
# BOTH forms are accepted here rather than mirroring install.sh's reject-the-space-form
# choice: the space form has shipped for this script's whole life and both Tier-3 instance
# installers in the reference estate call it that way (at lines 508 and 274 of their
# respective install.sh), so rejecting it would trade a hand-invocation hazard for an
# automated-path outage.
while [ $# -gt 0 ]; do
  case "$1" in
    --lock)   LOCK="${2:?--lock needs a path}"; shift 2 ;;
    --lock=*) LOCK="${1#--lock=}"
              [ -n "$LOCK" ] || { echo "FATAL: --lock= needs a path" >&2; exit 2; }
              shift ;;
    *) printf 'FATAL unknown option: %s\n' "$1" >&2
       printf '  valid: --lock <path> | --lock=<path>\n' >&2
       exit 2 ;;
  esac
done
[ -f "$LOCK" ] || { echo "FATAL: no lockfile at $LOCK"; exit 1; }
command -v jq >/dev/null || { echo "FATAL: jq required"; exit 1; }

ROOT="$(cd "$(dirname "$LOCK")" && pwd)"
VENDOR="$ROOT/$(jq -r '.vendorDir // "vendor"' "$LOCK")"

# `local:` is relative to the REPO, never to the lockfile — and those are the same
# directory only for a ROOT lockfile, which is why this went unseen. Name an instance
# lockfile, which is the whole point of --lock, and they diverge.
#
# All four installers in the reference estate agree, checked rather than assumed —
# two Tier-3 instances, one Tier-2 template, one live Tier-2 org layer:
#   tier3 instance A/install.sh:198   local:*) "$(pwd)/..."   pwd = the repo root
#   tier3 instance B/install.sh:148   local:*) "$(pwd)/..."   pwd = the repo root
#   tier2-org template/install.sh:142 local:*) "$ROOT/..."    ROOT = the repo root
#   tier2 org layer/install.sh:142    local:*) "$ROOT/..."    ROOT = the repo root
#
# Resolving it here against the lockfile's directory made L5 print DRIFT over a correct
# install on both AWS/ESO Coder workspaces, 2026-08-26 — the safe-looking half of the same
# pair as the `--lock=` defect, which printed PASS about the wrong machine. A false DRIFT
# hides nothing, but it empties the one verdict that is supposed to mean "this instance
# is right" on every instance that uses the convention --lock exists to serve.
#
# The marker is `install.sh`, because that IS the file whose resolution rule this mirrors:
# every Tier-3 installer cds to its own directory, so `$(pwd)` is the directory holding it.
# Derived structurally, not asked of git — a lockfile does not require a checkout.
# VENDOR is deliberately NOT moved: each instance directory carries a committed `vendor`
# symlink back to the repo-root cache, so the vendor base is per-instance by design.
REPO="$ROOT"
_d="$ROOT"
while [ "$_d" != "/" ] && [ -n "$_d" ]; do
  [ -f "$_d/install.sh" ] && { REPO="$_d"; break; }
  _d="$(dirname "$_d")"
done
LIVE="${LOOM_LIVE:-$HOME/.claude}"
DRIFT=0
pass() { printf 'PASS  %s\n' "$1"; }
drift() { printf 'DRIFT %s\n' "$1"; DRIFT=1; }
note() { printf '        %s\n' "$1"; }

echo "=== lock-verify ==="
echo "lock   = $LOCK"
echo "vendor = $VENDOR"
echo "live   = $LIVE"
echo ""

# ---- L1: lock -> vendor ------------------------------------------------------
echo "[L1] every locked upstream is vendored"
MISSING=""
while read -r name; do
  [ -n "$name" ] || continue
  [ -d "$VENDOR/$name" ] || MISSING="$MISSING$name"$'\n'
done < <(jq -r '.upstreams | keys[]' "$LOCK")
if [ -n "$MISSING" ]; then
  drift "L1 locked upstream(s) not vendored:"
  printf '%s' "$MISSING" | while read -r n; do [ -n "$n" ] && note "$n"; done
  note "run: bash rehydrate.sh"
else
  pass "L1 all locked upstreams present"
fi

# ---- L2: vendor -> lock (THE DIRECTION THAT USUALLY GOES MISSING) ------------
# Without this, an undeclared directory in vendor/ is invisible and would survive a
# rebuild by accident — content with no recorded provenance is exactly what Tier 3 exists
# to eliminate.
echo "[L2] every vendored dir is declared in the lock"
UNDECLARED=""
if [ -d "$VENDOR" ]; then
  for d in "$VENDOR"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    jq -e --arg n "$n" '.upstreams[$n]' "$LOCK" >/dev/null 2>&1 || UNDECLARED="$UNDECLARED$n"$'\n'
  done
fi
if [ -n "$UNDECLARED" ]; then
  drift "L2 vendored but NOT in the lock (unprovenanced content):"
  printf '%s' "$UNDECLARED" | while read -r n; do [ -n "$n" ] && note "$n"; done
else
  pass "L2 no undeclared vendor content"
fi

# ---- L3: pinned commits ------------------------------------------------------
echo "[L3] vendored upstreams sit at their pinned commit"
BADPIN=""; CHECKED=0
while read -r name; do
  [ -n "$name" ] || continue
  want="$(jq -r --arg n "$name" '.upstreams[$n].commit' "$LOCK")"
  [ -d "$VENDOR/$name/.git" ] || continue
  CHECKED=$((CHECKED + 1))
  have="$(git -C "$VENDOR/$name" rev-parse HEAD 2>/dev/null || echo unknown)"
  [ "$want" = "$have" ] || BADPIN="$BADPIN$name want=${want:0:8} have=${have:0:8}"$'\n'
done < <(jq -r '.upstreams | keys[]' "$LOCK")
if [ -n "$BADPIN" ]; then
  drift "L3 commit mismatch:"
  printf '%s' "$BADPIN" | while read -r l; do [ -n "$l" ] && note "$l"; done
elif [ "$CHECKED" -eq 0 ]; then
  # NOT a pass. With nothing vendored there is nothing to compare, and reporting PASS
  # here would be a check that cannot fail — the exact false-assurance pattern this
  # whole gate family exists to avoid. Say so plainly instead.
  drift "L3 nothing vendored — 0 pins checkable (not a pass; see L1)"
else
  pass "L3 all $CHECKED pin(s) match"
fi

# ---- L4: identities ----------------------------------------------------------
# One account cannot resolve the other org's repos AT ALL (404, not 403), so a missing
# identity is a hard rehydrate failure, not a permission warning.
echo "[L4] required git identities are available"
if command -v gh >/dev/null 2>&1; then
  HAVE="$(gh auth status 2>&1 | grep -oE 'account [A-Za-z0-9_-]+' | awk '{print $2}' | sort -u)"
  MISSID=""
  while read -r acct; do
    [ -n "$acct" ] || continue
    printf '%s\n' "$HAVE" | grep -qx "$acct" || MISSID="$MISSID$acct"$'\n'
    # `// empty`, not a bare lookup: an upstream that needs NO identity (a public repo
    # cloned over https) has no `account`, and jq -r renders that absent value as the
    # four-character string "null" -- which is non-empty, so it was checked as though it
    # were an account named "null" and reported as missing. That is false drift on the
    # most ordinary case there is, and it fired on the FIRST run of a fresh public
    # install, where a spurious DRIFT is exactly what teaches someone to ignore the gate.
  done < <(jq -r '[.upstreams[].account // empty] | unique[]' "$LOCK")
  if [ -n "$MISSID" ]; then
    drift "L4 not logged in as:"
    printf '%s' "$MISSID" | while read -r a; do [ -n "$a" ] && note "$a (gh auth login)"; done
  else
    pass "L4 all required identities present"
  fi
else
  drift "L4 gh not installed — cannot verify identities"
fi

# ---- L5: installed on the machine, AND pointing where this lock says --------
# L5 used to ask only "does $LIVE/skills/<name> exist". A skill is installed as a SYMLINK,
# so existence says nothing about what it resolves to -- and $LIVE is shared by every
# instance on the machine. Install two instances and the second one's links sit in the same
# directory as the first's. Whichever installed last wins, both report LOCKED, and each is
# running some of the other's skills.
#
# Found by installing four instances into one $LIVE in sequence: 8 of one instance's 9
# declared skills resolved into a DIFFERENT instance's vendor tree, with rc=0 and drift=0.
# Confirmed by repointing a declared skill at a decoy directory holding entirely different
# content -- still rc=0, still LOCKED. The check could not fail.
#
# It is invisible while every instance pins the same upstream commit, because the content
# happens to be identical. Pins are bumped ONE INSTANCE AT A TIME, so "two instances at
# different pins" is the ordinary steady state, not the exotic one: the first bump is the
# day one instance silently starts running another's older skills.
#
# So resolve the link and compare it with what THIS lockfile declares as the source.
# Resolution mirrors the installer's, deliberately -- `local:` against the REPO (see REPO
# above), anything else under vendorDir -- because two tools disagreeing about what a
# source string means is how this class of defect arrives in the first place.
#
# CORRECTED 2026-08-26. This comment used to say `local:` resolved "inside the instance",
# and the code below did that. No installer does. The comment asserted an agreement that
# did not hold, which is the more expensive half: it told the next reader the question had
# been settled.
phys() {                       # physical path of $1, symlinks resolved, or empty
  [ -e "$1" ] || return 1
  if [ -d "$1" ]; then (cd "$1" 2>/dev/null && pwd -P); else
    _d=$(dirname "$1"); _b=$(basename "$1")
    (cd "$_d" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$_b")
  fi
}

echo "[L5] locked skills/hooks are installed, and resolve to THIS instance"
NOTINST=""
MISPOINT=""
while read -r s; do
  [ -n "$s" ] || continue
  if [ ! -e "$LIVE/skills/$s" ]; then
    NOTINST="$NOTINST skill:$s"$'\n'
    continue
  fi
  src="$(jq -r --arg s "$s" '.install.skillSources[$s] // empty' "$LOCK")"
  # No source is L7's finding, not L5's. Reporting it twice trains you to read neither.
  [ -n "$src" ] || continue
  case "$src" in
    local:*)    want="$REPO/${src#local:}" ;;
    upstream:*) want="$VENDOR/${src#upstream:}" ;;
    *)          want="$VENDOR/$src" ;;
  esac
  got_p="$(phys "$LIVE/skills/$s" || true)"
  want_p="$(phys "$want" || true)"
  if [ -z "$want_p" ]; then
    MISPOINT="$MISPOINT$s|declared source does not exist: $want"$'\n'
  elif [ "$got_p" != "$want_p" ]; then
    MISPOINT="$MISPOINT$s|resolves to $got_p, this lock declares $want_p"$'\n'
  fi
done < <(jq -r '(.install.skills // [])[]' "$LOCK")
while read -r h; do
  [ -n "$h" ] || continue
  [ -f "$LIVE/hooks/$h" ] || NOTINST="$NOTINST hook:$h"$'\n'
done < <(jq -r '(.install.hooks // [])[]' "$LOCK")
if [ -n "$NOTINST" ] || [ -n "$MISPOINT" ]; then
  [ -n "$NOTINST" ] && {
    drift "L5 declared but not installed:"
    printf '%s' "$NOTINST" | while read -r l; do [ -n "$l" ] && note "$l"; done
  }
  [ -n "$MISPOINT" ] && {
    drift "L5 installed but pointing OUTSIDE this instance:"
    printf '%s' "$MISPOINT" | while IFS='|' read -r n d; do
      [ -n "$n" ] && note "$n -> $d"
    done
    note "another instance sharing this LOOM_LIVE installed over these links."
    note "re-run this instance's install.sh, then re-check. Both instances reporting"
    note "LOCKED is exactly what this check exists to stop."
  }
else
  pass "L5 everything the lock installs is present and resolves to this instance"
fi

# ---- L6: pins are reachable from a branch on the REMOTE ----------------------
# L3 compares the vendored checkout to the pin — which passes on the machine that
# already holds the stale objects. After an upstream force-push/history rewrite the
# pin still exists LOCALLY, so every local check stays green and the break surfaces
# only on the next fresh clone, where it reads as a bad pin rather than a rewrite.
# The only truthful referee is the remote itself: a pin nobody can fetch is dead.
UNVERIFIED=0
echo "[L6] pinned commits are reachable from a remote branch"

# A multi-identity instance CANNOT check every pin with one active identity. Each upstream
# names the account that can see it, and the other account gets 404-not-403 — the repo does
# not appear to exist at all. Checking only the active identity therefore reports UNVERIFIED
# for every lane whose account happens to be inactive, which is indistinguishable from being
# offline and trains the reader to skim past it. On a 4-upstream lock that is 1 permanent
# UNVERIFIED on every single run.
#
# So: on a fetch failure, switch to the identity the LOCK names, retry once, and switch back.
# The switch is a global side effect in a read-only checker, so it is restored by trap — on
# success, on failure, and on interrupt. If the original account cannot be determined, no
# switching is attempted at all: leaving the operator's gh in an unexpected state is worse
# than an UNVERIFIED line.
# `gh api user --jq .login` asks the API who the ACTIVE token belongs to. The obvious
# alternative — parsing `gh auth status` — is where this went wrong the first time: the line
# is "Logged in to github.com account <name> (keyring)", so $NF is "(keyring)", not the name.
# `gh auth switch --user '(keyring)'` then fails, the failure is swallowed by `|| true`, and
# the identity silently stays wherever the last upstream left it. Ask the API, do not scrape
# a human-readable status line.
L6_ORIG=""
if command -v gh >/dev/null 2>&1; then
  L6_ORIG="$(gh api user --jq .login 2>/dev/null || true)"
fi
l6_restore() {
  [ -n "$L6_ORIG" ] && command -v gh >/dev/null 2>&1 && \
    gh auth switch --user "$L6_ORIG" >/dev/null 2>&1 || true
}
trap l6_restore EXIT INT TERM

DEADPIN=""; L6CHECKED=0; L6SKIPPED=""; L6SWITCHED=0
while read -r name; do
  [ -n "$name" ] || continue
  want="$(jq -r --arg n "$name" '.upstreams[$n].commit' "$LOCK")"
  [ -d "$VENDOR/$name/.git" ] || continue
  # --prune matters: a branch deleted upstream leaves a stale remote-tracking ref
  # that would keep vouching for a pin the remote no longer serves.
  if ! git -C "$VENDOR/$name" fetch --prune --quiet origin 2>/dev/null; then
    # Retry as the account the lock names for THIS upstream, if that is not already active.
    acct="$(jq -r --arg n "$name" '.upstreams[$n].account // empty' "$LOCK")"
    fetched=0
    if [ -n "$L6_ORIG" ] && [ -n "$acct" ] && [ "$acct" != "null" ] && [ "$acct" != "$L6_ORIG" ]; then
      if gh auth switch --user "$acct" >/dev/null 2>&1; then
        L6SWITCHED=1
        git -C "$VENDOR/$name" fetch --prune --quiet origin 2>/dev/null && fetched=1
        gh auth switch --user "$L6_ORIG" >/dev/null 2>&1 || true
      fi
    fi
    if [ "$fetched" -eq 0 ]; then
      L6SKIPPED="$L6SKIPPED$name"$'\n'
      continue
    fi
    note "L6 $name fetched as '$acct' (the lock's account for it), then restored '$L6_ORIG'"
  fi
  L6CHECKED=$((L6CHECKED + 1))
  if ! git -C "$VENDOR/$name" cat-file -e "$want" 2>/dev/null; then
    DEADPIN="$DEADPIN$name ${want:0:8} — object not found even after fetch (history rewritten upstream?)"$'\n'
  elif [ -z "$(git -C "$VENDOR/$name" branch -r --contains "$want" 2>/dev/null)" ]; then
    DEADPIN="$DEADPIN$name ${want:0:8} — exists locally but NO remote branch contains it (force-push/rewrite; a fresh clone cannot check this out)"$'\n'
  fi
done < <(jq -r '.upstreams | keys[]' "$LOCK")
if [ -n "$DEADPIN" ]; then
  drift "L6 dead pin(s) — unreachable from any remote branch:"
  printf '%s' "$DEADPIN" | while read -r l; do [ -n "$l" ] && note "$l"; done
  note "re-pin to a commit on a live branch (git ls-remote settles what the remote serves)"
fi
if [ -n "$L6SKIPPED" ]; then
  # Offline is not drift — an --offline rehydrate after a workspace reset must still
  # succeed — but it is not a pass either; say UNVERIFIED and taint the final verdict.
  while read -r n; do
    [ -n "$n" ] || continue
    acct="$(jq -r --arg n "$n" '.upstreams[$n].account // "?"' "$LOCK")"
    # The identity retry already ran and still failed, so identity is no longer the likely
    # cause — say so, rather than repeating a hypothesis that has been tested and eliminated.
    note "L6 $n UNVERIFIED — fetch failed even as '$acct'; pin not checked against the remote (offline, or that account has lost access?)"
    UNVERIFIED=$((UNVERIFIED + 1))
  done <<< "$L6SKIPPED"
fi
if [ -z "$DEADPIN" ] && [ "$L6CHECKED" -gt 0 ]; then
  pass "L6 all $L6CHECKED pin(s) reachable from a remote branch"
elif [ -z "$DEADPIN" ] && [ "$L6CHECKED" -eq 0 ] && [ "$UNVERIFIED" -eq 0 ]; then
  drift "L6 nothing vendored — 0 pins checkable (not a pass; see L1)"
fi

# ---- L7: declarations and sources agree, in BOTH directions -----------------
# `install.skills` is a list of NAMES and `install.skillSources` is a map of name ->
# source. Two structures for one fact, so they can disagree, and each disagreement is
# silent in a different way:
#
#   name with no source     installs nothing. rehydrate WARNs once, during an install
#                           nobody re-reads, and the lockfile still appears to declare it.
#   source with no name     installs nothing either, and reads as a declaration. This is
#                           how a skill stops being installed when someone edits the list
#                           and forgets the map — the lockfile still mentions it by name.
#
# A single map keyed by name could not express either state. That shape was considered and
# not taken (the array is what four consumers and every existing lockfile already read), so
# the guarantee it would have given for free is bought back here instead.
#
# Keys beginning with `$` are documentation, not entries — the shipped templates carry a
# `$comment` inside both *Sources maps.
#
# ---- SHAPE FIRST, AND THE SAME THREE-WAY TEST THE INSTALLERS ALREADY MAKE.
# `install.<kind>` has an older reading: a single MAP of name -> source, with no *Sources
# key. Both shipped installers REFUSE it — `lock_shape_guard` in
# starter-kit/templates/tier2-org/install.sh:153-168 and in its tier3-instance/install.sh:83-98
# take `array|null`, `die` on `object`, and `die` on anything else. df-lock-migrate.py is
# the one-command fix they name.
#
# L7 was never given that guard, and jq's `(.install[$k] // [])[]` iterates a map's VALUES.
# So on the old shape L7 took "upstream:dark-factory/skills/agent-notepad" for a NAME,
# looked it up in an absent skillSources, and reported drift — 50 lines, 46 skills + 4
# hooks, every one false, on a live Tier-2 org layer's org.lock.json, the single
# file that decides what that layer's whole minted Tier-3 fleet installs. Failing loud and
# WRONG is worse than failing silent: it teaches the reader to skip the verdict.
#
# The verdict here must be the installers' verdict. A lockfile install.sh would refuse
# outright cannot also be LOCKED, and a verifier that is more permissive than the installer
# is how "in sync" comes to mean two different things in one estate. So: same case arms,
# same remedy, named. Empty is not an exception — the guard dies on `object` whether or not
# it has entries, and the live tier3 template is `{}` on both keys.
#
# Absence stays a fourth case. No declarations means nothing to check, which is a fact;
# "every declaration has a source" would be a claim. Both UPSTREAM.lock files land there.
echo "[L7] declarations and sources agree"
L7BAD=""
L7SHAPE=""
L7CHECKED=0
for kind in skills hooks; do
  case "$kind" in skills) smap=skillSources ;; hooks) smap=hookSources ;; esac
  # Ask jq for the TYPE rather than iterating and letting it abort mid-level with a message
  # that reads like a verdict. `.install` itself may be absent, or pathologically not an
  # object; both are answered here rather than crashing the level.
  t="$(jq -r --arg k "$kind" \
        'if (.install|type) == "object" then (.install[$k] | type)
         elif (.install|type) == "null" then "null"
         else "BADINSTALL" end' "$LOCK" 2>/dev/null || echo BADINSTALL)"
  case "$t" in
    null) : ;;   # not declared at all. Nothing to check, and not a failure.
    array)
      while read -r n; do
        [ -n "$n" ] || continue
        L7CHECKED=$((L7CHECKED + 1))
        v="$(jq -r --arg n "$n" --arg m "$smap" '.install[$m][$n] // empty' "$LOCK")"
        [ -n "$v" ] || L7BAD="$L7BAD ${kind%s}:$n declared with no $smap entry"$'\n'
      done < <(jq -r --arg k "$kind" '(.install[$k] // [])[]' "$LOCK")
      while read -r n; do
        [ -n "$n" ] || continue
        L7CHECKED=$((L7CHECKED + 1))
        jq -e --arg n "$n" --arg k "$kind" '(.install[$k] // []) | index($n)' "$LOCK" >/dev/null 2>&1 \
          || L7BAD="$L7BAD ${kind%s}:$n has a $smap entry but is not declared in install.$kind"$'\n'
      done < <(jq -r --arg m "$smap" '(.install[$m] // {}) | keys[] | select(startswith("$") | not)' "$LOCK")
      ;;
    object)
      n="$(jq -r --arg k "$kind" '.install[$k] | keys | map(select(startswith("$") | not)) | length' "$LOCK")"
      L7SHAPE="$L7SHAPE install.$kind is a MAP of $n entries — the old shape, from before names and sources were split. install.sh REFUSES this lockfile; nothing would be installed."$'\n'
      ;;
    BADINSTALL)
      L7BAD="$L7BAD install is a $(jq -r '.install | type' "$LOCK") — expected an object"$'\n'
      ;;
    *)
      L7SHAPE="$L7SHAPE install.$kind has unexpected type '$t' — expected an array of names."$'\n'
      ;;
  esac
done
if [ -n "$L7SHAPE" ]; then
  drift "L7 lockfile is in a shape the installers refuse:"
  printf '%s' "$L7SHAPE" | while read -r l; do [ -n "$l" ] && note "$l"; done
  note "convert once, then re-run:  python3 <dark-factory checkout>/boot-kit/scripts/df-lock-migrate.py --lock $LOCK --apply"
fi
if [ -n "$L7BAD" ]; then
  drift "L7 declarations and sources disagree:"
  printf '%s' "$L7BAD" | while read -r l; do [ -n "$l" ] && note "$l"; done
fi
if [ -z "$L7BAD" ] && [ -z "$L7SHAPE" ]; then
  if [ "$L7CHECKED" -gt 0 ]; then
    pass "L7 every declaration has a source and every source has a declaration ($L7CHECKED checked)"
  else
    # An empty or absent install block. Deliberately NOT the sentence above: a reader who
    # greps for that sentence is asking whether the cross-check ran, not whether it was
    # vacuous. Both UPSTREAM.lock files in the estate land here.
    pass "L7 nothing to check — no install.skills or install.hooks declarations"
  fi
fi

echo ""
if [ "$DRIFT" -eq 0 ]; then
  if [ "$UNVERIFIED" -gt 0 ]; then
    # Not the same claim as LOCKED: everything checkable passed, but $UNVERIFIED pin(s)
    # were never compared against the remote. Say so, or offline becomes false assurance.
    echo "=== RESULT: LOCKED (locally) — $UNVERIFIED pin(s) UNVERIFIED against the remote (offline?) ==="
  else
    echo "=== RESULT: LOCKED — this instance matches its lockfile ==="
  fi
  exit 0
else
  echo "=== RESULT: DRIFT ==="
  echo "Rehydrate:  bash rehydrate.sh          (lock -> machine)"
  echo "Re-pin:     edit loom.lock.json        (deliberate; never automatic)"
  exit 1
fi
