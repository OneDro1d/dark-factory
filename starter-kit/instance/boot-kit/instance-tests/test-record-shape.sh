#!/usr/bin/env bash
# test-record-shape.sh — every lockfile in THIS instance is a record something could install.
#
# WHY THIS SUITE EXISTS, AND WHY IT IS THE ONE A TIER-3 REPO OWES. A Tier-3 instance holds
# almost no code: the thing it owns outright is its LOCKFILE, and until now nothing checked
# one at rest. The checks that exist all need a machine — `install.sh` refuses a bad shape
# while installing, `lock-verify` compares a record against the box it is standing on. Both
# are the right checks and both arrive TOO LATE to stop a broken record being committed,
# pushed, and pulled by somebody else's laptop.
#
# ⚠️ THE ASYMMETRY THIS CLOSES IS MEASURED, NOT HYPOTHETICAL. `test-lock-verify-l7-shape.sh`
# in Tier 1 states the contract: "a lockfile install.sh would refuse outright must not verify
# as LOCKED — a verifier more permissive than the installer is how 'in sync' comes to mean two
# different things in one estate." This suite is the third position: refuse it in CI, before
# either of them ever sees it.
#
# ⚠️ WHAT IT DELIBERATELY DOES NOT DO. It never installs, never touches $HOME, never reaches
# the network, and never claims the record is TRUE of any machine — a lockfile can be
# perfectly shaped and describe a box that does not exist. Only `lock-verify` on the target
# machine can say that, and this suite passing must never be read as that claim.
#
# Run:  bash boot-kit/tests/test-record-shape.sh
# Exit: 0 every lockfile is well-formed · 1 at least one is not · 2 the harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${RECORD_ROOT:-$(cd "$SELF/../.." && pwd)}"
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }

# Every lockfile this repo carries: the root record (the machine the repo is named for) plus
# one per directory under instances/. Found by SHAPE, never by a hard-coded name — one live
# record in this estate is called `delia.lock.json`, and a glob on `loom.lock.json` silently
# checks nothing there while reporting success.
LOCKS="$(find "$ROOT" -maxdepth 3 -name '*.lock.json' \
          -not -path "*/vendor/*" -not -path "*/.git/*" -not -path "*/workers/*" 2>/dev/null | sort)"

if [ -z "$LOCKS" ]; then
  # ⚠️ TWO SITUATIONS LOOK IDENTICAL HERE AND ONLY ONE IS A DEFECT. This file lives in Tier 1's
  # instance TEMPLATE as well as in every instance minted from it, and the template legitimately
  # holds `loom.lock.json.template` and no record — there is no machine to describe yet. An
  # INSTANCE with no lockfile is the broken case: the lockfile is the only thing that makes the
  # directory an instance at all. Distinguish them rather than picking one and being wrong in
  # the other place.
  if [ -f "$ROOT/loom.lock.json.template" ]; then
    ok "this is the instance TEMPLATE, not a record — no lockfile to check, and that is correct"
  else
    bad "no *.lock.json found under $ROOT" "a Tier-3 record without a lockfile records nothing"
  fi
  printf '\nrecord shape: %d ok, %d failed\n' "$PASS" "$FAIL"
  printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

for L in $LOCKS; do
  rel="${L#$ROOT/}"
  printf '\n== %s\n' "$rel"

  if ! jq -e . "$L" >/dev/null 2>&1; then
    bad "$rel: is not valid JSON" "nothing downstream can read it — fix this first"
    continue
  fi
  ok "$rel: valid JSON"

  # ---- the pin ---------------------------------------------------------------
  # A pin is a COMMIT SHA. Never a branch: a branch moves under you between two installs of
  # the "same" instance, and it moves most while it is under review — exactly when people
  # onboard onto it. A surviving __T1_COMMIT__ placeholder is bootstrap saying out loud that
  # it could not reach the remote; it is a record nothing can check out, so it fails here
  # rather than at install time on somebody else's machine.
  pin="$(jq -r '.upstreams["dark-factory"].commit // empty' "$L")"
  case "$pin" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      ok "$rel: dark-factory pin is a full commit sha" ;;
    "")   bad "$rel: declares no dark-factory pin" "upstreams[\"dark-factory\"].commit is missing" ;;
    __*__) bad "$rel: pin is still the placeholder $pin" "bootstrap could not resolve it — nothing can check this out" ;;
    *)    bad "$rel: pin '$pin' is not a 40-character sha" "a branch or short sha moves under you between installs" ;;
  esac

  # ---- the shape guard, at rest ----------------------------------------------
  # install.sh REFUSES a map here (the pre-split shape, where a name could exist with no
  # source and a source with no name — the two states that install nothing while reading like
  # a declaration). Refusing it in CI is the same rule one step earlier.
  shape_bad=0
  for k in skills hooks plugins marketplacePlugins; do
    t="$(jq -r --arg k "$k" '.install[$k] | type' "$L" 2>/dev/null)"
    case "$t" in
      array|null) ;;
      *) bad "$rel: install.$k is '$t', expected an array" "install.sh refuses this shape outright"; shape_bad=1 ;;
    esac
  done
  [ "$shape_bad" -eq 0 ] && ok "$rel: install.{skills,hooks,plugins,marketplacePlugins} are arrays or absent"

  # ---- declarations and sources agree, both directions ------------------------
  # Either half alone installs nothing while still reading like a declaration. Keys beginning
  # with `$` are prose for the human, never entries — a check that forgets that reports the
  # documentation as a broken source, and a warning that is wrong on every correct lockfile
  # is the fastest way to teach somebody to skip warnings.
  for kind in skill hook; do
    plural="${kind}s"
    orphan="$(jq -r --arg p "$plural" --arg s "${kind}Sources" '
      (.install[$p] // []) - ((.install[$s] // {}) | keys | map(select(startswith("$") | not)))
      | .[]' "$L" 2>/dev/null)"
    unused="$(jq -r --arg p "$plural" --arg s "${kind}Sources" '
      (((.install[$s] // {}) | keys | map(select(startswith("$") | not))) - (.install[$p] // []))
      | .[]' "$L" 2>/dev/null)"
    if [ -n "$orphan" ]; then
      bad "$rel: ${plural} declared with no source" "$(printf '%s' "$orphan" | tr '\n' ' ')"
    elif [ -n "$unused" ]; then
      bad "$rel: ${kind}Sources entries nothing declares" "$(printf '%s' "$unused" | tr '\n' ' ')"
    else
      ok "$rel: every $kind has a source and every source has a $kind"
    fi
  done

  # ---- plugins: one pin, one home --------------------------------------------
  # `upstream:` only — a `local:` or bare path would materialise an unpinned tree under the
  # banner of a lockfile that claims one pin. dest under ~/.claude/skills/ only — that is the
  # one directory the personal skills-directory loader scans, so anywhere else is a copy that
  # loads in no session.
  pbad=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pn="$(jq -r '.name // "<unnamed>"' <<<"$p")"
    ps="$(jq -r '.source // empty' <<<"$p")"
    pd="$(jq -r '.dest // empty' <<<"$p")"
    case "$ps" in upstream:*) ;; *) bad "$rel: plugin $pn source '$ps' is not upstream:<path>" "install.sh refuses it"; pbad=1 ;; esac
    case "$pd" in "~/.claude/skills/"*) ;; *) bad "$rel: plugin $pn dest '$pd' is outside ~/.claude/skills/" "nothing would load it"; pbad=1 ;; esac
  done < <(jq -c '(.install.plugins // [])[]' "$L" 2>/dev/null)
  [ "$pbad" -eq 0 ] && ok "$rel: every plugin is pinned upstream: and lands under ~/.claude/skills/"

  # ---- marketplace plugins: installable somewhere other than the author's box --
  # ⚠️ THESE CANNOT BE VERSION-PINNED AND THIS SUITE DOES NOT PRETEND OTHERWISE. `claude
  # plugin install` takes no version argument; the resolved version is recorded in
  # `probed.marketplacePlugins` after the fact and lock-verify L14 reports it moving. What IS
  # checkable at rest is that the entry names a plugin, names a marketplace, and installs at
  # user scope — and that it carries the marketplace SOURCE, without which the install fails
  # on any machine whose config dir has not already been taught that marketplace by hand.
  mbad=0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    mn="$(jq -r '.name // empty' <<<"$m")"
    mm="$(jq -r '.marketplace // empty' <<<"$m")"
    ms="$(jq -r '.marketplaceSource // empty' <<<"$m")"
    msc="$(jq -r '.scope // "user"' <<<"$m")"
    [ -n "$mn" ] || { bad "$rel: a marketplacePlugins entry has no name"; mbad=1; continue; }
    [ -n "$mm" ] || { bad "$rel: marketplace plugin $mn names no marketplace"; mbad=1; continue; }
    [ "$msc" = "user" ] || { bad "$rel: marketplace plugin $mn scope '$msc'" "only 'user' installs a MACHINE fact"; mbad=1; }
    [ -n "$ms" ] || { bad "$rel: marketplace plugin $mn has no marketplaceSource" "a fresh config dir knows NO marketplaces — not even the official one — so this installs only where somebody already added it by hand"; mbad=1; }
  done < <(jq -c '(.install.marketplacePlugins // [])[]' "$L" 2>/dev/null)
  [ "$mbad" -eq 0 ] && ok "$rel: every marketplace plugin is installable on a machine that has never seen it"

  # ---- no secrets ------------------------------------------------------------
  # A lockfile is committed and, for the kits, shared. A token here is published the moment
  # somebody pushes. Shapes only — this is not a substitute for the publish gate, and it says
  # so rather than implying coverage it does not have.
  if jq -r '..|strings' "$L" 2>/dev/null \
     | grep -Eq 'gh[pousr]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-|-----BEGIN [A-Z ]*PRIVATE KEY'; then
    bad "$rel: contains a secret-shaped string" "a lockfile is committed — rotate it, do not just delete the line"
  else
    ok "$rel: no secret-shaped strings"
  fi
done

printf '\nrecord shape: %d ok, %d failed\n' "$PASS" "$FAIL"
# run-tests.sh treats a suite that exits 0 with no declared count as UNMEASURED, not a pass.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
