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

# set -u turns a variable nobody assigns into an abort halfway through.
UNSET="$(ruby -e '
  src = File.read(ARGV[0])
  used = src.scan(/\$\{?([A-Z][A-Z0-9_]*)/).flatten.uniq
  set = src.scan(/(?:^|[\s;(])([A-Z][A-Z0-9_]*)=/).flatten + src.scan(/\bread\b.*\s([A-Z][A-Z0-9_]*)$/).flatten + %w[PWD HOME USER]
  puts (used - set).join(" ")
' "$ROOT/ms/runner/install.sh")"
if [ -z "$UNSET" ]; then echo "ok   every variable the installer reads is assigned"; else echo "FAIL every variable the installer reads is assigned (not assigned: $UNSET)" >&2; FAILS=1; fi

# Migration: build code could have swapped the old key files for links, so they
# are read as that user and never moved into the root-only directory.
BLOCK="$(sed -n '/^elif sudo test -f "\$OLD_SIGNING_DIR/,/^fi$/p' "$ROOT/ms/runner/install.sh" | sed -e '1s/^elif/if/')"
OLD="$TMP/old"; KEYS="$TMP/keys"; mkdir -p "$OLD" "$KEYS"
printf 'secret' > "$TMP/root-file"; chmod 400 "$TMP/root-file"
printf 'p12' > "$OLD/developer-id.p12"; ln -s "$TMP/root-file" "$OLD/p12-password"
migrate() { # runs the block with sudo as a plain runner; "sudo -u" refuses $TMP/root-file, as that user's reads would be
  (set -euo pipefail
   OLD_SIGNING_DIR="$OLD" KEY_DIR="$KEYS" CI_USER=herdr-signer
   sudo() {
     if [ "$1" = -u ]; then shift 2; case "$(readlink "${!#}" 2>/dev/null)" in "$TMP/root-file") return 1 ;; esac; fi
     "$@"
   }
   eval "$BLOCK") >/dev/null 2>&1
}
migrate
if [ -z "$(ls "$KEYS" | grep -v '\.new$')" ] && [ -e "$OLD/developer-id.p12" ]; then echo "ok   a linked old key file is not migrated"; else echo "FAIL a linked old key file is not migrated (key dir: $(ls "$KEYS" | tr '\n' ' '))" >&2; FAILS=1; fi
rm -f "$OLD/p12-password" "$KEYS"/*; printf 'pw' > "$OLD/p12-password"
migrate
if [ "$(cat "$KEYS/developer-id.p12" "$KEYS/p12-password" 2>/dev/null)" = p12pw ] && [ "$(ls "$KEYS" | wc -l | tr -d ' ')" = 2 ]; then echo "ok   the old key files are migrated"; else echo "FAIL the old key files are migrated (key dir: $(ls "$KEYS" | tr '\n' ' '))" >&2; FAILS=1; fi
if [ "$(stat -f %Lp "$KEYS/developer-id.p12" 2>/dev/null)" = 600 ]; then echo "ok   a migrated key file is mode 600"; else echo "FAIL a migrated key file is mode 600" >&2; FAILS=1; fi

[ "$FAILS" -eq 0 ] || exit 1
echo "PASS: runner install refuses bad input before changing anything"
