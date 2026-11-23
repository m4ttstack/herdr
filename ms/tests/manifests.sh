#!/bin/bash
# ms/manifests.sh writes a cumulative herdr-builds.json and herdr's own latest.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/ms/tests/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0

check() { # check <description> <jq filter that must print true> <file>
  if [ "$(jq -r "$2" "$3")" = "true" ]; then echo "ok   $1"; else echo "FAIL $1" >&2; FAILS=$((FAILS + 1)); fi
}

ARM_SHA="$(shasum -a 256 "$FIX/herdr-macos-aarch64" | cut -d' ' -f1)"
X86_SHA="$(shasum -a 256 "$FIX/herdr-macos-x86_64" | cut -d' ' -f1)"

"$ROOT/ms/manifests.sh" --version 0.9.5-ms.1 --base 0.9.5 --revision 1 \
  --arm64 "$FIX/herdr-macos-aarch64" --x86_64 "$FIX/herdr-macos-x86_64" \
  --previous none --notes "$FIX/notes.md" --out "$WORK/one"
B1="$WORK/one/herdr-builds.json"
check "first build: schema 1" '.schema == 1' "$B1"
check "first build: newest is 0.9.5-ms.1" '.newest == "0.9.5-ms.1"' "$B1"
check "first build: one build" '.builds | length == 1' "$B1"
check "first build: version, herdr, revision, changesServer" \
  '.builds[0] | .version == "0.9.5-ms.1" and .herdr == "0.9.5" and .revision == 1 and .changesServer == true' "$B1"
check "first build: supersedes is empty" '.builds[0].supersedes == []' "$B1"
check "first build: 12 flock patch SHA-256s" '.flockPatchSha256 | length == 12 and all(test("^[0-9a-f]{64}$"))' "$B1"
check "first build: arm64 sha256 matches the binary" ".builds[0].assets.arm64.sha256 == \"$ARM_SHA\"" "$B1"
check "first build: x86_64 sha256 matches the binary" ".builds[0].assets.x86_64.sha256 == \"$X86_SHA\"" "$B1"
check "first build: asset urls on the fork release" \
  '.builds[0].assets.arm64.url == "https://github.com/m4ttstack/herdr/releases/download/v0.9.5-ms.1/herdr-macos-aarch64" and .builds[0].assets.x86_64.url == "https://github.com/m4ttstack/herdr/releases/download/v0.9.5-ms.1/herdr-macos-x86_64"' "$B1"

printf 'second arm64 build\n' > "$WORK/arm64-2"
printf 'second x86_64 build\n' > "$WORK/x86_64-2"
"$ROOT/ms/manifests.sh" --version 0.9.5-ms.2 --base 0.9.5 --revision 2 \
  --arm64 "$WORK/arm64-2" --x86_64 "$WORK/x86_64-2" \
  --previous "$B1" --notes "$FIX/notes.md" --out "$WORK/two"
B2="$WORK/two/herdr-builds.json"
check "second build: newest is 0.9.5-ms.2" '.newest == "0.9.5-ms.2"' "$B2"
check "second build: two builds in order" '[.builds[].version] == ["0.9.5-ms.1", "0.9.5-ms.2"]' "$B2"
check "second build: supersedes exactly the first build's sha256s" \
  ".builds[1].supersedes | sort == ([\"$ARM_SHA\", \"$X86_SHA\"] | sort)" "$B2"
if [ "$(jq -c '.builds[0]' "$B1")" = "$(jq -c '.builds[0]' "$B2")" ]; then echo "ok   second build: first build unchanged"; else echo "FAIL second build: first build unchanged" >&2; FAILS=$((FAILS + 1)); fi

L="$WORK/two/latest.json"
check "latest.json: version is the base" '.version == "0.9.5"' "$L"
check "latest.json: fork_revision 2" '.fork_revision == 2' "$L"
check "latest.json: protocol and endpoint_generation from the source" \
  ".protocol == $(sed -n 's/^pub const PROTOCOL_VERSION: u32 = \([0-9]*\);$/\1/p' "$ROOT/src/protocol/wire.rs") and .endpoint_generation == $(sed -n 's/^pub const ENDPOINT_PROTOCOL_GENERATION: u32 = \([0-9]*\);$/\1/p' "$ROOT/src/protocol/endpoint.rs")" "$L"
check "latest.json: notes are the notes file" '.notes == "herdr 0.9.5-ms.N (mattstack fork)\n"' "$L"
check "latest.json: both macos assets and sha256s" \
  '(.assets | has("macos-aarch64") and has("macos-x86_64")) and (.sha256 | has("macos-aarch64") and has("macos-x86_64"))' "$L"
ARM2_SHA="$(shasum -a 256 "$WORK/arm64-2" | cut -d' ' -f1)"
X862_SHA="$(shasum -a 256 "$WORK/x86_64-2" | cut -d' ' -f1)"
check "latest.json: asset sha256s match the second build's binaries" \
  ".sha256[\"macos-aarch64\"] == \"$ARM2_SHA\" and .assets[\"macos-aarch64\"].sha256 == \"$ARM2_SHA\" and .sha256[\"macos-x86_64\"] == \"$X862_SHA\"" "$L"
check "latest.json: no herdr.dev URL" '[.. | strings | select(test("herdr\\.dev"))] | length == 0' "$L"

"$ROOT/ms/manifests.sh" --version 0.9.5-ms.3 --base 0.9.5 --revision 3 \
  --arm64 "$FIX/herdr-macos-aarch64" --x86_64 "$FIX/herdr-macos-x86_64" \
  --previous "$B2" --notes "$FIX/notes.md" --out "$WORK/three" >/dev/null
check "a build never supersedes its own bytes" \
  ".builds[2].supersedes | sort == ([\"$ARM2_SHA\", \"$X862_SHA\"] | sort)" "$WORK/three/herdr-builds.json"

"$ROOT/ms/manifests.sh" --version 0.9.6-ms.1 --base 0.9.6 --revision 1 \
  --arm64 "$WORK/arm64-2" --x86_64 "$WORK/x86_64-2" \
  --previous "$WORK/three/herdr-builds.json" --notes "$FIX/notes.md" --out "$WORK/newer" >/dev/null
check "a newer base after revisions is the newest" '.newest == "0.9.6-ms.1"' "$WORK/newer/herdr-builds.json"
if "$ROOT/ms/manifests.sh" --version 0.9.5-ms.4 --base 0.9.5 --revision 4 \
  --arm64 "$FIX/herdr-macos-aarch64" --x86_64 "$FIX/herdr-macos-x86_64" \
  --previous "$WORK/newer/herdr-builds.json" --notes "$FIX/notes.md" --out "$WORK/older" 2>/dev/null; then
  echo "FAIL refuses a build older than the list's newest" >&2; FAILS=$((FAILS + 1))
else echo "ok   refuses a build older than the list's newest"; fi

if "$ROOT/ms/manifests.sh" --version 0.9.5-ms.2 --base 0.9.5 --revision 2 \
  --arm64 "$FIX/herdr-macos-aarch64" --x86_64 "$FIX/herdr-macos-x86_64" \
  --previous "$B2" --notes "$FIX/notes.md" --out "$WORK/dup" 2>/dev/null; then
  echo "FAIL refuses a version already in the list" >&2; FAILS=$((FAILS + 1))
else echo "ok   refuses a version already in the list"; fi

[ "$FAILS" -eq 0 ] || { echo "manifests.sh: $FAILS check(s) failed" >&2; exit 1; }
echo "PASS: manifests"
