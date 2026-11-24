#!/bin/bash
# ms/runner/sign.sh signs and notarizes Mach-O files from the runner's _work
# directory with the root-only key, and refuses everything else. Runs as you,
# with a throwaway legacy .p12 and a stub rcodesign.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/ms/runner/sign.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1" >&2; FAILS=$((FAILS + 1)); }

WORK="$TMP/runner/_work"
KEYS="$TMP/keys"
LOG="$TMP/rcodesign.log"
mkdir -p "$WORK/herdr/herdr/dist" "$KEYS" "$TMP/outside" "$TMP/bin"
openssl req -x509 -newkey rsa:2048 -nodes -subj "/CN=Developer ID Application: Test (TEST000000)" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 1 >/dev/null 2>&1
printf 'throwaway' > "$KEYS/p12-password"
openssl pkcs12 -export -legacy -in "$TMP/cert.pem" -inkey "$TMP/key.pem" \
  -passout file:"$KEYS/p12-password" -out "$KEYS/developer-id.p12" 2>/dev/null
printf '{"issuer_id":"i","key_id":"k","private_key":"p"}' > "$KEYS/notary-api-key.json"

# The stub signs by appending a marker, after proving it was handed the key and
# a password that opens it; notary-submit checks the zip holds a signed file.
# The helper hands it no environment, so its knobs are files beside it.
cat > "$TMP/bin/rcodesign" <<'STUB'
#!/bin/bash
ME="$(dirname "$0")"
. "$ME/stub.env"
echo "$*" >> "$STUB_LOG"
{ echo "cwd=$PWD"; env; } > "$ME/seen"
case "$*" in *"--config-file /dev/null"*) ;; *) echo "stub: would load config files" >> "$STUB_LOG" ;; esac
cmd="$1"; shift
case "$cmd" in
  sign)
    [ ! -e "$ME/fail-sign" ] || exit 1
    p12=""; pw=""; target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --p12-file) p12="$2"; shift 2 ;;
        --p12-password-file) pw="$2"; shift 2 ;;
        --code-signature-flags|--timestamp-url|--config-file) shift 2 ;;
        *) target="$1"; shift ;;
      esac
    done
    openssl pkcs12 -legacy -in "$p12" -passin file:"$pw" -nokeys >/dev/null 2>&1 || { echo "stub: bad p12" >&2; exit 1; }
    echo "signed-path $target" >> "$STUB_LOG"
    printf 'SIGNED' >> "$target" ;;
  notary-submit)
    [ ! -e "$ME/fail-notary" ] || exit 1
    zip="${*: -1}"
    unzip -p "$zip" | tail -c 6 | grep -qx SIGNED || { echo "stub: zip holds no signed file" >&2; exit 1; }
    echo "notarized" >> "$STUB_LOG" ;;
  *) exit 64 ;;
esac
STUB
chmod 755 "$TMP/bin/rcodesign"

printf 'STUB_LOG=%q\nPATH=%q\n' "$LOG" "$PATH" > "$TMP/bin/stub.env"
run() {
  HERDR_SIGNER_WORK_DIR="$WORK" HERDR_SIGNER_KEY_DIR="$KEYS" HERDR_SIGNER_RCODESIGN="$TMP/bin/rcodesign" \
    "$HELPER" "$@"
}
fresh() { # fresh <path>: a Mach-O copy of /usr/bin/true
  cp /usr/bin/true "$1"; chmod 755 "$1"; : > "$LOG"
}

# A Mach-O in _work is signed with hardened runtime and Apple's timestamp,
# notarized, and written back in place.
BIN="$WORK/herdr/herdr/dist/herdr-macos-aarch64"
fresh "$BIN"
if OUT="$(run "$BIN" 2>&1)"; then ok "signs a Mach-O in _work"; else bad "signs a Mach-O in _work (got: $OUT)"; fi
[ "$(tail -c 6 "$BIN")" = "SIGNED" ] && ok "the signed copy replaces the file" || bad "the signed copy replaces the file"
[ -x "$BIN" ] && ok "the file stays executable" || bad "the file stays executable"
grep -q -- "--code-signature-flags runtime" "$LOG" && ok "signs with hardened runtime" || bad "signs with hardened runtime"
grep -q -- "--timestamp-url http://timestamp.apple.com/ts01" "$LOG" && ok "signs with Apple's timestamp" || bad "signs with Apple's timestamp"
grep -q -- "--p12-file $KEYS/developer-id.p12 --p12-password-file $KEYS/p12-password" "$LOG" && ok "signs with the root-only key" || bad "signs with the root-only key"
SIGNED_PATH="$(sed -n 's/^signed-path //p' "$LOG")"
case "$SIGNED_PATH" in
  "$WORK"/*|"$(cd "$WORK" && pwd -P)"/*|"") bad "signs a copy outside _work, not the file itself (signed $SIGNED_PATH)" ;;
  *) ok "signs a copy outside _work, not the file itself" ;;
esac
grep -q -- "notary-submit --config-file /dev/null --api-key-file $KEYS/notary-api-key.json --wait --max-wait-seconds " "$LOG" && ok "notarizes with the root-only API key and waits" || bad "notarizes with the root-only API key and waits"
grep -qx notarized "$LOG" && ok "notarizes the signed file" || bad "notarizes the signed file"

# Apple can take longer than rcodesign's default 10 minutes.
grep -q -- "--wait --max-wait-seconds 1500 " "$LOG" && ok "waits 25 minutes for Apple" || bad "waits 25 minutes for Apple"
# As root, every read and write of a caller's path goes through the caller.
grep -qxF '  as_caller() { sudo -u "$CALLER" -- "$@"; }' "$HELPER" && ok "as root, touches the caller's files as the caller" || bad "as root, touches the caller's files as the caller"

# Two files in one call.
BIN2="$WORK/herdr/herdr/dist/herdr-macos-x86_64"
fresh "$BIN"; cp /usr/bin/true "$BIN2"
if run "$BIN" "$BIN2" >/dev/null 2>&1 && [ "$(tail -c 6 "$BIN2")" = "SIGNED" ] && [ "$(grep -c '^notarized$' "$LOG")" = 2 ]; then
  ok "signs and notarizes each file given"; else bad "signs and notarizes each file given"; fi

refuses() { # refuses <label> <expected text> <path>...
  local label="$1" want="$2"; shift 2
  : > "$LOG"
  local out code
  out="$(run "$@" 2>&1)"; code=$?
  if [ "$code" -ne 0 ] && [ ! -s "$LOG" ]; then ok "refuses $label"; else bad "refuses $label (exit $code, rcodesign log: $(tr '\n' ' ' < "$LOG"))"; fi
  case "$out" in *"$want"*) ok "names why: $label" ;; *) bad "names why: $label (got: $out)" ;; esac
}

ln -sf "$BIN" "$WORK/link"
refuses "a symlink" "symlink" "$WORK/link"
printf 'not a binary\n' > "$WORK/notes.txt"
refuses "a file that is not Mach-O" "not a Mach-O" "$WORK/notes.txt"
cp /usr/bin/true "$TMP/outside/herdr"
refuses "a file outside _work" "outside" "$TMP/outside/herdr"
refuses "a path that climbs out of _work" "outside" "$WORK/../../outside/herdr"
refuses "a relative path" "absolute" "herdr"
refuses "a missing file" "no file" "$WORK/missing"
refuses "a refused file among good ones, before signing any" "not a Mach-O" "$BIN" "$WORK/notes.txt"

# A failed signing or notarization leaves the file as it was.
fresh "$BIN"; BEFORE="$(shasum -a 256 < "$BIN")"
touch "$TMP/bin/fail-sign"; run "$BIN" >/dev/null 2>&1; CODE=$?; rm -f "$TMP/bin/fail-sign"
[ "$CODE" -ne 0 ] && [ "$(shasum -a 256 < "$BIN")" = "$BEFORE" ] && ok "a failed signing leaves the file unchanged" || bad "a failed signing leaves the file unchanged"
touch "$TMP/bin/fail-notary"; run "$BIN" >/dev/null 2>&1; CODE=$?; rm -f "$TMP/bin/fail-notary"
[ "$CODE" -ne 0 ] && [ "$(shasum -a 256 < "$BIN")" = "$BEFORE" ] && ok "a failed notarization leaves the file unchanged" || bad "a failed notarization leaves the file unchanged"

# macOS's sudo keeps the caller's PATH and HOME, so the helper must not run the
# caller's commands, and rcodesign must not read the caller's config files.
mkdir -p "$TMP/evil" "$TMP/evilhome/.config/rcodesign"
for tool in id test sh cat od tr mktemp mkdir basename dirname ditto rm env sudo; do
  printf '#!/bin/bash\necho %s >> %q\nexec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin %s "$@"\n' "$tool" "$TMP/planted" "$tool" > "$TMP/evil/$tool"
done
chmod 755 "$TMP/evil"/*
printf 'echo BASH_ENV >> %q\n' "$TMP/planted" > "$TMP/evil.bashrc"
fresh "$BIN"
(cd "$TMP/evilhome" && PATH="$TMP/evil:$PATH" HOME="$TMP/evilhome" BASH_ENV="$TMP/evil.bashrc" \
  RCODESIGN_PLANTED=1 run "$BIN" >/dev/null 2>&1); CODE=$?
[ "$CODE" -eq 0 ] && ok "signs under a hostile environment" || bad "signs under a hostile environment (exit $CODE)"
[ ! -e "$TMP/planted" ] && ok "runs nothing from the caller's PATH or BASH_ENV" || bad "runs nothing from the caller's PATH or BASH_ENV (ran: $(sort -u "$TMP/planted" | tr '\n' ' '))"
grep -q 'evil' "$TMP/bin/seen" && bad "rcodesign gets none of the caller's HOME, PATH or directory ($(grep evil "$TMP/bin/seen" | tr '\n' ' '))" || ok "rcodesign gets none of the caller's HOME, PATH or directory"
grep -q '^RCODESIGN_' "$TMP/bin/seen" && bad "rcodesign gets no RCODESIGN_ settings from the caller" || ok "rcodesign gets no RCODESIGN_ settings from the caller"
grep -q 'would load config files' "$LOG" && bad "rcodesign loads no config file" || ok "rcodesign loads no config file"

run >/dev/null 2>&1; CODE=$?
[ "$CODE" -eq 2 ] && ok "no file is a usage error" || bad "no file is a usage error (got $CODE)"

[ "$FAILS" -eq 0 ] || { echo "sign-helper: $FAILS check(s) failed" >&2; exit 1; }
echo "PASS: the signing helper signs and notarizes only Mach-O files in _work"
