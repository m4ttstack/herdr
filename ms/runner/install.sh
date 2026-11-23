#!/bin/bash
# Installs the herdr-signer runner: the one self-hosted runner that builds and
# signs m4ttstack/herdr releases. Run it on the signing Mac, from a real terminal
# at the repo root, as yourself: it needs sudo's password prompt, your gh login
# and the Developer ID Application certificate exported as a .p12.
# Usage: ms/runner/install.sh --p12 PATH [--registration-token TOKEN]
# --registration-token takes a runner registration token minted elsewhere
# (gh api -X POST repos/m4ttstack/herdr/actions/runners/registration-token),
# for a Mac whose gh is not signed in.
set -euo pipefail

P12=""
REGISTRATION_TOKEN=""
USAGE="usage: ms/runner/install.sh --p12 PATH [--registration-token TOKEN]"
while [ $# -gt 0 ]; do
  case "$1" in
    --p12) P12="${2:-}"; shift 2 ;;
    --registration-token) REGISTRATION_TOKEN="${2:-}"; shift 2 ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "Unknown option $1. $USAGE" >&2; exit 2 ;;
  esac
done
# Before anything changes this Mac: a wrong path most likely means the wrong Mac.
if [ -n "$P12" ] && [ ! -f "$P12" ]; then
  echo "No file $P12. Export the Developer ID Application certificate as a .p12 first (see ms/runner/README.md), on the signing Mac." >&2
  exit 1
fi

VERSION=2.338.2
case "$(uname -m)" in
  arm64) RUNNER_ARCH=arm64; SHA256=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388 ;;
  x86_64) RUNNER_ARCH=x64; SHA256=109fff505a34014a7e8d1acb850c33d404811102f572b8fb9788e2fff013cc49 ;;
  *) echo "No runner build for $(uname -m)." >&2; exit 1 ;;
esac
REPO=m4ttstack/herdr
ZIG_VERSION=0.16.0
# Its own user, not the mattstack CI user: every job a runner takes can read
# that user's keychains, and mattstack's runners take pull request jobs.
CI_USER=herdr-signer
CI_HOME=/Users/$CI_USER
HOOK_DIR=/usr/local/herdr-signer
KEYCHAIN=$CI_HOME/Library/Keychains/herdr-signing.keychain-db
KEYCHAIN_PASSWORD_FILE=$CI_HOME/.herdr-signing/keychain-password
HOST=$(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]')
NAME=herdr-signer-$HOST
DIR=$CI_HOME/runner
LABEL=dev.mattstack.herdr-signer
PLIST=/Library/LaunchDaemons/$LABEL.plist
TOOL_PATH=$CI_HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

[ "$(id -u)" != 0 ] || { echo "Run this as yourself, not root." >&2; exit 1; }
[ -f ms/runner/job-started.sh ] || { echo "Run this from the repo root." >&2; exit 1; }
if [ -z "$REGISTRATION_TOKEN" ]; then
  command -v gh >/dev/null || { echo "Install gh and run gh auth login first, or pass --registration-token." >&2; exit 1; }
  gh auth status --hostname github.com >/dev/null
fi
# Release jobs run as $CI_USER with only $TOOL_PATH, so the tools must be there,
# not in your home.
for tool in gh jq zig; do
  PATH="$TOOL_PATH" command -v "$tool" >/dev/null || {
    echo "Release jobs need $tool in /usr/local/bin or /opt/homebrew/bin (see ms/runner/README.md)." >&2; exit 1; }
done
[ "$(PATH="$TOOL_PATH" zig version)" = "$ZIG_VERSION" ] || {
  echo "zig in /usr/local/bin or /opt/homebrew/bin is $(PATH="$TOOL_PATH" zig version); herdr's build needs $ZIG_VERSION." >&2; exit 1; }
PATH="$TOOL_PATH:$PATH"

sudo -v

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

# Root owns the hook, so a job cannot rewrite the rule that admits it.
sudo mkdir -p "$HOOK_DIR"
sudo install -o root -g wheel -m 755 ms/runner/job-started.sh "$HOOK_DIR/job-started.sh"

# The runner user's commands below cannot start from a directory in your home.
REPO_ROOT=$PWD
cd /

sudo -u "$CI_USER" -H bash -c '
  set -euo pipefail
  export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  command -v rustup >/dev/null || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
'

has_identity() {
  sudo -u "$CI_USER" -H security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q '"Developer ID Application:'
}
if ! has_identity; then
  [ -n "$P12" ] || { echo "The signing keychain has no Developer ID Application identity yet: pass --p12." >&2; exit 1; }
  read -r -s -p "Password of $P12: " P12_PASSWORD
  echo
  sudo -u "$CI_USER" -H mkdir -p "$(dirname "$KEYCHAIN_PASSWORD_FILE")" "$(dirname "$KEYCHAIN")"
  sudo -u "$CI_USER" -H chmod 700 "$(dirname "$KEYCHAIN_PASSWORD_FILE")"
  if ! sudo test -f "$KEYCHAIN"; then
    KEYCHAIN_PASSWORD=$(openssl rand -base64 24)
    printf '%s' "$KEYCHAIN_PASSWORD" | sudo -u "$CI_USER" -H tee "$KEYCHAIN_PASSWORD_FILE" >/dev/null
    sudo -u "$CI_USER" -H chmod 600 "$KEYCHAIN_PASSWORD_FILE"
    sudo -u "$CI_USER" -H security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    # No auto-lock: a release job unlocks it with the password file.
    sudo -u "$CI_USER" -H security set-keychain-settings "$KEYCHAIN"
  else
    KEYCHAIN_PASSWORD=$(sudo -u "$CI_USER" -H cat "$KEYCHAIN_PASSWORD_FILE")
  fi
  # Not $TMPDIR: the runner user cannot read yours.
  P12_COPY=$(mktemp /tmp/herdr-signing.XXXXXX)
  trap 'sudo rm -f "$P12_COPY"' EXIT
  cp "$P12" "$P12_COPY"
  sudo chown "$CI_USER" "$P12_COPY"
  sudo chmod 600 "$P12_COPY"
  sudo -u "$CI_USER" -H security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  # -f: the copy has no .p12 extension to infer the format from.
  # -x: the private key can never be exported from this keychain, even by a
  # job that knows the keychain password.
  sudo -u "$CI_USER" -H security import "$P12_COPY" -k "$KEYCHAIN" -f pkcs12 -P "$P12_PASSWORD" -x -T /usr/bin/codesign
  # Lets codesign use the key without a GUI prompt, which a launchd job cannot answer.
  sudo -u "$CI_USER" -H security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
fi
has_identity || {
  echo "The signing keychain holds no valid Developer ID Application identity. See ms/runner/README.md." >&2; exit 1; }

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
    <key>HERDR_SIGNING_KEYCHAIN</key><string>$KEYCHAIN</string>
    <key>HERDR_SIGNING_KEYCHAIN_PASSWORD_FILE</key><string>$KEYCHAIN_PASSWORD_FILE</string>
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
