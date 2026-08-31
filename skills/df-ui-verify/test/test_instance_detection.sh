#!/usr/bin/env bash
# Unit: instance detection from the Clerk secret-key prefix, cross-checked against the
# Frontend API host. Not discovered directly by run-tests.sh (that finds `test-*.sh`) —
# the entry point is test-df-ui-verify.sh, which sums the ASSERTIONS line below.
#
# The hosts here are PLACEHOLDERS and must stay that way. A real Clerk dev slug is a
# landmark: it identifies the instance and, with it, the app. `*.clerk.accounts.dev` is
# the shape the detector keys on, so the shape is what the test needs — never a real one.
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

CLERK_FRONTEND_API="https://example-app-42.clerk.accounts.dev"
assert_eq "$(detect_instance sk_test_abc 2>/dev/null)" "dev" "sk_test -> dev"

CLERK_FRONTEND_API="https://clerk.example.com"
assert_eq "$(detect_instance sk_live_abc 2>/dev/null)" "prod" "sk_live -> prod"

# A live key against an accounts.dev FAPI is a mismatch and must exit non-zero.
CLERK_FRONTEND_API="https://example-app-42.clerk.accounts.dev"
assert_rejects "sk_live against an accounts.dev FAPI" detect_instance sk_live_abc

# An unknown prefix must exit non-zero rather than guessing an instance class.
assert_rejects "unknown key prefix" detect_instance pk_test_abc

echo "ASSERTIONS: $n"
exit $fail
