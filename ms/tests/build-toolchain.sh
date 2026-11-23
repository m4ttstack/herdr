#!/bin/bash
# ms/build.sh builds with the repo's pinned toolchain (rust-toolchain.toml)
# wherever it is run from: rustup picks the toolchain from the directory.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUBS="$(mktemp -d)"
OUT="$(mktemp -d)"
trap 'rm -rf "$STUBS" "$OUT"' EXIT

# rustup and cargo stand-ins that see the pinned toolchain only inside the repo.
cat > "$STUBS/rustup" <<STUB
#!/bin/bash
[ "\$PWD" = "$ROOT" ] && printf 'aarch64-apple-darwin\nx86_64-apple-darwin\n'
exit 0
STUB
cat > "$STUBS/cargo" <<STUB
#!/bin/bash
echo "\$PWD" > "$OUT/cargo-cwd"
mkdir -p "\$CARGO_TARGET_DIR/x86_64-apple-darwin/release"
printf '#!/bin/sh\n' > "\$CARGO_TARGET_DIR/x86_64-apple-darwin/release/herdr"
chmod +x "\$CARGO_TARGET_DIR/x86_64-apple-darwin/release/herdr"
STUB
printf '#!/bin/sh\necho 0.16.0\n' > "$STUBS/zig"
chmod +x "$STUBS/rustup" "$STUBS/cargo" "$STUBS/zig"

if (cd / && PATH="$STUBS:$PATH" CARGO_TARGET_DIR="$OUT/target" "$ROOT/ms/build.sh" --arch x86_64 --revision 1 --out "$OUT/dist" >/dev/null 2>&1) \
  && [ "$(cat "$OUT/cargo-cwd" 2>/dev/null)" = "$ROOT" ]; then
  echo "PASS: build.sh uses the repo's toolchain from any directory"
else
  echo "FAIL: build.sh run from / did not check and build inside the repo" >&2
  exit 1
fi
