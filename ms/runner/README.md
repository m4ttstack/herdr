# The herdr-signer runner

`ms-release.yml` builds, signs and notarizes fork releases on one self-hosted
Mac runner, labelled `herdr-signer`. The Developer ID Application certificate
and the App Store Connect API key live only on that Mac, readable only by root;
they are never GitHub secrets.

Release jobs run as the `herdr-signer` user, and so does every build script and
crate a release compiles. That user cannot read the key. It can run exactly one
command as root, the signing helper, which signs and notarizes the binaries a
job hands it.

## What the install sets up

`ms/runner/install.sh`:

- creates a hidden `herdr-signer` macOS user, separate from mattstack's CI user,
  because every job a runner takes can read its user's files;
- installs a root-owned job-started hook (`ms/runner/job-started.sh`) that
  refuses every job except a manual `ms-release.yml` run on a `mattstack/*`
  branch of `m4ttstack/herdr`;
- installs rustup and the `aarch64-apple-darwin` and `x86_64-apple-darwin`
  targets for that user;
- installs, owned by `root:wheel`, the signing helper
  `/usr/local/herdr-signer/sign.sh` (`ms/runner/sign.sh`) and a pinned
  [rcodesign](https://github.com/indygreg/apple-platform-rs) 0.29.0
  (`/usr/local/herdr-signer/rcodesign`, checked against its sha256). rcodesign
  signs from a `.p12` file, because the runner is a launchd daemon outside any
  user session, where macOS refuses keychain signing;
- keeps the key in `/usr/local/herdr-signer/keys` (`root:wheel`, mode 700):
  `developer-id.p12`, its password `p12-password`, and `notary-api-key.json`,
  the App Store Connect API key in rcodesign's
  `encode-app-store-connect-api-key` form (each mode 600). An older install's
  `~herdr-signer/.herdr-signing` moves there and is deleted;
- installs the sudoers drop-in `/etc/sudoers.d/herdr-signer`
  (`ms/runner/sudoers`, mode 440), checked with `visudo -c` first, which lets
  `herdr-signer` run the helper as root without a password and nothing else,
  and gives anything an admin runs as `herdr-signer` its own terminal (`use_pty`);
- registers runner `herdr-signer-<LocalHostName>` with the single label
  `herdr-signer`, run by launchd (`dev.mattstack.herdr-signer`).

## The signing helper

The Sign and notarize step runs
`sudo -n /usr/local/herdr-signer/sign.sh "$PWD/dist/herdr-macos-aarch64" "$PWD/dist/herdr-macos-x86_64"`.
For each path the helper:

1. refuses a relative path, a symlink, a missing file, a file outside
   `~herdr-signer/runner/_work`, and (after copying it) anything that is not a
   Mach-O binary; it checks every path before it signs any;
2. copies the file into a root-owned temporary directory, reading it as
   `herdr-signer`, so it never reads a file that user could not;
3. signs the copy with hardened runtime and Apple's timestamp server.
   rcodesign gets an empty environment and no config file, and the helper pins
   its own `PATH`, because macOS's sudo keeps the caller's `PATH` and `HOME`;
4. zips it (Apple's notary service takes no bare Mach-O) and submits it with
   `rcodesign notary-submit --wait`, which waits for Apple's verdict;
5. once every file is signed and notarized, writes each back over its path,
   as `herdr-signer`.

The Verify step then runs `ms/verify-release.sh` on each binary: it fails
unless the signature names a `Developer ID Application` authority, carries the
hardened runtime flag and a secure timestamp, `spctl -a -t install` accepts it
as `Notarized Developer ID`, and `lipo` reports the expected CPU. A bare binary
cannot carry a stapled ticket, so Gatekeeper looks the notarization up online
the first time it sees the file.

What the helper does not stop: build code in a release job can hand it any
Mach-O file it writes under `_work` and get it signed and notarized as the
fork. It can no longer take the key away. The job-started hook is what keeps
other jobs off this runner.

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
3. For notarization, create an App Store Connect API key at
   https://appstoreconnect.apple.com/access/api with the Developer
   role (or reuse one), note its Key ID and the Issuer ID, download its
   `AuthKey_<Key ID>.p8`, and copy that to the signing Mac too.
4. From a real terminal (it asks for your sudo password and the `.p12`
   password), at the root of a clone of `m4ttstack/herdr`:

   ```bash
   ms/runner/install.sh --p12 ~/developer-id.p12 \
     --notary-key-id <Key ID> --notary-issuer <Issuer ID> --notary-key ~/AuthKey_<Key ID>.p8
   ```

   If `gh` on the signing Mac is not signed in, mint the runner registration
   token on a Mac where it is, and run the install over SSH from there:

   ```bash
   ssh -t <signing mac> "cd <clone> && ms/runner/install.sh --p12 ~/developer-id.p12 \
     --notary-key-id <Key ID> --notary-issuer <Issuer ID> --notary-key ~/AuthKey_<Key ID>.p8 \
     --registration-token $(gh api -X POST repos/m4ttstack/herdr/actions/runners/registration-token --jq .token)"
   ```

5. Delete the `.p12` and `.p8` copies.

A rerun keeps the runner registration and the installed key material, and
rewrites the hook, the helper, rcodesign, the sudoers drop-in and the launchd
job; `--p12` replaces the signing certificate and the `--notary-*` flags the
API key. It deletes the signing keychain an older install made.

### Reinstall after this change

An install from before the signing helper kept the `.p12` in
`~herdr-signer/.herdr-signing`. Pull this branch on the signing Mac and rerun
the install with the notary flags (the `.p12` moves by itself; pass `--p12`
only to replace it). After it, `~herdr-signer/.herdr-signing` is gone and
release jobs can no longer read the key.

## Check it

```bash
gh api repos/m4ttstack/herdr/actions/runners --jq '.runners[]|.name+" "+.status'
sudo ls -la /usr/local/herdr-signer /usr/local/herdr-signer/keys
sudo -u herdr-signer sudo -n -l
```

The first lists `herdr-signer-<host> online`. The second shows `sign.sh`,
`rcodesign` and `job-started.sh` owned by `root`, and `keys` as
`drwx------ root wheel` holding `developer-id.p12`, `p12-password` and
`notary-api-key.json`, each `-rw------- root wheel`. The third lists only
`(root) NOPASSWD: /usr/local/herdr-signer/sign.sh`.

rcodesign reads only the legacy `.p12` format. If a release fails to sign with
"incorrect password given when decrypting PFX data", convert the export and
install again with the converted file:
`openssl pkcs12 -in developer-id.p12 -nodes | openssl pkcs12 -export -legacy -out developer-id-legacy.p12`.

## Publish

```bash
gh workflow run ms-release.yml -R m4ttstack/herdr -f branch=mattstack/<upstream version>
gh run watch -R m4ttstack/herdr
```

A GitHub-hosted job picks the version. The job on this runner builds both CPUs,
signs and notarizes them through the helper, fails unless `ms/verify-release.sh`
accepts each one, and reports their hashes; build code runs there, so it gets no
token that can write. A second GitHub-hosted job checks the hashes and publishes
`v<base>-ms.<N>` as the latest release with `herdr-builds.json` and `latest.json`.
When it publishes a newer base it prints the `gh repo edit --default-branch`
command to run, since its token cannot change the default branch.

## The nightly upstream check

`ms-upstream.yml` runs every night at 09:00 UTC. GitHub turns off a public
repository's scheduled workflows after 60 days without repository activity, so a
fork that goes that long without a push or release loses its nightly. When the Actions tab shows ms-upstream as disabled,
turn it back on:

```bash
gh workflow enable ms-upstream.yml -R m4ttstack/herdr
gh workflow run ms-upstream.yml -R m4ttstack/herdr
```

The job that runs upstream's build and test code gets no token. A second job, on
a fresh machine, rebases again and pushes only if it gets the tree that was
tested.

The nightly keeps one issue per upstream version, labelled `ms-upstream` and
marked in its body. It opens the issue the first night, edits and comments on
it when the outcome changes (a conflict fixed, a push that now works), and
stays quiet while a night repeats the last outcome.
