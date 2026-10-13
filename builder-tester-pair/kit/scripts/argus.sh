#!/usr/bin/env bash
# argus.sh — one generic front door to Argus, for any app, from the tester or builder workspace.
#
# Generalises the upstream helper scripts (which hardcode scratch paths and the in-cluster
# Service). Workspaces outside the control plane's NetworkPolicy may not reach that Service (it times out),
# so this script talks to the INGRESS host and trusts the self-signed estate wildcard instead.
#
#   argus.sh setup                     build the CLI with your Argus host + trust bundle (no secrets)
#   argus.sh login                     human step: Clerk sign-in, author scope
#   argus.sh doctor [kit]              read-only health of creds/config/executor
#   argus.sh validate <kit>            validate argus-config + every scenario (no token needed)
#   argus.sh onboard <app> <sut-ns> <workspace-id> <image@sha256:...>   (TESTER, 900 s window)
#   argus.sh seed <app>                upload the kit's scenarios to the catalog   (TESTER)
#   argus.sh run <app> [tag]           request a run and wait for the verdict       (TESTER)
#   argus.sh status <app>              executor registered / poll_accepted
#   argus.sh schedule <app> [1h]       hourly monitor schedule                      (TESTER)
#
# Kits live in $ARGUS_KITS (default ~/argus-kits/<app>/{argus-config.yaml,scenarios/}) — in the
# TESTER's workspace only. Tokens: ~/.config/argus/tokens/<app>.author (mode 600, never printed).
# Nothing here prints a secret. Kubernetes Secrets are created, never applied.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PC() { python3 "$KIT/kit/lib/pairconf.py" "$@"; }
SHARED_ROOT="$(PC get paths.shared_root)"
TESTER_HOST="$(PC get tester.host)"
CP="${ARGUS_CP_URL:-$(PC get argus.url)}"
[ -n "$CP" ] || { echo "argus.sh: set argus.url in pair.yaml (Argus is optional)" >&2; exit 1; }
CP_HOST="${CP#https://}"; CP_HOST="${CP_HOST%%/*}"
# The tester's full clone (with kits/) lives in ITS OWN home — the shared folder is mounted by every workspace,
# including the builder's, so a tester repo under the shared folder would hand the builder the checks.
# The tester hat is bound to the WORKSPACE (as in argus-guard): an env var alone cannot make a
# builder the tester — otherwise `ARGUS_HAT=tester argus.sh setup` would full-clone the checks
# into the builder's own home.
TESTER_WORKSPACES="$(PC get tester.workspace)"
if [ "${ARGUS_HAT:-}" = tester ] && ! printf ' %s ' $TESTER_WORKSPACES | grep -q " ${CODER_WORKSPACE_NAME:-none} "; then
  echo "argus.sh: ARGUS_HAT=tester outside a tester workspace (${CODER_WORKSPACE_NAME:-unknown}; allowed: $TESTER_WORKSPACES) — refusing" >&2; exit 1
fi
if [ "${ARGUS_HAT:-}" = tester ]; then
  REPO="${ARGUS_REPO:-$HOME/argus-src}"
  case "$REPO" in "$SHARED_ROOT"/*) echo "argus.sh: refusing tester repo under the shared folder ($REPO) — shared with the builder" >&2; exit 1;; esac
else
  REPO="${ARGUS_REPO:-$SHARED_ROOT/argus-src}"            # builder: history-free snapshot, no kits/
fi
KITS="${ARGUS_KITS:-$HOME/argus-kits}"
case "$KITS" in "$SHARED_ROOT"/*) echo "argus.sh: refusing kits under the shared folder ($KITS) — shared with the builder" >&2; exit 1;; esac
TOK="${ARGUS_TOKEN_DIR:-$HOME/.config/argus/tokens}"
CTX="${ARGUS_KUBE_CONTEXT:-$(PC get argus.kube_context)}"
CA="$HOME/.config/argus/ca-bundle.crt"
ARGUS="${ARGUS_BIN:-$HOME/.local/bin/argus}"
OUT="${ARGUS_OUT:-$HOME/.cache/argus-out}"
INGRESS_IP=10.36.64.17
# The self-signed estate wildcard is trusted ONLY for Argus calls. Exporting SSL_CERT_FILE globally
# replaced the system trust for git too, and git's Coder credential helper then failed with
# "x509: certificate signed by unknown authority" (seen on the tester workspace, 2026-10-10).
argus() { SSL_CERT_FILE="$CA" REQUESTS_CA_BUNDLE="$CA" "$ARGUS" "$@"; }
author_call() { SSL_CERT_FILE="$CA" REQUESTS_CA_BUNDLE="$CA" ARGUS_CP_URL="$CP" ARGUS_EXECUTOR_SECRET_FILE="$TOK/$APP.author" python3 "$REPO/scripts/argus-author-call.py" "$@"; }

die() { echo "argus.sh: $*" >&2; exit 1; }
need_tester() { [ "${ARGUS_HAT:-}" = tester ] || die "this step belongs to the TESTER workspace (export ARGUS_HAT=tester there). The builder never holds scenarios."; }
author_tok() {
  [ -s "$TOK/$1.author" ] || die "no $TOK/$1.author — mint a workspace-bound author token for $1 (skill §3.3) and save it there, mode 600"
  ARGUS_CP_AUTHOR_TOKEN="$(tr -d '[:space:]' < "$TOK/$1.author")"; export ARGUS_CP_AUTHOR_TOKEN
}

cmd="${1:-}"; shift || true
case "$cmd" in
setup)
  mkdir -p "$(dirname "$CA")" "$HOME/.local/bin"
  echo | openssl s_client -connect "$INGRESS_IP:443" -servername "$CP_HOST" 2>/dev/null \
    | openssl x509 -out "$HOME/.config/argus/aks-dev-scus-wildcard.crt"
  cp /etc/ssl/certs/ca-certificates.crt "$CA"
  openssl x509 -in "$HOME/.config/argus/aks-dev-scus-wildcard.crt" >> "$CA"
  echo "trust bundle: $CA ($(wc -c < "$CA") bytes)"
  URL="$(PC get argus.source_repo)"; [ -n "$URL" ] || die "set argus.source_repo (git URL of the Argus source) in pair.yaml"
  if [ "${ARGUS_HAT:-}" = tester ]; then
    [ -d "$REPO/.git" ] || git clone -q "$URL" "$REPO"
  elif [ ! -d "$REPO" ]; then
    # Builder: a HISTORY-FREE snapshot without kits/. A sparse checkout is not enough — it hides
    # the files from the working tree but keeps every scenario blob in .git, readable with
    # `git cat-file -p` / `git archive` / `git log -p`.
    # A blob:none clone fetches only the blobs `archive` asks for, so kits/ never lands at all.
    T="$(mktemp -d)"
    git clone -q --filter=blob:none --no-checkout "$URL" "$T/src"
    mkdir -p "$REPO"
    git -C "$T/src" archive HEAD -- . ':(exclude)kits' ':(exclude)examples/**/scenarios*' | tar -x -C "$REPO"
    git -C "$T/src" rev-parse --short HEAD > "$REPO/.argus-src-commit"
    rm -rf "$T"
  fi
  if [ "${ARGUS_HAT:-}" != tester ]; then
    # -e, not -d: a worktree or --separate-git-dir clone has a .git FILE that still reaches every blob.
    [ -e "$REPO/.git" ] && die "$REPO is a git clone/worktree on a BUILDER — it carries the scenarios. Remove it and re-run setup."
    [ -n "$(find "$REPO" -maxdepth 3 -type d \( -name kits -o -name test-agent \) -print -quit 2>/dev/null)" ] \
      && die "$REPO contains a kits/ or test-agent/ directory on a BUILDER. Remove it and re-run setup."
  fi
  COMMIT="$(cat "$REPO/.argus-src-commit" 2>/dev/null || git -C "$REPO" rev-parse --short HEAD)"
  # `|| true`: with set -euo pipefail a no-match `ls` used to end the script silently (rc=2).
  TC=$(ls -d "$HOME"/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.26.* 2>/dev/null | sort -V | tail -1 || true)
  if [ -z "$TC" ]; then
    # No cached Go 1.26 here: fetch the toolchain go.mod asks for ONCE, through the public proxy.
    # The build below stays offline (vendored modules, GOPROXY=off); only the compiler is downloaded.
    WANT=$(awk '$1=="toolchain"{print $2}' "$REPO/go.mod"); WANT=${WANT:-go1.26.5}
    echo "fetching Go toolchain $WANT (one time)"
    ( cd "$REPO" && GOTOOLCHAIN="$WANT" GOPROXY=https://proxy.golang.org GOFLAGS= go version ) \
      || die "could not fetch Go toolchain $WANT"
    TC=$(ls -d "$HOME"/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.26.* 2>/dev/null | sort -V | tail -1 || true)
    [ -n "$TC" ] || die "toolchain $WANT fetched but not found under ~/go/pkg/mod/golang.org"
  fi
  export GOROOT="$TC" PATH="$TC/bin:$PATH" GOTOOLCHAIN=local
  PKG="$(awk '/^module /{print $2; exit}' "$REPO/go.mod")/internal/buildinfo"   # the Argus source's own module path
  V="${ARGUS_VERSION:-$(PC get argus.version)}"
  ( cd "$REPO" && GOFLAGS=-mod=vendor GOPROXY=off go build -o "$ARGUS" -ldflags \
      "-X $PKG.ControlPlaneURL=$CP -X $PKG.GrafanaURL=$CP -X $PKG.DocsURL=$CP -X $PKG.Version=$V -X $PKG.Commit=$COMMIT" ./cmd/argus )
  argus version | grep -E '"(version|control_plane)"'
  argus version | grep -q "\"control_plane\": *\"$CP\"" && echo "hosts OK (configured host)" || die "binary does not name $CP as its control plane — rebuild" ;;
login)
  echo "Opens a Clerk sign-in. Pick scope AUTHOR only in the tester workspace; a builder signs in with --scope runner."
  argus cloud-login --control-plane "$CP" --scope "${1:-author}" ;;
doctor)
  if [ -n "${1:-}" ]; then argus doctor --control-plane "$CP" --config "$KITS/$1/argus-config.yaml" --scenarios "$KITS/$1/scenarios"
  else argus doctor --control-plane "$CP"; fi ;;
validate)
  need_tester; K="$KITS/${1:?kit}"
  argus validate-config --config "$K/argus-config.yaml" --scenarios "$K/scenarios" ;;
onboard)
  need_tester
  APP="${1:?app}"; SUT_NS="${2:?sut-namespace}"; WS="${3:?workspace-id}"; IMAGE="${4:?image@sha256}"
  ID="$APP-$(PC get argus.instance_suffix)"; INST_NS="argus-inst-$ID"; O="$OUT/$ID"; mkdir -p -m 700 "$TOK" "$O"
  case "$IMAGE" in *@sha256:*) ;; *) die "deploy by digest, never a tag" ;; esac
  author_tok "$APP"; export ARGUS_WORKSPACE_ID="$WS"
  argus validate-config --config "$KITS/$APP/argus-config.yaml" >/dev/null
  echo "enrolling $ID — the 900 s window starts NOW"
  argus cloud-enroll --control-plane "$CP" --instance-id "$ID" --token-dir "$TOK"
  ARGUS_ENROLLMENT_TOKEN="$(tr -d '[:space:]' < "$TOK/$ID.enrollment")"
  ARGUS_RUNNER_TOKEN="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"
  ARGUS_EXECUTOR_SECRET="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"
  export ARGUS_ENROLLMENT_TOKEN ARGUS_RUNNER_TOKEN ARGUS_EXECUTOR_SECRET
  # Executors live in-cluster and DO reach the in-cluster Service; render with that URL.
  ( cd "$KITS" && argus render-k8s --config "$APP/argus-config.yaml" --instance-id "$ID" \
      --sut-namespace "$SUT_NS" --image "$IMAGE" --tier aks --replicas 1 --kube-context "$CTX" \
      --control-plane "$(PC get argus.control_service)" \
      --obs-storage-class managed-csi-tagged --scenarios "$APP/scenarios" --out "$O" >/dev/null )
  unset ARGUS_ENROLLMENT_TOKEN ARGUS_RUNNER_TOKEN ARGUS_EXECUTOR_SECRET ARGUS_CP_AUTHOR_TOKEN
  yq -i '(select(.kind=="Deployment" and .metadata.name=="executor") | .spec.template.spec.imagePullSecrets) = [{"name":"registry-pull"}]' "$O/executor.yaml"
  yq -i '(select(.kind=="Namespace") | .metadata.labels."part-of") = "dev-environment"' "$O/executor.yaml"
  kubectl --context "$CTX" create -f "$O/executor.yaml" -f "$O/obs.yaml"
  shred -u "$O/executor.yaml"
  kubectl --context "$CTX" -n "$(PC get argus.control_namespace)" get secret registry-pull -o json \
    | jq 'del(.metadata.namespace,.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields,.metadata.annotations,.metadata.ownerReferences)' \
    | kubectl --context "$CTX" -n "$INST_NS" create -f - >/dev/null && echo "registry-pull copied to $INST_NS"
  "$REPO/$(PC get argus.egress_script)" | bash -s "$INST_NS" "$SUT_NS"
  kubectl --context "$CTX" -n "$INST_NS" rollout status deploy/executor --timeout=420s
  sleep 10; "$0" status "$APP" ;;
seed)
  need_tester; APP="${1:?app}"; author_tok "$APP"
  argus cloud-seed-scenarios --control-plane "$CP" --instance-id "$APP-$(PC get argus.instance_suffix)" --scenarios "$KITS/$APP/scenarios" ;;
run)
  need_tester; APP="${1:?app}"; author_tok "$APP"
  # run <app> [tag]  |  run <app> --scenario <ID>  (one scenario by id — the fix-loop retest; author_request_run scenario_ref)
  if [ "${2:-}" = "--scenario" ]; then
    [[ "${3:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "run $APP --scenario <ID>: give one scenario id"
    ARGS="{\"instance_id\":\"$APP-$(PC get argus.instance_suffix)\",\"scenario_ref\":\"$3\"}"
  else
    ARGS="{\"instance_id\":\"$APP-$(PC get argus.instance_suffix)\"${2:+,\"tag\":\"$2\"}}"
  fi
  author_call author_request_run "$ARGS" --wait ;;
status)
  APP="${1:?app}"; author_tok "$APP"
  argus cloud-executor-status --control-plane "$CP" --instance-id "$APP-$(PC get argus.instance_suffix)" ;;
schedule)
  need_tester; APP="${1:?app}"; author_tok "$APP"
  author_call author_set_schedule \
    "{\"instance_id\":\"$APP-$(PC get argus.instance_suffix)\",\"interval\":\"${2:-1h}\",\"mode\":\"monitor\"}" ;;
*) sed -n '2,20p' "$0"; exit 2 ;;
esac
