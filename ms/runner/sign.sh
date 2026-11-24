#!/bin/bash
# Signs and notarizes release binaries with the Developer ID key, which only root
# can read. install.sh installs this root-owned at /usr/local/herdr-signer/sign.sh
# and lets herdr-signer run it, and nothing else, through sudo -n.
# Usage: sudo -n /usr/local/herdr-signer/sign.sh /abs/path/in/_work/binary...
set -euo pipefail

CALLER=herdr-signer
WORK_DIR=/Users/$CALLER/runner/_work
KEY_DIR=/usr/local/herdr-signer/keys
RCODESIGN=/usr/local/herdr-signer/rcodesign
TIMESTAMP_URL=http://timestamp.apple.com/ts01

# Overrides are for ms/tests/sign-helper.sh, which runs this as you. Under sudo
# they are never honoured: root signs only with the paths above.
if [ "$(id -u)" = 0 ]; then
  export TMPDIR=/private/tmp
  as_caller() { sudo -u "$CALLER" -- "$@"; }
else
  WORK_DIR="${HERDR_SIGNER_WORK_DIR:-$WORK_DIR}"
  KEY_DIR="${HERDR_SIGNER_KEY_DIR:-$KEY_DIR}"
  RCODESIGN="${HERDR_SIGNER_RCODESIGN:-$RCODESIGN}"
  as_caller() { "$@"; }
fi

refuse() {
  echo "sign.sh: $*" >&2
  exit 1
}

[ $# -gt 0 ] || { echo "usage: sign.sh /absolute/path/to/binary..." >&2; exit 2; }
WORK_REAL="$(cd "$WORK_DIR" 2>/dev/null && pwd -P)" || refuse "no runner work directory $WORK_DIR"

# Every path is checked before any is signed. The checks read as the caller, so
# this never reads a file the caller could not.
for path in "$@"; do
  case "$path" in /*) ;; *) refuse "$path is not an absolute path" ;; esac
  [ ! -L "$path" ] || refuse "$path is a symlink"
  as_caller test -f "$path" || refuse "no file $path"
  dir="$(as_caller sh -c 'cd "$(dirname "$1")" && pwd -P' _ "$path")" || refuse "cannot resolve $path"
  case "$dir/" in "$WORK_REAL"/*) ;; *) refuse "$path is outside $WORK_DIR" ;; esac
done

is_macho() { # is_macho <file>: thin or fat Mach-O magic
  case "$(od -An -tx1 -N4 "$1" | tr -d ' \n')" in
    cffaedfe|cefaedfe|cafebabe|cafebabf) return 0 ;;
    *) return 1 ;;
  esac
}

SCRATCH="$(mktemp -d -t herdr-sign)"
trap 'rm -rf "$SCRATCH"' EXIT

# Copy every file in, and check the copies, which only root can change.
i=0
for path in "$@"; do
  i=$((i + 1))
  mkdir "$SCRATCH/$i"
  copy="$SCRATCH/$i/$(basename "$path")"
  as_caller cat "$path" > "$copy"
  is_macho "$copy" || refuse "$path is not a Mach-O binary"
done

i=0
for path in "$@"; do
  i=$((i + 1))
  copy="$SCRATCH/$i/$(basename "$path")"
  "$RCODESIGN" sign --p12-file "$KEY_DIR/developer-id.p12" --p12-password-file "$KEY_DIR/p12-password" \
    --code-signature-flags runtime --timestamp-url "$TIMESTAMP_URL" "$copy" \
    || refuse "rcodesign could not sign $path"
  # Apple's notary service takes no bare Mach-O, only a zip of one.
  ditto -c -k --norsrc --noextattr --noqtn --noacl "$copy" "$copy.zip"
  "$RCODESIGN" notary-submit --api-key-file "$KEY_DIR/notary-api-key.json" --wait "$copy.zip" \
    || refuse "Apple did not notarize $path"
done

# Written back only once every file is signed and notarized, as the caller, so
# a swapped path lands only where the caller could write anyway.
i=0
for path in "$@"; do
  i=$((i + 1))
  as_caller sh -c 'cat > "$1"' _ "$path" < "$SCRATCH/$i/$(basename "$path")"
  echo "sign.sh: signed and notarized $path"
done
