#!/bin/bash
# codesign builds the certificate chain from keychains only, so the signing
# keychain carries Apple's Developer ID intermediates. These are Apple's
# published files from https://www.apple.com/certificateauthority/.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0
check() { # check <file> <sha256>
  local got
  got="$(shasum -a 256 "$ROOT/ms/runner/apple/$1" 2>/dev/null | cut -c1-64)"
  if [ "$got" = "$2" ]; then echo "PASS: $1 is Apple's file"; else echo "FAIL $1 sha256 is ${got:-missing}"; fails=1; fi
}
check DeveloperIDCA.cer 7afc9d01a62f03a2de9637936d4afe68090d2de18d03f29c88cfb0b1ba63587f
check DeveloperIDG2CA.cer f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a
sign_step="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).dig("jobs","release","steps").find { |s| s["name"] == "Sign" }["run"]' "$ROOT/.github/workflows/ms-release.yml")"
if grep -q 'ms/runner/apple/\*\.cer' <<<"$sign_step"; then echo "PASS: the Sign step imports the intermediates"; else echo "FAIL the Sign step does not import ms/runner/apple/*.cer"; fails=1; fi
if grep -q '/apple/\*\.cer' "$ROOT/ms/runner/install.sh"; then echo "PASS: the installer imports the intermediates"; else echo "FAIL install.sh does not import ms/runner/apple"; fails=1; fi
exit $fails
