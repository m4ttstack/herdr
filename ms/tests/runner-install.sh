#!/bin/bash
# ms/runner/install.sh refuses a missing .p12 before it changes anything
# (no sudo, no user, no hook).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MISSING="$(mktemp -d)/developer-id.p12"
# An exported function wins over every sudo on PATH, and install.sh puts
# /usr/bin first on PATH, so a stub binary would never run.
sudo() { echo "sudo was called" >&2; exit 99; }
export -f sudo

OUT="$(cd "$ROOT" && bash ms/runner/install.sh --p12 "$MISSING" 2>&1)"; CODE=$?
FAILS=0
if [ "$CODE" -ne 0 ]; then echo "ok   exits non-zero"; else echo "FAIL exits non-zero" >&2; FAILS=1; fi
case "$OUT" in *"sudo was called"*) echo "FAIL never reaches sudo" >&2; FAILS=1 ;; *) echo "ok   never reaches sudo" ;; esac
case "$OUT" in *"$MISSING"*) echo "ok   names the missing file" ;; *) echo "FAIL names the missing file (got: $OUT)" >&2; FAILS=1 ;; esac
[ "$FAILS" -eq 0 ] || exit 1
echo "PASS: runner install refuses a missing .p12"
