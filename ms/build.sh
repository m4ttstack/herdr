#!/bin/bash
# Builds one macOS herdr binary that reports <Cargo.toml version>-ms.<revision>.
# No signing here: ms-release.yml signs on the herdr-signer runner.
set -euo pipefail

ZIG_VERSION=0.16.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH=""
REVISION=""
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --revision) REVISION="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help)
      echo "usage: ms/build.sh --arch arm64|x86_64 --revision N --out DIR"
      echo "  writes DIR/herdr-macos-<aarch64|x86_64>, reporting <base>-ms.<N>"
      exit 0 ;;
    *) echo "ms/build.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

case "$ARCH" in
  arm64) RUST_TARGET=aarch64-apple-darwin; ASSET=herdr-macos-aarch64 ;;
  x86_64) RUST_TARGET=x86_64-apple-darwin; ASSET=herdr-macos-x86_64 ;;
  *) echo "ms/build.sh: --arch must be arm64 or x86_64, not $ARCH" >&2; exit 2 ;;
esac
case "$REVISION" in
  ''|*[!0-9]*) echo "ms/build.sh: --revision must be a whole number from 1, not $REVISION" >&2; exit 2 ;;
esac
[ "$REVISION" -ge 1 ] || { echo "ms/build.sh: --revision must be a whole number from 1, not $REVISION" >&2; exit 2; }
[ -n "$OUT" ] || { echo "ms/build.sh: --out is required" >&2; exit 2; }

case "$(uname -s)" in
  Darwin) ;;
  *) echo "ms/build.sh: this builds on macOS only ($(uname -s))" >&2; exit 1 ;;
esac
command -v cargo >/dev/null 2>&1 || { echo "ms/build.sh: cargo is not on PATH (https://rustup.rs)" >&2; exit 1; }
rustup target list --installed 2>/dev/null | grep -x "$RUST_TARGET" >/dev/null || {
  echo "ms/build.sh: the Rust $RUST_TARGET target is missing. Run: rustup target add $RUST_TARGET" >&2; exit 1; }
command -v zig >/dev/null 2>&1 || {
  echo "ms/build.sh: zig $ZIG_VERSION is not on PATH; herdr's build.rs needs it" >&2; exit 1; }
[ "$(zig version)" = "$ZIG_VERSION" ] || {
  echo "ms/build.sh: zig is $(zig version), herdr's build.rs requires $ZIG_VERSION" >&2; exit 1; }

COMMIT="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || true)"
echo "ms/build.sh: building $ASSET, revision $REVISION (this takes a few minutes)"
HERDR_BUILD_CHANNEL=ms HERDR_BUILD_ID="$REVISION" HERDR_BUILD_COMMIT="$COMMIT" ZIG="$(command -v zig)" \
  cargo build --release --locked --target "$RUST_TARGET" --manifest-path "$ROOT/Cargo.toml"

TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
BUILT="$TARGET_DIR/$RUST_TARGET/release/herdr"
[ -x "$BUILT" ] || { echo "ms/build.sh: cargo build produced no $BUILT" >&2; exit 1; }

mkdir -p "$OUT"
cp "$BUILT" "$OUT/$ASSET"
chmod 755 "$OUT/$ASSET"
echo "ms/build.sh: built $OUT/$ASSET"
