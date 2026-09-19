#!/usr/bin/env bash
# test-secret-guard.sh — hooks/secret-guard.py: "never print a secret" as a mechanism, not a habit.
#
# WHY THIS EXISTS. A rule that says "do not print a credential" was broken repeatedly by agents
# that knew it: a dump command's output lands in a session transcript, and a transcript is stored,
# copied and sometimes committed. These cases pin the mechanism that replaces the rule:
#   D  PreToolUse(Bash) DENIES the known dump commands, and the reason names a safe form
#   A  the safe forms stay ALLOWED (a guard that blocks the recommended command is a guard
#      that gets switched off)
#   R  in bypassPermissions, every other foreground Bash command is rewritten to run through the
#      redactor: the CURRENT values of secret-named env vars (raw and base64) and known token
#      shapes are masked on stdout AND stderr; the output is whole, the exit code and cwd survive.
#      In every other mode nothing is rewritten (permission rules would stop matching).
#   M  PostToolUse on MCP tools masks the same things in tool output (updatedMCPToolOutput),
#      including a token returned under a "token"/"secret"/"password" JSON key
#   U  UserPromptSubmit blocks a prompt carrying a token-shaped string or an exact secret value,
#      and never echoes it back
#   P  the notepad pre-commit: re-redacts staged session journals in place, refuses any other
#      staged secret, names file + rule and never the value; install is idempotent and chains
#   G  the gitleaks config is generated from the SAME rule table (one source, no drift)
#   W  the hook is declared by a kit and wired in the starter settings template
# Case ids that end in a number (D4, R6, M12 …) are regression cases for dump shapes seen in
# practice; the letter-only ids widen each class.
#
# ⚠️ HERMETIC, AND NO REAL VALUE EVER. Every guard run is under `env -i`: the hook sees ONLY the
# synthetic variables below, so a failing assertion cannot print a credential from the machine
# running the suite. Every fixture is generated at run time; no token-shaped literal lives in
# this file, so the file itself passes the scanner it tests.
#
# Run: bash boot-kit/scripts/tests/test-secret-guard.sh      Exit 0 = all pass.
# SECRET_GUARD=<path> runs the suite against another copy (the mutant check uses this).
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
T1="$(cd "$SELF/../../.." && pwd)"
GUARD="${SECRET_GUARD:-$T1/hooks/secret-guard.py}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home"

# ── synthetic fixtures, generated here, never literal ────────────────────────
rnd() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$1"; }
FAKE_PAT="fk$(rnd 38)"                 # an env secret with NO recognisable prefix
FAKE_PW="pw$(rnd 22)"
FAKE_CODER="$(rnd 10)-$(rnd 22)"
FAKE_SYN="syn_$(rnd 40)"
FAKE_GH="gh""o_$(rnd 36)"
FAKE_XOX="xo""xb-$(rnd 12)-$(rnd 12)-$(rnd 24)"
FAKE_BS="$(rnd 24)"                    # a prefix-less token returned under a "token" key

# run the guard as a hook: stdin = event JSON; only synthetic env reaches it.
hook() {
  env -i PATH="$PATH" HOME="$W/home" \
      SERVICE_PAT="$FAKE_PAT" DB_PASSWORD="$FAKE_PW" CODER_AGENT_TOKEN="$FAKE_CODER" \
      SHELL_LEVEL_NOT_SECRET="plainvalue" \
      python3 "$GUARD" "$@"
}
bash_event() { # command [permission_mode] [run_in_background]
  jq -cn --arg c "$1" --arg m "${2:-bypassPermissions}" --argjson bg "${3:-false}" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", permission_mode:$m,
      tool_input:({command:$c, description:"t"} + (if $bg then {run_in_background:true} else {} end)), cwd:"/tmp"}'
}
decision()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // .decision // "none"' 2>/dev/null; }
reason()     { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // .reason // ""' 2>/dev/null; }
rewritten()  { printf '%s' "$1" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null; }

[ -f "$GUARD" ] || echo "  NOTE $GUARD is missing -- every case below runs anyway, so each incident shows its own result"

deny() { # id command [must-mention]
  local out; out="$(bash_event "$2" | hook)"
  if [ "$(decision "$out")" = "deny" ] || [ "$(decision "$out")" = "block" ]; then
    if [ -n "${3:-}" ] && ! reason "$out" | grep -qF -- "$3"; then
      bad "$1 denied, but the reason does not name the safe form" "$(reason "$out" | head -c 200)"
    else
      ok "$1 denied: $2"
    fi
  else
    bad "$1 NOT denied: $2" "$(printf '%s' "$out" | head -c 200)"
  fi
}
allow() { # id command
  local out; out="$(bash_event "$2" | hook)"
  case "$(decision "$out")" in
    deny|block) bad "$1 wrongly denied: $2" "$(reason "$out" | head -c 200)" ;;
    *) ok "$1 allowed: $2" ;;
  esac
}

echo "=== D: the dump commands are denied, and the reason names what to use instead ==="
deny D4  "kubectl get secrets -n ns-a -o go-template='{{range .items}}{{.data}}{{end}}'" 'range $k'
deny D4b "kubectl get secret app-secrets -n ns-a -o yaml" 'range $k'
deny D4c "kubectl get cm,secret -A -o json"
deny D4d "kubectl get secret x --output=json"
deny D5  "gh auth token"
deny D5b "gh auth token -u someone"
deny D5c "gh auth status --show-token"
deny D6  "env" 'cut -d= -f1'
deny D6b "printenv"
deny D6c "printenv SERVICE_PAT"
deny D6d "env | grep PAT"
deny D6e "bash -c 'env'"
deny D6f "cat /proc/self/environ"
deny D8  "kubectl get secret -n ns-b -o custom-columns=NAME:.metadata.name,DATA:.data"
deny D9  "kubectl get secret svc-creds -n ns-b -o jsonpath={.data}"
deny D9b "kubectl get secret svc-creds -n ns-b -o jsonpath='{.data.password}'"
deny D10 "doctl apps get 1234 --output json" 'jq'
deny D10b "doctl apps get 1234"
deny D10c "doctl apps list -o json"
deny D10d "doctl apps spec get 1234"
deny Denv "cat .env"
deny Denv2 "cat ./svc/.env.local"
deny Denv3 "grep PASSWORD .env.production"
deny Dvlt "vault kv get secret/team/x" '-field'
deny Dvlt2 "vault kv get -format=json secret/team/x"
deny Dvlt3 "vault kv get -field=password secret/team/x"
deny Daz  "az keyvault secret show --vault-name kv --name db"
deny Dop  "op read op://vault/item/field"
deny Dop2 "op item get item --reveal"

echo
echo "=== A: the safe forms stay allowed ==="
allow A1 "kubectl get secrets -n ns-a"
allow A2 "kubectl describe secret app-secrets -n ns-a"
allow A3 "kubectl get secret app-secrets -n ns-a -o go-template='{{range \$k, \$v := .data}}{{\$k}} {{end}}'"
allow A4 "kubectl get pods -n ns-a -o yaml"
allow A5 "kubectl get secret x -o name"
allow A6 "env | cut -d= -f1"
allow A7 "printenv | cut -d= -f1"
allow A8 "env -u DEBUG python3 run.py"
allow A9 "vault kv get -field=password secret/team/x | kubectl create secret generic y --from-file=password=/dev/stdin"
allow A10 "doctl apps spec get 1234 | jq '.services[].envs[].key'"
allow A11 "doctl apps list"
allow A12 "gh auth status"
allow A13 "cat .env.example"
allow A14 "op read op://vault/item/field --out-file /tmp/f"
allow A15 "git log --oneline -3"
allow A16 "echo the env command is denied"
allow A17 "cut -d= -f1 .env"

echo
echo "=== R: every other command runs through the redactor ==="
# Run the rewritten command the way Claude Code does: eval it, record `pwd -P` after it, with
# stdout+stderr going to a FILE that is read the moment the shell exits -- not a pipe read to EOF.
# ⚠️ A pipe hides the bug this models: a filter still flushing after the shell exits. The first
# design (exec redirection into async >( ) filters) passed every case under `$(bash -c …)` and
# returned EMPTY output in a live session.  SG_SHELL=zsh runs the same cases under zsh.
run_rewritten() { # command -> prints output, returns exit code; the cwd lands in $W/cwd
  local out cmd rc; out="$(bash_event "$1" | hook)"; cmd="$(rewritten "$out")"
  [ -n "$cmd" ] || { printf 'NO-REWRITE'; return 99; }
  rm -f "$W/cwd" "$W/out"
  env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W" \
      SERVICE_PAT="$FAKE_PAT" DB_PASSWORD="$FAKE_PW" CODER_AGENT_TOKEN="$FAKE_CODER" \
      FAKE_SYN="$FAKE_SYN" FAKE_GH="$FAKE_GH" FAKE_XOX="$FAKE_XOX" \
      "${SG_SHELL:-bash}" -c 'eval "$1" < /dev/null && pwd -P >| "$2"' _ "$cmd" "$W/cwd" > "$W/out" 2>&1
  rc=$?
  cat "$W/out"
  return $rc
}
redacted() { # id command needle...
  local id="$1" c="$2" out rc; shift 2
  out="$(run_rewritten "$c")"; rc=$?
  if [ "$rc" -eq 99 ]; then bad "$id command was not rewritten" "$c"; return; fi
  local leaked=""
  for n in "$@"; do printf '%s' "$out" | grep -qF -- "$n" && leaked="yes"; done
  if [ -n "$leaked" ]; then bad "$id value reached the output" "(value withheld)"
  elif printf '%s' "$out" | grep -q 'REDACTED'; then ok "$id masked: $c"
  else bad "$id no REDACTED marker in the output" "$(printf '%s' "$out" | head -c 120)"; fi
}
redacted R6  'python3 -c "import os; print(os.environ[\"SERVICE_PAT\"])"' "$FAKE_PAT"
redacted R6b 'python3 -c "import os; print(\"CODER_AGENT_TOKEN=\" + os.environ[\"CODER_AGENT_TOKEN\"])"' "$FAKE_CODER"
redacted R4  'printf "%s" "$DB_PASSWORD" | base64' "$(printf '%s' "$FAKE_PW" | base64)"
redacted R4b 'echo "password: $DB_PASSWORD"' "$FAKE_PW"
redacted Rsyn 'echo "hub token $FAKE_SYN"' "$FAKE_SYN"
redacted Rgh  'echo "$FAKE_GH"' "$FAKE_GH"
redacted Rxox 'echo "slack $FAKE_XOX"' "$FAKE_XOX"
redacted Rerr 'echo "$DB_PASSWORD" >&2' "$FAKE_PW"
OUT="$(run_rewritten 'echo "postgres://app:$DB_PASSWORD@db.internal:5432/x"')"
if printf '%s' "$OUT" | grep -qF "$FAKE_PW"; then bad "Rpg postgres URL password reached the output" "(value withheld)"
elif printf '%s' "$OUT" | grep -q 'postgres://app:'; then ok "Rpg postgres URL: user kept, password masked"
else bad "Rpg postgres URL mangled" "$OUT"; fi
OUT="$(run_rewritten 'echo visible; exit 3')"; RC=$?
[ "$RC" -eq 3 ] && ok "Rrc exit code preserved (3)" || bad "Rrc exit code lost" "rc=$RC"
printf '%s' "$OUT" | grep -qx 'visible' && ok "Rplain ordinary output passes through unchanged" || bad "Rplain ordinary output changed" "$OUT"
OUT="$(run_rewritten 'echo plainvalue')"
printf '%s' "$OUT" | grep -qx 'plainvalue' && ok "Rname a non-secret env var is not masked" || bad "Rname over-redaction" "$OUT"
OUT="$(run_rewritten 'echo --from-file=password=/dev/stdin')"
printf '%s' "$OUT" | grep -qx -- '--from-file=password=/dev/stdin' && ok "Rpath a path after a secret-named key is not masked" || bad "Rpath over-redaction" "$OUT"
OUT="$(run_rewritten 'seq 1 30000')"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 30000 ] && printf '%s' "$OUT" | tail -1 | grep -qx 30000 \
  && ok "Rfull 30000 lines arrive whole, read the moment the shell exits" || bad "Rfull output incomplete" "$(printf '%s\n' "$OUT" | wc -l) lines"
OUT="$(run_rewritten 'mkdir -p "$TMPDIR/sub"; cd "$TMPDIR/sub"; echo moved')"
[ "$(cat "$W/cwd" 2>/dev/null)" = "$(cd "$W/sub" && pwd -P)" ] && ok "Rcwd a cd in the command still moves the shell" || bad "Rcwd cwd lost" "$(cat "$W/cwd" 2>/dev/null)"
OUT="$(run_rewritten 'echo "before $DB_PASSWORD"; exit 4')"; RC=$?
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep -q 'before \[REDACTED\]' && ! printf '%s' "$OUT" | grep -qF "$FAKE_PW"; then
  ok "Rexit an exit inside the command: rc 4 kept, output delivered and masked"
else bad "Rexit output or rc lost on exit" "rc=$RC"; fi
LEFT="$(find "$W" -maxdepth 1 -name 'secret-guard.*' | wc -l | tr -d ' ')"
[ "$LEFT" = 0 ] && ok "Rtmp no capture file left behind" || bad "Rtmp capture files left behind" "$LEFT"

# The rewrite is ONLY for bypassPermissions. Measured live: in every other mode Claude Code matches
# permission rules against the REWRITTEN command, so allow-listed commands stop matching and a
# dontAsk worker is denied every Bash call. A background command is left alone too: its output is
# read while it runs, and the rewrite only delivers output at the end.
for m in default dontAsk acceptEdits plan; do
  OUT="$(bash_event 'echo hi' "$m" | hook)"
  [ -z "$(rewritten "$OUT")" ] && [ "$(decision "$OUT")" = none ] && ok "Rmode $m: not rewritten, not decided" || bad "Rmode $m rewritten or decided" "$OUT"
done
OUT="$(bash_event 'gh auth token' dontAsk | hook)"
[ "$(decision "$OUT")" = deny ] && ok "Rmode the deny list applies in every mode (dontAsk)" || bad "Rmode deny skipped in dontAsk" "$OUT"
OUT="$(bash_event 'tail -f app.log' bypassPermissions true | hook)"
[ -z "$(rewritten "$OUT")" ] && ok "Rbg a background command is not rewritten" || bad "Rbg background command rewritten" "-"

echo
echo "=== M: MCP tool output is masked (updatedMCPToolOutput) ==="
mcp_event() { jq -cn --arg t "$1" '{hook_event_name:"PostToolUse", tool_name:"mcp__vendor__get_source", tool_input:{}, tool_response:[{type:"text", text:$t}]}'; }
BS_JSON="$(jq -cn --arg tok "$FAKE_BS" '{data:{id:"1", attributes:{name:"service-a", token:$tok, ingesting_host:"in.example"}}}')"
OUT="$(mcp_event "$BS_JSON" | hook)"
UPD="$(printf '%s' "$OUT" | jq -c '.hookSpecificOutput.updatedMCPToolOutput // empty' 2>/dev/null)"
if [ -z "$UPD" ]; then bad "M12 token under a \"token\" key was not rewritten" "$(printf '%s' "$OUT" | head -c 160)"
elif printf '%s' "$UPD" | grep -qF "$FAKE_BS"; then bad "M12 token still in the rewritten output" "(value withheld)"
elif printf '%s' "$UPD" | grep -q 'service-a'; then ok "M12 token masked, the rest of the record kept"
else bad "M12 record mangled" "$(printf '%s' "$UPD" | head -c 160)"; fi
OUT="$(mcp_event "config: hub=$FAKE_PAT" | hook)"
UPD="$(printf '%s' "$OUT" | jq -c '.hookSpecificOutput.updatedMCPToolOutput // empty' 2>/dev/null)"
if [ -n "$UPD" ] && ! printf '%s' "$UPD" | grep -qF "$FAKE_PAT"; then ok "Menv an env secret value in MCP output is masked"
else bad "Menv env secret value not masked in MCP output" "(value withheld)"; fi
OUT="$(mcp_event "nothing to see here" | hook)"
[ -z "$(printf '%s' "$OUT" | jq -c '.hookSpecificOutput.updatedMCPToolOutput // empty' 2>/dev/null)" ] \
  && ok "Mclean clean MCP output is left alone" || bad "Mclean clean output rewritten" "$OUT"

echo
echo "=== U: a prompt carrying a secret is blocked, and the value is not echoed ==="
prompt() { jq -cn --arg p "$1" '{hook_event_name:"UserPromptSubmit", prompt:$p}' | hook; }
OUT="$(prompt "use this hub token: $FAKE_SYN please")"
if [ "$(decision "$OUT")" = "block" ] && ! printf '%s' "$OUT" | grep -qF "$FAKE_SYN"; then ok "U1 token-shaped string blocked, not echoed"
else bad "U1 token-shaped prompt not blocked (or echoed)" "(value withheld)"; fi
OUT="$(prompt "the password is $FAKE_PW")"
if [ "$(decision "$OUT")" = "block" ] && ! printf '%s' "$OUT" | grep -qF "$FAKE_PW"; then ok "U2 exact env secret value blocked, not echoed"
else bad "U2 env secret value prompt not blocked (or echoed)" "(value withheld)"; fi
OUT="$(prompt "reinstall the workspace and check the syn_ prefix rule")"
[ "$(decision "$OUT")" != "block" ] && ok "U3 ordinary prompt allowed" || bad "U3 ordinary prompt blocked" "$(reason "$OUT")"

echo
echo "=== P: notepad pre-commit ==="
R="$W/np"; git init -q "$R"; git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
printf 'hello\n' > "$R/NOTES.md"; git -C "$R" add NOTES.md; git -C "$R" commit -qm init
pc() { ( cd "$R" && env -i PATH="$PATH" HOME="$W/home" DB_PASSWORD="$FAKE_PW" python3 "$GUARD" --pre-commit ) 2>&1; }
printf 'hub=%s\n' "$FAKE_SYN" > "$R/leak.md"; git -C "$R" add leak.md
OUT="$(pc)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'leak.md' && ! printf '%s' "$OUT" | grep -qF "$FAKE_SYN"; then
  ok "P1 staged secret refused, file named, value withheld"
else bad "P1 staged secret not refused (or value printed)" "rc=$RC"; fi
git -C "$R" rm -q --cached leak.md; rm -f "$R/leak.md"
mkdir -p "$R/sessions"
jq -cn --arg c "curl -H 'Authorization: Bearer x' -d pw=$FAKE_PW $FAKE_SYN" '{ts:"t", cmd:$c}' > "$R/sessions/s1.jsonl"
git -C "$R" add sessions/s1.jsonl
OUT="$(pc)"; RC=$?
STAGED="$(git -C "$R" show :sessions/s1.jsonl)"
if [ "$RC" -eq 0 ] && ! printf '%s' "$STAGED" | grep -qF "$FAKE_SYN" && ! printf '%s' "$STAGED" | grep -qF "$FAKE_PW"; then
  ok "P2 staged journal re-redacted in place and re-staged; commit allowed"
else bad "P2 journal not cleaned (rc=$RC)" "$(printf '%s' "$OUT" | head -c 160)"; fi
git -C "$R" commit -qm journal
printf 'clean\n' >> "$R/NOTES.md"; git -C "$R" add NOTES.md
pc >/dev/null; [ $? -eq 0 ] && ok "P3 clean change passes" || bad "P3 clean change refused" "$(pc)"
git -C "$R" commit -qm clean
# install into the repo, chaining a foreign hook
HD="$(git -C "$R" rev-parse --git-path hooks)"; case "$HD" in /*) ;; *) HD="$R/$HD" ;; esac
mkdir -p "$HD"; printf '#!/bin/sh\necho foreign-ran >> "%s/foreign.log"\n' "$W" > "$HD/pre-commit"; chmod +x "$HD/pre-commit"
hook --install-precommit "$R" >/dev/null 2>&1
hook --install-precommit "$R" >/dev/null 2>&1
grep -q 'secret-guard' "$HD/pre-commit" 2>/dev/null && ok "P4 pre-commit installed" || bad "P4 pre-commit not installed" "$HD/pre-commit"
[ -x "$HD/pre-commit.local" ] && grep -q foreign-ran "$HD/pre-commit.local" \
  && ok "P4b the foreign pre-commit was kept as pre-commit.local" || bad "P4b foreign pre-commit lost" "$(ls "$HD" | tr '\n' ' ')"
# idempotent: the second install must not have moved OUR shim over the foreign hook
! grep -q 'secret-guard' "$HD/pre-commit.local" 2>/dev/null \
  && ok "P4c second install is idempotent (foreign hook not overwritten)" || bad "P4c second install clobbered pre-commit.local" "-"
printf 'k=%s\n' "$FAKE_SYN" > "$R/leak2.md"; git -C "$R" add leak2.md
( cd "$R" && env -i PATH="$PATH" HOME="$W/home" SECRET_GUARD_PATH="$GUARD" git commit -qm leak ) >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && ok "P5 a real git commit of a secret is refused by the installed hook" || bad "P5 real commit of a secret went through" "rc=$RC"
git -C "$R" rm -q --cached leak2.md; rm -f "$R/leak2.md"
printf 'more\n' >> "$R/NOTES.md"; git -C "$R" add NOTES.md
( cd "$R" && env -i PATH="$PATH" HOME="$W/home" SECRET_GUARD_PATH="$GUARD" git commit -qm ok ) >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "P6 a clean real commit goes through" || bad "P6 clean real commit refused" "rc=$RC"
grep -q foreign-ran "$W/foreign.log" 2>/dev/null && ok "P7 the chained foreign hook still runs" || bad "P7 chained foreign hook did not run" "-"

echo
echo "=== F: review fixes (each was RED on the first head, fc8b033) ==="
# F1 — the already-wrapped check was "MARKER in cmd": a trailing comment carrying the marker text
# skipped the WHOLE hook, deny list included.
for m in dontAsk bypassPermissions; do
  OUT="$(bash_event 'gh auth token # secret-guard: output is redacted' "$m" | hook)"
  [ "$(decision "$OUT")" = deny ] && ok "F1 $m: a marker comment does not skip the deny list" || bad "F1 $m: marker comment bypassed the deny list" "$OUT"
done
FORGED="$(printf '# secret-guard: output is redacted (secret-guard.py); the original command follows unchanged\ngh auth token')"
OUT="$(bash_event "$FORGED" | hook)"
[ "$(decision "$OUT")" = deny ] && ok "F1b a forged wrapper header does not skip the deny list" || bad "F1b forged header bypassed the deny list" "$OUT"
ONCE="$(rewritten "$(bash_event 'echo hi' | hook)")"
OUT="$(bash_event "$ONCE" | hook)"
[ -z "$(rewritten "$OUT")" ] && [ "$(decision "$OUT")" = none ] && ok "F1c the hook's own wrapper is not wrapped twice" || bad "F1c wrapper re-wrapped or denied" "$(printf '%s' "$OUT" | head -c 120)"

# F2 — prefix rules had no left boundary: ordinary hyphenated words matched sk-… and were masked,
# prompts were blocked, and the pre-commit (same findings()) refused the commit.
filt() { printf '%s\n' "$1" | hook --filter; }
for w in disk-encryption-configuration-v2 task-management-framework-overview risk-assessment-matrix-2024-final \
         thighs_abcdefghijklmnopqrstuv0123 xxoxb-not-a-slack-token-at-all BAKIAABCDEFGHIJKLMNOP; do
  [ "$(filt "see $w here")" = "see $w here" ] && ok "F2 not masked: $w" || bad "F2 over-redacted: $w" "$(filt "see $w here")"
done
OUT="$(jq -cn '{hook_event_name:"UserPromptSubmit", prompt:"please check the disk-encryption-configuration-v2 setting"}' | hook)"
[ "$(decision "$OUT")" = none ] && ok "F2 prompt with a hyphenated word is not blocked" || bad "F2 prompt wrongly blocked" "$OUT"
FAKE_SK="sk-$(rnd 20)7Q$(rnd 20)"
case "$(filt "key $FAKE_SK")" in *"$FAKE_SK"*) bad "F2 a real-shaped sk- key is no longer masked" "(value withheld)" ;; *) ok "F2 a real-shaped sk- key is still masked" ;; esac
case "$(filt "k=$FAKE_GH")" in *"$FAKE_GH"*) bad "F2 gh token after = no longer masked" "(value withheld)" ;; *) ok "F2 a gh token after '=' is still masked" ;; esac
printf 'see disk-encryption-configuration-v2 and task-management-framework-overview\n' > "$R/words.md"; git -C "$R" add words.md
pc >/dev/null; [ $? -eq 0 ] && ok "F2 pre-commit passes hyphenated words" || bad "F2 pre-commit refused hyphenated words" "$(pc | head -3)"
git -C "$R" commit -qm words

# F3 — install followed core.hooksPath: a global hooksPath had its shared pre-commit renamed and the
# guard armed for every repo; husky's .husky/_ file was renamed. Now: hooksPath set -> skip, say so.
R3="$W/husky"; git init -q "$R3"; mkdir -p "$R3/.husky/_"
printf '#!/bin/sh\necho husky\n' > "$R3/.husky/_/pre-commit"; chmod +x "$R3/.husky/_/pre-commit"
git -C "$R3" config core.hooksPath .husky/_
BEFORE="$(cksum < "$R3/.husky/_/pre-commit")"
hook --install-precommit "$R3" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(cksum < "$R3/.husky/_/pre-commit")" = "$BEFORE" ] && [ ! -e "$R3/.husky/_/pre-commit.local" ] \
  && ok "F3 repo core.hooksPath (husky): left alone, exit 0" || bad "F3 husky hook touched" "rc=$RC $(ls "$R3/.husky/_" | tr '\n' ' ')"
R4="$W/plain"; git init -q "$R4"; GH4="$W/global-hooks"; mkdir -p "$GH4"
printf '#!/bin/sh\necho shared\n' > "$GH4/pre-commit"; chmod +x "$GH4/pre-commit"
printf '[core]\n\thooksPath = %s\n' "$GH4" > "$W/gitconfig-global"
BEFORE="$(cksum < "$GH4/pre-commit")"
env -i PATH="$PATH" HOME="$W/home" GIT_CONFIG_GLOBAL="$W/gitconfig-global" python3 "$GUARD" --install-precommit "$R4" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(cksum < "$GH4/pre-commit")" = "$BEFORE" ] && [ ! -e "$GH4/pre-commit.local" ] && [ ! -e "$R4/.git/hooks/pre-commit" ] \
  && ok "F3b global core.hooksPath: the shared hook is left alone" || bad "F3b global hooksPath hook touched" "rc=$RC"
OUT="$(env -i PATH="$PATH" HOME="$W/home" GIT_CONFIG_GLOBAL="$W/gitconfig-global" python3 "$GUARD" --install-precommit "$R4" 2>&1 >/dev/null)"
printf '%s' "$OUT" | grep -q 'hooksPath' && ok "F3c the skip is logged, naming core.hooksPath" || bad "F3c skip not logged" "$OUT"

# F4 — every doctl -o json was denied. Only the spec/secret-bearing subcommands are.
allow F4 "doctl compute droplet list -o json"
allow F4b "doctl kubernetes cluster list --output json"
allow F4c "doctl databases list -o json"
deny F4d "doctl databases connection 1234"
deny F4e "doctl databases user list 1234"
deny F4f "doctl kubernetes cluster kubeconfig show k8s-1"
deny F4g "doctl registry docker-config"

# F5 — wrapper robustness: the command runs in a subshell whose stdout+stderr go to the capture file,
# so nothing it does (PATH, exec, traps, fds, shadowed commands, unset) can reach around the filter.
wr() { # id command expected-line [value-that-must-not-appear]
  local out rc; out="$(run_rewritten "$2")"; rc=$?
  local left; left="$(find "$W" -maxdepth 1 -name 'secret-guard.*' | wc -l | tr -d ' ')"
  if [ "$rc" -eq 99 ]; then bad "$1 not rewritten" "$2"
  elif [ -n "${4:-}" ] && printf '%s' "$out" | grep -qF -- "$4"; then bad "$1 value reached the output" "(value withheld)"
  elif ! printf '%s\n' "$out" | grep -qxF -- "$3"; then bad "$1 expected line missing" "$(printf '%s' "$out" | head -c 160)"
  elif [ "$left" != 0 ]; then bad "$1 capture file left behind" "$left"
  else ok "$1 $2"; fi
}
wr F5a 'export PATH=/nonexistent; echo x' 'x'
wr F5b 'exec echo "pw $DB_PASSWORD"' 'pw [REDACTED]' "$FAKE_PW"
wr F5c 'trap "echo bye $DB_PASSWORD" EXIT; echo hi' 'bye [REDACTED]' "$FAKE_PW"
wr F5d 'echo x \' 'x'
OUT="$(run_rewritten 'echo x \')"
printf '%s' "$OUT" | grep -q '__sg' && bad "F5d wrapper internals leaked into the output" "$OUT" || ok "F5d no wrapper internals in the output"
wr F5e 'echo "fd3 $DB_PASSWORD" >&3; echo after' 'after' "$FAKE_PW"
wr F5f 'python3() { cat; }; rm() { :; }; echo "pw $DB_PASSWORD"' 'pw [REDACTED]' "$FAKE_PW"
wr F5g 'v="$DB_PASSWORD"; unset DB_PASSWORD; echo "v $v"' 'v [REDACTED]' "$FAKE_PW"
OUT="$(run_rewritten 'cd "$TMPDIR"; mkdir -p f5; cd f5; echo "in $DB_PASSWORD"; exit 7')"; RC=$?
[ "$RC" -eq 7 ] && [ "$OUT" = "in [REDACTED]" ] \
  && ok "F5h cd, output, exit 7: rc kept, output masked" || bad "F5h rc/output lost" "rc=$RC"
OUT="$(run_rewritten 'cd "$TMPDIR"; mkdir -p f5b; cd f5b')"
[ "$(cat "$W/cwd" 2>/dev/null)" = "$(cd "$W/f5b" && pwd -P)" ] && ok "F5h2 a cd in the command still moves the shell" || bad "F5h2 cwd lost" "$(cat "$W/cwd" 2>/dev/null)"
for bad_in in 'not json' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":"a string"}' \
              '{"hook_event_name":"PostToolUse","tool_name":"mcp__x__y","tool_response":{"a":[1,{"b":null}]}}' '[]'; do
  OUT="$(printf '%s' "$bad_in" | hook 2>/dev/null)"; RC=$?
  [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -c . 2>/dev/null)" = '{}' ] \
    && ok "F5i malformed input -> {} exit 0: ${bad_in:0:40}" || bad "F5i malformed input crashed" "rc=$RC out=$(printf '%s' "$OUT" | head -c 80)"
done

echo
echo "=== G: the gitleaks config comes from the same rule table ==="
CFG="$(hook --gitleaks-config)"
for id in synapse-pat coder-token postgres-url-password; do
  printf '%s' "$CFG" | grep -q "id = \"$id\"" && ok "G rule $id present" || bad "G rule $id missing" "-"
done
if [ -z "$CFG" ]; then
  bad "G the config is empty" "-"
elif python3 -c 'import tomllib' 2>/dev/null; then
  printf '%s' "$CFG" | python3 -c 'import sys,tomllib; tomllib.loads(sys.stdin.read())' 2>/dev/null \
    && ok "G the config parses as TOML" || bad "G config is not valid TOML" "-"
fi

echo
echo "=== W: declared by a kit, wired by the starter template ==="
KIT="$T1/kits/agent-ops/kit.json"; TPL="$T1/starter-kit/instance/boot-kit/settings.template.json"
jq -e '.hooks | index("secret-guard.py")' "$KIT" >/dev/null && ok "W1 agent-ops declares secret-guard.py" || bad "W1 not declared" "$KIT"
for ev in PreToolUse PostToolUse UserPromptSubmit; do
  jq -e --arg ev "$ev" '.hooks[$ev][]?.hooks[]?.command | select(test("secret-guard.py"))' "$TPL" >/dev/null \
    && ok "W2 $ev wires secret-guard.py" || bad "W2 $ev does not wire secret-guard.py" "$TPL"
done
jq -e '.hooks.PostToolUse[]? | select(.matcher == "mcp__.*") | .hooks[].command | select(test("secret-guard.py"))' "$TPL" >/dev/null \
  && ok "W3 PostToolUse matcher covers every MCP tool" || bad "W3 PostToolUse matcher is not mcp__.*" "-"
grep -q 'install-precommit' "$T1/skills/agent-notepad/plugin/hooks/session-start.sh" \
  && ok "W4 notepad session-start installs the pre-commit" || bad "W4 session-start does not install the pre-commit" "-"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
