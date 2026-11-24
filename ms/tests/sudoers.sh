#!/bin/bash
# The sudoers drop-in lets herdr-signer run the signing helper as root and
# nothing else, and install.sh validates it before it goes live.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DROPIN="$ROOT/ms/runner/sudoers"
INSTALL="$ROOT/ms/runner/install.sh"
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1" >&2; FAILS=$((FAILS + 1)); }

if OUT="$(visudo -cf "$DROPIN" 2>&1)"; then ok "visudo -c parses the drop-in"; else bad "visudo -c parses the drop-in ($OUT)"; fi

RULES="$(grep -v -E '^[[:space:]]*(#|$)' "$DROPIN" 2>/dev/null)"
WANT="herdr-signer ALL=(root) NOPASSWD: /usr/local/herdr-signer/sign.sh"
if [ "$RULES" = "$WANT" ]; then ok "the only rule runs the helper as root without a password"
else bad "the only rule runs the helper as root without a password (got: $RULES)"; fi

grep -q 'visudo -cf ms/runner/sudoers' "$INSTALL" && ok "install.sh validates the drop-in before installing it" \
  || bad "install.sh validates the drop-in before installing it"
grep -q 'install -o root -g wheel -m 440 ms/runner/sudoers /etc/sudoers.d/herdr-signer' "$INSTALL" \
  && ok "install.sh installs it root:wheel 440" || bad "install.sh installs it root:wheel 440"
grep -q 'sudo -n -l /usr/local/herdr-signer/sign.sh' "$INSTALL" && ok "install.sh proves the rule is live for herdr-signer" \
  || bad "install.sh proves the rule is live for herdr-signer"

[ "$FAILS" -eq 0 ] || { echo "sudoers: $FAILS check(s) failed" >&2; exit 1; }
echo "PASS: the sudoers drop-in admits only the signing helper"
