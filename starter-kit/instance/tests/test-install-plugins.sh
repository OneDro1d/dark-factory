#!/usr/bin/env bash
# test-install-plugins.sh — install.sh materialises `install.plugins[]` as a personal
# skills-directory plugin, and refuses anything that does not fit the one shape that was
# ever measured to load: a COPY under ~/.claude/skills/<name>/.
#
# WHY THIS EXISTS. kitv2/b4 measured that a plugin declared via a marketplace + project
# `enabledPlugins` loads NOTHING headlessly -- no hooks, no bin, no monitors, no agent, and
# no error a worker could see. The only path ever shown to work interactively is a
# materialised copy under the personal skills directory (docs: a `.claude-plugin/plugin.json`
# under `~/.claude/skills/<name>/` loads "in every project" as `<name>@skills-dir`). This
# suite is the behavioural proof that install.sh actually produces that copy, refuses the
# shapes that would not load, and that `--dry-run` touches nothing while still saying what it
# would have done.
#
# HOW EACH CASE IS ISOLATED. `mk_instance` builds a throwaway "Tier 1" as a real, local,
# offline git repo (`vendor/dark-factory`) and copies THIS REPO'S OWN install.sh into the
# fixture root -- not a rewritten stand-in. `install.sh` resolves its own ROOT from
# `dirname "${BASH_SOURCE[0]}"`, so running the copy from inside the fixture is what makes
# `$ROOT`, `$LOCK` and `$VENDOR` resolve inside the fixture rather than inside this checkout.
# Every run passes `--offline` (no network is under test) and overrides `LOOM_LIVE`/`LOOM_BIN`
# so nothing here can touch the real ~/.claude or ~/.local/bin.
#
# Usage: bash starter-kit/instance/tests/test-install-plugins.sh
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
eqnum()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/instplug.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
GITC=(-c user.email=test@example.com -c user.name=test)

# mk_instance <case> <install-json> — a fixture "Tier 1" (a real, local, offline git repo)
# carrying a valid plugin under plugins/df-governed AND a no-op lock-verify.sh (so step 5 of
# install.sh cannot itself flip the exit code and confound the plugin-refusal assertions),
# plus a fresh instance root with the given `install` block and its own private LOOM_LIVE.
mk_instance() {
  local c="$1"
  local ins="$2"
  local d="$WORK/$c"
  mkdir -p "$d/inst" "$d/t1/boot-kit/scripts" \
           "$d/t1/plugins/df-governed/.claude-plugin" \
           "$d/t1/plugins/df-governed/hooks"
  printf '{"name":"df-governed"}\n' > "$d/t1/plugins/df-governed/.claude-plugin/plugin.json"
  printf '#!/bin/sh\necho hook\n' > "$d/t1/plugins/df-governed/hooks/probe.sh"
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
  # A real, local, offline clone -- install.sh's --offline path only requires a `.git` dir,
  # it never dereferences the URL.
  git clone -q "$d/t1" "$d/inst/vendor/dark-factory"
  cp "$INSTALL_SRC" "$d/inst/install.sh"
  jq -n --argjson inst "$ins" \
    '{vendorDir:"vendor", upstreams:{"dark-factory":{repo:"example/dark-factory",commit:""}}, install:$inst}' \
    > "$d/inst/loom.lock.json"
}

# run <case> [extra install.sh args...] — always --offline; LOOM_LIVE/LOOM_BIN pinned inside
# the fixture so a bug here could never reach the real ~/.claude or ~/.local/bin.
run() {
  local c="$1"; shift
  ( cd "$WORK/$c/inst" \
      && LOOM_LIVE="$WORK/$c/inst/live" LOOM_BIN="$WORK/$c/inst/bin" \
         bash install.sh --offline "$@" )
}
rc_of() { # rc_of <case> [extra args...] -- run and capture ONLY the exit code
  local c="$1"; shift
  ( cd "$WORK/$c/inst" \
      && LOOM_LIVE="$WORK/$c/inst/live" LOOM_BIN="$WORK/$c/inst/bin" \
         bash install.sh --offline "$@" >/dev/null 2>&1 )
  echo $?
}

DECL='{"plugins":[{"name":"df-governed","source":"upstream:plugins/df-governed","dest":"~/.claude/skills/df-governed"}]}'

echo "=== A: a declared plugin is materialised, and matches the pin exactly ==="
mk_instance a "$DECL"
OUT_A="$(run a 2>&1)"
contains "A prints the materialised line" "plugin df-governed: materialised from" "$OUT_A"
if [ -f "$WORK/a/inst/live/skills/df-governed/.claude-plugin/plugin.json" ]; then
  ok "A dest carries the plugin manifest"
else
  bad "A dest carries the plugin manifest" "not present at live/skills/df-governed/.claude-plugin/plugin.json"
fi
DIFF_A="$(diff -r --brief "$WORK/a/t1/plugins/df-governed" "$WORK/a/inst/live/skills/df-governed" 2>&1)"
eqnum "A materialised copy is byte-identical to the pin (diff -r --brief empty)" "" "$DIFF_A"
RC_A="$(rc_of a)"
eqnum "A a clean install with no refusals exits 0" "0" "$RC_A"

echo "=== B: no install.plugins section -- reported, and the install continues ==="
mk_instance b '{}'
OUT_B="$(run b 2>&1)"
contains "B the absent-section line is printed" "plugins: none declared" "$OUT_B"
absent   "B nothing is reported as materialised"  "materialised from"     "$OUT_B"

echo "=== C: source is not upstream: -- refused, not silently skipped ==="
mk_instance c '{"plugins":[{"name":"bad","source":"local:plugins/df-governed","dest":"~/.claude/skills/bad"}]}'
OUT_C="$(run c 2>&1)"
contains "C the refusal names the plugin"        "REFUSED plugin bad"     "$OUT_C"
contains "C the refusal names the actual reason" "not upstream:<path>"    "$OUT_C"
if [ -e "$WORK/c/inst/live/skills/bad" ]; then
  bad "C nothing was written for the refused plugin" "live/skills/bad exists"
else
  ok "C nothing was written for the refused plugin"
fi
RC_C="$(rc_of c)"
[ "$RC_C" != "0" ] && ok "C a refused source makes the run exit non-zero (got $RC_C)" \
                    || bad "C a refused source makes the run exit non-zero" "exit 0"

echo "=== D: dest resolves outside ~/.claude/skills/ -- refused ==="
mk_instance d '{"plugins":[{"name":"bad2","source":"upstream:plugins/df-governed","dest":"/etc/passwd"}]}'
OUT_D="$(run d 2>&1)"
contains "D the refusal names the plugin"  "REFUSED plugin bad2"          "$OUT_D"
contains "D the refusal names the reason"  "outside ~/.claude/skills/"    "$OUT_D"
if [ -e "/etc/passwd.d" ] || [ -e "$WORK/d/inst/live/skills/bad2" ]; then
  bad "D nothing was written anywhere for the refused plugin" "unexpected artefact present"
else
  ok "D nothing was written anywhere for the refused plugin"
fi
RC_D="$(rc_of d)"
[ "$RC_D" != "0" ] && ok "D a refused dest makes the run exit non-zero (got $RC_D)" \
                    || bad "D a refused dest makes the run exit non-zero" "exit 0"

echo "=== E: --dry-run prints the plan and touches nothing ==="
mk_instance e "$DECL"
OUT_E="$(run e --dry-run 2>&1)"
contains "E dry-run states what it would do"    "would materialise plugin df-governed" "$OUT_E"
if [ -e "$WORK/e/inst/live/skills/df-governed" ]; then
  bad "E dry-run leaves the dest untouched" "live/skills/df-governed was created"
else
  ok "E dry-run leaves the dest untouched"
fi
RC_E="$(rc_of e --dry-run)"
eqnum "E dry-run always exits 0 (existing install.sh contract)" "0" "$RC_E"

echo ""
printf 'install.sh plugins step: %d ok, %d failed\n' "$PASS" "$FAIL"
# run-tests.sh treats a suite that exits 0 with no declared count as UNMEASURED, not a pass.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
