#!/usr/bin/env bash
# local-verify.sh — the tester tests a PR's EXACT commit locally, with NO deploy.
#
#   local-verify.sh <app> <40-char commit> [--base <ref>] [--full-stack]
#   local-verify.sh --selftest
#
# <app> is one of pair.yaml repos[].app; the repo comes from repos[].github (or repos[].remote: any git URL or
# path) and the default base from repos[].base (origin/<base>). Optional per-app special cases live in
# repos[].local_verify (see docs/KNOWLEDGE.md, "Local verify"), never in this script.
#
# 1. Clone at that commit in ~/.cache/local-verify/<app>-<sha12>/src, reset --hard + clean -ffdx EVERY run.
#    The tree is never edited: a Go module replace (local_verify.go_replace) runs on an ALTERNATE go.mod outside
#    the tree, and that deviation is recorded.
# 2. Finds what changed vs the base (or --base).
# 3. Per changed top-level directory: build + its unit tests (Go: build + vet + test; .NET: build + every test
#    project that references it; npm: ci + build + test). A repo-root package.json covers changes outside any
#    sub-project. Changed files no step covered are listed; any → verdict UNVERIFIED, never PASS. A build-only
#    service (no tests in its language) also keeps the verdict at UNVERIFIED.
# 4. --full-stack: only when repos[].local_verify.full_stack is set — local Postgres (migrations applied),
#    Azurite blob, then the integration test projects. No docker, no cloud.
# Every step runs with a scrubbed environment (allow-list of variables) and HOME pointed at an empty per-run
# directory, so ~/.kube, ~/.azure and ~/.aws are not where the code under test looks. Known limits (no sandbox):
# a pod's service-account token file stays readable and the network stays reachable.
# Exit = the verdict: 0 PASS, 1 FAIL, 2 UNVERIFIED (setup failed, nothing ran, or changes left uncovered).
# Never prints secret values. Written to result.json beside the log.
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIB="$HERE/../lib"

if [ "${1:-}" = "--selftest" ]; then
  # Throw-away pair + a local bare 'origin' with a tiny Go module; three commits: tests pass, a test fails,
  # a change no step covers. The Go cases need a cached Go >= 1.25 toolchain (as the real runs do); without one the
  # same runs must come out UNVERIFIED (2) — never PASS or FAIL — and that is what the selftest then checks.
  BASEDIR="/tmp/claude-$(id -u)"; [ -d "$BASEDIR" ] || BASEDIR="${TMPDIR:-/tmp}"
  HAVE_GO=0
  for tc in "$HOME"/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.*linux-amd64; do
    minor="${tc##*go1.}"; minor="${minor%%.*}"
    [ -d "$tc" ] && [ "${minor:-0}" -ge 25 ] 2>/dev/null && GOROOT="$tc" GOTOOLCHAIN=local "$tc/bin/go" version >/dev/null 2>&1 \
      && HAVE_GO=1
  done
  if [ "$HAVE_GO" = 1 ]; then W_OK=0; W_FAIL=1; W_RJ=PASS
  else W_OK=2; W_FAIL=2; W_RJ=UNVERIFIED; echo "note: no cached Go >= 1.25 toolchain — the Go runs must be UNVERIFIED (2)"; fi
  T=$(mktemp -d "$BASEDIR/lv-selftest-XXXXXX"); bad=0
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git init -q --bare -b main "$T/origin.git"; git clone -q "$T/origin.git" "$T/w" 2>/dev/null
  mkdir -p "$T/w/svc"; printf 'module example.com/svc\n\ngo 1.22\n' > "$T/w/svc/go.mod"
  printf 'package svc\n\nfunc Limit() int { return 100 }\n' > "$T/w/svc/limit.go"
  printf 'package svc\n\nimport "testing"\n\nfunc TestLimit(t *testing.T) { if Limit() != 100 { t.Fatal("limit") } }\n' > "$T/w/svc/limit_test.go"
  (cd "$T/w" && git add -A && git commit -qm base && git push -q origin HEAD:main)
  cat > "$T/pair.yaml" <<EOF
project: {name: S, slug: s}
owner: {name: O}
builder: {name: B, host: none}
tester: {name: T, host: none}
paths: {shared_root: $T, ledger: $T/ledger}
repos:
  - {app: api, remote: $T/origin.git, base: main}
EOF
  export PAIR_CONFIG="$T/pair.yaml" HOME_OVERRIDE="$T/home"
  mk() { (cd "$T/w" && git checkout -q -B "$1" origin/main && eval "$2" && git add -A && git commit -qm "$1" && git push -q -f origin "HEAD:$1" && git rev-parse HEAD); }
  ok_sha=$(mk ok 'printf "package svc\n\n// raised\nfunc Limit() int { return 100 }\n" > svc/limit.go')
  fail_sha=$(mk fail 'printf "package svc\n\nfunc Limit() int { return 200 }\n" > svc/limit.go')
  unc_sha=$(mk unc 'mkdir -p ops && echo x > ops/notes.cfg')
  expect() { # name want-exit cmd...
    local name="$1" want="$2"; shift 2; local out rc; out=$("$@" 2>&1); rc=$?
    if [ "$rc" = "$want" ]; then echo "PASS $name"; else echo "FAIL $name (exit $rc, want $want): $(echo "$out" | tail -3)"; bad=$((bad+1)); fi
  }
  me="$(readlink -f "$0")"
  expect "usage error -> 2"                 2 "$me"
  expect "unknown app -> 2"                 2 "$me" nope "$ok_sha"
  expect "short sha -> 2"                   2 "$me" api abc123
  expect "tests pass -> $W_RJ ($W_OK)"      "$W_OK" "$me" api "$ok_sha"
  expect "failing test -> exit $W_FAIL"     "$W_FAIL" "$me" api "$fail_sha"
  expect "uncovered change -> UNVERIFIED (2)" 2 "$me" api "$unc_sha"
  expect "--full-stack without config -> 2" 2 "$me" api "$ok_sha" --full-stack
  rj="$T/home/.cache/local-verify/api-${ok_sha:0:12}/result.json"
  if [ -f "$rj" ] && grep -q "\"verdict\": \"$W_RJ\"" "$rj"; then echo "PASS result.json written ($W_RJ)"; else echo "FAIL result.json missing or not $W_RJ"; bad=$((bad+1)); fi
  rm -rf "$T"
  [ "$bad" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$bad FAILED"; exit 1; }
fi

USAGE="usage: local-verify.sh <app> <40-char commit> [--base ref] [--full-stack]   (apps: pair.yaml repos[].app)"
APP="${1:-}"; SHA="${2:-}"
shift 2 2>/dev/null || { echo "$USAGE"; exit 2; }
BASE=""; FULL=0
while [ $# -gt 0 ]; do case "$1" in
  --base) { [ $# -ge 2 ] && [ -n "$2" ]; } || { echo "--base needs a ref"; exit 2; }; BASE="$2"; shift 2 ;;
  --full-stack) FULL=1; shift ;;
  *) echo "unknown arg $1"; exit 2 ;; esac; done
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "commit must be the full 40-char sha"; exit 2; }

# --- this app's settings from pair.yaml (shell-quoted by Python, never interpolated raw) ---
CONF=$(python3 -I - "$LIB" "$APP" <<'PY'
import shlex, sys
sys.path.insert(0, sys.argv[1])
import pairconf
cfg = pairconf.load()
apps = pairconf.apps(cfg)
app = apps.get(sys.argv[2])
if not app:
    print(f"echo {shlex.quote('unknown app ' + repr(sys.argv[2]) + '; pair.yaml repos: ' + (', '.join(apps) or '(none)'))}; exit 2")
    sys.exit(0)
lv = app.get("local_verify") or {}
remote = app.get("remote") or f"https://github.com/{app['github']}.git"
q = shlex.quote
print(f"REMOTE={q(str(remote))}")
print(f"DEFBASE={q('origin/' + str(app.get('base', 'main')))}")
print(f"DOTNET_CHANNEL={q(str(lv.get('dotnet_sdk', '10.0')))}")
print(f"GO_MIN={q(str(lv.get('go_min', '1.25')))}")
print(f"EXTRA_SETUP_SIG={q(str(lv.get('setup_signatures', '')))}")
print("declare -a GO_REPLACE=(" + " ".join(q(f"{r['module']}|{r['git']}|{r['sha']}") for r in lv.get("go_replace", [])) + ")")
print("declare -a DOTNET_PREPACK=(" + " ".join(q(str(p)) for p in lv.get("dotnet_prepack", [])) + ")")
print("declare -a CUSTOM_CMDS=(" + " ".join(q(str(c)) for c in (lv.get("commands") or [])) + ")")
print(f"NPM_TEST_ARGS={q(str(lv.get('npm_test_args', '--watch=false')))}")
print(f"ROOT_NPM_TEST_ARGS={q(str(lv.get('root_npm_test_args', '--watch=false')))}")
fs = lv.get("full_stack") or {}
print(f"FS_ENABLED={'1' if fs else '0'}")
pg = fs.get("postgres") or {}
print(f"FS_PG={'1' if pg else '0'}")
print(f"FS_PG_USER={q(str(pg.get('user', 'app_test')))}")
print(f"FS_PG_PORT={q(str(pg.get('port', 55432)))}")
print(f"FS_PG_MIGRATIONS={q(str(pg.get('migrations', 'migrations/*.sql')))}")
print("declare -a FS_PG_ENV=(" + " ".join(q(str(v)) for v in pg.get("connection_env", [])) + ")")
az = fs.get("azurite") or {}
print(f"FS_AZ={'1' if az else '0'}")
print(f"FS_AZ_PORT={q(str(az.get('port', 10000)))}")
print(f"FS_AZ_ENV={q(str(az.get('endpoint_env', '')))}")
print(f"FS_IT_GLOB={q(str(fs.get('integration_tests', 'tests/integration/*/')))}")
PY
) || { echo "SETUP FAIL: could not read pair.yaml"; exit 2; }
eval "$CONF"
BASE="${BASE:-$DEFBASE}"
if [ "$FULL" = 1 ] && [ "$FS_ENABLED" != 1 ]; then echo "SETUP FAIL: --full-stack needs repos[].local_verify.full_stack for $APP in pair.yaml"; exit 2; fi
HOME_RUN="${HOME_OVERRIDE:-$HOME}"
W="$HOME_RUN/.cache/local-verify/$APP-${SHA:0:12}"; mkdir -p "$W"; LOG="$W/log.txt"; : > "$LOG"
BUILD="$W/build"; rm -rf "$BUILD"; mkdir -p "$BUILD" "$W/tmp"; rm -f "$W/result.json"
S="$HOME_RUN/.cache/local-stack"; AZPID=""; PGB=""; PW=""
cleanup() { [ -n "$AZPID" ] && kill "$AZPID" 2>/dev/null; [ -n "$PGB" ] && [ -d "$S/data" ] && "$PGB/pg_ctl" -D "$S/data" stop -m fast >/dev/null 2>&1; rm -f "$S/pw" "$S/pgpass"; }
trap cleanup EXIT
declare -a STEPS=() DEVIATIONS=() COVERED=() EXTRA_ENV=(); FAILS=0; SETUP_FAIL=0; BUILD_ONLY=0
setup_fail() { echo "SETUP FAIL: $*"; echo "SETUP FAIL: $*" >>"$LOG"; SETUP_FAIL=1; }

# --- toolchains (one-time, in this agent's own home; found in $HOME even when the run's cache is elsewhere) ---
DOTNET_HOME="$HOME/.dotnet"
GOMIN_MINOR="${GO_MIN#1.}"
GOTC=$(ls -d "$HOME"/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.*linux-amd64 2>/dev/null | sort -V | \
       awk -v m="$GOMIN_MINOR" -F'go1.' '{split($2,a,"."); if (a[1]+0 >= m+0) print}' | tail -1)
if [ -n "$GOTC" ] && ! GOROOT="$GOTC" GOTOOLCHAIN=local "$GOTC/bin/go" version >/dev/null 2>&1; then GOTC=""; fi

CHROME_BIN=$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)
# Steps get ONLY these variables (no KUBECONFIG, AZURE_*, AWS_*, KUBERNETES_*, tokens).
CLEANPATH="$DOTNET_HOME:${GOTC:+$GOTC/bin:}/usr/local/bin:/usr/bin:/bin"
mkdir -p "$W/home"
run_env() { env -i HOME="$W/home" PATH="$CLEANPATH" LANG=C.UTF-8 TMPDIR="$W/tmp" \
  DOTNET_ROOT="$DOTNET_HOME" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 NUGET_PACKAGES="$HOME/.nuget/packages" \
  DOTNET_CLI_HOME="$W/home" AGENT_HOME="$HOME" \
  GOROOT="${GOTC:-}" GOTOOLCHAIN=local GOPATH="$HOME/go" GOMODCACHE="$HOME/go/pkg/mod" GOCACHE="$HOME/.cache/go-build" GOWORK=off GOFLAGS=-mod=mod CI=1 \
  ${CHROME_BIN:+CHROME_BIN="$CHROME_BIN"} "${EXTRA_ENV[@]}" "$@"; }
# output that means "the harness could not set this up", not "the code is wrong"
SETUP_SIG='The local source .* does(n.t| not) exist|ENOTCACHED|EAI_AGAIN|ETIMEDOUT|could not resolve host|Unable to load the service index|No binary for ChromeHeadless|No such file or directory: .*(chrome|chromium)|repository root .* not found|connection refused|ECONNREFUSED|is either not running|Testcontainers'
[ -n "$EXTRA_SETUP_SIG" ] && SETUP_SIG="$SETUP_SIG|$EXTRA_SETUP_SIG"
SVC_BLOCKED=0
step() { # step <name> <cmd...>
  local name="$1"; shift; local t0 out; t0=$(date +%s); out="$W/tmp/step.out"
  if [ "$SVC_BLOCKED" = 1 ]; then echo "SKIP  $name   (an earlier set-up step for this service could not run)"; return; fi
  if ( run_env "$@" ) >"$out" 2>&1; then cat "$out" >>"$LOG"; STEPS+=("PASS|$name|$(( $(date +%s)-t0 ))s"); echo "PASS  $name"
  else cat "$out" >>"$LOG"
    if /usr/bin/grep -qiE "$SETUP_SIG" "$out"; then setup_fail "$name could not run here ($(/usr/bin/grep -oiE "$SETUP_SIG" "$out" | head -1))"; SVC_BLOCKED=1
    else STEPS+=("FAIL|$name|$(( $(date +%s)-t0 ))s"); echo "FAIL  $name   (see $LOG)"; FAILS=$((FAILS+1)); fi
  fi
}

# --- source at the exact commit, clean ---
if [ ! -d "$W/src/.git" ]; then
  git clone --filter=blob:none -q "$REMOTE" "$W/src" >>"$LOG" 2>&1 || { echo "SETUP FAIL: clone $REMOTE"; exit 2; }
fi
git -C "$W/src" fetch -q origin >>"$LOG" 2>&1; git -C "$W/src" fetch -q origin "$SHA" >>"$LOG" 2>&1
git -C "$W/src" checkout -q --detach "$SHA" >>"$LOG" 2>&1 || { echo "SETUP FAIL: commit $SHA not found in $REMOTE"; exit 2; }
{ git -C "$W/src" reset -q --hard "$SHA" && git -C "$W/src" clean -qffdx; } || { echo "SETUP FAIL: could not clean the tree"; exit 2; }
[ "$(git -C "$W/src" rev-parse HEAD)" = "$SHA" ] || { echo "SETUP FAIL: HEAD is not $SHA"; exit 2; }
MB=$(git -C "$W/src" merge-base "$SHA" "$BASE" 2>/dev/null) || { echo "SETUP FAIL: no merge-base with $BASE"; exit 2; }
mapfile -t CHANGED < <(git -C "$W/src" diff --name-only "$MB" "$SHA")
echo "commit ${SHA:0:12} vs $BASE: ${#CHANGED[@]} files changed"
[ "${#CHANGED[@]}" -gt 0 ] || { echo "SETUP FAIL: nothing changed vs $BASE — nothing to test"; exit 2; }
mapfile -t DIRS < <(printf '%s\n' "${CHANGED[@]}" | awk -F/ 'NF>1{print $1}' | sort -u)
cd "$W/src" || exit 2

# --- .NET projects packed first when the app says so (as its Dockerfiles do) ---
if [ "${#DOTNET_PREPACK[@]}" -gt 0 ] && ls -d "$DOTNET_HOME"/sdk/"${DOTNET_CHANNEL%%.*}".* >/dev/null 2>&1; then
  mkdir -p nupkg
  for pj in "${DOTNET_PREPACK[@]}"; do
    [ -f "$pj" ] || continue
    if ( run_env dotnet build "$pj" -c Release --nologo -v q && run_env dotnet pack "$pj" -c Release -o nupkg --nologo -v q ) >>"$LOG" 2>&1; then
      DEVIATIONS+=("packed $pj into ./nupkg first (local_verify.dotnet_prepack)")
    else setup_fail "dotnet pack $pj (local_verify.dotnet_prepack) failed"; fi
  done
fi

# --- per changed service ---
for d in "${DIRS[@]}"; do
  [ -d "$d" ] || continue
  ran=0; SVC_BLOCKED=0
  if [ -f "$d/go.mod" ] && [ -z "$(find "$d" -name '*.go' -not -path '*/vendor/*' -print -quit)" ]; then
    DEVIATIONS+=("$d: go.mod but no Go code — Go steps skipped")
  elif [ -f "$d/go.mod" ]; then
    if [ -z "$GOTC" ]; then setup_fail "no Go >=$GO_MIN toolchain cached (needed for $d)"
    else
      src="$W/src/$d"; ok=1; MF=""
      for rep in "${GO_REPLACE[@]}"; do
        IFS='|' read -r RMOD RGIT RSHA <<<"$rep"
        grep -q "$RMOD" "$d/go.mod" || continue
        RD="$HOME_RUN/.cache/local-verify/replace-${RSHA:0:12}"
        if [ "$(git -C "$RD" rev-parse HEAD 2>/dev/null)" != "$RSHA" ]; then
          rm -rf "$RD"
          { git clone -q --filter=blob:none "$RGIT" "$RD" && git -C "$RD" checkout -q --detach "$RSHA"; } >>"$LOG" 2>&1 \
            || { setup_fail "$RMOD pinned at $RSHA not fetchable"; ok=0; }
        fi
        if [ "$ok" = 1 ]; then
          [ -n "$MF" ] || { MF="$BUILD/${d//\//_}.go.mod"; cp "$d/go.mod" "$MF"; [ -f "$d/go.sum" ] && cp "$d/go.sum" "${MF%.mod}.sum"; }
          if ( run_env go mod edit -replace "$RMOD=$RD" "$MF" && cd "$d" && run_env go mod tidy -modfile="$MF" ) >>"$LOG" 2>&1; then
            DEVIATIONS+=("$d: alternate go.mod: $RMOD pinned to ${RSHA:0:12} + go mod tidy (local_verify.go_replace)")
          else setup_fail "$d: replace $RMOD + go mod tidy failed"; ok=0; fi
        fi
      done
      if [ "$ok" = 1 ]; then
        GMF=${MF:+-modfile=$MF}
        step "$d: go build" bash -c "cd '$src' && go build $GMF ./..."
        step "$d: go vet"   bash -c "cd '$src' && go vet $GMF ./..."
        if [ -n "$(find "$d" -name '*_test.go' -not -path '*/vendor/*' -print -quit)" ]; then
          step "$d: go test" bash -c "cd '$src' && go test $GMF ./... -count=1"; ran=1
        else DEVIATIONS+=("$d: build only — no Go tests"); BUILD_ONLY=$((BUILD_ONLY+1)); fi
      fi
    fi
  fi
  if ls "$d"/*.csproj >/dev/null 2>&1; then
    if ! ls -d "$DOTNET_HOME"/sdk/"${DOTNET_CHANNEL%%.*}".* >/dev/null 2>&1; then setup_fail "no .NET $DOTNET_CHANNEL SDK in ~/.dotnet (needed for $d)"
    else
      step "$d: dotnet build" dotnet build "$d" -c Release --nologo -v q
      # unit tests: every test project (a .csproj under a tests/ folder or named *Tests) that references this
      # service or compiles its source files. A service with no test project is BUILD-ONLY → never a plain PASS.
      nt=0
      while IFS= read -r t; do
        [ -f "$t" ] || continue
        case "$t" in "$d"/*) continue ;; esac
        if printf '%s\n' "${DOTNET_PREPACK[@]}" | /usr/bin/grep -qx "$d/$(basename "$d").csproj" \
           || /usr/bin/grep -qE "(ProjectReference|Compile)[^>]*Include=\"[^\"]*[\\/]$d[\\/]" "$t"; then
          step "$(dirname "$t"): dotnet test" dotnet test "$t" -c Release --nologo -v q --logger "console;verbosity=normal"; nt=$((nt+1))
        fi
      done < <(find . -path ./nupkg -prune -o \( -path '*/tests/*' -o -name '*Tests.csproj' \) -name '*.csproj' -print | sed 's#^\./##' | sort -u)
      if [ "$nt" = 0 ]; then DEVIATIONS+=("$d: build only — no test project covers it"); BUILD_ONLY=$((BUILD_ONLY+1)); else ran=1; fi
    fi
  fi
  if [ -f "$d/package.json" ]; then
    step "$d: npm ci" bash -c "cd '$d' && npm ci --no-audit --no-fund"
    step "$d: npm build" bash -c "cd '$d' && npm run -s build --if-present"
    if grep -q '"test"' "$d/package.json"; then step "$d: npm test" bash -c "cd '$d' && npm test -s -- $NPM_TEST_ARGS"; ran=1
    else DEVIATIONS+=("$d: build only — no npm test script"); BUILD_ONLY=$((BUILD_ONLY+1)); fi
  fi
  [ "$ran" = 1 ] && COVERED+=("$d/")
done
# single-project repo: the root package.json covers changes not under a sub-project
if [ -f package.json ]; then
  root_needed=0
  for f in "${CHANGED[@]}"; do
    top="${f%%/*}"
    if [ "$top" = "$f" ] || ! { [ -f "$top/package.json" ] || [ -f "$top/go.mod" ] || ls "$top"/*.csproj >/dev/null 2>&1; }; then root_needed=1; break; fi
  done
  if [ "$root_needed" = 1 ]; then
    SVC_BLOCKED=0
    step "root: npm ci" npm ci --no-audit --no-fund
    step "root: npm build" npm run -s build --if-present
    if grep -q '"test"' package.json; then
      if [[ "$ROOT_NPM_TEST_ARGS" == *Chrome* ]] && [ -z "$CHROME_BIN" ]; then setup_fail "root npm test needs a headless Chrome (none installed)"
      else step "root: npm test" npm test -s -- $ROOT_NPM_TEST_ARGS; COVERED+=("*"); fi
    else DEVIATIONS+=("root: build only — no npm test script"); BUILD_ONLY=$((BUILD_ONLY+1)); fi
  fi
fi

# --- optional project test commands (repos[].local_verify.commands): for a repo whose tests are not a Go / .NET / npm
# project the steps above can find (e.g. a single-file app with `node tests/run-all.mjs`). Each runs from the repo
# root in the scrubbed environment; $AGENT_HOME is this agent's real home (toolchains live there: the step's own HOME
# is an empty per-run folder). A command that exits non-zero is a FAIL; all of them passing covers the whole tree. ---
if [ "${#CUSTOM_CMDS[@]}" -gt 0 ] && [ "${#CHANGED[@]}" -gt 0 ]; then
  SVC_BLOCKED=0
  ci=0
  for c in "${CUSTOM_CMDS[@]}"; do ci=$((ci+1)); step "custom $ci: ${c:0:60}" bash -c "$c"; done
  COVERED+=("*")
fi

# --- optional local full stack (repos[].local_verify.full_stack): Postgres + Azurite + integration tests ---
if [ "$FULL" = 1 ]; then
  mkdir -p "$S"
  if [ "$FS_PG" = 1 ]; then
    [ -x "$S/pg/node_modules/@embedded-postgres/linux-x64/native/bin/pg_ctl" ] || \
      npm install --prefix "$S/pg" @embedded-postgres/linux-x64@16.14.0-beta.17 >>"$LOG" 2>&1 || setup_fail "embedded postgres install"
    PGB="$S/pg/node_modules/@embedded-postgres/linux-x64/native/bin"
    if [ -x "$PGB/pg_ctl" ]; then
      rm -rf "$S/data"; PW=$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9); printf '%s' "$PW" > "$S/pw"
      if "$PGB/initdb" -D "$S/data" -U "$FS_PG_USER" --pwfile "$S/pw" -A scram-sha-256 >>"$LOG" 2>&1 \
         && "$PGB/pg_ctl" -D "$S/data" -o "-p $FS_PG_PORT -k $S -c listen_addresses=127.0.0.1" -l "$S/pg.log" -w start >>"$LOG" 2>&1; then
        compgen -G "$FS_PG_MIGRATIONS" >/dev/null || setup_fail "no $FS_PG_MIGRATIONS at this commit"
        printf '127.0.0.1:%s:*:%s:%s\n' "$FS_PG_PORT" "$FS_PG_USER" "$PW" > "$S/pgpass"     # password by file, never on a command line
        EXTRA_ENV=(PGPASSFILE="$S/pgpass")
        step "postgres: apply migrations" bash -c "set -e; for f in \$(ls $FS_PG_MIGRATIONS | sort -V); do '$PGB/psql' -h 127.0.0.1 -p $FS_PG_PORT -U $FS_PG_USER -d postgres -v ON_ERROR_STOP=1 -q -f \"\$f\"; done"
        CS="Host=127.0.0.1;Port=$FS_PG_PORT;Database=postgres;Username=$FS_PG_USER;Password=$PW"
        for v in "${FS_PG_ENV[@]}"; do EXTRA_ENV+=("$v=$CS"); done; unset CS
      else setup_fail "postgres initdb/start"; fi
    fi
  fi
  if [ "$FS_AZ" = 1 ]; then
    [ -x "$S/az/node_modules/.bin/azurite-blob" ] || npm install --prefix "$S/az" azurite@3 >>"$LOG" 2>&1
    if [ -x "$S/az/node_modules/.bin/azurite-blob" ]; then
      "$S/az/node_modules/.bin/azurite-blob" --blobPort "$FS_AZ_PORT" --location "$S/azdata" >"$S/az.log" 2>&1 & AZPID=$!
      for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>"/dev/tcp/127.0.0.1/$FS_AZ_PORT") 2>/dev/null && break; sleep 1; done
      (exec 3<>"/dev/tcp/127.0.0.1/$FS_AZ_PORT") 2>/dev/null || setup_fail "azurite did not start on :$FS_AZ_PORT"
      [ -n "$FS_AZ_ENV" ] && EXTRA_ENV+=("$FS_AZ_ENV=http://127.0.0.1:$FS_AZ_PORT/devstoreaccount1")
    else setup_fail "azurite install"; fi
  fi
  n=0
  for t in $FS_IT_GLOB; do
    ls "$t"*.csproj >/dev/null 2>&1 || continue; n=$((n+1))
    step "integration: $(basename "$t")" dotnet test "$t" -c Release --nologo -v q
  done
  [ "$n" -gt 0 ] || setup_fail "--full-stack: no integration test projects match $FS_IT_GLOB at this commit"
  EXTRA_ENV=()
fi
# the local DB password must never stay in the log (a failing test may print its connection string)
[ -n "$PW" ] && sed -i "s/$PW/<redacted>/g" "$LOG"; PW=""

# --- changed files no step covered ---
declare -a UNCOVERED=()
for f in "${CHANGED[@]}"; do
  case "$f" in *.md|docs/*|*.txt|LICENSE|.github/*) continue ;; esac
  ok=0; for c in "${COVERED[@]}"; do { [ "$c" = "*" ] || [[ "$f" == "$c"* ]]; } && ok=1; done
  [ "$ok" = 1 ] || UNCOVERED+=("$f")
done
[ "${#UNCOVERED[@]}" -gt 0 ] && echo "UNCOVERED (no local step tests these): ${UNCOVERED[*]:0:12}"
[ -z "$(git -C "$W/src" status --porcelain -- . ':!nupkg' ':!**/bin' ':!**/obj')" ] || setup_fail "the source tree was modified during the run"

# --- result: exit code = verdict ---
python3 -I - "$W/result.json" "$APP" "$SHA" "$BASE" "$FAILS" "$SETUP_FAIL" "${#UNCOVERED[@]}:$BUILD_ONLY" \
  "$(printf '%s\n' "${DEVIATIONS[@]}")" "$(printf '%s\n' "${UNCOVERED[@]}")" "${STEPS[@]}" <<'EOF'
import json, sys
out, app, sha, base, fails, setup, counts, devs, unc = sys.argv[1:10]
nunc, nbuild = (int(x) for x in counts.split(":"))
steps = [dict(zip(("result", "step", "took"), s.split("|", 2))) for s in sys.argv[10:]]
verdict = "FAIL" if int(fails) else ("UNVERIFIED" if (int(setup) or not steps or nunc or nbuild) else "PASS")
json.dump({"app": app, "commit": sha, "base": base, "verdict": verdict, "steps": steps,
           "deviations": [d for d in devs.splitlines() if d], "uncovered": [u for u in unc.splitlines() if u],
           "setup_failed": bool(int(setup))}, open(out, "w"), indent=1)
print(f"\nVERDICT {verdict}: {sum(s['result']=='PASS' for s in steps)} passed, {int(fails)} failed"
      + (", setup incomplete" if int(setup) else "") + (f", {nunc} changed file(s) not covered" if nunc else "") + (f", {nbuild} build-only service(s)" if nbuild else "")
      + f"  → {out}")
sys.exit({"PASS": 0, "FAIL": 1}.get(verdict, 2))
EOF
