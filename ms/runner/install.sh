#!/bin/bash
# Installs the herdr-signer runner: the one self-hosted runner that builds and
# signs m4ttstack/herdr releases. Run it on the signing Mac, from a real terminal
# at the repo root, as yourself: it needs sudo's password prompt, your gh login,
# the Developer ID Application certificate exported as a .p12 and an App Store
# Connect API key for notarization.
# Usage: ms/runner/install.sh [--p12 PATH] [--notary-key-id ID --notary-issuer UUID
#   --notary-key AuthKey_ID.p8] [--registration-token TOKEN]
# The first install needs --p12 and the three notary flags; a rerun keeps the
# key material already installed. --registration-token takes a runner
# registration token minted elsewhere
# (gh api -X POST repos/m4ttstack/herdr/actions/runners/registration-token),
# for a Mac whose gh is not signed in.
set -euo pipefail

P12=""
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
NOTARY_KEY=""
REGISTRATION_TOKEN=""
USAGE="usage: ms/runner/install.sh [--p12 PATH] [--notary-key-id ID --notary-issuer UUID --notary-key PATH] [--registration-token TOKEN]"
value() { # value <flag> <next arg>: the flag's value, or a refusal naming the flag
  case "${2:-}" in
    ''|--*) echo "$1 needs a value. $USAGE" >&2; exit 2 ;;
  esac
  printf '%s' "$2"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --p12) P12="$(value "$1" "${2:-}")"; shift 2 ;;
    --notary-key-id) NOTARY_KEY_ID="$(value "$1" "${2:-}")"; shift 2 ;;
    --notary-issuer) NOTARY_ISSUER="$(value "$1" "${2:-}")"; shift 2 ;;
    --notary-key) NOTARY_KEY="$(value "$1" "${2:-}")"; shift 2 ;;
    --registration-token) REGISTRATION_TOKEN="$(value "$1" "${2:-}")"; shift 2 ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "Unknown option $1. $USAGE" >&2; exit 2 ;;
  esac
done
# Before anything changes this Mac: a wrong path most likely means the wrong Mac.
if [ -n "$P12" ] && [ ! -f "$P12" ]; then
  echo "No file $P12. Export the Developer ID Application certificate as a .p12 first (see ms/runner/README.md), on the signing Mac." >&2
  exit 1
fi
if [ -n "$NOTARY_KEY_ID$NOTARY_ISSUER$NOTARY_KEY" ]; then
  for pair in "--notary-key-id:$NOTARY_KEY_ID" "--notary-issuer:$NOTARY_ISSUER" "--notary-key:$NOTARY_KEY"; do
    [ -n "${pair#*:}" ] || { echo "Notarization needs all three of --notary-key-id, --notary-issuer and --notary-key; ${pair%%:*} is missing." >&2; exit 2; }
  done
  [ -f "$NOTARY_KEY" ] || { echo "No file $NOTARY_KEY. Copy the App Store Connect API key's .p8 to this Mac first (see ms/runner/README.md)." >&2; exit 1; }
fi
# The install changes directory before it reads these.
[ -z "$P12" ] || P12="$(cd "$(dirname "$P12")" && pwd -P)/$(basename "$P12")"
[ -z "$NOTARY_KEY" ] || NOTARY_KEY="$(cd "$(dirname "$NOTARY_KEY")" && pwd -P)/$(basename "$NOTARY_KEY")"

VERSION=2.338.2
case "$(uname -m)" in
  arm64) RUNNER_ARCH=arm64; SHA256=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388 ;;
  x86_64) RUNNER_ARCH=x64; SHA256=109fff505a34014a7e8d1acb850c33d404811102f572b8fb9788e2fff013cc49 ;;
  *) echo "No runner build for $(uname -m)." >&2; exit 1 ;;
esac
REPO=m4ttstack/herdr
ZIG_VERSION=0.16.0
# Its own user, not the mattstack CI user: every job a runner takes can read
# that user's files, the signing .p12 among them, and mattstack's runners take
# pull request jobs.
CI_USER=herdr-signer
CI_HOME=/Users/$CI_USER
HOOK_DIR=/usr/local/herdr-signer
# Root-only: build code in a release job runs as $CI_USER and must not read the
# key. Jobs sign through $HOOK_DIR/sign.sh, which sudoers lets $CI_USER run.
KEY_DIR=$HOOK_DIR/keys
OLD_SIGNING_DIR=$CI_HOME/.herdr-signing
RCODESIGN_VERSION=0.29.0
RCODESIGN_SHA256=d98372d5524226ccf9dc0eda03d4e4f5826182dabb2fc3f2bd303ed9113a748d
OLD_KEYCHAIN=$CI_HOME/Library/Keychains/herdr-signing.keychain-db
HOST=$(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]')
NAME=herdr-signer-$HOST
DIR=$CI_HOME/runner
LABEL=dev.mattstack.herdr-signer
PLIST=/Library/LaunchDaemons/$LABEL.plist
TOOL_PATH=$CI_HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
# This script's own PATH. Build code can write $CI_HOME, so nothing run here, as
# an admin with sudo, may be looked up in it.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin

[ "$(id -u)" != 0 ] || { echo "Run this as yourself, not root." >&2; exit 1; }
[ -f ms/runner/job-started.sh ] || { echo "Run this from the repo root." >&2; exit 1; }
if [ -z "$REGISTRATION_TOKEN" ]; then
  command -v gh >/dev/null || { echo "Install gh and run gh auth login first, or pass --registration-token." >&2; exit 1; }
  gh auth status --hostname github.com >/dev/null
fi
# Release jobs run as $CI_USER, so the tools must be where it can find them, not
# in your home.
for tool in gh jq zig; do
  command -v "$tool" >/dev/null || {
    echo "Release jobs need $tool in /usr/local/bin or /opt/homebrew/bin (see ms/runner/README.md)." >&2; exit 1; }
done
[ "$(zig version)" = "$ZIG_VERSION" ] || {
  echo "zig in /usr/local/bin or /opt/homebrew/bin is $(zig version); herdr's build needs $ZIG_VERSION." >&2; exit 1; }

sudo -v

# Before anything runs as the runner user: the drop-in keeps its programs off this
# terminal. A drop-in that fails to parse would break sudo for everyone on this Mac.
visudo -cf ms/runner/sudoers
sudo install -o root -g wheel -m 440 ms/runner/sudoers /etc/sudoers.d/herdr-signer
if ! sudo visudo -c >/dev/null; then
  sudo rm -f /etc/sudoers.d/herdr-signer
  echo "sudo refused its configuration with the herdr-signer drop-in, so it is removed again." >&2
  exit 1
fi

if ! id "$CI_USER" >/dev/null 2>&1; then
  sudo sysadminctl -addUser "$CI_USER" -fullName "herdr signer" -home "$CI_HOME" -password "$(openssl rand -base64 24)"
  sudo createhomedir -c -u "$CI_USER" >/dev/null
  sudo dscl . create "/Users/$CI_USER" IsHidden 1
fi
sudo chmod 700 "$CI_HOME"

# A new macOS user joins staff, which a default home lets in.
if sudo -u "$CI_USER" test -x "$HOME"; then
  echo "$CI_USER can enter $HOME, so jobs could read your files. Run: chmod 700 $HOME" >&2
  exit 1
fi

# Root owns the hook and the signing helper, so a job can rewrite neither the
# rule that admits it nor the checks that guard the key.
sudo install -d -o root -g wheel -m 755 "$HOOK_DIR"
sudo install -o root -g wheel -m 755 ms/runner/job-started.sh "$HOOK_DIR/job-started.sh"
sudo install -o root -g wheel -m 755 ms/runner/sign.sh "$HOOK_DIR/sign.sh"
RCODESIGN_TARBALL=$(mktemp /tmp/apple-codesign.XXXXXX)
curl -fsSL -o "$RCODESIGN_TARBALL" \
  "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/$RCODESIGN_VERSION/apple-codesign-$RCODESIGN_VERSION-macos-universal.tar.gz"
echo "$RCODESIGN_SHA256  $RCODESIGN_TARBALL" | shasum -a 256 -c -
RCODESIGN_DIR=$(mktemp -d /tmp/apple-codesign.XXXXXX)
tar -xzf "$RCODESIGN_TARBALL" -C "$RCODESIGN_DIR"
sudo install -o root -g wheel -m 755 "$RCODESIGN_DIR/apple-codesign-$RCODESIGN_VERSION-macos-universal/rcodesign" "$HOOK_DIR/rcodesign"
rm -rf "$RCODESIGN_TARBALL" "$RCODESIGN_DIR"

# The runner user's commands below cannot start from a directory in your home.
REPO_ROOT=$PWD
cd /

sudo -u "$CI_USER" -H bash -c '
  set -euo pipefail
  export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  command -v rustup >/dev/null || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
'

# The helper signs with rcodesign from the .p12 file, since a launchd daemon runs
# outside any user session, where macOS refuses keychain signing.
sudo install -d -o root -g wheel -m 700 "$KEY_DIR"
has_signing_key() { sudo test -f "$KEY_DIR/developer-id.p12" && sudo test -f "$KEY_DIR/p12-password"; }
STAGED=""
if [ -n "$P12" ]; then
  read -r -s -p "Password of $P12: " P12_PASSWORD
  echo
  sudo install -o root -g wheel -m 600 "$P12" "$KEY_DIR/developer-id.p12.new"
  printf '%s' "$P12_PASSWORD" | sudo sh -c 'umask 077; cat > "$1"' _ "$KEY_DIR/p12-password.new"
  STAGED=yes
elif ! has_signing_key && sudo test -f "$OLD_SIGNING_DIR/developer-id.p12"; then
  # An older install kept the key in the runner user's home, where build code
  # could swap a file for a link: read as that user, never move as root.
  for file in developer-id.p12 p12-password; do
    sudo -u "$CI_USER" cat "$OLD_SIGNING_DIR/$file" | sudo sh -c 'umask 077; cat > "$1"' _ "$KEY_DIR/$file.new"
  done
  STAGED=yes
fi
if [ -n "$STAGED" ]; then
  # A wrong password must not replace a working pair: sign a scratch file first.
  PROBE=$(mktemp -d /tmp/herdr-signer-probe.XXXXXX)
  cp /usr/bin/true "$PROBE/probe"
  if ! sudo "$HOOK_DIR/rcodesign" sign --config-file /dev/null --p12-file "$KEY_DIR/developer-id.p12.new" \
      --p12-password-file "$KEY_DIR/p12-password.new" --timestamp-url none "$PROBE/probe" >"$PROBE/log" 2>&1; then
    tail -1 "$PROBE/log" >&2
    sudo rm -rf "$PROBE"
    sudo rm -f "$KEY_DIR/developer-id.p12.new" "$KEY_DIR/p12-password.new"
    echo "rcodesign cannot sign with that .p12 and password; the runner's key is unchanged." >&2
    echo "With the right password, convert the .p12 and install again: (umask 077; /usr/bin/openssl pkcs12 -in developer-id.p12 -nodes -out key.pem && /usr/bin/openssl pkcs12 -export -in key.pem -out developer-id-legacy.p12; rm -f key.pem)" >&2
    exit 1
  fi
  sudo rm -rf "$PROBE"
  for file in p12-password developer-id.p12; do sudo mv "$KEY_DIR/$file.new" "$KEY_DIR/$file"; done
fi
has_signing_key || {
  echo "The runner has no signing key yet: pass --p12 (see ms/runner/README.md)." >&2; exit 1; }
sudo rm -rf "$OLD_SIGNING_DIR"
if [ -n "$NOTARY_KEY" ]; then
  sudo "$HOOK_DIR/rcodesign" encode-app-store-connect-api-key -o "$KEY_DIR/notary-api-key.json" \
    "$NOTARY_ISSUER" "$NOTARY_KEY_ID" "$NOTARY_KEY" >/dev/null
fi
for file in developer-id.p12 p12-password notary-api-key.json; do
  sudo test -f "$KEY_DIR/$file" || {
    echo "The runner has no $file yet: pass --p12 and the --notary-* flags (see ms/runner/README.md)." >&2; exit 1; }
  sudo chown root:wheel "$KEY_DIR/$file"
  sudo chmod 600 "$KEY_DIR/$file"
done
sudo -u "$CI_USER" sudo -n -l /usr/local/herdr-signer/sign.sh >/dev/null || {
  echo "sudo does not let $CI_USER run $HOOK_DIR/sign.sh; check that /etc/sudoers includes /private/etc/sudoers.d." >&2; exit 1; }
if sudo test -f "$OLD_KEYCHAIN"; then
  sudo -u "$CI_USER" -H security delete-keychain "$OLD_KEYCHAIN"
fi

if ! sudo test -f "$DIR/.runner"; then
  TARBALL=$(mktemp /tmp/actions-runner.XXXXXX)
  curl -fsSL -o "$TARBALL" "https://github.com/actions/runner/releases/download/v$VERSION/actions-runner-osx-$RUNNER_ARCH-$VERSION.tar.gz"
  echo "$SHA256  $TARBALL" | shasum -a 256 -c -
  chmod 644 "$TARBALL"
  token=${REGISTRATION_TOKEN:-$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)}
  sudo -u "$CI_USER" -H mkdir -p "$DIR"
  sudo -u "$CI_USER" -H tar xzf "$TARBALL" -C "$DIR"
  rm -f "$TARBALL"
  sudo -u "$CI_USER" -H bash -c "cd '$DIR' && ./config.sh --unattended --url 'https://github.com/$REPO' --token '$token' --name '$NAME' --labels herdr-signer --no-default-labels --replace"
fi

sudo tee "$PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>UserName</key><string>$CI_USER</string>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>ProgramArguments</key><array><string>$DIR/run.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/launchd.log</string>
  <key>StandardErrorPath</key><string>$DIR/launchd.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$CI_HOME</string>
    <key>PATH</key><string>$TOOL_PATH</string>
    <key>ACTIONS_RUNNER_HOOK_JOB_STARTED</key><string>$HOOK_DIR/job-started.sh</string>
  </dict>
</dict>
</plist>
PLIST
sudo chown root:wheel "$PLIST"
sudo chmod 644 "$PLIST"
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
# A runner can outlive its bootout, and launchd can refuse the bootstrap with
# error 5 just after one.
for _ in $(seq 1 30); do
  launchctl print "system/$LABEL" >/dev/null 2>&1 || break
  sleep 1
done
for attempt in $(seq 1 18); do
  sudo launchctl bootstrap system "$PLIST" && break
  [ "$attempt" -lt 18 ] || exit 1
  sleep 5
done

cd "$REPO_ROOT"
echo "Installed $NAME. Check it: gh api repos/$REPO/actions/runners --jq '.runners[]|.name+\" \"+.status'"
