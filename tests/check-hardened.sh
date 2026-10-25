#!/usr/bin/env bash
# Tests the hardened check against users and groups every Mac does or cannot have.
#
# Usage: check-hardened.sh <automic-vault-check-hardened>
set -euo pipefail

check="$1"
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

"$check" root wheel || fail "root and wheel were refused"

missing=automic-vault-test-missing-$$
for args in "$missing wheel" "root $missing"; do
  status=0
  # shellcheck disable=SC2086
  err="$("$check" $args 2>&1)" || status=$?
  [[ $status == 2 ]] || fail "$args: exited $status, not 2"
  [[ $err == *"there is no ${args% *} user or ${args#* } group"* ]] || fail "$args: unexpected error: $err"
done

((failures == 0)) || exit 1
echo "check-hardened tests passed"
