#!/usr/bin/env bash
# Unit: resolve_user_id must establish identity from the RETURNED RECORD, never from the
# fact that a lookup answered.
#
# Regression for 2026-09-15: the kernel sent `email_address[]=<email>`, which Clerk's
# Backend API ignores, answering with every user on the instance newest-first — and took
# `.[0].id`, minting a session as whoever had signed up last. `curl` is stubbed here with
# canned Backend API responses; no network, no real ids. The addresses are placeholders.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../scripts/clerk-auth.sh" --source-only

fail=0
n=0
assert_eq() {
  n=$((n + 1))
  if [ "$1" != "$2" ]; then echo "FAIL: expected '$2' got '$1'"; fail=1; else echo "ok: $3"; fi
}
assert_rejects() { # description, then the command
  n=$((n + 1))
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL: $what not rejected"; fail=1; else echo "ok: $what rejected"; fi
}

CLERK_SECRET_KEY="sk_test_placeholder"
STUB_BODY=""
# resolve_user_id calls curl inside $(…), a subshell, so a variable set by the stub would
# never reach this shell. The stub records its arguments in a file instead.
ARGS_FILE="$(mktemp)"
trap 'rm -f "$ARGS_FILE"' EXIT
curl() { printf '%s' "$*" > "$ARGS_FILE"; printf '%s' "$STUB_BODY"; }

user() { printf '{"id":"%s","email_addresses":[{"email_address":"%s"}]}' "$1" "$2"; }

# 1. The filter the API honours is `email_address=`, not `email_address[]=`.
STUB_BODY="[$(user user_demo demo@example.test)]"
resolve_user_id demo@example.test >/dev/null 2>&1
STUB_ARGS="$(cat "$ARGS_FILE")"
case "$STUB_ARGS" in
  *"email_address[]="*) n=$((n + 1)); echo "FAIL: still sends the ignored email_address[] spelling"; fail=1 ;;
  *"email_address=demo@example.test"*) n=$((n + 1)); echo "ok: sends email_address=" ;;
  *) n=$((n + 1)); echo "FAIL: no email filter sent: $STUB_ARGS"; fail=1 ;;
esac

# 2. Exactly one record carrying the email -> its id (case-insensitive on the address).
STUB_BODY="[$(user user_demo Demo@Example.test)]"
assert_eq "$(resolve_user_id demo@example.test 2>/dev/null)" "user_demo" "one matching record -> its id"

# 3. THE REGRESSION: an unfiltered answer (every user, newest first) must be refused,
#    not resolved to the newest stranger.
STUB_BODY="[$(user user_newest stranger@example.test),$(user user_demo demo@example.test)]"
assert_rejects "an unfiltered list of several users" resolve_user_id demo@example.test

# 4. A single record that does NOT carry the email must be refused.
STUB_BODY="[$(user user_newest stranger@example.test)]"
assert_rejects "a lone record for a different email" resolve_user_id demo@example.test

# 5. No match and a non-array error body must both be refused.
STUB_BODY="[]"
assert_rejects "an empty result" resolve_user_id demo@example.test
STUB_BODY='{"errors":[{"message":"unauthorized"}]}'
assert_rejects "an API error body" resolve_user_id demo@example.test

echo "ASSERTIONS: $n"
exit $fail
