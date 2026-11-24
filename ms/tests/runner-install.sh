#!/bin/bash
# ms/runner/install.sh refuses bad input before it changes anything (no sudo,
# no user, no hook): a missing .p12 or notary key, notary flags given only in
# part, and a flag with no value.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MISSING="$TMP/developer-id.p12"
P8="$TMP/AuthKey_TEST.p8"
: > "$P8"
# An exported function wins over every sudo on PATH, and install.sh puts
# /usr/bin first on PATH, so a stub binary would never run.
sudo() { echo "sudo was called" >&2; exit 99; }
export -f sudo
FAILS=0

refuses() { # refuses <label> <expected text> <install.sh args>...
  local label="$1" want="$2"; shift 2
  local out code
  out="$(cd "$ROOT" && bash ms/runner/install.sh "$@" 2>&1)"; code=$?
  if [ "$code" -ne 0 ]; then echo "ok   $label: exits non-zero"; else echo "FAIL $label: exits non-zero" >&2; FAILS=1; fi
  case "$out" in *"sudo was called"*) echo "FAIL $label: never reaches sudo" >&2; FAILS=1 ;; *) echo "ok   $label: never reaches sudo" ;; esac
  case "$out" in *"$want"*) echo "ok   $label: names $want" ;; *) echo "FAIL $label: names $want (got: $out)" >&2; FAILS=1 ;; esac
}

refuses "a missing .p12" "$MISSING" --p12 "$MISSING"
refuses "a missing notary key" "$TMP/AuthKey_NONE.p8" \
  --notary-key-id ABC --notary-issuer 00000000-0000-0000-0000-000000000000 --notary-key "$TMP/AuthKey_NONE.p8"
refuses "notary flags in part" "--notary-issuer" --notary-key-id ABC --notary-key "$P8"
refuses "a flag with no value" "--p12" --p12
refuses "a flag followed by another flag" "--notary-key-id" --notary-key-id --notary-issuer X

[ "$FAILS" -eq 0 ] || exit 1
echo "PASS: runner install refuses bad input before changing anything"
