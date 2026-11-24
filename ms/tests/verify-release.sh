#!/bin/bash
# ms/verify-release.sh accepts only a Developer ID signature with hardened
# runtime and a secure timestamp, notarized, for the expected CPU.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/ms/verify-release.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1" >&2; FAILS=$((FAILS + 1)); }

# Stubs print what the real tools print for a good release; each STUB_* knob
# breaks one fact.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codesign" <<'STUB'
#!/bin/bash
case "$1" in
  --verify) [ -z "${STUB_BAD_VERIFY:-}" ] || { echo "$3: invalid signature" >&2; exit 1; } ;;
  -dvvv)
    {
      echo "Executable=$2"
      echo "CodeDirectory v=20500 size=1 flags=${STUB_FLAGS:-0x10000(runtime)} hashes=1+7 location=embedded"
      authority="${STUB_AUTHORITY-Developer ID Application: Test (TEST000000)}"
      if [ -n "$authority" ]; then
        echo "Authority=$authority"
        echo "Authority=Developer ID Certification Authority"
        echo "Authority=Apple Root CA"
      else
        echo "Signature=adhoc"
      fi
      [ -n "${STUB_NO_TIMESTAMP:-}" ] || echo "Timestamp=Nov 23, 2026 at 19:00:00"
    } >&2 ;;
esac
STUB
cat > "$TMP/bin/spctl" <<'STUB'
#!/bin/bash
if [ -n "${STUB_NOT_NOTARIZED:-}" ]; then
  echo "${*: -1}: rejected" >&2; echo "source=Unnotarized Developer ID" >&2; exit 3
fi
echo "${*: -1}: accepted" >&2; echo "source=Notarized Developer ID" >&2
STUB
cat > "$TMP/bin/lipo" <<'STUB'
#!/bin/bash
echo "${STUB_ARCHS:-arm64}"
STUB
chmod 755 "$TMP/bin/"*
BIN="$TMP/herdr-macos-aarch64"
cp /usr/bin/true "$BIN"

stubbed() { PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@"; }

if OUT="$(stubbed "$BIN" arm64 2>&1)"; then ok "accepts a notarized Developer ID build"; else bad "accepts a notarized Developer ID build (got: $OUT)"; fi

refuses() { # refuses <label> <expected text> <env assignment>
  local label="$1" want="$2" out code
  out="$(env "$3" PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$BIN" arm64 2>&1)"; code=$?
  if [ "$code" -ne 0 ]; then ok "refuses $label"; else bad "refuses $label"; fi
  case "$out" in *"$want"*) ok "names why: $label" ;; *) bad "names why: $label (got: $out)" ;; esac
}
refuses "a signature codesign rejects" "codesign" STUB_BAD_VERIFY=1
refuses "an ad-hoc signature" "Developer ID Application" STUB_AUTHORITY=
refuses "another certificate" "Developer ID Application" "STUB_AUTHORITY=Apple Development: Someone (ABC)"
refuses "no hardened runtime" "hardened runtime" "STUB_FLAGS=0x0(none)"
refuses "no secure timestamp" "timestamp" STUB_NO_TIMESTAMP=1
refuses "a build Apple did not notarize" "notarized" STUB_NOT_NOTARIZED=1
refuses "the wrong CPU" "x86_64" STUB_ARCHS=x86_64

# The real tools on an ad-hoc signed binary.
codesign -s - -f "$BIN" 2>/dev/null
OUT="$(bash "$SCRIPT" "$BIN" "$(lipo -archs "$BIN")" 2>&1)"; CODE=$?
if [ "$CODE" -ne 0 ]; then ok "the real codesign output of an ad-hoc build is refused"; else bad "the real codesign output of an ad-hoc build is refused"; fi
case "$OUT" in *"Developer ID Application"*) ok "names the missing Developer ID" ;; *) bad "names the missing Developer ID (got: $OUT)" ;; esac

bash "$SCRIPT" "$BIN" >/dev/null 2>&1; CODE=$?
[ "$CODE" -eq 2 ] && ok "a missing arch is a usage error" || bad "a missing arch is a usage error (got $CODE)"

[ "$FAILS" -eq 0 ] || { echo "verify-release: $FAILS check(s) failed" >&2; exit 1; }
echo "PASS: verify-release accepts only notarized Developer ID builds"
