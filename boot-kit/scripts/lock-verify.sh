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
#   L8  every hook ON THE MACHINE is declared here     (the reverse direction, for hooks)
#   L9  every declared hook is WIRED in the live settings, and every wired path exists
#   L10 every skill ON THE MACHINE is declared here    (the reverse direction, for skills)
#
# L8/L9 added 2026-08-29. L1..L7 could all pass on a machine that boots with no identity and
# no memory, because the hooks supplying those were in no lockfile (L8) or in one and wired
# nowhere (L9). "LOCKED" meant the cache agreed with the lock; it did not mean the machine
# came back. See the block comments at each layer for what was measured.
#
# L10 added 2026-08-30, and it is THE SAME OMISSION A SECOND TIME. L8 closed the reverse
# direction for hooks and stopped there; skills kept the identical blind spot for one more
# day, until undeclaring one left a live symlink that every layer above still called LOCKED.
# Whenever a layer is added in one direction for one artefact kind, ask what the OTHER kind
# is still missing. That question, asked on 2026-08-29, would have shipped both at once.
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

# ---- the not-an-entry set, named ONCE ---------------------------------------
# L8 and L10 both walk a live directory and both have to skip the same debris: editor and
# tool leftovers that are not hooks and not skills. Until now that set was written out twice,
# verbatim, in two `case` arms four hundred lines apart, and its human-readable form twice
# more in two `note` strings — four copies of one decision.
#
# ⚠️ WHY THAT MATTERS MORE HERE THAN IT LOOKS. These layers report DRIFT: an entry on the
# machine that no lockfile declares. Add a pattern to one copy and not the other and the two
# layers disagree about what counts as a file — L8 stays quiet about a `.bak` while L10 calls
# the same debris undeclared drift. A verifier that contradicts itself is one whose verdicts
# get skipped, which is the specific failure this file's own comments warn about twice.
#
# So: one function, one string, and the `case` arms both call it. A shell `case` cannot take
# its patterns from a variable, so a function is the only way to name this once.
is_not_an_entry() { # <basename> -> 0 if this is debris rather than a hook/skill
  case "$1" in
    __pycache__|*.bak|*.bak.*|*.retired-*|*.orig|*.rej|.*) return 0 ;;
    *) return 1 ;;
  esac
}
NOT_AN_ENTRY_DESC=".bak* / .retired-* / .orig / .rej / dotfiles / __pycache__"

# ---- L8: hooks on the machine that this lock does not declare ---------------
# THE HOOK DIRECTORY HAD NO L2. L2 asks "is every vendored dir declared?" and catches
# unprovenanced CONTENT. Nothing asked the same question of $LIVE/hooks, so a hook could be
# hand-copied onto a machine, hand-wired into settings.json, work perfectly for months, and
# appear in no lockfile — installed by nothing, reported by nothing, restored by nothing.
#
# Measured across the reference estate 2026-08-28/29, four machines, and it is not drift —
# it is structural. Every one of the five instance records declared THE SAME FIVE HOOKS,
# exactly this repo's own hooks/ set. Everything a human ever added since is undeclared:
# 13 on the laptop, 8 and 10 and 7 on the three workspaces. On the laptop 3 of the 4
# SessionStart entries were undeclared, including the one that supplies the agent's identity.
# The lockfile only ever grew through an install from here; hand-wiring never wrote back.
#
# The consequence is the one RESTORE promises against: wipe ~/.claude, restore from the
# lockfile, pass L1..L7, print LOCKED — and boot with no identity and no memory. On a cloud
# workspace whose ~/.claude is local disk and whose vendor mount survives a reset, the
# undeclared half is EXACTLY the half a reset destroys.
#
# ⚠️ WHY THIS IS NOT WORDED LIKE L2. $LIVE/hooks is SHARED BY EVERY INSTANCE on the machine
# — the same fact that forced L5 to resolve symlinks rather than test existence. A hook
# another instance correctly declares and installs is undeclared HERE and is not a defect.
# So the finding is "declared by no lockfile THIS check can see", never "unprovenanced".
# Read it with the other instances' locks in hand before deleting anything.
#
# ⚠️ AND WHY IT CANNOT DO BETTER. Skills are installed as symlinks, so L5 can resolve one and
# name the tree it came from. Hooks are COPIED — L5 tests them with a bare `[ -f ]`. Nothing
# on disk records a hook's provenance. That absence is why the class stayed invisible, and it
# is why L8 can only report the set difference, not attribute it.
echo "[L8] every hook on the machine is declared in this lock"
if [ ! -d "$LIVE/hooks" ]; then
  pass "L8 no $LIVE/hooks directory — nothing to check"
else
  # Files that cannot be a hook are counted and named-by-pattern, never silently dropped:
  # a reader must be able to audit the denominator. The reference laptop carried 12 such
  # backups beside 16 real hooks, enough to bury the finding if they were listed inline.
  L8SKIP=0
  L8UNDECL=""
  L8SEEN=0
  DECLARED_HOOKS="$(jq -r '(.install.hooks // [])[]' "$LOCK")"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="$(basename "$f")"
    if is_not_an_entry "$b"; then L8SKIP=$((L8SKIP + 1)); continue; fi
    L8SEEN=$((L8SEEN + 1))
    # An exact name match is the ordinary case. A DIRECTORY also counts as declared when
    # something inside it is declared: a plugin hook suite is installed under a nested name
    # (`agent-notepad/hooks/session-start.sh`) and the parent directory is never itself a
    # lockfile entry. Without this second test, correctly declaring all five hooks of a
    # suite still leaves its directory reported as undeclared for ever — a finding that
    # cannot be resolved is a finding people learn to skip. Found by declaring one.
    if printf '%s\n' "$DECLARED_HOOKS" | grep -qxF "$b"; then
      continue
    fi
    if [ -d "$LIVE/hooks/$b" ] && printf '%s\n' "$DECLARED_HOOKS" | grep -q "^$b/"; then
      continue
    fi
    L8UNDECL="$L8UNDECL $b"$'\n'
  done < <(find "$LIVE/hooks" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
  if [ -n "$L8UNDECL" ]; then
    drift "L8 present in $LIVE/hooks but declared in NO lockfile entry here:"
    printf '%s' "$L8UNDECL" | while read -r l; do [ -n "$l" ] && note "$l"; done
    note "each of these is installed by nothing and restored by nothing."
    note "decide per artefact: declare it here, own it in a plugin manifest, serve it"
    note "from the doctrine store, or record it as deliberately machine-local."
    note "⚠️ another instance sharing this LOOM_LIVE may declare some of them — check its"
    note "lock before deleting. This layer sees only the lockfile it was given."
  else
    pass "L8 all $L8SEEN hook entry/entries are declared in this lock"
  fi
  [ "$L8SKIP" -gt 0 ] && note "L8 skipped $L8SKIP non-hook file(s) ($NOT_AN_ENTRY_DESC)"
fi

echo ""

# ---- L9: every declared hook is actually WIRED into the live settings -------
# A hook can be declared, installed, hash-verified and INERT. On disk is not on duty: Claude
# Code runs a hook only because settings.json names it in an event chain, and install.sh
# copies hooks and NEVER TOUCHES settings.json. That gap was hit twice in one day
# (2026-08-28) on two different workspaces — the hook was present, the gate was green, and
# the behaviour it enforces simply did not happen.
#
# The installer already carries this concept FOR SKILLS ("on disk is inert until settings
# names it") and never carried it for hooks, which is the whole defect in one sentence.
#
# Both directions are checked, because they fail differently:
#   declared but unwired   -> silent no-op. The gate says LOCKED and nothing enforces.
#   wired but not on disk  -> a broken event chain, every session, on every fire.
#
# Settings are read from settings.json AND settings.local.json. The reference estate's
# workspaces carry both, and a hook wired only in the local file would otherwise be
# reported as unwired — a false DRIFT, which empties the verdict that is supposed to mean
# "this instance is right".
#
# ⚠️ SCOPE, AND WHY THE ESCAPE HATCH IS DESIGN RATHER THAN A FUDGE. Only the USER-level
# settings are read. A harness also merges PROJECT-level settings, and a hook can legitimately
# be wired there — the reference estate's notepad commit gate is wired in each notepad repo's
# own .claude/settings.json precisely so it arms in those sessions and nowhere else. This
# layer cannot enumerate every project on a machine, and pretending otherwise would mean
# either a false DRIFT on every such hook or a check that quietly stopped looking. So user
# level is checked, and a project-wired hook is RECORDED, with that as its stated reason.
#
# ESCAPE HATCH, deliberately narrow: `install.hooksUnwired` maps a hook NAME to a REASON
# STRING. A genuine exception (project-level wiring, a hook invoked by another hook, or one
# staged ahead of its wiring) can be recorded — but it cannot be silenced anonymously. An
# empty or missing reason is itself reported. A gate with a free mute button becomes a gate
# people learn to ignore, which is how verify-kit passed for weeks with 15 mandated skills
# absent.
echo "[L9] every declared hook is wired into the live settings"
L9SETTINGS=""
for s in "$LIVE/settings.json" "$LIVE/settings.local.json"; do
  [ -f "$s" ] && L9SETTINGS="$L9SETTINGS$s"$'\n'
done
if [ -z "$L9SETTINGS" ]; then
  drift "L9 no settings.json or settings.local.json under $LIVE — NOTHING is wired"
  note "every declared hook is inert. This is not a pass: an absent settings file means"
  note "the event chains do not exist, not that they are empty."
else
  # Every command string in every event chain, from every settings file present.
  L9CMDS=""
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if ! jq -e . "$s" >/dev/null 2>&1; then
      drift "L9 $s is not valid JSON — Claude Code cannot read it, so nothing is wired"
      continue
    fi
    L9CMDS="$L9CMDS$(jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command? // empty] | .[]' "$s" 2>/dev/null)"$'\n'
  done <<< "$L9SETTINGS"

  L9UNWIRED=""
  L9EXCUSED=""
  L9BADEXCUSE=""
  while read -r h; do
    [ -n "$h" ] || continue
    if printf '%s' "$L9CMDS" | grep -qF -- "$h"; then
      continue
    fi
    reason="$(jq -r --arg h "$h" '.install.hooksUnwired[$h] // empty' "$LOCK" 2>/dev/null)"
    if [ -n "$reason" ]; then
      L9EXCUSED="$L9EXCUSED $h — $reason"$'\n'
    elif jq -e --arg h "$h" '.install.hooksUnwired | has($h)' "$LOCK" >/dev/null 2>&1; then
      L9BADEXCUSE="$L9BADEXCUSE $h"$'\n'
    else
      L9UNWIRED="$L9UNWIRED $h"$'\n'
    fi
  done <<< "$(jq -r '(.install.hooks // [])[]' "$LOCK")"

  # The other direction: a chain naming a file that is not there.
  L9GHOST=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$c" in *"/hooks/"*) ;; *) continue ;; esac
    # Expand the two spellings the estate's settings files actually use, then take the
    # first whitespace-delimited token: chains carry arguments, paths do not.
    p="${c//\$\{HOME\}/$HOME}"
    p="${p//\$HOME/$HOME}"
    p="${p%% *}"
    [ -e "$p" ] || L9GHOST="$L9GHOST $p"$'\n'
  done <<< "$L9CMDS"

  if [ -n "$L9UNWIRED" ] || [ -n "$L9BADEXCUSE" ] || [ -n "$L9GHOST" ]; then
    [ -n "$L9UNWIRED" ] && {
      drift "L9 declared and installed but WIRED NOWHERE — inert:"
      printf '%s' "$L9UNWIRED" | while read -r l; do [ -n "$l" ] && note "$l"; done
      note "add it to a settings.json event chain, or record the exception with a reason"
      note "in install.hooksUnwired. install.sh does not wire hooks — a human does."
    }
    [ -n "$L9BADEXCUSE" ] && {
      drift "L9 listed in install.hooksUnwired with NO reason:"
      printf '%s' "$L9BADEXCUSE" | while read -r l; do [ -n "$l" ] && note "$l"; done
      note "the reason is the point. An exception nobody can audit is a silent failure"
      note "wearing a lockfile key."
    }
    [ -n "$L9GHOST" ] && {
      drift "L9 wired in settings but NOT PRESENT on disk — the chain breaks every session:"
      printf '%s' "$L9GHOST" | while read -r l; do [ -n "$l" ] && note "$l"; done
    }
  else
    pass "L9 every declared hook is wired, and every wired hook path exists"
  fi
  [ -n "$L9EXCUSED" ] && {
    note "L9 deliberate exceptions recorded in install.hooksUnwired:"
    printf '%s' "$L9EXCUSED" | while read -r l; do [ -n "$l" ] && note "$l"; done
  }
fi

echo ""

# ---- L10: skills on the machine that this lock does not declare -------------
# THE SKILLS DIRECTORY HAD THE BLIND SPOT HOOKS HAD BEFORE L8. The layers that touch an
# artefact ran in one direction only, and the gap is visible the moment they are listed:
#
#     L2   vendor dirs       -> declared?      content, both directions covered
#     L5   declared skills   -> installed?     ONE DIRECTION
#     L8   hooks on machine  -> declared?      the reverse, for hooks
#     ---  skills on machine -> declared?      DID NOT EXIST
#
# Measured 2026-08-30 while retiring a duplicate: dropping `smart-contract-auditor` from
# install.skills left ~/.claude/skills/smart-contract-auditor as a LIVE SYMLINK into the
# vendor tree, declared by nothing — and lock-verify printed LOCKED. Every layer above was
# satisfied. L5 does not iterate the machine, only the lock; L8 does not look at skills.
# The skill still loads, still fires on its triggers, and is restored by nothing.
#
# ⚠️ WHY THIS LAYER CAN DO WHAT L8 CANNOT. L8's own comment states the limit: hooks are
# COPIED, so nothing on disk records a hook's provenance and L8 can report only the set
# difference. Skills are installed as SYMLINKS — the same fact that forced L5 to resolve
# rather than test existence — so an undeclared skill still carries where it came from.
# That is worth spending, because the three ways a skill can be undeclared want three
# different remedies, and reporting them as one class is how a finding becomes noise:
#
#   ORPHANED    resolves INTO this instance's own vendor/ or repo. This lock owns the
#               content and declares nothing. Almost always a half-finished retirement or
#               a hand-linked skill. Declare it here, or remove the link.
#   FOREIGN     resolves somewhere else. $LIVE is SHARED BY EVERY INSTANCE on the machine,
#               so another instance may declare this correctly and it is not a defect
#               here. Read that instance's lock before touching it.
#   OPAQUE      not a symlink at all — a real directory, hand-copied. No provenance exists
#               on disk, which is exactly the hook situation, and the reason L8 can only
#               ever print names.
#
# ⚠️ AND WHY THERE IS NO ESCAPE HATCH, unlike L9. L9's `install.hooksUnwired` exists because
# a hook can be legitimately wired at PROJECT level, which this script cannot enumerate — a
# structural blind spot needing a recorded exception. Nothing equivalent is true here: every
# skill on the machine is visible to this layer, so a mute button would buy nothing except
# the ability to hide a finding. The file's own verdict on that trade, from L9: a gate with
# a free mute button becomes a gate people learn to ignore.
echo "[L10] every skill on the machine is declared in this lock"
if [ ! -d "$LIVE/skills" ]; then
  pass "L10 no $LIVE/skills directory — nothing to check"
else
  # Same denominator discipline as L8: files that cannot be a skill are counted and
  # named-by-pattern, never silently dropped. A reader must be able to audit what was
  # excluded, or the pass count means nothing.
  L10SKIP=0
  L10SEEN=0
  L10ORPHAN=""
  L10FOREIGN=""
  L10OPAQUE=""
  DECLARED_SKILLS="$(jq -r '(.install.skills // [])[]' "$LOCK")"
  # Resolve the two trees this instance owns ONCE. Both may be absent — a lockfile does not
  # require a checkout — and an empty prefix must never match, or every foreign skill would
  # be misreported as this instance's own.
  L10_VENDOR_P="$(phys "$VENDOR" || true)"
  L10_REPO_P="$(phys "$REPO" || true)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="$(basename "$f")"
    if is_not_an_entry "$b"; then L10SKIP=$((L10SKIP + 1)); continue; fi
    L10SEEN=$((L10SEEN + 1))
    printf '%s\n' "$DECLARED_SKILLS" | grep -qxF "$b" && continue
    if [ ! -L "$LIVE/skills/$b" ]; then
      L10OPAQUE="$L10OPAQUE$b"$'\n'
      continue
    fi
    p="$(phys "$LIVE/skills/$b" || true)"
    OWNED=0
    if [ -n "$L10_VENDOR_P" ]; then
      case "$p" in "$L10_VENDOR_P"/*) OWNED=1 ;; esac
    fi
    if [ -n "$L10_REPO_P" ]; then
      case "$p" in "$L10_REPO_P"/*) OWNED=1 ;; esac
    fi
    if [ -z "$p" ]; then
      # A symlink whose target is gone. Undeclared AND broken: it loads nothing, but it is
      # still a name in the skills directory that no lockfile accounts for.
      L10ORPHAN="$L10ORPHAN$b|dangling symlink -> $(readlink "$LIVE/skills/$b" 2>/dev/null)"$'\n'
    elif [ "$OWNED" -eq 1 ]; then
      L10ORPHAN="$L10ORPHAN$b|$p"$'\n'
    else
      L10FOREIGN="$L10FOREIGN$b|$p"$'\n'
    fi
  done < <(find "$LIVE/skills" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
  if [ -n "$L10ORPHAN" ] || [ -n "$L10OPAQUE" ] || [ -n "$L10FOREIGN" ]; then
    [ -n "$L10ORPHAN" ] && {
      drift "L10 resolves INTO this instance but is declared by nothing here:"
      printf '%s' "$L10ORPHAN" | while IFS='|' read -r n d; do
        [ -n "$n" ] && note "$n -> $d"
      done
      note "this lock owns the content and does not declare it. Installed by nothing,"
      note "restored by nothing — and still loaded by the harness every session."
      note "declare it in install.skills + install.skillSources, or remove the link."
    }
    [ -n "$L10OPAQUE" ] && {
      drift "L10 present in $LIVE/skills as a real directory, not a symlink:"
      printf '%s' "$L10OPAQUE" | while read -r l; do [ -n "$l" ] && note "$l"; done
      note "hand-copied content. Nothing on disk records where it came from, so this"
      note "layer cannot say whose it is — the same limit L8 lives with for hooks."
      note "give it a source and declare it, or record it as deliberately machine-local."
    }
    [ -n "$L10FOREIGN" ] && {
      drift "L10 present in $LIVE/skills, resolving OUTSIDE this instance:"
      printf '%s' "$L10FOREIGN" | while IFS='|' read -r n d; do
        [ -n "$n" ] && note "$n -> $d"
      done
      note "⚠️ $LIVE is shared by every instance on this machine. Another instance may"
      note "declare these correctly, in which case they are not a defect HERE. Read its"
      note "lock before deleting anything. This layer sees only the lockfile it was given."
    }
  else
    pass "L10 all $L10SEEN skill entry/entries are declared in this lock"
  fi
  [ "$L10SKIP" -gt 0 ] && note "L10 skipped $L10SKIP non-skill file(s) ($NOT_AN_ENTRY_DESC)"
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
