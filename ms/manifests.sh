#!/bin/bash
# Writes the two manifests a fork release publishes:
#   herdr-builds.json  every published fork build, read by rt setup and Flock
#   latest.json        herdr's own update manifest, read by `herdr update`
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_URL="https://github.com/m4ttstack/herdr"

# The herdr builds Flock published from patches/herdr before this fork existed
# (Sources/FlockCore/Herdr/HerdrMousePatchCatalog.swift), so a Flock user on one
# of them is offered a fork build as an update.
FLOCK_PATCH_SHA256='[
  "535cc07b2f8f617439acac9720104fa791ee62926e6669df75b89f37e6e4cfec",
  "4d24edb6e6ad17b257a1ff22e72c51997c47934da24f2645ea9ede89b2bd1c31",
  "c9660a5510697ffefff67669cfdb9991bb53eedac91ff11f2040289ac36700ff",
  "b7191225e2b4fd7c699e081ff3d37d5ff2886213d03aea54e94ea44289e66c89",
  "630d0d0f462b0094bb1383273220288584fca71e7127d70e6308e799160b33eb",
  "80c2c47fe595bcdee342abb063e6e969ddbcf0c1008eef1c3e168e1701041b72",
  "e5ae358c87d039b9b7edb8cf9071a718ce2c9f9f781f795f3e9309e2dc3e5786",
  "c1e4b5b2999044ec333aa29a518aab52cfe2373bb3a5f7de8db3a52447035aa4",
  "892dd1fc0dff0013272a3482f1253d91021a546db61ae25e6c426a4ed3750cd4",
  "57cd047ccca88d4224677f309583b4252e862f492ee95fa96cb0fdf5144e6805",
  "2ae1848280ef0773425c054cccd3aba3fc1d990d9379c48e4d2224d95ad01494",
  "3849f9af31396f1d7926e5a823227730fbd37faced05918d8668ccaf890f9cf0"
]'

usage() {
  echo "usage: ms/manifests.sh --version <base>-ms.<N> --base <base> --revision N \\"
  echo "         --arm64 PATH --x86_64 PATH --previous HERDR_BUILDS_JSON|none --notes FILE --out DIR"
}

VERSION="" BASE="" REVISION="" ARM64="" X86_64="" PREVIOUS="" NOTES="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --revision) REVISION="${2:-}"; shift 2 ;;
    --arm64) ARM64="${2:-}"; shift 2 ;;
    --x86_64) X86_64="${2:-}"; shift 2 ;;
    --previous) PREVIOUS="${2:-}"; shift 2 ;;
    --notes) NOTES="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ms/manifests.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "ms/manifests.sh: $*" >&2; exit 2; }
for pair in "version:$VERSION" "base:$BASE" "revision:$REVISION" "arm64:$ARM64" "x86_64:$X86_64" \
  "previous:$PREVIOUS" "notes:$NOTES" "out:$OUT"; do
  [ -n "${pair#*:}" ] || fail "--${pair%%:*} is required"
done
case "$REVISION" in ''|*[!0-9]*) fail "--revision must be a whole number from 1, not $REVISION" ;; esac
[ "$REVISION" -ge 1 ] || fail "--revision must be a whole number from 1, not $REVISION"
[ "$VERSION" = "$BASE-ms.$REVISION" ] || fail "--version $VERSION is not $BASE-ms.$REVISION"
for file in "$ARM64" "$X86_64" "$NOTES"; do [ -f "$file" ] || fail "no file $file"; done
[ "$PREVIOUS" = none ] || [ -f "$PREVIOUS" ] || fail "no file $PREVIOUS"
command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"

source_const() { # source_const <file> <const name>
  sed -n "s/^pub const $2: u32 = \([0-9]*\);$/\1/p" "$ROOT/$1"
}
PROTOCOL="$(source_const src/protocol/wire.rs PROTOCOL_VERSION)"
GENERATION="$(source_const src/protocol/endpoint.rs ENDPOINT_PROTOCOL_GENERATION)"
[ -n "$PROTOCOL" ] || fail "could not read PROTOCOL_VERSION from src/protocol/wire.rs"
[ -n "$GENERATION" ] || fail "could not read ENDPOINT_PROTOCOL_GENERATION from src/protocol/endpoint.rs"

ARM64_SHA="$(shasum -a 256 "$ARM64" | cut -d' ' -f1)"
X86_64_SHA="$(shasum -a 256 "$X86_64" | cut -d' ' -f1)"
DOWNLOAD="$REPO_URL/releases/download/v$VERSION"

if [ "$PREVIOUS" = none ]; then
  PREVIOUS_JSON="{\"schema\":1,\"builds\":[],\"flockPatchSha256\":$FLOCK_PATCH_SHA256}"
else
  PREVIOUS_JSON="$(cat "$PREVIOUS")"
  jq -e '.schema == 1 and (.builds | type == "array")' <<<"$PREVIOUS_JSON" >/dev/null \
    || fail "$PREVIOUS is not a schema 1 herdr-builds.json"
  if jq -e --arg v "$VERSION" 'any(.builds[]; .version == $v)' <<<"$PREVIOUS_JSON" >/dev/null; then
    fail "$VERSION is already in $PREVIOUS"
  fi
fi

mkdir -p "$OUT"
jq --arg version "$VERSION" --arg base "$BASE" --argjson revision "$REVISION" \
  --arg armUrl "$DOWNLOAD/herdr-macos-aarch64" --arg armSha "$ARM64_SHA" \
  --arg x86Url "$DOWNLOAD/herdr-macos-x86_64" --arg x86Sha "$X86_64_SHA" \
  --argjson flock "$FLOCK_PATCH_SHA256" '
  {
    schema: 1,
    newest: $version,
    builds: (.builds + [{
      version: $version,
      herdr: $base,
      revision: $revision,
      changesServer: true,
      assets: {
        arm64: { url: $armUrl, sha256: $armSha },
        x86_64: { url: $x86Url, sha256: $x86Sha }
      },
      supersedes: (([.builds[].assets[].sha256] | unique) - [$armSha, $x86Sha])
    }]),
    flockPatchSha256: $flock
  }' <<<"$PREVIOUS_JSON" > "$OUT/herdr-builds.json"

jq -n --arg base "$BASE" --argjson revision "$REVISION" \
  --argjson protocol "$PROTOCOL" --argjson generation "$GENERATION" \
  --rawfile notes "$NOTES" \
  --arg armUrl "$DOWNLOAD/herdr-macos-aarch64" --arg armSha "$ARM64_SHA" \
  --arg x86Url "$DOWNLOAD/herdr-macos-x86_64" --arg x86Sha "$X86_64_SHA" '
  {
    version: $base,
    fork_revision: $revision,
    protocol: $protocol,
    endpoint_generation: $generation,
    notes: $notes,
    assets: {
      "macos-aarch64": { url: $armUrl, sha256: $armSha },
      "macos-x86_64": { url: $x86Url, sha256: $x86Sha }
    },
    sha256: { "macos-aarch64": $armSha, "macos-x86_64": $x86Sha }
  }' > "$OUT/latest.json"

echo "ms/manifests.sh: wrote $OUT/herdr-builds.json and $OUT/latest.json for $VERSION"
