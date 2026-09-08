#!/usr/bin/env bash
# test-install-marketplace-plugins.sh — install.sh step 3c installs `install.marketplacePlugins[]`
# through the Claude CLI, records the RESOLVED version into `probed.marketplacePlugins`, and
# refuses the shapes that would install nothing or install somewhere unverifiable.
#
# WHY THIS EXISTS, AND WHY IT IS A SEPARATE SUITE FROM test-install-plugins.sh. Those two keys
# share the word "plugin" and behave oppositely. `install.plugins` materialises a COPY of a
# tree inside this lockfile's Tier-1 pin — pinned, diffable, and that suite proves the copy.
# `install.marketplacePlugins` shells out to `claude plugin install`, which was MEASURED
# 2026-09-08 to accept no version argument at all: it installs LATEST, on every machine, every
# time. The whole design turns on that one fact, so the behaviour under test here is not "did
# the right bytes land" — nothing can know that — but "was it installed, was the version we
# actually got WRITTEN DOWN, and did an entry that could not be verified get refused".
#
# THE CLI IS STUBBED, DELIBERATELY AND WITHOUT APOLOGY. `DF_CLAUDE_BIN` exists in install.sh
# for exactly this, the way `LOOM_LIVE` and `LOOM_BIN` exist for the other steps: a suite that
# shelled out to the real `claude` would fetch from the network, mutate the real
# ~/.claude/settings.json (measured: `marketplace add` writes `extraKnownMarketplaces` and
# `install` writes `enabledPlugins` there), and could never assert a failure path at all. The
# stub logs every argv it is handed, so "did install.sh call the CLI, with what, and in what
# order" is itself checkable — including the case where it must call NOTHING.
#
# ⚠️ WHAT THIS SUITE CANNOT PROVE, stated so nobody reads a green run as more than it is: that
# the real CLI still behaves the way the stub imitates. That is a fact about someone else's
# binary and it can change under us. It was measured by hand on 2026-09-08 — install and
# marketplace-add both idempotent and exit 0 on a second run, a fresh config dir starting with
# ZERO marketplaces configured (the official one included), and a fresh install arriving
# enabled. Re-measure before trusting those lines again; a stub agrees with whatever it was
# written to agree with.
#
# Usage: bash starter-kit/instance/tests/test-install-marketplace-plugins.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"
INSTALL_SRC="$KIT/install.sh"
[ -f "$INSTALL_SRC" ] || { echo "missing $INSTALL_SRC"; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "jq required";  exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output" ;; *) ok "$1" ;; esac; }
eqstr()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/instmkt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
GITC=(-c user.email=test@example.com -c user.name=test)

# mk_instance <case> <install-json> — a fixture "Tier 1" (a real, local, offline git repo) with
# a no-op lock-verify.sh, so step 5 cannot itself flip the exit code and confound the refusal
# assertions; plus a fresh instance root carrying the given `install` block.
mk_instance() {
  local c="$1" ins="$2" d="$WORK/$1"
  mkdir -p "$d/inst" "$d/t1/boot-kit/scripts"
  cat > "$d/t1/boot-kit/scripts/lock-verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "RESULT: LOCKED (fixture stub)"
exit 0
EOF
  chmod +x "$d/t1/boot-kit/scripts/lock-verify.sh"
  git -C "$d/t1" init -q
  git "${GITC[@]}" -C "$d/t1" add -A
  git "${GITC[@]}" -C "$d/t1" commit -q -m fixture
  mkdir -p "$d/inst/vendor"
  git clone -q "$d/t1" "$d/inst/vendor/dark-factory"
  cp "$INSTALL_SRC" "$d/inst/install.sh"
  jq -n --argjson inst "$ins" \
    '{vendorDir:"vendor", upstreams:{"dark-factory":{repo:"example/dark-factory",commit:""}}, install:$inst}' \
    > "$d/inst/loom.lock.json"
}

# mk_stub <case> — a fake `claude` that LOGS every invocation and answers from env:
#   STUB_MKT_RC       exit code for `plugin marketplace add`   (default 0)
#   STUB_INSTALL_RC   exit code for `plugin install`           (default 0)
#   STUB_LIST_JSON    body for `plugin list --json`            (default [])
# The log is the point: it makes "called nothing" an assertable outcome, which is the only way
# to prove --dry-run really is dry.
mk_stub() {
  local d="$WORK/$1"
  mkdir -p "$d/stub"
  cat > "$d/stub/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG:?}"
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "add" ]; then
  echo "marketplace add: ${4:-}"; exit "${STUB_MKT_RC:-0}"
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "install" ]; then
  echo "install: ${3:-}"; exit "${STUB_INSTALL_RC:-0}"
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' "${STUB_LIST_JSON:-[]}"; exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "enable" ]; then exit 0; fi
exit 0
EOF
  chmod +x "$d/stub/claude"
}

# run <case> [extra install.sh args...] — always --offline; LOOM_LIVE/LOOM_BIN pinned inside the
# fixture and DF_CLAUDE_BIN pointed at the stub, so nothing here can reach the real ~/.claude,
# the real ~/.local/bin, or the real Claude CLI.
run() {
  local c="$1"; shift
  ( cd "$WORK/$c/inst" \
      && LOOM_LIVE="$WORK/$c/inst/live" LOOM_BIN="$WORK/$c/inst/bin" \
         DF_CLAUDE_BIN="${DF_CLAUDE_BIN_OVERRIDE:-$WORK/$c/stub/claude}" \
         STUB_LOG="$WORK/$c/stub.log" \
         bash install.sh --offline "$@" 2>&1 )
}
rc_of() {
  local c="$1"; shift
  ( cd "$WORK/$c/inst" \
      && LOOM_LIVE="$WORK/$c/inst/live" LOOM_BIN="$WORK/$c/inst/bin" \
         DF_CLAUDE_BIN="${DF_CLAUDE_BIN_OVERRIDE:-$WORK/$c/stub/claude}" \
         STUB_LOG="$WORK/$c/stub.log" \
         bash install.sh --offline "$@" >/dev/null 2>&1 )
  echo $?
}
lock_of() { jq -c "$2" "$WORK/$1/inst/loom.lock.json"; }
log_of()  { cat "$WORK/$1/stub.log" 2>/dev/null; }

MKT_LIST='[{"id":"playwright@claude-plugins-official","version":"85cce0381e78","scope":"user","enabled":true,"installPath":"/tmp/pw"}]'
ENTRY='{"name":"playwright","marketplace":"claude-plugins-official","marketplaceSource":"anthropics/claude-plugins-official"}'

echo "== undeclared =="
mk_instance none '{"skills":[],"hooks":[]}'
mk_stub none
OUT="$(run none)"
contains "says so rather than staying silent" "marketplace plugins: none declared" "$OUT"
eqstr    "exit 0" "0" "$(rc_of none)"
eqstr    "the CLI was never called" "" "$(log_of none)"

echo ""
echo "== the happy path =="
mk_instance happy "$(jq -n --argjson e "$ENTRY" '{skills:[],hooks:[],marketplacePlugins:[$e]}')"
mk_stub happy
OUT="$(STUB_LIST_JSON="$MKT_LIST" run happy)"
contains "reports the id and the resolved version" "playwright@claude-plugins-official: installed, version 85cce0381e78" "$OUT"
contains "refuses to let that read as a pin"      "NOT a pin" "$OUT"
contains "tells the operator to commit the record" "COMMIT THAT FILE" "$OUT"
LOG="$(log_of happy)"
contains "added the marketplace first"  "plugin marketplace add anthropics/claude-plugins-official" "$LOG"
contains "installed non-interactively"  "plugin install playwright@claude-plugins-official -y --scope user" "$LOG"
contains "asked the CLI what it did"    "plugin list --json" "$LOG"
eqstr "recorded the resolved version into probed" \
      '"85cce0381e78"' "$(lock_of happy '.probed.marketplacePlugins["playwright@claude-plugins-official"].version')"
eqstr "recorded the install path" '"/tmp/pw"' \
      "$(lock_of happy '.probed.marketplacePlugins["playwright@claude-plugins-official"].installPath')"
RESOLVED="$(lock_of happy '.probed.marketplacePluginsResolvedAt')"
case "$RESOLVED" in
  '"'20[0-9][0-9]-*Z'"') ok "stamped when it was resolved" ;;
  *) bad "stamped when it was resolved" "got $RESOLVED" ;;
esac

echo ""
echo "== --dry-run really is dry =="
mk_instance dry "$(jq -n --argjson e "$ENTRY" '{skills:[],hooks:[],marketplacePlugins:[$e]}')"
mk_stub dry
OUT="$(STUB_LIST_JSON="$MKT_LIST" run dry --dry-run)"
contains "says what it would install" "would install playwright@claude-plugins-official" "$OUT"
contains "names the marketplace it would add" "would add marketplace claude-plugins-official" "$OUT"
eqstr    "called the CLI zero times" "" "$(log_of dry)"
eqstr    "wrote nothing into probed" "null" "$(lock_of dry '.probed // null')"

echo ""
echo "== refusals =="
# scope: the machine installer has no business writing into one checkout's settings, and
# lock-verify — which asks the CLI about THIS MACHINE — would never see such an install.
mk_instance scope "$(jq -n --argjson e "$ENTRY" '{skills:[],hooks:[],marketplacePlugins:[($e + {scope:"project"})]}')"
mk_stub scope
OUT="$(STUB_LIST_JSON="$MKT_LIST" run scope)"
contains "refuses a non-user scope" "only 'user' is accepted" "$OUT"
eqstr    "and does not call the CLI at all" "" "$(log_of scope)"
eqstr    "and costs the exit code" "2" "$(STUB_LIST_JSON="$MKT_LIST" rc_of scope)"

mk_instance nomkt '{"skills":[],"hooks":[],"marketplacePlugins":[{"name":"playwright"}]}'
mk_stub nomkt
OUT="$(run nomkt)"
contains "refuses an entry with no marketplace" "needs both name and marketplace" "$OUT"
eqstr    "and costs the exit code" "2" "$(rc_of nomkt)"

echo ""
echo "== the CLI is missing =="
# Not a warning. There is no other fetch path for these, so an install that cannot reach the
# CLI has not installed them, and a green exit would say it had.
mk_instance nocli "$(jq -n --argjson e "$ENTRY" '{skills:[],hooks:[],marketplacePlugins:[$e]}')"
mk_stub nocli
OUT="$(DF_CLAUDE_BIN_OVERRIDE="$WORK/nocli/not-a-real-binary" run nocli)"
contains "names the binary it could not find" "is not on PATH" "$OUT"
eqstr    "and costs the exit code" "2" \
         "$(DF_CLAUDE_BIN_OVERRIDE="$WORK/nocli/not-a-real-binary" rc_of nocli)"

echo ""
echo "== the CLI fails =="
mk_instance failed "$(jq -n --argjson e "$ENTRY" '{skills:[],hooks:[],marketplacePlugins:[$e]}')"
mk_stub failed
OUT="$(STUB_INSTALL_RC=1 run failed)"
contains "reports the refusal" "install failed" "$OUT"
eqstr    "and records nothing" "null" "$(lock_of failed '.probed.marketplacePlugins // null')"
eqstr    "and costs the exit code" "2" "$(STUB_INSTALL_RC=1 rc_of failed)"

echo ""
echo "== success that installed nothing =="
# The failure mode this catches is the quiet one: the CLI says it worked and the plugin is not
# in the listing. Believing the success line would write a record of something absent.
mk_instance ghost "$(jq -n --argjson e "$ENTRY" '{skills:[],hooks:[],marketplacePlugins:[$e]}')"
mk_stub ghost
OUT="$(STUB_LIST_JSON='[]' run ghost)"
contains "does not believe the success line" "absent from" "$OUT"
eqstr    "and records nothing" "null" "$(lock_of ghost '.probed.marketplacePlugins // null')"
eqstr    "and costs the exit code" "2" "$(STUB_LIST_JSON='[]' rc_of ghost)"

echo ""
echo "== installed but disabled =="
# Measured on a real laptop: `plugin list --json` carries "enabled": false entries — on disk,
# loading nothing. The installer repairs it rather than reporting a plugin that does nothing.
mk_instance disabled "$(jq -n --argjson e "$ENTRY" '{skills:[],hooks:[],marketplacePlugins:[$e]}')"
mk_stub disabled
DIS='[{"id":"playwright@claude-plugins-official","version":"1.2.3","scope":"user","enabled":false,"installPath":"/tmp/pw"}]'
OUT="$(STUB_LIST_JSON="$DIS" run disabled)"
contains "enables it" "plugin enable playwright@claude-plugins-official" "$(log_of disabled)"
absent   "and does not call that a failure" "REFUSED" "$OUT"

echo ""
printf 'install.sh marketplace-plugins step: %d ok, %d failed\n' "$PASS" "$FAIL"
# run-tests.sh treats a suite that exits 0 with no declared count as UNMEASURED, not a pass.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
