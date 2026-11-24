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

# The installer runs as an admin with sudo, and build code owns everything under
# the runner user's home, so nothing it looks up may resolve there. Runs the
# whole script with every command that changes the Mac stubbed out, and records
# the PATH in effect at each command, inside the stubs too.
cat > "$TMP/harness.sh" <<'HARNESS'
sudo() { case "$*" in "-u herdr-signer test -x"*) return 1 ;; esac; :; }
zig() { echo 0.16.0; }
for tool in curl shasum tar gh jq launchctl security visudo sleep; do eval "$tool() { :; }"; done
id() { echo 501; }
scutil() { echo Test-Mac; }
seen_path() { [ "$PATH" = "${SEEN_PATH:-}" ] || { SEEN_PATH="$PATH"; printf '%s\n' "$PATH" >> "$PATH_LOG"; }; }
set -T
trap seen_path DEBUG
HARNESS
PATH_LOG="$TMP/paths"; : > "$PATH_LOG"
OUT="$(cd "$ROOT" && unset -f sudo && PATH_LOG="$PATH_LOG" BASH_ENV="$TMP/harness.sh" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  bash ms/runner/install.sh --registration-token T --notary-key-id K --notary-issuer I --notary-key "$P8" </dev/null 2>&1)"; CODE=$?
if [ "$CODE" -eq 0 ]; then case "$OUT" in *"Installed herdr-signer-"*) echo "ok   the stubbed install runs to the end" ;; *) echo "FAIL the stubbed install runs to the end (got: $OUT)" >&2; FAILS=1 ;; esac
else echo "FAIL the stubbed install runs to the end (exit $CODE: $OUT)" >&2; FAILS=1; fi
WRITABLE="$(tr ':' '\n' < "$PATH_LOG" | grep -E -v '^(/usr/bin|/bin|/usr/sbin|/sbin|/opt/homebrew/bin|/usr/local/bin)$' | sort -u | tr '\n' ' ')"
if [ -s "$PATH_LOG" ] && [ -z "$WRITABLE" ]; then echo "ok   the installer looks commands up only in system and Homebrew directories"
else echo "FAIL the installer looks commands up only in system and Homebrew directories (also: $WRITABLE)" >&2; FAILS=1; fi
# A one-command PATH in front of a builtin (command -v) never shows in the log.
USES="$(grep -n 'TOOL_PATH' "$ROOT/ms/runner/install.sh" | grep -v -E '^[0-9]+:(TOOL_PATH=|[[:space:]]*#|[[:space:]]*<key>PATH</key>)')"
if [ -z "$USES" ]; then echo "ok   only the launchd job gets the runner user's PATH"; else echo "FAIL only the launchd job gets the runner user's PATH ($USES)" >&2; FAILS=1; fi
DROPIN_LINE="$(grep -n 'sudoers.d/herdr-signer$' "$ROOT/ms/runner/install.sh" | head -1 | cut -d: -f1)"
AS_USER_LINE="$(grep -n 'sudo -u "\$CI_USER"' "$ROOT/ms/runner/install.sh" | head -1 | cut -d: -f1)"
if [ "${DROPIN_LINE:-9999}" -lt "$AS_USER_LINE" ]; then echo "ok   the sudoers drop-in is in place before anything runs as the runner user"
else echo "FAIL the sudoers drop-in is in place before anything runs as the runner user" >&2; FAILS=1; fi

# The key files: staged, proved with a throwaway signing, then put in place, and
# only then is an older install's copy removed. The old files are read as the
# runner user, since build code could have swapped one for a link.
BLOCK="$(sed -n '/^sudo install -d -o root -g wheel -m 700 "\$KEY_DIR"$/,/^sudo -u "\$CI_USER" sudo -n -l/p' "$ROOT/ms/runner/install.sh" | sed '$d')"
mkdir -p "$TMP/hook"
cat > "$TMP/hook/rcodesign" <<'STUB'
#!/bin/bash
cmd="$1"; shift
p12=""; pw=""; out=""
while [ $# -gt 0 ]; do case "$1" in --p12-file) p12="$2"; shift ;; --p12-password-file) pw="$2"; shift ;; -o) out="$2"; shift ;; esac; shift; done
case "$cmd" in
  sign) [ "$(cat "$p12"):$(cat "$pw")" = "p12:pw" ] || { echo "Error: incorrect password given when decrypting PFX data" >&2; exit 1; } ;;
  encode-app-store-connect-api-key) echo '{}' > "$out" ;;
esac
STUB
chmod 755 "$TMP/hook/rcodesign"
OLD="$TMP/old"; KEYS="$TMP/keys"
keys() { # keys <stdin> <P12>: runs the block, sudo as a plain runner
  printf '%s' "$1" | (set -euo pipefail
   P12="$2" OLD_SIGNING_DIR="$OLD" KEY_DIR="$KEYS" HOOK_DIR="$TMP/hook" CI_USER=herdr-signer
   NOTARY_KEY="${NOTARY-$P8}" NOTARY_ISSUER=I NOTARY_KEY_ID=K
   chown() { :; }
   sudo() {
     if [ "$1" = -u ]; then shift 2; [ ! -L "${!#}" ] || return 1; fi
     if [ "$1" = install ]; then shift; set -- "${@/#root/$(command id -un)}"; set -- "${@/#wheel/$(command id -gn)}"; command install "$@"; return; fi
     "$@"
   }
   eval "$BLOCK") >"$TMP/keys.out" 2>&1
}
reset_keys() { rm -rf "$OLD" "$KEYS"; mkdir -p "$OLD"; printf p12 > "$OLD/developer-id.p12"; printf pw > "$OLD/p12-password"; }
key_is() { [ "$(cat "$KEYS/developer-id.p12" 2>/dev/null):$(cat "$KEYS/p12-password" 2>/dev/null)" = "$1" ]; }
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 ($(cat "$TMP/keys.out"); keys: $(ls -l "$KEYS" 2>/dev/null))" >&2; FAILS=1; fi; }

reset_keys; keys "" ""; CODE=$?
check "an older install's key is migrated" '[ $CODE -eq 0 ] && key_is p12:pw && [ ! -e "$OLD" ]'
check "the key directory is mode 700" '[ "$(stat -f %Lp "$KEYS")" = 700 ]'
check "every key file is mode 600" '[ "$(stat -f %Lp "$KEYS"/* | sort -u)" = 600 ] && [ "$(ls "$KEYS" | wc -l | tr -d " ")" = 3 ]'
reset_keys; rm "$OLD/p12-password"; ln -s "$P8" "$OLD/p12-password"; keys "" ""; CODE=$?
check "a linked old key file stops the install and stays" '[ $CODE -ne 0 ] && [ ! -e "$KEYS/developer-id.p12" ] && [ -e "$OLD/developer-id.p12" ]'
reset_keys; printf bad > "$OLD/p12-password"; keys "" ""; CODE=$?
check "an old key that cannot sign is not migrated" '[ $CODE -ne 0 ] && [ ! -e "$KEYS/developer-id.p12" ] && [ -e "$OLD/developer-id.p12" ]'
reset_keys; mkdir -p "$KEYS"; printf half > "$KEYS/developer-id.p12"; keys "" ""; CODE=$?
check "a .p12 with no password does not count as installed" '[ $CODE -eq 0 ] && key_is p12:pw'
reset_keys; mkdir -p "$KEYS"; printf kept > "$KEYS/developer-id.p12"; printf keptpw > "$KEYS/p12-password"; keys "" ""; CODE=$?
check "a rerun keeps the installed key" '[ $CODE -eq 0 ] && key_is kept:keptpw && [ ! -e "$OLD" ]'
printf p12 > "$TMP/new.p12"
reset_keys; mkdir -p "$KEYS"; printf kept > "$KEYS/developer-id.p12"; printf keptpw > "$KEYS/p12-password"
keys $'wrong\n' "$TMP/new.p12"; CODE=$?
check "a mistyped .p12 password changes nothing" '[ $CODE -ne 0 ] && key_is kept:keptpw && [ -e "$OLD" ] && [ -z "$(ls "$KEYS" | grep new)" ]'
# macOS's own openssl: it writes the form rcodesign reads and has no -legacy flag.
# Through a file: piping the .p12's parts fails when the certificate comes first.
CONVERT='(umask 077; /usr/bin/openssl pkcs12 -in developer-id.p12 -nodes -out key.pem && /usr/bin/openssl pkcs12 -export -in key.pem -out developer-id-legacy.p12; rm -f key.pem)'
check "a refused .p12 says why and how to convert it" 'grep -q "incorrect password given" "$TMP/keys.out" && grep -qF "$CONVERT" "$TMP/keys.out" && grep -qF "$CONVERT" "$ROOT/ms/runner/README.md"'
keys $'pw\n' "$TMP/new.p12"; CODE=$?
check "a new .p12 replaces the installed one" '[ $CODE -eq 0 ] && key_is p12:pw'

[ "$FAILS" -eq 0 ] || exit 1
echo "PASS: runner install refuses bad input before changing anything"
