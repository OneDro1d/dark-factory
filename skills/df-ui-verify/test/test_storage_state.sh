#!/usr/bin/env bash
# Unit: storageState assembly — the pure function, no network.
# Entry point is test-df-ui-verify.sh, which sums the ASSERTIONS line below.
#
# APP_ORIGIN is a PLACEHOLDER. A real app origin is a landmark: it names a deployment.
# The assertions care that the host is derived from the origin, not what the host is.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../scripts/lib/storage-state.sh"

ORIGIN="https://app.example.com"
HOST="app.example.com"

fail=0
n=0
out="$(assemble_storage_state "DBJWT123" "SESSJWT456" "$ORIGIN" 1750000000)"
check() {
  n=$((n + 1))
  if echo "$out" | jq -e "$1" >/dev/null; then echo "ok: $2"; else echo "FAIL: $2"; fail=1; fi
}

check '.cookies[] | select(.name=="__session" and .value=="SESSJWT456")' "__session cookie = session jwt"
check '.cookies[] | select(.name=="__clerk_db_jwt" and .value=="DBJWT123")' "__clerk_db_jwt cookie"
check '.cookies[] | select(.name=="__client_uat" and (.value|tonumber)>0)' "__client_uat non-zero (signed-in)"
check ".cookies[] | select(.name==\"__session\") | .domain==\"$HOST\"" "cookie domain = app host, derived from the origin"
check ".origins[] | select(.origin==\"$ORIGIN\")" "origin present"
check '.origins[].localStorage[] | select(.name=="__clerk_db_jwt")' "db_jwt mirrored to localStorage"

echo "ASSERTIONS: $n"
exit $fail
