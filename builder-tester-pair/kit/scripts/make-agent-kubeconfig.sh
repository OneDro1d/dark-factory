#!/usr/bin/env bash
# make-agent-kubeconfig.sh — PRINTS the commands the OWNER runs (in their own terminal, with their own identity) to
# give the agent sessions a read-only cluster identity. It applies nothing and mints nothing itself: an agent must
# never create its own credentials. Run it, read the commands, then the owner pastes them (or prefixes with `!`).
#
#   bash kit/scripts/make-agent-kubeconfig.sh --context <kube-context> --namespace <sa-namespace> [--hours 720]
#   bash kit/scripts/make-agent-kubeconfig.sh --verify      # prints the read-only self-check commands
#   bash kit/scripts/make-agent-kubeconfig.sh --no-expiry --context <ctx> --namespace <sa-ns> \
#        [--read-namespace <ns>] [--coder-owner <user>] [--to <other-workspace>]
#
# Defaults: --context = environments[0].cluster from pair.yaml (else the current context); --hours 720 (30 days —
# time-bound on purpose; re-mint when it expires). Output file: ~/.kube/agent-readonly.conf (mode 600). install.sh
# points the agents' settings.json env.KUBECONFIG at it when it exists.
# --no-expiry: the owner's commands for a NON-expiring token instead (a kubernetes.io/service-account-token Secret from
# k8s/agent-readonly-token.yaml; valid until the Secret is deleted), with verification here and a streamed copy to the
# other workspace (`coder ssh <owner.coder_user>/<other workspace>`, verified there too). The token is never printed.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CTX=""; NS=""; HOURS=720; VERIFY=0; NOEXP=0; READNS=""; CODER_OWNER=""; TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX="$2"; shift 2 ;;
    --namespace|-n) NS="$2"; shift 2 ;;
    --hours) HOURS="$2"; shift 2 ;;
    --verify) VERIFY=1; shift ;;
    --no-expiry) NOEXP=1; shift ;;
    --read-namespace) READNS="$2"; shift 2 ;;
    --coder-owner) CODER_OWNER="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$CTX" ]; then
  CTX="$(python3 - "$KIT" <<'PY' 2>/dev/null || true
import sys; sys.path.insert(0, sys.argv[1] + "/kit/lib")
import pairconf
envs = pairconf.get(pairconf.load(), "environments", []) or []
print(next((e.get("cluster", "") for e in envs if isinstance(e, dict) and e.get("cluster")), ""))
PY
)"
fi
CTX="${CTX:-<your-kube-context>}"
NS="${NS:-<namespace-you-control>}"
OUT='$HOME/.kube/agent-readonly.conf'

if [ "$NOEXP" = 1 ]; then
  # pair.yaml: a namespace to prove a real read in, the coder owner and the OTHER workspace (the one this host is not).
  IFS=$'\t' read -r P_READNS P_OWNER P_TO <<<"$(python3 - "$KIT" <<'PY' 2>/dev/null || printf '\t\t\n'
import sys; sys.path.insert(0, sys.argv[1] + "/kit/lib")
import pairconf
c = pairconf.load(); g = lambda k, d="": pairconf.get(c, k, d) or d
ns = ""
for r in g("repos", []) or []:
    if isinstance(r, dict) and (r.get("sut_namespaces") or r.get("infra")):
        ns = (r.get("sut_namespaces") or r.get("infra"))[0]; break
role = pairconf.role(c)
other = g("builder.workspace") if role == "tester" else g("tester.workspace")
print("\t".join([str(ns), str(g("owner.coder_user")), str(other)]))
PY
)"
  READNS="${READNS:-${P_READNS:-default}}"
  CODER_OWNER="${CODER_OWNER:-${P_OWNER:-<coder-owner>}}"
  TO="${TO:-${P_TO:-<other-workspace>}}"
  cat <<EOF
# ---- For the OWNER to run, in the owner's own terminal (uses the owner's identity) ----
# NON-EXPIRING read-only token: valid until the Secret is deleted (see the undo at the bottom).
# Needs the agent-readonly ServiceAccount from k8s/agent-readonly.yaml (the default mode's step 1) to exist in $NS.
( set -euo pipefail; umask 077; CTX=$CTX; NS=$NS; OUT=$OUT; mkdir -p "\$(dirname "\$OUT")"
  echo "1/5 create the token Secret (cluster change)"
  sed 's/__SA_NAMESPACE__/$NS/g' "$KIT/k8s/agent-readonly-token.yaml" | kubectl --context "\$CTX" apply -f -

  echo "2/5 wait for the cluster to fill in the token (length only)"
  n=0; for i in \$(seq 1 30); do
    n=\$(kubectl --context "\$CTX" -n "\$NS" get secret agent-readonly-token -o jsonpath='{.data.token}' | wc -c)
    [ "\$n" -gt 100 ] && break; sleep 2
  done
  [ "\$n" -gt 100 ] || { echo "token not populated after 60s"; exit 1; }

  echo "3/5 write \$OUT (token never printed)"
  CA="\$(mktemp)"; trap 'rm -f "\$CA"' EXIT
  SERVER="\$(kubectl config view --context "\$CTX" --minify --raw -o jsonpath='{.clusters[0].cluster.server}')"
  kubectl config view --context "\$CTX" --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "\$CA"
  TOKEN="\$(kubectl --context "\$CTX" -n "\$NS" get secret agent-readonly-token -o jsonpath='{.data.token}' | base64 -d)"
  NEW="\$OUT.new"; rm -f "\$NEW"
  KUBECONFIG="\$NEW" kubectl config set-cluster agent-cluster --server="\$SERVER" --certificate-authority="\$CA" --embed-certs=true >/dev/null
  KUBECONFIG="\$NEW" kubectl config set-credentials agent-readonly --token="\$TOKEN" >/dev/null
  KUBECONFIG="\$NEW" kubectl config set-context agent-readonly --cluster=agent-cluster --user=agent-readonly >/dev/null
  KUBECONFIG="\$NEW" kubectl config use-context agent-readonly >/dev/null
  unset TOKEN; chmod 600 "\$NEW"; mv "\$NEW" "\$OUT"

  echo "4/5 verify here (identity, a real read, secrets refused, no writes, no expiry claim)"
  echo "  identity: \$(kubectl --kubeconfig "\$OUT" auth whoami -o jsonpath='{.status.userInfo.username}')"
  echo "  get pods -n $READNS: \$(kubectl --kubeconfig "\$OUT" -n $READNS get pods --no-headers | wc -l) rows"
  echo "  get secrets -n $READNS: \$(kubectl --kubeconfig "\$OUT" -n $READNS get secrets 2>&1 | grep -o Forbidden | head -1)   (expect Forbidden)"
  echo "  can-i patch deployments -n $READNS: \$(kubectl --kubeconfig "\$OUT" auth can-i patch deployments -n $READNS)   (expect no)"
  python3 - "\$OUT" <<'PYEXP'
import base64, json, re, sys
t = re.search(r"token: (\S+)", open(sys.argv[1]).read()).group(1)
p = json.loads(base64.urlsafe_b64decode(t.split(".")[1] + "=="))
print("  token expiry:", "NONE (non-expiring)" if "exp" not in p else "exp claim present: " + str(p["exp"]))
PYEXP

  echo "5/5 copy to $TO (streamed, never printed) and verify there"
  coder ssh $CODER_OWNER/$TO -- 'umask 077; mkdir -p ~/.kube; cat > ~/.kube/agent-readonly.conf.new && mv ~/.kube/agent-readonly.conf.new ~/.kube/agent-readonly.conf' < "\$OUT" 2>/dev/null
  coder ssh $CODER_OWNER/$TO -- 'K=~/.kube/agent-readonly.conf; echo "  $TO identity: \$(kubectl --kubeconfig \$K auth whoami -o jsonpath="{.status.userInfo.username}"); pods -n $READNS: \$(kubectl --kubeconfig \$K -n $READNS get pods --no-headers | wc -l); patch: \$(kubectl --kubeconfig \$K auth can-i patch deployments -n $READNS)"' 2>/dev/null
  echo "done — both workspaces use the non-expiring read-only token. Re-run ./install.sh in each so env.KUBECONFIG points at it." )

# Undo (revokes instantly; both agents lose cluster read access until a token is minted again):
#   kubectl --context $CTX -n $NS delete secret agent-readonly-token
EOF
  exit 0
fi

if [ "$VERIFY" = 1 ]; then
  cat <<EOF
# Read-only self-check of $OUT (safe for anyone to run; prints no token):
kubectl --kubeconfig $OUT auth whoami -o jsonpath='{.status.userInfo.username}'; echo
for ns in default kube-system; do
  for v in "get pods" "create deployments" "patch deployments" "get secrets" "create pods/exec"; do
    printf '%-12s %-20s %s\n' "\$ns" "\$v" "\$(kubectl --kubeconfig $OUT auth can-i \$v -n \$ns)"
  done
done
# expected: get pods = yes, everything else = no
EOF
  exit 0
fi

cat <<EOF
# ---- For the OWNER to run, in the owner's own terminal (uses the owner's identity) ----
# 1. Create the read-only ServiceAccount + ClusterRole + binding (once):
sed 's/__SA_NAMESPACE__/$NS/g' "$KIT/k8s/agent-readonly.yaml" | kubectl --context $CTX create -f -

# 2. Mint a time-bound kubeconfig for the agents (${HOURS}h). The token is never printed:
( set -euo pipefail; umask 077; OUT=$OUT; mkdir -p "\$(dirname "\$OUT")"
  CA="\$(mktemp)"; trap 'rm -f "\$CA"' EXIT
  SERVER="\$(kubectl config view --context $CTX --minify --raw -o jsonpath='{.clusters[0].cluster.server}')"
  kubectl config view --context $CTX --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "\$CA"
  TOKEN="\$(kubectl --context $CTX -n $NS create token agent-readonly --duration=${HOURS}h)"
  KUBECONFIG="\$OUT" kubectl config set-cluster agent-cluster --server="\$SERVER" --certificate-authority="\$CA" --embed-certs=true >/dev/null
  KUBECONFIG="\$OUT" kubectl config set-credentials agent-readonly --token="\$TOKEN" >/dev/null
  KUBECONFIG="\$OUT" kubectl config set-context agent-readonly --cluster=agent-cluster --user=agent-readonly >/dev/null
  KUBECONFIG="\$OUT" kubectl config use-context agent-readonly >/dev/null
  unset TOKEN; chmod 600 "\$OUT"; echo "written: \$OUT (valid ${HOURS}h)" )

# 3. Copy ~/.kube/agent-readonly.conf into EACH agent workspace's ~/.kube/ (mode 600), then re-run ./install.sh there
#    so settings.json env.KUBECONFIG points the agent's kubectl at it. Check it:
#      bash $KIT/kit/scripts/make-agent-kubeconfig.sh --verify
#
# Revoke at any time:
#   kubectl --context $CTX delete clusterrolebinding agent-readonly
#   kubectl --context $CTX delete clusterrole agent-readonly
#   kubectl --context $CTX -n $NS delete sa agent-readonly
EOF
