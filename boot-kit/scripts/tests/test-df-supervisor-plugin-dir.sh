#!/usr/bin/env bash
# test-df-supervisor-plugin-dir.sh — the loop passes --plugin-dir, or says loudly that it
# cannot.
#
# ⛔ THE BUG THIS GUARDS. df-supervisor.sh passes `--setting-sources project` to keep the
# user-level SessionStart hooks (~114KB) out of every iteration. That flag also removes
# every plugin the user surface would have enabled — and a plugin declared through a
# project `enabledPlugins` key delivers NOTHING to `claude -p` either, in either settings
# mode. Measured: no hooks, no bin, no agent, no monitor, and NO diagnostic — stdout carries
# no warning, stderr is 0 bytes, `--debug` adds 0 bytes. An ungoverned iteration is
# invisible from the inside, which is why it has to be asserted from the outside, here.
#
# `--plugin-dir` is a COMMAND-LINE FLAG, so `--setting-sources` cannot exclude it. That is
# the whole mechanism, and this suite asserts the flag reaches the real argv.
#
# HOW. There is no dry-run or inspection mode in df-supervisor.sh — this suite was written
# after reading it — so the argv is captured the only honest way available: the REAL script
# is run against a scratch kit with a stub `claude` first on PATH that records its argv and
# writes a terminal state so the loop exits after one iteration. df-preflight.py and
# df-render-prompt.py are stubbed for the same reason (the real ones probe the estate).
# Nothing here launches a model and nothing touches the real kit.
#
# Enrolled by GLOB, per tests/README.md — a suite is enrolled by existing.
#
# Usage: bash boot-kit/scripts/tests/test-df-supervisor-plugin-dir.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
SUP="$SCRIPTS/df-supervisor.sh"
[ -f "$SUP" ] || { echo "missing $SUP"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
pair() { # label flag value file-of-one-arg-per-line
  if awk -v f="$2" -v v="$3" 'prev==f && $0==v {found=1} {prev=$0} END{exit !found}' "$4"
  then ok "$1"; else bad "$1" "no adjacent [$2] [$3] in the rendered argv"; fi
}
absent_flag() { # label flag file
  if grep -Fxq -- "$2" "$3"; then bad "$1" "$2 is present and must not be"; else ok "$1"; fi
}
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/supplugin.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# CANONICAL: df-supervisor.sh resolves its own root with `readlink -f` + `cd && pwd`, and
# on this platform $TMPDIR is a symlink. Comparing a symlinked path against a resolved one
# fails for a reason that has nothing to do with the supervisor.
WORK="$(cd "$WORK" && pwd -P)"

# ── a stub `claude`, first on PATH ──────────────────────────────────────────────────────
# Records the argv one word per line, then writes DONE so the loop takes exactly one lap.
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
: > "$ARGV_OUT"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGV_OUT"; done
printf 'DONE\n' > "$STATE_OUT"
printf '{"subtype":"success","is_error":false}\n'
exit 0
STUB
chmod +x "$BIN/claude"
PATH="$BIN:$PATH"
export PATH

# ── a scratch kit that mirrors the shipped layout ───────────────────────────────────────
mk_kit() { # $1 = kit root, $2 = "plugin" | "noplugin"
  local kit="$1"
  mkdir -p "$kit/boot-kit/scripts" "$kit/.df/missions/M-TEST"
  cp "$SUP" "$kit/boot-kit/scripts/df-supervisor.sh"
  chmod +x "$kit/boot-kit/scripts/df-supervisor.sh"
  # stubs: the real ones probe the estate and would make this suite depend on the machine.
  printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$kit/boot-kit/scripts/df-preflight.py"
  printf '#!/usr/bin/env python3\nprint("iteration prompt")\n'  > "$kit/boot-kit/scripts/df-render-prompt.py"
  printf 'NOTES\n' > "$kit/NOTES.md"
  if [ "$2" = "plugin" ]; then
    # the VENDORED shape: install.sh fetches Tier 1 into vendorDir at its pinned commit,
    # and the plugin ships inside that tree. This is what an installed instance looks like.
    mkdir -p "$kit/vendor/dark-factory/plugins/df-governed/hooks"
  fi
}

run_sup() { # $1 = kit root ; extra env comes from the caller
  ARGV_OUT="$WORK/argv.txt" STATE_OUT="$1/.df/missions/M-TEST/state" \
    bash "$1/boot-kit/scripts/df-supervisor.sh" --mission "$1/.df/missions/M-TEST" \
         --max-iter 1 2>&1
}

# ── case 1: an installed kit with a vendored plugin ─────────────────────────────────────
K1="$WORK/kit1"; mk_kit "$K1" plugin
OUT1="$(run_sup "$K1")"; RC1=$?
if [ "$RC1" -eq 0 ]; then ok "S1 the loop completes"; else bad "S1 the loop completes" "rc=$RC1: $OUT1"; fi
if [ -s "$WORK/argv.txt" ]; then ok "S2 an iteration actually launched"
else bad "S2 an iteration actually launched" "no argv captured"; fi
pair "S3 --plugin-dir names the vendored plugin root" \
     "--plugin-dir" "$K1/vendor/dark-factory/plugins/df-governed" "$WORK/argv.txt"
# regression: the flag that made --plugin-dir necessary must still be there.
pair "S4 --setting-sources project is still passed" "--setting-sources" "project" "$WORK/argv.txt"

# ── case 2: a Tier-1 checkout, where plugins/ sits beside boot-kit/ ─────────────────────
K2="$WORK/kit2"; mk_kit "$K2" noplugin
mkdir -p "$K2/plugins/df-governed"
OUT2="$(run_sup "$K2")"
pair "S5 --plugin-dir resolves plugins/ beside boot-kit/" \
     "--plugin-dir" "$K2/plugins/df-governed" "$WORK/argv.txt"

# ── case 3: DF_PLUGIN_ROOT wins over both ───────────────────────────────────────────────
K3="$WORK/kit3"; mk_kit "$K3" plugin
mkdir -p "$WORK/elsewhere/df-governed"
export DF_PLUGIN_ROOT="$WORK/elsewhere/df-governed"
OUT3="$(run_sup "$K3")"
unset DF_PLUGIN_ROOT
pair "S6 DF_PLUGIN_ROOT overrides the discovered root" \
     "--plugin-dir" "$WORK/elsewhere/df-governed" "$WORK/argv.txt"

# ── case 4: no plugin anywhere — WARN LOUDLY, do not fail the loop ──────────────────────
# ⚠️ Refusing to start because governance is missing would trade a governed-but-stopped
# mission for nothing. But an ungoverned iteration says nothing about itself, so the one
# place it can be said is the supervisor log, before any of it runs.
K4="$WORK/kit4"; mk_kit "$K4" noplugin
OUT4="$(run_sup "$K4")"; RC4=$?
if [ "$RC4" -eq 0 ]; then ok "S7 a missing plugin root does NOT fail the loop"
else bad "S7 a missing plugin root does not fail the loop" "rc=$RC4"; fi
absent_flag "S8 no --plugin-dir is passed when none resolves" "--plugin-dir" "$WORK/argv.txt"
contains "S9 the loop warns that iterations are ungoverned" "UNGOVERNED" "$OUT4"
if [ -s "$K4/.df/missions/M-TEST/supervisor.log" ]; then ok "S10 the warning is in the supervisor log"
else bad "S10 the warning is in the supervisor log" "log empty"; fi

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
