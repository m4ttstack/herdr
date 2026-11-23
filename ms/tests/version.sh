#!/bin/bash
# A build from ms/build.sh reports <base>-ms.<revision> as its version.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

case "$(uname -m)" in
  arm64) ARCH=arm64; ASSET=herdr-macos-aarch64 ;;
  x86_64) ARCH=x86_64; ASSET=herdr-macos-x86_64 ;;
  *) echo "version.sh: unsupported machine $(uname -m)" >&2; exit 1 ;;
esac

"$ROOT/ms/build.sh" --arch "$ARCH" --revision 7 --out "$OUT"

GOT="$(env -i HOME="$(mktemp -d)" PATH=/usr/bin:/bin "$OUT/$ASSET" --version)"
BASE="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$ROOT/Cargo.toml" | head -1)"
WANT="herdr $BASE-ms.7"
if [ "$GOT" != "$WANT" ]; then
  echo "FAIL: --version printed '$GOT', want '$WANT'" >&2
  exit 1
fi
echo "PASS: $GOT"
