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
#   L11 every materialised plugin still matches its pin (a copy, not a symlink)
#   L12 every plugin's own invariants suite, if it ships one, still passes
#   L13 every estate's declared MCP source (a hub set, or a claude.ai connector) is present
#   L14 every declared marketplace plugin is installed, enabled, and still the version
#       install.sh recorded — the only drift signal available for something unpinnable
#   L15 every estate ANY record in the kit names, that THIS record does not, is denied for a
#       SESSION here too — the same rule other_estates() applies to a worker, applied to the
#       live settings a hand-rolled `claude` session actually reads
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

# Where THIS script lives. rehydrate.sh is its sibling, and the repair lines below
# must name a path the reader can actually run: lock-verify is invoked from a Tier-3
# repo root or from vendor/dark-factory/boot-kit/scripts/, never from a directory
# where a bare `rehydrate.sh` resolves. Measured 2026-09-02 -- an ESO install report
# searched its whole repo, found none, and recorded the repair as a dead pointer.
# ⚠️ A gate that names a repair the reader cannot run teaches them to ignore the gate.
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# UNKNOWN is a THIRD verdict and it is not a synonym for DRIFT. `drift` means "probed, and
# reality differs" — a positive negative. `unknown` means "could not probe at all", which is
# a fact about this machine's tooling, not about the instance. Collapsing the two is how a
# missing binary gets reported as a broken install: it fires on the most ordinary case there
# is, on a first run, and a gate that fires wrong on day one is the gate people learn to
# ignore. This file had the rule (see the `// empty` comment in L4) and applied it one level
# in while the outer test still collapsed them — the rule was understood and unenforced.
UNKNOWN=0
pass() { printf 'PASS  %s\n' "$1"; }
drift() { printf 'DRIFT %s\n' "$1"; DRIFT=1; }
unknown() { printf 'UNKNOWN %s\n' "$1"; UNKNOWN=$((UNKNOWN + 1)); }
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
  note "run: bash \"$SELFDIR/rehydrate.sh\""
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
# ORDER IS THE WHOLE FIX. Ask "which accounts does this lock actually REQUIRE" FIRST — that
# question is answered by jq against the lockfile and needs no `gh` at all. The previous
# version wrapped the entire check in `command -v gh`, so a machine without `gh` reported
# DRIFT before anything had asked whether an identity was needed. The public starter
# lockfile declares NO account, so the public kit could not reach exit 0 with its own four
# documented prerequisites — `gh` appears nowhere in START-HERE, and install.sh's own
# comments say the public method must install with git alone. Installing `gh` and nothing
# else was the only thing between a correct install and success. Reported cold, on a clean
# Debian container, first try (outside-installer feedback, 24-27 Aug 2026, finding 03).
#
# `// empty`, not a bare lookup: an upstream that needs NO identity (a public repo cloned
# over https) has no `account`, and jq -r renders that absent value as the four-character
# string "null" -- which is non-empty, so it was checked as though it were an account named
# "null" and reported as missing. That is false drift on the most ordinary case there is.
# ⚠️ That fix and this one are THE SAME BUG at two different depths: both report "no
# identity required" as a missing identity. Fixing the inner one in isolation is why the
# outer one survived to be found by a stranger instead of by us.
REQ_ACCTS="$(jq -r '[.upstreams[].account // empty] | unique[]' "$LOCK")"
if [ -z "$REQ_ACCTS" ]; then
  pass "L4 no upstream declares an account — no git identity required, gh not consulted"
elif command -v gh >/dev/null 2>&1; then
  HAVE="$(gh auth status 2>&1 | grep -oE 'account [A-Za-z0-9_-]+' | awk '{print $2}' | sort -u)"
  MISSID=""
  while read -r acct; do
    [ -n "$acct" ] || continue
    grep -qx "$acct" <<<"$HAVE" || MISSID="$MISSID$acct"$'\n'
  done <<EOF
$REQ_ACCTS
EOF
  if [ -n "$MISSID" ]; then
    drift "L4 not logged in as:"
    printf '%s' "$MISSID" | while read -r a; do [ -n "$a" ] && note "$a (gh auth login)"; done
  else
    pass "L4 all required identities present"
  fi
else
  # Identities ARE required here and we cannot check them. That is not drift — nothing has
  # been shown to differ. Say UNKNOWN, name the accounts, and let the RESULT line carry it.
  unknown "L4 gh not installed — required identities NOT verified (this is unknown, not drift)"
  printf '%s\n' "$REQ_ACCTS" | while read -r a; do [ -n "$a" ] && note "$a — declared by an upstream in this lock"; done
  note "Install gh and re-run, or accept that L4 was not checked on this machine."
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
# starter-kit/templates/tier2-org/install.sh:153-168 and in starter-kit/instance/install.sh's
# lock_shape_guard (ported there 2026-09-07 -- it had been MISSING from Tier 1's own instance
# installer, so that installer accepted a shape this very check refuses)
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
    if grep -qxF "$b" <<<"$DECLARED_HOOKS"; then
      continue
    fi
    if [ -d "$LIVE/hooks/$b" ] && grep -q "^$b/" <<<"$DECLARED_HOOKS"; then
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
    if grep -qF -- "$h" <<<"$L9CMDS"; then
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
  # A materialised plugin (install.plugins[]) is a REAL DIRECTORY under $LIVE/skills — the
  # personal skills-directory loader scans nothing else — so by shape it is OPAQUE. But it is
  # not undeclared: install.plugins names it, and L11 attests its provenance by diffing the
  # copy against the pin, which is stronger than the symlink target L10 reads for a skill.
  # Measured 2026-09-05 on the first laptop install that carried a plugin: L11 PASS, L12
  # PASS, and L10 DRIFT over the same directory — a check that lists what is present learnt
  # nothing when a new KIND of declaration was added beside it. The dest basename is the
  # declared name here.
  DECLARED_PLUGIN_DIRS="$(jq -r '(.install.plugins // [])[] | (.dest // "") | split("/") | last' "$LOCK")"
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
    # ⚠️ HERE-STRINGS, NOT PIPES. This script runs under `set -o pipefail`, and `grep -q` exits
    # on its first match — if `printf` is still writing when it does, printf takes SIGPIPE, the
    # pipeline is non-zero, and a DECLARED name reads as undeclared. Measured 2026-09-05 on a
    # Linux instance: the SAME record, the SAME code, LOCKED at 17:5x and two declared skills
    # reported as orphans at 18:59 — links this very install had just created. A here-string has
    # no second process to be interrupted. (The L8 hook check above had the same shape.)
    grep -qxF "$b" <<<"$DECLARED_SKILLS" && continue
    grep -qxF "$b" <<<"$DECLARED_PLUGIN_DIRS" && continue
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

# ---- L11: plugins — the materialised copy still matches the pin -------------
# ADDED for M-KITV2 B15. A personal skills-directory plugin (docs: "a
# .claude-plugin/plugin.json under ~/.claude/skills/<name>/ loads in every project")
# is a COPY, not a symlink — install.sh rsyncs/cp's the pinned plugin tree into
# $LIVE/skills/<name>/, and a copy can drift from its source silently in a way a
# symlink cannot: L5's `phys()` comparison, built for symlinks, would report a
# materialised plugin as "present" the instant it was installed and never again.
# This layer is the copy's honesty check — does the tree on disk still equal the
# tree at the pin, byte for byte, right now.
#
# Resolution mirrors install.sh's own, on purpose: only `upstream:<path>` is
# accepted as a source (a malformed lockfile is a finding here, not a shrug), and
# `dest` must resolve under `$LIVE/skills/` — the one directory the personal
# skills-directory loader scans. Two tools disagreeing about what a plugin
# declaration means is exactly the class of defect this whole file exists to catch.
echo "[L11] plugins materialise a copy that still matches the pin"
L11_PLUGIN_N="$(jq -r '(.install.plugins // []) | length' "$LOCK")"
if [ "$L11_PLUGIN_N" -eq 0 ]; then
  pass "L11 no plugins declared — nothing to check"
else
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pname="$(jq -r '.name // empty' <<<"$p")"
    psrc="$(jq -r '.source // empty' <<<"$p")"
    pdest="$(jq -r '.dest // empty' <<<"$p")"
    case "$psrc" in
      upstream:*) srcpath="$VENDOR/dark-factory/${psrc#upstream:}" ;;
      *) drift "L11 plugin $pname: source '$psrc' is not upstream:<path> — cannot verify"; continue ;;
    esac
    case "$pdest" in
      "~/.claude/skills/"*) destpath="$LIVE/skills/${pdest#\~/.claude/skills/}" ;;
      *) drift "L11 plugin $pname: dest '$pdest' is outside ~/.claude/skills/ — cannot verify"; continue ;;
    esac
    if [ ! -d "$destpath" ]; then
      drift "L11 plugin $pname: not installed ($destpath missing)"
      continue
    fi
    if [ ! -d "$srcpath" ]; then
      drift "L11 plugin $pname: pin source missing ($srcpath) — cannot verify"
      continue
    fi
    # ⛔ EXCLUDE NFS SILLY-RENAMES, 2026-09-08, AND THE RUN THAT MEASURES IS THE RUN THAT
    # CAUSES IT. On a box where ~/.claude is a symlink into shared NFS (every provisioned
    # Coder in the reference estate), install.sh's re-materialisation UNLINKS files under
    # $LIVE/skills/<plugin>/. NFS cannot unlink a file another process still holds open, so
    # it renames it aside as .nfsXXXXXXXX and keeps the ghost until the last fd closes.
    # `diff -r` then sees a file the pin does not have and this layer reports the plugin as
    # drifted when it is byte-identical.
    #
    # ⚠️ THE HOLDER IS USUALLY THIS ESTATE'S OWN MONITOR. Measured twice on 2026-09-08
    # (homelab Coder): the fd belonged to mission-tick.sh -- fd 255, bash's own script fd --
    # started by the very session running install.sh, mid-`sleep` on the copy being replaced.
    # The remedy that existed before this line was "kill the holder", which is operator
    # technique, and technique does not survive the next run: the monitor is armed by default,
    # so "install from a session with no monitors armed" is not a thing anyone can reliably do.
    #
    # A silly-rename is never plugin content -- it is a deleted inode with a witness. It
    # cannot be part of a pin, so excluding it costs this layer no honesty: a real extra file
    # in the materialised tree is still caught, and the ghost disappears on its own.
    # ⚠️ A gate that cries wolf on a green kit trains the reader to discount it. That is the
    # cost being paid here, not the noise.
    L11DIFF="$(diff -r --brief --exclude='.nfs*' "$srcpath" "$destpath" 2>&1)"
    if [ -n "$L11DIFF" ]; then
      drift "L11 plugin $pname: materialised copy does NOT match the pin:"
      printf '%s\n' "$L11DIFF" | head -5 | while IFS= read -r l; do note "$l"; done
      L11N="$(printf '%s\n' "$L11DIFF" | wc -l | tr -d ' ')"
      [ "$L11N" -gt 5 ] && note "... and $((L11N - 5)) more"
      note "run install.sh to re-materialise, or bump the pin if this is deliberate"
    else
      pass "L11 plugin $pname: materialised copy matches the pin"
    fi
  done < <(jq -c '(.install.plugins // [])[]' "$LOCK")
fi

echo ""

# ---- L12: plugin invariants suites -------------------------------------------
# ADDED for M-KITV2 B15. A materialised plugin CAN ship its own self-check —
# `tests/test-plugin-invariants.sh` at its root — for the properties this file
# cannot see from outside, e.g. "settings.json does not carry an `agent` key" (S-1
# in the kitv2/b4 measurement: an `agent` key there hijacks the main thread of a
# HEADLESS run too, silently, and exits 0). Running it is not optional if it ships:
# absent is reported, not assumed benign, and it is `unknown` rather than a pass —
# a plugin that ships no suite is not thereby proven to have no invariants.
echo "[L12] plugin invariants suites"
if [ "$L11_PLUGIN_N" -eq 0 ]; then
  unknown "L12 skipped: no plugins declared"
else
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pname="$(jq -r '.name // empty' <<<"$p")"
    pdest="$(jq -r '.dest // empty' <<<"$p")"
    case "$pdest" in
      "~/.claude/skills/"*) destpath="$LIVE/skills/${pdest#\~/.claude/skills/}" ;;
      *) unknown "L12 plugin $pname: dest is outside ~/.claude/skills/ — cannot locate a suite"; continue ;;
    esac
    L12SUITE="$destpath/tests/test-plugin-invariants.sh"
    if [ ! -f "$L12SUITE" ]; then
      unknown "L12 skipped: plugin $pname ships no invariants suite"
      continue
    fi
    L12OUT="$(bash "$L12SUITE" 2>&1)"; L12RC=$?
    if [ "$L12RC" -eq 0 ]; then
      pass "L12 plugin $pname: invariants suite passed"
    else
      drift "L12 plugin $pname: invariants suite FAILED (exit $L12RC):"
      printf '%s\n' "$L12OUT" | tail -3 | while IFS= read -r l; do note "$l"; done
    fi
  done < <(jq -c '(.install.plugins // [])[]' "$LOCK")
fi

echo ""

# ---- L13: estate MCP declared and present ------------------------------------
# ADDED for M-KITV2 B24. Which servers in ~/.claude.json (or which claude.ai CONNECTOR)
# actually serve a given estate is a MACHINE fact -- recorded, when known, as
# `mcp.profiles.<estate>` in this lockfile (see the starter-kit template's `$comment`). Before
# this layer, nothing verified that record against reality: a stale `hubs` list, or a
# connector that had quietly disconnected, would sit in the lockfile looking authoritative
# forever, because df-worker's own NAME-PREFIX fallback would keep finding SOMETHING to
# launch with and never say the declared source was wrong.
#
# ⚠️ THE THREE-WAY VERDICT MATTERS MORE HERE THAN ANYWHERE ELSE IN THIS FILE. `kind: hubs` is
# checked purely from the lockfile and ~/.claude.json -- no network, so its verdict is always
# ok/drift, never unknown. `kind: connector` needs a LIVE `claude mcp list`, so a machine with
# no `claude` on PATH (or one where the listing itself fails) can say NOTHING about whether the
# connector is actually connected -- that is UNKNOWN, never a silent pass and never drift.
#
# `LOCK_VERIFY_CLAUDE_BIN` exists for the same reason `LOOM_LIVE` does: a suite must not shell
# out to the real `claude` on the machine running the tests, so a stub binary can be named by
# this variable exactly as `LOOM_LIVE` redirects the hooks/skills root.
echo "[L13] estate MCP declared and present"
CLAUDE_JSON="${LOOM_CLAUDE_JSON:-$HOME/.claude.json}"
CLAUDE_BIN="${LOCK_VERIFY_CLAUDE_BIN:-claude}"

# ⛔ MEASUREMENT PROVENANCE, added because a project-scope `.mcp.json` server's approval is
# per DIRECTORY, stored in the workspace-LOCAL `~/.claude.json` -- so an operator who approved
# a server in one directory and a DRIFT printed by a check run from another are two different
# facts about two different places, and until now a DRIFT here named neither. `cwd` says where
# THIS run measured from; the approval map says every directory THIS machine's ~/.claude.json
# actually has an approval recorded in, so the two can be told apart at a glance instead of
# re-derived by hand after the fact.
l13_provenance() {  # $1 = what was read/run to produce this drift (a file list or a command)
  note "measured from cwd: $PWD; listing/config read: $1"

  # ⛔ EXTENDED 2026-09-09, MEASURED ON A PROVISIONED CODER WORKSPACE. A project-scope
  # `.mcp.json` server's approval was found NOT in $CLAUDE_JSON's own `.projects` map (every
  # entry there was `[]` on the box measured) but as `enabledMcpjsonServers` in the STARTING
  # DIRECTORY's own `<dir>/.claude/settings.local.json`. Both kinds of source are real and
  # neither alone is the whole answer, so both are read: $CLAUDE_JSON's `.projects` map, AND
  # `.claude/settings.local.json` under $PWD, every ancestor of $PWD up to $HOME inclusive,
  # $HOME itself, and every directory $CLAUDE_JSON's own `.projects` map names — the same set
  # of directories a real approval could actually have been written into.
  l13_emit() {  # $1 = dir  $2 = names (comma-joined)  $3 = source file
    case $'\n'"$L13_EMITTED_DIRS"$'\n' in
      *$'\n'"$1"$'\n'*) return ;;  # already emitted for this dir — dedup by directory
    esac
    L13_EMITTED_DIRS="$L13_EMITTED_DIRS"$'\n'"$1"
    L13_ANY=1
    note "approved in $1: $2  (via $3)"
  }
  L13_EMITTED_DIRS=""
  L13_ANY=0

  L13_APPROVED=""
  if [ -f "$CLAUDE_JSON" ]; then
    L13_APPROVED="$(jq -r '
      (.projects // {}) | to_entries[]
      | select((.value.enabledMcpjsonServers // []) | length > 0)
      | [.key, (.value.enabledMcpjsonServers | join(", "))] | @tsv
    ' "$CLAUDE_JSON" 2>/dev/null)"
  fi
  if [ -n "$L13_APPROVED" ]; then
    while IFS=$'\t' read -r l13dir l13names; do
      [ -n "$l13dir" ] || continue
      l13_emit "$l13dir" "$l13names" "$CLAUDE_JSON"
    done <<<"$L13_APPROVED"
  fi

  # Candidate directories for a per-directory .claude/settings.local.json: cwd, every ancestor
  # of cwd up to $HOME, $HOME itself, and every project key $CLAUDE_JSON names.
  L13_DIRS=""
  d="$PWD"
  while :; do
    L13_DIRS="$L13_DIRS"$'\n'"$d"
    [ "$d" = "$HOME" ] && break
    [ "$d" = "/" ] && break
    l13parent="$(dirname "$d")"
    [ "$l13parent" = "$d" ] && break
    d="$l13parent"
  done
  L13_DIRS="$L13_DIRS"$'\n'"$HOME"
  if [ -f "$CLAUDE_JSON" ]; then
    while IFS= read -r l13pdir; do
      [ -n "$l13pdir" ] && L13_DIRS="$L13_DIRS"$'\n'"$l13pdir"
    done < <(jq -r '(.projects // {}) | keys[]' "$CLAUDE_JSON" 2>/dev/null)
  fi

  L13_SEEN=""
  while IFS= read -r l13cand; do
    [ -n "$l13cand" ] || continue
    case $'\n'"$L13_SEEN"$'\n' in
      *$'\n'"$l13cand"$'\n'*) continue ;;  # already checked this directory
    esac
    L13_SEEN="$L13_SEEN"$'\n'"$l13cand"
    L13_SL="$l13cand/.claude/settings.local.json"
    [ -f "$L13_SL" ] || continue
    L13_SL_NAMES="$(jq -r '(.enabledMcpjsonServers // []) | select(length > 0) | join(", ")' \
      "$L13_SL" 2>/dev/null)"
    [ -n "$L13_SL_NAMES" ] || continue
    l13_emit "$l13cand" "$L13_SL_NAMES" "$L13_SL"
  done <<<"$L13_DIRS"

  if [ "$L13_ANY" -eq 0 ]; then
    note "no directory in $CLAUDE_JSON or any .claude/settings.local.json has enabledMcpjsonServers — nothing is approved anywhere on this box"
  fi
}
L13_PROFILES="$(jq -r '(.mcp.profiles // {}) | keys[] | select(startswith("$") | not)' "$LOCK")"
if [ -z "$L13_PROFILES" ]; then
  note "L13 mcp.profiles undeclared — prefix rule in force; declare it to make each estate's MCP source verifiable"
else
  L13_LISTED=0
  L13_LIST_OUT=""
  L13_LIST_OK=0
  while IFS= read -r prof; do
    [ -n "$prof" ] || continue
    kind="$(jq -r --arg p "$prof" '.mcp.profiles[$p].kind // empty' "$LOCK")"
    case "$kind" in
      hubs)
        # ⛔ SEARCH EVERY PLACE A HUB CAN LIVE, 2026-09-08, AND SAY WHICH ONES WERE SEARCHED.
        # This check used to read ~/.claude.json ALONE and report "server(s) missing from
        # <that file>" otherwise. Measured on a provisioned Coder workspace (homelab k3s): the
        # box was FULLY configured -- two synapse hubs with bearer tokens, materialised from
        # shared storage into ~/.mcp.json -> ~/.config/loom/mcp-config.json -- and L13 called
        # it missing. The verdict was a fact about ONE FILE reported as a fact about MCP.
        #
        # ⚠️ AND THE MESSAGE MADE THE BUG WORSE THAN THE LOGIC. Naming only ~/.claude.json
        # tells the reader where to "fix" it, so the natural repair is to COPY the bearer token
        # into ~/.claude.json -- duplicating a secret away from its shared-storage source of
        # truth to satisfy a checker. A check that names one location teaches people to put
        # things there.
        #
        # ⚠️ ~/.claude.json IS WORKSPACE-LOCAL ON THESE BOXES while ~/.claude is a symlink into
        # shared NFS. So hub CONFIG persists fleet-wide and per-project APPROVAL does not --
        # see the approval note under `connector` below, which applies to .mcp.json servers too.
        L13BAD=""
        L13_MCP_JSON="${LOOM_MCP_JSON:-$HOME/.mcp.json}"
        L13_SEARCHED="$CLAUDE_JSON"
        [ -f "$L13_MCP_JSON" ] && L13_SEARCHED="$L13_SEARCHED, $L13_MCP_JSON"
        while IFS= read -r srv; do
          [ -n "$srv" ] || continue
          if [ -f "$CLAUDE_JSON" ] && jq -e --arg s "$srv" '.mcpServers[$s]' "$CLAUDE_JSON" >/dev/null 2>&1
          then :
          elif [ -f "$L13_MCP_JSON" ] && jq -e --arg s "$srv" '.mcpServers[$s]' "$L13_MCP_JSON" >/dev/null 2>&1
          then :
          else L13BAD="$L13BAD$srv"$'\n'
          fi
        done < <(jq -r --arg p "$prof" '(.mcp.profiles[$p].servers // [])[]' "$LOCK")
        if [ -n "$L13BAD" ]; then
          drift "L13 profile $prof (hubs): server(s) not found in any of: $L13_SEARCHED"
          printf '%s' "$L13BAD" | while read -r n; do [ -n "$n" ] && note "$n"; done
          l13_provenance "$L13_SEARCHED"
          note "⚠️ On a PROVISIONED box (Coder), hub config is materialised from shared storage"
          note "   into ~/.mcp.json and is NOT hand-merged into ~/.claude.json. If that is this"
          note "   machine, the right record is kind: \"connector\" -- which verifies the LIVE"
          note "   connected state -- not kind: \"hubs\" plus a copied bearer token."
        else
          pass "L13 profile $prof (hubs): every declared server is present"
        fi
        ;;
      connector)
        if [ "$L13_LISTED" -eq 0 ]; then
          L13_LISTED=1
          if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
            L13_LIST_OUT="$("$CLAUDE_BIN" mcp list 2>&1)" && L13_LIST_OK=1
          fi
        fi
        srv="$(jq -r --arg p "$prof" '(.mcp.profiles[$p].servers // [])[0] // empty' "$LOCK")"
        if [ "$L13_LIST_OK" -ne 1 ]; then
          unknown "L13 profile $prof (connector): could not run '$CLAUDE_BIN mcp list' — probe could not run"
        elif [ -z "$srv" ]; then
          drift "L13 profile $prof (connector): mcp.profiles.$prof declares no server name"
        else
          L13FOUND=0
          while IFS= read -r ln; do
            case "$ln" in
              "$srv"*) case "$ln" in *Connected*) L13FOUND=1 ;; esac ;;
            esac
          done <<<"$L13_LIST_OUT"
          if [ "$L13FOUND" -eq 1 ]; then
            pass "L13 profile $prof (connector): $srv is Connected"
          else
            drift "L13 profile $prof (connector): no line starting with '$srv' and containing Connected in '$CLAUDE_BIN mcp list'"
            l13_provenance "'$CLAUDE_BIN mcp list'"
            # ⚠️ THE APPROVAL CAVEAT, and it is the most likely cause of this line on a freshly
            # provisioned box. Servers declared in a project-scope .mcp.json arrive as
            # "Pending approval", not Connected. Approval happens ONCE, INTERACTIVELY, in a real
            # `claude` session -- there is no non-interactive approve (only
            # `claude mcp reset-project-choices`).
            #
            # ⛔ CORRECTED 2026-09-09, MEASURED ON A PROVISIONED CODER WORKSPACE. This block used
            # to say the approval "lives in workspace-local ~/.claude.json". WRONG on the version
            # measured: `~/.claude.json` .projects[*].enabledMcpjsonServers was `[]` for EVERY
            # project on that box, while the operator's approval of the very servers a DRIFT here
            # names existed as `enabledMcpjsonServers` in the STARTING DIRECTORY's own
            # `.claude/settings.local.json`. `claude mcp list` is a SEPARATE PROCESS that carries
            # no session state and reflects neither file either way.
            #
            # ⚠️ AND IF THIS BOX'S SESSIONS ACTUALLY HAVE WORKING HUBS, THIS DRIFT IS NOT ABOUT
            # APPROVAL AT ALL -- it is the RECORD's `kind` being wrong. A hub declared in
            # `~/.mcp.json` (see L13 `hubs`, above) verifies by FILE PRESENCE alone; no approval
            # is involved. `kind: connector` is for an actual claude.ai CONNECTOR, which appears
            # in no file. A `kind: connector` DRIFT on a box whose sessions have working hubs
            # means the record should say `kind: "hubs"` instead — chasing an approval here
            # chases a problem that was never the real one.
            note "if this box is provisioned (Coder): the servers may be PENDING APPROVAL, not absent."
            note "approve once in an interactive 'claude' session — there is no non-interactive"
            note "approve. The approval is recorded in the STARTING DIRECTORY's own"
            note "'.claude/settings.local.json' (enabledMcpjsonServers), NOT ~/.claude.json --"
            note "'claude mcp list' is a separate process and reflects neither file."
            note "if this box's sessions actually have working hubs, this DRIFT is the record's"
            note "kind being wrong: a hub declared in ~/.mcp.json verifies by file presence, no"
            note "approval involved -- the right record here is kind: \"hubs\", not connector."
          fi
        fi
        ;;
      *)
        drift "L13 profile $prof: unrecognised kind '${kind:-<absent>}' — expected hubs or connector"
        ;;
    esac
  done <<<"$L13_PROFILES"
fi

# ---- L14: marketplace plugins — present, enabled, and still the version we got ----
# ADDED 2026-09-08, and it exists because `install.marketplacePlugins` is the one thing this
# kit installs that it CANNOT PIN. `claude plugin install` takes no version argument
# (measured against the real CLI): every machine gets LATEST at whatever moment it ran. So
# install.sh records the RESOLVED version into `probed.marketplacePlugins`, and this layer is
# the half that makes that recording worth anything — without it, the record is a number
# nobody ever reads back.
#
# ⚠️ WHAT THIS LAYER CAN AND CANNOT CLAIM. It cannot say the installed code is correct: there
# is no pin to diff against, so nothing here is L11's byte-for-byte check. It says three
# weaker things that are still worth saying — the plugin is THERE, it is ENABLED, and its
# version has not MOVED since the day this machine installed it. Calling that a pin, in the
# output or in anyone's head, is the failure this layer is trying to prevent.
#
# ⚠️ INSTALLED IS NOT ENABLED, and the difference is invisible in the filesystem. Measured on
# a real laptop: `plugin list --json` carries entries with "enabled": false — on disk, in
# installed_plugins.json, loading nothing. A check that only asked "is it installed" would
# pass on a machine where the plugin does nothing at all.
echo "[L14] marketplace plugins present, enabled, and unmoved since install"
L14_CLAUDE="${LOCK_VERIFY_CLAUDE_BIN:-claude}"
L14_N="$(jq -r '(.install.marketplacePlugins // []) | length' "$LOCK")"
if [ "$L14_N" -eq 0 ]; then
  pass "L14 no marketplace plugins declared — nothing to check"
elif ! command -v "$L14_CLAUDE" >/dev/null 2>&1; then
  # UNKNOWN, not drift: the plugins may be perfectly installed. Nothing here can see.
  unknown "L14 '$L14_CLAUDE' is not on PATH — the only surface that lists these could not be read"
else
  L14_LIST="$("$L14_CLAUDE" plugin list --json 2>/dev/null)"
  if [ -z "$L14_LIST" ]; then
    unknown "L14 '$L14_CLAUDE plugin list --json' returned nothing — probe could not run"
  else
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      l14name="$(jq -r '.name // empty' <<<"$m")"
      l14mkt="$(jq -r '.marketplace // empty' <<<"$m")"
      if [ -z "$l14name" ] || [ -z "$l14mkt" ]; then
        drift "L14 entry missing name or marketplace — install.sh refuses this shape too"
        continue
      fi
      l14id="$l14name@$l14mkt"
      l14live="$(printf '%s' "$L14_LIST" | jq -c --arg id "$l14id" \
        'map(select(.id == $id)) | .[0] // empty' 2>/dev/null)"
      if [ -z "$l14live" ]; then
        drift "L14 $l14id: declared but NOT installed — run install.sh"
        continue
      fi
      if [ "$(jq -r '.enabled // false' <<<"$l14live")" != "true" ]; then
        drift "L14 $l14id: installed but DISABLED — on disk, loading nothing"
        continue
      fi
      l14now="$(jq -r '.version // "unknown"' <<<"$l14live")"
      l14was="$(jq -r --arg id "$l14id" '.probed.marketplacePlugins[$id].version // empty' "$LOCK")"
      if [ -z "$l14was" ]; then
        # Genuinely UNKNOWN for the question this layer asks. The plugin is present and
        # enabled — but with no recorded baseline there is no such thing as "moved", and
        # saying ok would claim a check that never happened.
        unknown "L14 $l14id: installed and enabled, but no recorded version — re-run install.sh to record one"
      elif [ "$l14was" != "$l14now" ]; then
        drift "L14 $l14id: version MOVED since install — recorded $l14was, now $l14now"
        note "this is not a broken machine. It is what unpinnable means: LATEST moved under you."
        note "if the new version is wanted, re-run install.sh so probed records it and this clears."
      else
        pass "L14 $l14id: enabled, version $l14now — unchanged since install"
      fi
    done < <(jq -c '(.install.marketplacePlugins // [])[]' "$LOCK")
  fi
fi

echo ""

# ---- L15: session deny list — estates other records name, this one does not -----------
# ADDED alongside the session-deny delivery path (mcp-profile-config.py --session-deny,
# wire-settings.py --deny-file, rehydrate.sh step 4b). L13 above verifies THIS machine's own
# declared MCP source; it says nothing about every OTHER estate the kit's records name. This
# layer is the check that rehydrate.sh step 4b's write actually took: derive the SAME list a
# session should deny, then read the LIVE settings back and confirm each entry is really
# there — a derivation with nothing to compare it against would just be a second copy of the
# same claim, so both the tmp file this layer writes and the settings files are always read
# fresh, not from what an earlier layer already loaded.
echo "[L15] session deny list"
if ! command -v python3 >/dev/null 2>&1; then
  unknown "L15 session deny: python3 required — could not derive the list"
else
  L15_MPC="$SELFDIR/mcp-profile-config.py"
  if [ ! -f "$L15_MPC" ]; then
    unknown "L15 session deny: mcp-profile-config.py not beside this script — could not derive the list"
  else
    L15_TMP="$(mktemp "${TMPDIR:-/tmp}/l15-session-deny.XXXXXX.json")"
    # ⚠️ $REPO, NOT $ROOT. $ROOT is the directory holding whichever lockfile --lock named --
    # for an INSTANCE lockfile that is $ROOT/instances/x, one level too deep to see the root
    # lockfile or any sibling instance beside it. $REPO is the engine root this whole file
    # already climbs to once, at the top (the same directory L10 resolves `local:` sources
    # against) -- and it is exactly the directory kit_records() expects: root *.lock.json
    # files directly under it, instances/*/loom.lock.json beneath that.
    L15_ERR="$(python3 "$L15_MPC" --session-deny "$L15_TMP" --lock "$LOCK" --kit-root "$REPO" 2>&1 >/dev/null)"
    L15_RC=$?
    if [ "$L15_RC" -ne 0 ]; then
      L15_FIRST="$(printf '%s\n' "$L15_ERR" | head -1)"
      unknown "L15 session deny: could not derive the list — $L15_FIRST"
    else
      L15_WANT="$(jq -r '(.deniedMcpServers // [])[].serverName // empty' "$L15_TMP" 2>/dev/null)"
      if [ -z "$L15_WANT" ]; then
        pass "L15 session deny: nothing to deny (no other record names an estate this one does not)"
      else
        # UNION of settings.json and settings.local.json — deniedMcpServers merges from every
        # settings scope, so a name present in either is denied for the session, not just one.
        L15_HAVE="$(
          { [ -f "$LIVE/settings.json" ] && jq -r '(.deniedMcpServers // [])[].serverName // empty' "$LIVE/settings.json" 2>/dev/null
            [ -f "$LIVE/settings.local.json" ] && jq -r '(.deniedMcpServers // [])[].serverName // empty' "$LIVE/settings.local.json" 2>/dev/null
          } | sort -u
        )"
        L15_N=0
        L15_MISSING=""
        while IFS= read -r l15name; do
          [ -n "$l15name" ] || continue
          L15_N=$((L15_N + 1))
          if ! grep -qxF "$l15name" <<<"$L15_HAVE"; then
            L15_MISSING="$L15_MISSING$l15name"$'\n'
          fi
        done <<<"$L15_WANT"
        if [ -z "$L15_MISSING" ]; then
          pass "L15 session deny: $L15_N server(s) other records name are denied for sessions here"
        else
          L15_M="$(printf '%s' "$L15_MISSING" | grep -c .)"
          drift "L15 session deny: $L15_M server(s) other records name are NOT denied for sessions here"
          printf '%s' "$L15_MISSING" | while IFS= read -r l15m; do [ -n "$l15m" ] && note "$l15m"; done
          note "rehydrate.sh step 4b / install.sh writes them; until then a hand-rolled session here can reach them"
        fi
      fi
    fi
    rm -f "$L15_TMP"
  fi
fi

echo ""
if [ "$DRIFT" -eq 0 ]; then
  if [ "$UNVERIFIED" -gt 0 ] || [ "$UNKNOWN" -gt 0 ]; then
    # Not the same claim as LOCKED: everything checkable passed, but something was never
    # actually checked. Say so, or offline becomes false assurance. The two classes are
    # named separately because they have different remedies: a pin needs the network, an
    # unknown check needs a binary.
    qual=""
    [ "$UNVERIFIED" -gt 0 ] && qual="$UNVERIFIED pin(s) UNVERIFIED against the remote (offline?)"
    [ "$UNKNOWN" -gt 0 ] && qual="${qual:+$qual; }$UNKNOWN check(s) UNKNOWN — could not be probed on this machine"
    echo "=== RESULT: LOCKED (locally) — $qual ==="
  else
    echo "=== RESULT: LOCKED — this instance matches its lockfile ==="
  fi
  # ⚠️ NAME THE PIN IN THE VERDICT. Operator request 2026-09-05, and it closes a real gap:
  # "a run on this laptop is not hermetic", so two LOCKED results taken at different times
  # against DIFFERENT Tier-1 pins are indistinguishable on their face. A validation report that
  # says LOCKED without saying WHICH commit it measured cannot be compared with another one —
  # and this estate spent a whole day on results that were true of one pin and quoted about
  # another. The verdict now carries its own subject.
  _lv_pin="$(jq -r '(.upstreams["dark-factory"].commit // empty)' "$LOCK" 2>/dev/null)"
  [ -n "$_lv_pin" ] && echo "    measured against dark-factory ${_lv_pin:0:12}  (lock: $LOCK)"
  # EXIT 0, DELIBERATELY, AND THIS IS THE JUDGEMENT CALL WORTH ARGUING WITH.
  # An unknown is not a failure: nothing has been shown to differ, so blocking here would
  # re-create the exact bug this change removes, one layer up. It stays 0 rather than
  # borrowing df-preflight's rc=2-means-unknowns convention because callers here
  # (rehydrate.sh, install.sh, CI) test `-eq 0`, and silently turning a passing install
  # into a non-zero exit is a breaking change dressed as a correctness fix.
  # ⚠️ THE COST: a caller that reads only the exit code cannot tell LOCKED from
  # LOCKED-with-unknowns. The RESULT line is the only place that distinction lives. Any
  # caller that must not proceed on an unverified identity has to read the text, or this
  # script needs a --strict flag. Aligning the two tools on 0/1/2 is the right long-term
  # answer and it is a deliberate follow-up, not an oversight.
  exit 0
else
  echo "=== RESULT: DRIFT ==="
  echo "Rehydrate:  bash \"$SELFDIR/rehydrate.sh\"   (lock -> machine)"
  echo "Re-pin:     edit loom.lock.json        (deliberate; never automatic)"
  exit 1
fi
