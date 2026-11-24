#!/bin/bash
# Refuses a release binary unless it carries a Developer ID Application
# signature with hardened runtime and a secure timestamp, Gatekeeper accepts it
# as notarized, and it is built for the expected CPU.
# Usage: ms/verify-release.sh FILE arm64|x86_64
set -euo pipefail

FILE="${1:-}"
ARCH="${2:-}"
[ -n "$FILE" ] && [ -n "$ARCH" ] || { echo "usage: ms/verify-release.sh FILE arm64|x86_64" >&2; exit 2; }

refuse() {
  echo "ms/verify-release.sh: $FILE $*" >&2
  exit 1
}

codesign --verify --strict "$FILE" 2>/dev/null || refuse "fails codesign --verify --strict"
details="$(codesign -dvvv "$FILE" 2>&1)" || refuse "has no signature codesign can read"
grep -q '^Authority=Developer ID Application: ' <<<"$details" || refuse "is not signed with a Developer ID Application certificate"
grep -q '^CodeDirectory .*flags=0x[0-9a-f]*([^)]*runtime' <<<"$details" || refuse "is not signed with the hardened runtime"
grep -q '^Timestamp=' <<<"$details" || refuse "has no secure timestamp"
assessment="$(spctl -a -t install -vv "$FILE" 2>&1)" || refuse "is not accepted by Gatekeeper as notarized: $assessment"
grep -q 'source=Notarized Developer ID' <<<"$assessment" || refuse "is not notarized: $assessment"
got="$(lipo -archs "$FILE")"
[ "$got" = "$ARCH" ] || refuse "is $got, expected $ARCH"
echo "ms/verify-release.sh: $FILE is a notarized Developer ID build for $ARCH"
