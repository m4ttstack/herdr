# The herdr-signer runner

`ms-release.yml` builds and signs fork releases on one self-hosted Mac runner,
labelled `herdr-signer`. The Developer ID Application certificate lives only on
that Mac, as a `.p12` file only the runner's user can read; it is never a GitHub
secret.

## What the install sets up

`ms/runner/install.sh`:

- creates a hidden `herdr-signer` macOS user, separate from mattstack's CI user,
  because every job a runner takes can read its user's files;
- installs a root-owned job-started hook (`ms/runner/job-started.sh`) that
  refuses every job except a manual `ms-release.yml` run on a `mattstack/*`
  branch of `m4ttstack/herdr`;
- installs rustup and the `aarch64-apple-darwin` and `x86_64-apple-darwin`
  targets for that user;
- copies the `.p12` to `~herdr-signer/.herdr-signing/developer-id.p12` and its
  password to `~herdr-signer/.herdr-signing/p12-password` (both mode 600);
  release jobs sign with a pinned [rcodesign](https://github.com/indygreg/apple-platform-rs)
  from that file, because the runner is a launchd daemon outside any user
  session, where macOS refuses keychain signing;
- registers runner `herdr-signer-<LocalHostName>` with the single label
  `herdr-signer`, run by launchd (`dev.mattstack.herdr-signer`).

## Install

On the signing Mac:

1. Put `gh`, `jq` and zig 0.16.0 where the `herdr-signer` user can run them:
   `/usr/local/bin` or `/opt/homebrew/bin` (`jq` ships with macOS at
   `/usr/bin/jq`). On Apple silicon, `brew install gh jq zig`. On an Intel Mac,
   which Homebrew no longer supports, unpack zig from
   https://ziglang.org/download/ (`zig-x86_64-macos-0.16.0.tar.xz`) into a
   folder only you can write, such as `/Users/Shared/herdr-tools`, and link
   `zig` and a copy of `gh` into `/usr/local/bin`.
2. On the Mac that holds the certificate, open Keychain Access, find
   "Developer ID Application: …" under My Certificates, and export it with its
   private key as a `.p12` with a password. Copy the file to the signing Mac.
3. From a real terminal (it asks for your sudo password and the `.p12`
   password), at the root of a clone of `m4ttstack/herdr`:

   ```bash
   ms/runner/install.sh --p12 ~/developer-id.p12
   ```

   If `gh` on the signing Mac is not signed in, mint the runner registration
   token on a Mac where it is, and run the install over SSH from there:

   ```bash
   ssh -t <signing mac> "cd <clone> && ms/runner/install.sh --p12 ~/developer-id.p12 \
     --registration-token $(gh api -X POST repos/m4ttstack/herdr/actions/runners/registration-token --jq .token)"
   ```

4. Delete the `.p12` copy.

A rerun keeps the runner registration and rewrites the hook and the launchd job;
with `--p12` it also replaces the signing certificate. It deletes the signing
keychain an older install made.

## Check it

```bash
gh api repos/m4ttstack/herdr/actions/runners --jq '.runners[]|.name+" "+.status'
sudo ls -l /Users/herdr-signer/.herdr-signing
```

The first lists `herdr-signer-<host> online`. The second lists
`developer-id.p12` and `p12-password`, each `-rw-------` and owned by
`herdr-signer`.

rcodesign reads only the legacy `.p12` format. If a release fails to sign with
"incorrect password given when decrypting PFX data", convert the export and
install again with the converted file:
`openssl pkcs12 -in developer-id.p12 -nodes | openssl pkcs12 -export -legacy -out developer-id-legacy.p12`.

## Publish

```bash
gh workflow run ms-release.yml -R m4ttstack/herdr -f branch=mattstack/<upstream version>
gh run watch -R m4ttstack/herdr
```

The job builds both CPUs, signs them, fails unless `codesign --verify --strict`
and `lipo -archs` pass, and publishes `v<base>-ms.<N>` as the latest release
with `herdr-builds.json` and `latest.json`. When it publishes a newer base it
prints the `gh repo edit --default-branch` command to run, since its token
cannot change the default branch.
