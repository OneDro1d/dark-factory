#!/usr/bin/env bash
# test-df-start.sh — df-start, df-open, df-bg and bin/link.sh against a SCRATCH kit.
#
# Never touches the real $HOME, ~/.claude, ~/.local/bin or network: HOME, LOOM_BIN, the kit, the
# notepads and the repos all live under one mktemp dir, and claude is a stub that records its cwd,
# environment and arguments.
#
# Run:  bash starter-kit/instance/tests/test-df-start.sh
# Exit: 0 all assertions pass · 1 at least one fails · 2 the harness could not run
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ../bin, not ../../bin: this suite sits in the instance's own tests/, beside bin/. It came from
# a kit that nested it one level deeper, and a wrong BIN here does not fail loudly — every
# assertion just misses, which reads as 60 broken launchers instead of one bad path.
BIN="$(cd "$SELF/../bin" && pwd)" || { echo "no bin/ beside $SELF"; exit 2; }
[ -f "$BIN/df-start" ] || { echo "harness: no df-start in $BIN"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# ⛔ NORMALISE, do not just mktemp. Two macOS defaults each broke assertions that compare a path
# the launchers printed against one the harness built, and both are invisible on a Linux runner:
#   · $TMPDIR ends in "/", so mktemp yields "…/T//test-df-start.XXX" — a DOUBLE SLASH
#   · /tmp and /var are symlinks, so the launchers' `cd -P; pwd` resolves them and the harness
#     did not, leaving /tmp/… compared against /private/tmp/…
# Measured 2026-09-14 on this suite: 7 of 52 failed on the first, 5 of 52 on the second, 0 with
# both removed — while the launchers were correct the whole time. A suite that only passes where
# it was written is not evidence about the code; `cd -P && pwd` settles both at the source.
T="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/test-df-start.XXXXXX")" && pwd)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
unset LOOM_LOCK LOOM_LIVE CLAUDE_CONFIG_DIR DF_MISSION_SKILL DF_JTL_VERIFY DF_KIT
git config --global user.name "Test User"; git config --global user.email "test@example.invalid"; git config --global init.defaultBranch main
export LOOM_BIN="$T/bin"
export DF_NOTEPADS="$T/notepads"

# ── scratch kit: the bin/ under test, one machine record, a notepad template, a live tree ────
KIT="$T/kit"; mkdir -p "$KIT/bin" "$KIT/instances/m1" "$T/live/hooks/agent-notepad"
cp "$BIN"/df-start "$BIN"/df-open "$BIN"/df-bg "$BIN"/df-kit-env.sh "$BIN"/link.sh "$KIT/bin/"
chmod +x "$KIT/bin/"*
echo '{}' > "$KIT/instances/m1/loom.lock.json"
TPL="$KIT/vendor/dark-factory/skills/agent-notepad/plugin/notepad-template"
mkdir -p "$TPL/.claude"
printf '# NOTES\n\ntemplate\n' > "$TPL/NOTES.md"
printf '# <group>-<objective>\n\n<one-sentence objective — what "done" looks like. Full charter in SCOPE.md.>\n' > "$TPL/CLAUDE.md"
printf '{"hooks":{"PreToolUse":[{"command":"${HOME}/.claude/hooks/agent-notepad/hooks/commit-gate.sh"}]}}\n' > "$TPL/.claude/settings.json"
export LOOM_LIVE="$T/live"

cat > "$T/claude-stub" <<'EOF'
#!/usr/bin/env bash
{ echo "cwd=$PWD"; echo "cfg=${CLAUDE_CONFIG_DIR:-<unset>}"; echo "lock=${LOOM_LOCK:-<unset>}"; echo "argc=$#"
  for a in "$@"; do echo "arg=$a"; done; } > "$STUB_OUT"
EOF
chmod +x "$T/claude-stub"; export DF_CLAUDE="$T/claude-stub"

# a repo with a JMeter Job, a load Job (must be skipped) and a Makefile integration target
R="$T/repos/app"; mkdir -p "$R/tests/k8s"
printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: app-e2e-run\n  namespace: dev-app\nspec:\n  template:\n    spec:\n      containers:\n      - image: justb4/jmeter\n' > "$R/tests/k8s/app-e2e-job.yaml"
printf 'kind: Job\nmetadata:\n  name: app-load\n' > "$R/tests/k8s/app-load-job.yaml"
printf 'integration-test: up\n\tgo test ./...\nintegration-test-up:\n\ttrue\n' > "$R/Makefile"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" commit -q -m init
# a background session's worktree of the same repo: its copy of the suite must NOT be listed again
mkdir -p "$R/.claude/worktrees/bg-1/tests/k8s"
cp "$R/tests/k8s/app-e2e-job.yaml" "$R/.claude/worktrees/bg-1/tests/k8s/app-e2e-job.yaml"

DS="$KIT/bin/df-start"

echo "== a) a bad repo path fails before anything is created"
out="$("$DS" "Add export" --repo /nope/repo --no-launch 2>&1)"; rc=$?
check "exit 2" '[ "$rc" -eq 2 ]' "rc=$rc"
check "error names the path" 'printf "%s" "$out" | grep -q "/nope/repo"' "$out"
check "no notepad dir created" '[ ! -d "$DF_NOTEPADS" ]'

echo "== b) notepad from a repo, e2e suites listed as OPTIONAL"
out="$("$DS" "Add CSV export to reports" --repo "$R" --no-launch 2>&1)"; rc=$?
NP="$DF_NOTEPADS/add-csv-export-to-reports"
check "exit 0" '[ "$rc" -eq 0 ]' "$out"
check "kind auto-detected as mission" 'printf "%s" "$out" | grep -q "kind: mission (auto"'
check "SCOPE.md written" '[ -f "$NP/SCOPE.md" ]'
check "JMeter Job listed as optional, not a criterion" 'grep -q "^- app e2e (app-e2e-job.yaml)" "$NP/SCOPE.md" && ! grep -q "^- \[ \] app e2e (app-e2e-job" "$NP/SCOPE.md"'
check "load Job skipped" '! grep -q "app-load-job" "$NP/SCOPE.md"'
check "suite in .claude/worktrees not listed again" '[ "$(grep -c "app-e2e-job.yaml" "$NP/SCOPE.md")" -eq 1 ] && ! grep -q "worktrees" "$NP/SCOPE.md"'
check "Makefile integration-test found (not -up)" 'grep -q "make -C $R integration-test\`" "$NP/SCOPE.md" && ! grep -q "integration-test-up" "$NP/SCOPE.md"'
check "no JTL counter on PATH → generic success-column wording" 'grep -q "JTL \`success\` column" "$NP/SCOPE.md"'
check "manifest is valid JSON with the repo as primary" '[ "$(jq -r ".repos[0].role + \" \" + .repos[0].path" "$NP/repos.manifest.json")" = "primary $R" ]'
check "notepad committed with the user's own git identity" '[ "$(git -C "$NP" log -1 --format=%ae)" = "test@example.invalid" ]'
check "hooks repointed to the side-by-side live tree" 'grep -q "$T/live/hooks/agent-notepad" "$NP/.claude/settings.json" && ! grep -q "\${HOME}/.claude/hooks" "$NP/.claude/settings.json"'
check "CLAUDE.md placeholders filled" '! grep -q "<group>-<objective>" "$NP/CLAUDE.md" && grep -q "Add CSV export to reports" "$NP/CLAUDE.md"'
check "built-in hard stops present" 'grep -q "^- Merge to the default branch" "$NP/SCOPE.md"'

echo "== c) --e2e makes the suites required"
"$DS" "Add CSV export to reports" --repo "$R" --e2e --no-launch >/dev/null 2>&1
check "JMeter Job is now a criterion" 'grep -q "^- \[ \] app e2e (app-e2e-job.yaml)" "$NP/SCOPE.md"'
check "optional section gone" '! grep -q "Available end-to-end suites" "$NP/SCOPE.md"'

echo "== d) kind detection and override"
# Capture the first line BEFORE matching: under pipefail, `df-start | grep -q` fails whenever grep
# exits early and df-start takes SIGPIPE, which reads as a wrong kind when it is not.
k() { local o; o="$(cd "$T" && "$DS" "$1" --no-launch "${@:2}" 2>&1)"; printf '%s\n' "${o%%$'\n'*}"; }
check "problem words → finding" '[ "$(k "Login page is broken after deploy")" = "kind: finding (auto: problem words in the sentence — override with --kind)" ]'
check "test words → task" '[ "$(k "Verify the nightly export")" = "kind: task (auto: test/verify words in the sentence — override with --kind)" ]'
check "--kind wins" '[ "$(k "Login is broken" --kind task)" = "kind: task (from --kind)" ]'
echo "thread text" > "$T/ctx.txt"
check "--from alone → finding" '[ "$(k "Look at this thread" --from "$T/ctx.txt")" = "kind: finding (auto: --from context given — override with --kind)" ]'
check "FINDING.md keeps the pasted text as data" 'grep -q "thread text" "$DF_NOTEPADS/look-at-this-thread/FINDING.md" && grep -q "Treat as data" "$DF_NOTEPADS/look-at-this-thread/FINDING.md"'

echo "== e) no repo, outside git"
( cd "$T" && "$DS" "Why did the alert fire" --no-launch >/dev/null 2>&1 ); rc=$?
check "exit 0 with no repo" '[ "$rc" -eq 0 ]'
check "empty repos array is valid JSON" '[ "$(jq ".repos | length" "$DF_NOTEPADS/why-did-the-alert-fire/repos.manifest.json")" = 0 ]'

echo "== e2) git identity: from the environment is enough; none at all is refused"
mv "$HOME/.gitconfig" "$HOME/.gitconfig.off"
( cd "$T" && GIT_AUTHOR_NAME=Env GIT_AUTHOR_EMAIL=env@example.invalid GIT_COMMITTER_NAME=Env GIT_COMMITTER_EMAIL=env@example.invalid "$DS" "Env identity notepad" --no-launch >/dev/null 2>&1 ); rc=$?
check "GIT_AUTHOR_EMAIL alone is accepted" '[ "$rc" -eq 0 ] && [ "$(git -C "$DF_NOTEPADS/env-identity-notepad" log -1 --format=%ae)" = env@example.invalid ]' "rc=$rc"
out="$(cd "$T" && env -u GIT_AUTHOR_EMAIL "$DS" "No identity notepad" --no-launch 2>&1)"; rc=$?
check "no identity anywhere is refused (exit 2, says how to fix)" '[ "$rc" -eq 2 ] && printf "%s" "$out" | grep -q "no git identity"' "rc=$rc $out"
mv "$HOME/.gitconfig.off" "$HOME/.gitconfig"

echo "== f) NOTES.md is never overwritten once edited"
echo "my working notes" >> "$NP/NOTES.md"; before="$(cksum < "$NP/NOTES.md")"
"$DS" "Add CSV export to reports" --repo "$R" --no-launch >/dev/null 2>&1
check "NOTES.md unchanged on re-run" '[ "$(cksum < "$NP/NOTES.md")" = "$before" ]'

echo "== g) team hard stops from <kit>/df-start.never, plus --never"
printf '# team rules\nRead production customer data\n\n' > "$KIT/df-start.never"
export STUB_OUT="$T/stub-g"
"$DS" "Add CSV export to reports" --repo "$R" --never "Touch the shared queue" >/dev/null 2>&1
check "team rule in SCOPE.md" 'grep -q "^- Read production customer data" "$NP/SCOPE.md"'
check "comment lines ignored" '! grep -q "team rules" "$NP/SCOPE.md"'
check "--never in SCOPE.md" 'grep -q "^- Touch the shared queue" "$NP/SCOPE.md"'
check "both rules in the prompt" 'grep -q "Never: Read production customer data." "$STUB_OUT" && grep -q "Never: Touch the shared queue." "$STUB_OUT"'
rm -f "$KIT/df-start.never"

echo "== h) launch: cwd, environment, one prompt argument"
check "cwd is the notepad" 'grep -qx "cwd=$NP" "$STUB_OUT"'
check "CLAUDE_CONFIG_DIR = side-by-side live tree" 'grep -qx "cfg=$T/live" "$STUB_OUT"'
check "LOOM_LOCK = the one machine record" 'grep -qx "lock=$KIT/instances/m1/loom.lock.json" "$STUB_OUT"'
check "exactly one argument" 'grep -qx "argc=1" "$STUB_OUT"'
# The generic default, since this kit is linked under no prefix. Section p) covers the
# per-organisation names, where the invoked name chooses the skill.
check "prompt opens the mission skill" 'grep -qx "arg=/dark-factory-build" "$STUB_OUT"'
check "--skill overrides the skill" 'export STUB_OUT="$T/stub-h2"; "$DS" "Add CSV export to reports" --repo "$R" --skill /my-mission >/dev/null 2>&1; grep -qx "arg=/my-mission" "$STUB_OUT"'

echo "== i) default live tree ~/.claude: CLAUDE_CONFIG_DIR is not forced"
mkdir -p "$HOME/.claude"
check "cfg unset when LIVE is ~/.claude" 'export STUB_OUT="$T/stub-i"; LOOM_LIVE="$HOME/.claude" "$DS" "Add CSV export to reports" --repo "$R" >/dev/null 2>&1; grep -qx "cfg=<unset>" "$STUB_OUT"'

echo "== j) --bg starts a background session"
check "--bg starts a background session" 'export STUB_OUT="$T/stub-j"; "$DS" "Add CSV export to reports" --repo "$R" --bg >/dev/null 2>&1; grep -qx "arg=--bg" "$STUB_OUT"'
# ⛔ --bg USED TO IMPLY --permission-mode auto: a session nobody is watching, approving its own
# actions, guarded only by the "Never:" SENTENCES in its prompt. A sentence is a request; the
# deny list a dispatched worker gets is a mechanism. Default asks; auto is opt-in and says so.
check "--bg alone does NOT auto-approve" '! grep -qx "arg=--permission-mode" "$T/stub-j" && ! grep -qx "arg=auto" "$T/stub-j"'
check "--yes-auto opts in to auto-approval" 'export STUB_OUT="$T/stub-j2"; "$DS" "Add CSV export to reports" --repo "$R" --bg --yes-auto >/dev/null 2>&1; grep -qx "arg=--permission-mode" "$STUB_OUT" && grep -qx "arg=auto" "$STUB_OUT"'
check "--yes-auto warns that nobody is in the loop" 'out="$("$DS" "Add CSV export to reports" --repo "$R" --bg --yes-auto 2>&1)"; printf "%s" "$out" | grep -q "nobody is in the loop"'

echo "== k) machine records: several and no LOOM_LOCK is refused; LOOM_LOCK resolves relative"
mkdir -p "$KIT/instances/m2"; echo '{}' > "$KIT/instances/m2/loom.lock.json"
out="$("$DS" "Add CSV export to reports" --repo "$R" --no-launch 2>&1)"; rc=$?
check "exit 2 with two records" '[ "$rc" -eq 2 ]' "rc=$rc"
check "error lists both records" 'printf "%s" "$out" | grep -q "instances/m1/loom.lock.json" && printf "%s" "$out" | grep -q "instances/m2/loom.lock.json"'
check "LOOM_LOCK relative to the kit root" 'export STUB_OUT="$T/stub-k"; LOOM_LOCK=instances/m2/loom.lock.json "$DS" "Add CSV export to reports" --repo "$R" >/dev/null 2>&1; grep -qx "lock=$KIT/instances/m2/loom.lock.json" "$STUB_OUT"'
rm -rf "$KIT/instances/m2"

echo "== l) df-bg and df-open"
check "df-bg passes args under the kit config" 'export STUB_OUT="$T/stub-l"; "$KIT/bin/df-bg" agents --json >/dev/null 2>&1; grep -qx "arg=agents" "$STUB_OUT" && grep -qx "cfg=$T/live" "$STUB_OUT"'
out="$("$KIT/bin/df-open" --notepad "$T" 2>&1)"; rc=$?
check "df-open refuses a non-notepad" '[ "$rc" -eq 2 ] && printf "%s" "$out" | grep -q "not a notepad"'
check "df-open --notepad opens in the notepad" 'export STUB_OUT="$T/stub-l2"; "$KIT/bin/df-open" --notepad "$NP" >/dev/null 2>&1; grep -qx "cwd=$NP" "$STUB_OUT"'

echo "== m) link.sh links through PATH symlinks, refuses to clobber, unlinks only its own"
check "links three commands" 'bash "$KIT/bin/link.sh" >/dev/null 2>&1; [ -L "$LOOM_BIN/df-start" ] && [ -L "$LOOM_BIN/df-open" ] && [ -L "$LOOM_BIN/df-bg" ]'
check "a linked df-start still resolves its kit" 'export STUB_OUT="$T/stub-m"; "$LOOM_BIN/df-start" "Add CSV export to reports" --repo "$R" >/dev/null 2>&1; grep -qx "lock=$KIT/instances/m1/loom.lock.json" "$STUB_OUT"'
rm -f "$LOOM_BIN/df-bg"; echo "mine" > "$LOOM_BIN/df-bg"
bash "$KIT/bin/link.sh" >/dev/null 2>&1; rc=$?
check "refuses to replace a foreign file (exit 2, file kept)" '[ "$rc" -eq 2 ] && [ "$(cat "$LOOM_BIN/df-bg")" = mine ]'
bash "$KIT/bin/link.sh" --unlink >/dev/null 2>&1
check "--unlink removes its links and keeps the foreign file" '[ ! -e "$LOOM_BIN/df-start" ] && [ ! -e "$LOOM_BIN/df-open" ] && [ -f "$LOOM_BIN/df-bg" ]'

echo "== o) --from is redacted, kept OUT of git, and the human is told"
# ⛔ --from is for pasting a bug report, an alert or a chat thread: raw output from a real system,
# chosen by a human in a hurry. It used to be committed into the notepad repo verbatim. Deleting
# the file later does not remove it from history, and on a health estate the first hard stop is
# "no patient data in any file". So: redact credential shapes, never commit, and say so.
mkdir -p "$T/live/hooks/agent-notepad/lib"
cat > "$T/live/hooks/agent-notepad/lib/redact.sh" <<'EOF'
redact_secrets() { sed -E 's/(ghp_)[A-Za-z0-9_]{10,}/[REDACTED]/g'; }
EOF
printf 'the api died\ntoken ghp_AAAAAAAAAAAAAAAAAAAAAA here\n' > "$T/paste.txt"
export STUB_OUT="$T/stub-o"
"$DS" "Why did the API return 503" --repo "$R" --name from-redact --from "$T/paste.txt" >/dev/null 2>&1
FNP="$DF_NOTEPADS/from-redact"
check "FINDING.md is written" '[ -f "$FNP/FINDING.md" ]'
check "the credential shape is redacted" 'grep -q "REDACTED" "$FNP/FINDING.md" && ! grep -q "ghp_AAAAAAAAAAAAAAAAAAAAAA" "$FNP/FINDING.md"'
check "the non-secret content survives" 'grep -q "the api died" "$FNP/FINDING.md"'
check "FINDING.md is gitignored" 'grep -qxF "FINDING.md" "$FNP/.gitignore"'
check "FINDING.md is NOT committed" '! git -C "$FNP" ls-files --error-unmatch FINDING.md >/dev/null 2>&1'
check "the human is warned it is theirs to judge" 'out="$("$DS" "Why did the API return 503" --repo "$R" --name from-redact2 --from "$T/paste.txt" 2>&1)"; printf "%s" "$out" | grep -q "only you can judge it"'

echo "== p) the estate prefix comes from the INVOKED name, so several kits coexist"
# ⛔ link.sh refuses a name that is taken, so with fixed names the SECOND kit on a machine got
# nothing. The prefix also picks the mission skill, so one T1 implementation serves every estate.
check "unprefixed df-start opens the generic skill" 'export STUB_OUT="$T/stub-p0"; "$DS" "Add CSV export to reports" --repo "$R" >/dev/null 2>&1; grep -qx "arg=/dark-factory-build" "$STUB_OUT"'
check "link.sh --prefix links prefixed names only" 'bash "$KIT/bin/link.sh" --prefix acme >/dev/null 2>&1; [ -L "$LOOM_BIN/acme-df-start" ] && [ ! -e "$LOOM_BIN/df-start" ]'
check "acme-df-start opens /acme-dark-factory" 'export STUB_OUT="$T/stub-p1"; "$LOOM_BIN/acme-df-start" "Add CSV export to reports" --repo "$R" >/dev/null 2>&1; grep -qx "arg=/acme-dark-factory" "$STUB_OUT"'
check "a second kit can coexist under its own prefix" 'bash "$KIT/bin/link.sh" --prefix globex >/dev/null 2>&1; [ -L "$LOOM_BIN/globex-df-start" ] && [ -L "$LOOM_BIN/acme-df-start" ]'
check "globex-df-start opens /globex-dark-factory" 'export STUB_OUT="$T/stub-p2"; "$LOOM_BIN/globex-df-start" "Add CSV export to reports" --repo "$R" >/dev/null 2>&1; grep -qx "arg=/globex-dark-factory" "$STUB_OUT"'
check "--skill still wins over the prefix" 'export STUB_OUT="$T/stub-p3"; "$LOOM_BIN/acme-df-start" "Add CSV export to reports" --repo "$R" --skill /my-mission >/dev/null 2>&1; grep -qx "arg=/my-mission" "$STUB_OUT"'
check "DF_MISSION_SKILL still wins over the prefix" 'export STUB_OUT="$T/stub-p4"; DF_MISSION_SKILL=env-skill "$LOOM_BIN/acme-df-start" "Add CSV export to reports" --repo "$R" >/dev/null 2>&1; grep -qx "arg=/env-skill" "$STUB_OUT"'
check "a prefixed link still resolves its own kit" 'export STUB_OUT="$T/stub-p5"; "$LOOM_BIN/acme-df-start" "Add CSV export to reports" --repo "$R" >/dev/null 2>&1; grep -qx "lock=$KIT/instances/m1/loom.lock.json" "$STUB_OUT"'
check "--prefix --unlink removes only that prefix" 'bash "$KIT/bin/link.sh" --prefix globex --unlink >/dev/null 2>&1; [ ! -e "$LOOM_BIN/globex-df-start" ] && [ -L "$LOOM_BIN/acme-df-start" ]'
# Assert the REASON, not just exit 2: a link.sh with no --prefix at all also exits 2 here, as an
# unknown argument, so a bare status check passes against the very code this case exists to catch.
check "a bad prefix is refused, naming the rule" 'out="$(bash "$KIT/bin/link.sh" --prefix "Bad Prefix" 2>&1)"; rc=$?; [ "$rc" -eq 2 ] && printf "%s" "$out" | grep -q "lower-case"'
bash "$KIT/bin/link.sh" --prefix acme --unlink >/dev/null 2>&1

echo "== q) --help prints the WHOLE header, however long it grows"
# ⛔ It used to print a fixed line range ('2,33p'). The header grew past 33 and --help silently
# lost its last options — and a truncated help page looks exactly like a complete one.
H="$("$DS" --help 2>&1)"
check "help starts at the summary line" 'printf "%s" "$H" | head -1 | grep -q "df-start"'
check "help reaches the LAST header line" 'printf "%s" "$H" | grep -q "context stores in the code repos"'
check "help stops before the code" '! printf "%s" "$H" | grep -q "set -euo pipefail"'
# The subshell is load-bearing: check() runs this through `eval` in the CURRENT shell, so a bare
# `exit 1` here ends the whole suite instead of failing one case — measured, it truncated a run
# with no summary line at all, which reads as a crash rather than a red assertion.
check "help documents every option the parser accepts" '( for o in --repo --group --name --never --kind --from --skill --e2e --bg --yes-auto --no-launch; do printf "%s" "$H" | grep -q -- "$o" || exit 1; done )'
check "df-bg with no arguments prints its whole header" 'B="$("$KIT/bin/df-bg" 2>&1)"; printf "%s" "$B" | grep -q "df-bg stop" && ! printf "%s" "$B" | grep -q "set -euo pipefail"'

echo "== n) nothing organisation-specific is baked in"
check "no org-specific words in the launchers" '! grep -niE "\beso\b|patient|clinical|teams|\bCAT-|slack|jira" "$BIN"/df-start "$BIN"/df-open "$BIN"/df-bg "$BIN"/df-kit-env.sh "$BIN"/link.sh'
check "no personal paths in the launchers" '! grep -nE "/home/|pardeep|coder-" "$BIN"/df-start "$BIN"/df-open "$BIN"/df-bg "$BIN"/df-kit-env.sh "$BIN"/link.sh'

echo
echo "PASS: $PASS  FAIL: $FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
