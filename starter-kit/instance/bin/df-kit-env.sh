# df-kit-env.sh — sourced by df-start, df-open and df-bg. Resolves THIS kit, its live tree and
# this machine's record the same way install.sh does, so the launchers need no per-person paths.
#
#   DF_KIT     the kit root. Default: the directory above bin/, found through the PATH symlink.
#   LIVE       ${LOOM_LIVE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}} — where install.sh put skills/hooks.
#   LOCK       --lock rule from install.sh: $LOOM_LOCK (absolute, or relative to the kit root);
#              else the ONE record under instances/; else the root loom.lock.json.
#   DF_CLAUDE  the claude binary (tests point it at a stub).
#
# ⚠️ Several records under instances/ and no LOOM_LOCK is an error, not a guess: launching a
# session against another machine's record reports that machine's installs as this one's.

df_die() { printf '%s: %s\n' "${DF_PROG:-df}" "$*" >&2; exit 2; }

# ── the estate prefix: the name this command was INVOKED as, not the file it resolves to ──────
# ONE implementation, linked per estate as <estate>-df-start (link.sh --prefix). A machine that
# holds several kits NEEDS several names: link.sh refuses to overwrite a name that already
# exists, so whichever kit ran it second got nothing at all. A single `df-start` on PATH can
# only ever point into one kit, and this estate's own laptop carries four.
#
# The prefix also chooses the mission skill, so the launcher needs no per-organisation fork and
# no config file: `<prefix>-df-start` opens `/<prefix>-dark-factory`. Unprefixed `df-start` is
# the generic kit: /dark-factory-build.
# Precedence, highest first: --skill · $DF_MISSION_SKILL · the invoked prefix · the generic default.
df_invoked_prefix() {
  local n="${1##*/}"
  case "$n" in
    df-start|df-open|df-bg)       printf '' ;;
    *-df-start|*-df-open|*-df-bg) printf '%s' "${n%-df-*}" ;;
    *)                            printf '' ;;
  esac
}

df_resolve_kit() {
  local here="$1"
  DF_KIT="${DF_KIT:-$(cd "$here/.." && pwd)}"
  [ -d "$DF_KIT" ] || df_die "kit root not found: $DF_KIT"
  LIVE="${LOOM_LIVE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
  CLAUDE_BIN="${DF_CLAUDE:-claude}"

  if [ -n "${LOOM_LOCK:-}" ]; then
    case "$LOOM_LOCK" in
      /*) LOCK="$LOOM_LOCK" ;;
      *)  LOCK="$DF_KIT/$LOOM_LOCK" ;;
    esac
    [ -f "$LOCK" ] || df_die "LOOM_LOCK points at nothing: $LOCK"
    return 0
  fi
  local records=() f
  for f in "$DF_KIT"/instances/*/*.lock.json; do [ -f "$f" ] && records+=("$f"); done
  case "${#records[@]}" in
    1) LOCK="${records[0]}" ;;
    0) LOCK="$DF_KIT/loom.lock.json"
       [ -f "$LOCK" ] || df_die "no machine record in $DF_KIT (instances/<machine>/*.lock.json or loom.lock.json) — install the kit first (START-HERE.md)" ;;
    *) printf '%s: this kit holds %s machine records and LOOM_LOCK is not set:\n' "${DF_PROG:-df}" "${#records[@]}" >&2
       for f in "${records[@]}"; do printf '  %s\n' "${f#"$DF_KIT"/}" >&2; done
       df_die "export LOOM_LOCK=instances/<this machine>/<record>.lock.json" ;;
  esac
}

# Export the kit environment for a claude session. CLAUDE_CONFIG_DIR is set only when the live
# tree is NOT the default ~/.claude, so a normal install keeps claude's own default untouched.
df_export_env() {
  export LOOM_LIVE="$LIVE" LOOM_LOCK="$LOCK"
  if [ "$LIVE" != "$HOME/.claude" ]; then export CLAUDE_CONFIG_DIR="$LIVE"; fi
}
