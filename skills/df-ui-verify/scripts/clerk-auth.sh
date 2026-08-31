#!/usr/bin/env bash
# df-ui-verify — Clerk auth kernel.
# Phase 1: instance-detect -> dev_browser handshake -> storageState.json + session.jwt
# Sourceable for unit tests via: source clerk-auth.sh --source-only
set -uo pipefail

_CA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/storage-state.sh
source "$_CA_DIR/lib/storage-state.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'. Install: brew install $1" >&2; exit 3; }
}

load_env() {
  local dir="$1"
  if [ -f "$dir/.env.local" ]; then set -a; . "$dir/.env.local"; set +a; fi
}

# detect_instance <secret_key> -> echoes "dev" | "prod"; non-zero on mismatch/unknown.
detect_instance() {
  local key="$1" kind
  case "$key" in
    sk_test_*) kind="dev" ;;
    sk_live_*) kind="prod" ;;
    *) echo "Unrecognized CLERK_SECRET_KEY prefix (need sk_test_ or sk_live_)" >&2; return 2 ;;
  esac
  local fapi="${CLERK_FRONTEND_API:-}"
  case "$fapi" in
    *accounts.dev*)
      if [ "$kind" = "prod" ]; then
        echo "Mismatch: sk_live key with an accounts.dev FAPI ($fapi)" >&2; return 4
      fi
      echo "dev"; return 0 ;;
    *)
      if [ "$kind" = "dev" ]; then
        echo "Mismatch: sk_test key with a non-dev FAPI ($fapi)" >&2; return 4
      fi
      echo "prod"; return 0 ;;
  esac
}

# resolve_user_id <email> -> echoes user_… (Clerk Backend API). Empty on miss.
resolve_user_id() {
  local email="$1"
  curl -sS -G "https://api.clerk.com/v1/users" \
    --data-urlencode "email_address[]=$email" \
    -H "Authorization: Bearer $CLERK_SECRET_KEY" | jq -r '.[0].id // empty'
}

# dev_handshake -> sets DB_JWT TESTING_TOKEN SESSION_ID SESSION_JWT.
dev_handshake() {
  local fapi="$CLERK_FRONTEND_API" origin="${APP_ORIGIN:?set APP_ORIGIN}"
  DB_JWT="$(curl -sS -X POST "$fapi/v1/dev_browser" -H "Origin: $origin" -H "Accept: application/json" | jq -r '.token // empty')"
  [ -n "$DB_JWT" ] || { echo "step1 dev_browser failed (no token)" >&2; return 11; }
  TESTING_TOKEN="$(curl -sS -X POST "https://api.clerk.com/v1/testing_tokens" -H "Authorization: Bearer $CLERK_SECRET_KEY" -H "Content-Type: application/json" -d '{}' | jq -r '.token // empty')"
  [ -n "$TESTING_TOKEN" ] || { echo "step2 testing_tokens failed" >&2; return 12; }
  local ticket
  ticket="$(curl -sS -X POST "https://api.clerk.com/v1/sign_in_tokens" -H "Authorization: Bearer $CLERK_SECRET_KEY" -H "Content-Type: application/json" -d "{\"user_id\":\"$CLERK_USER_ID\",\"expires_in_seconds\":600}" | jq -r '.token // empty')"
  [ -n "$ticket" ] || { echo "step3 sign_in_tokens failed (check CLERK_USER_ID)" >&2; return 13; }
  local exch
  exch="$(curl -sS -X POST "$fapi/v1/client/sign_ins?__clerk_db_jwt=$DB_JWT&__clerk_testing_token=$TESTING_TOKEN&strategy=ticket&ticket=$ticket" -H "Origin: $origin" -H "Content-Type: application/json" -H "Accept: application/json" -H "Cookie: __clerk_db_jwt=$DB_JWT")"
  SESSION_ID="$(echo "$exch" | jq -r '.client.last_active_session_id // .response.client.last_active_session_id // empty')"
  [ -n "$SESSION_ID" ] || { echo "step4 sign_ins failed: $(echo "$exch" | jq -c '.errors // .' 2>/dev/null)" >&2; return 14; }
  SESSION_JWT="$(curl -sS -X POST "$fapi/v1/client/sessions/$SESSION_ID/tokens?__clerk_db_jwt=$DB_JWT&__clerk_testing_token=$TESTING_TOKEN" -H "Origin: $origin" -H "Cookie: __clerk_db_jwt=$DB_JWT" -H "Content-Type: application/json" | jq -r '.jwt // empty')"
  [ -n "$SESSION_JWT" ] || { echo "step5 session token failed" >&2; return 15; }
  echo "handshake ok: session_id=$SESSION_ID jwt_len=${#SESSION_JWT}" >&2
}

main() {
  local skill_dir; skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  require_cmd curl; require_cmd jq
  load_env "$skill_dir"
  : "${CLERK_SECRET_KEY:?set CLERK_SECRET_KEY in .env.local}"
  : "${CLERK_FRONTEND_API:?set CLERK_FRONTEND_API}"
  : "${APP_ORIGIN:?set APP_ORIGIN}"
  local instance; instance="$(detect_instance "$CLERK_SECRET_KEY")" || exit $?
  echo "instance=$instance key=${CLERK_SECRET_KEY:0:8}…" >&2
  if [ "$instance" = "prod" ]; then
    echo "Prod path is out of scope for this build (dev-only)." >&2; exit 5
  fi

  if [ -z "${CLERK_USER_ID:-}" ]; then
    [ -n "${CLERK_USER_EMAIL:-}" ] || { echo "set CLERK_USER_ID or CLERK_USER_EMAIL" >&2; exit 6; }
    CLERK_USER_ID="$(resolve_user_id "$CLERK_USER_EMAIL")"
    [ -n "$CLERK_USER_ID" ] || { echo "could not resolve user_id for $CLERK_USER_EMAIL" >&2; exit 7; }
    echo "resolved user_id=$CLERK_USER_ID" >&2
  fi

  dev_handshake || exit $?

  local out_dir="${OUT_DIR:-$skill_dir/.run}"; mkdir -p "$out_dir"
  local now_epoch="${NOW_EPOCH:-$(date +%s)}"
  assemble_storage_state "$DB_JWT" "$SESSION_JWT" "$APP_ORIGIN" "$now_epoch" > "$out_dir/storageState.json"
  printf '%s' "$SESSION_JWT" > "$out_dir/session.jwt"
  echo "wrote $out_dir/storageState.json + session.jwt" >&2
  echo "$out_dir/storageState.json"
}

if [ "${1:-}" != "--source-only" ]; then main "$@"; fi
