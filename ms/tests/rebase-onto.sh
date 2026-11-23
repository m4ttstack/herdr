#!/bin/bash
# ms/rebase-onto.sh moves the fork commits onto a new upstream tag as
# mattstack/<version>, and names the fork commit that conflicts.
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/ms/rebase-onto.sh"
REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1" >&2; FAILS=$((FAILS + 1)); }
g() { git -C "$REPO" -c user.name=test -c user.email=test@example.com "$@"; }

g init -q -b main
printf 'version = "1.0.0"\n' > "$REPO/Cargo.toml"
printf 'x\n' > "$REPO/x.txt"; printf 'y\n' > "$REPO/y.txt"; printf 'z\n' > "$REPO/z.txt"
printf '# herdr\nupstream readme\n' > "$REPO/README.md"; printf 'upstream translation\n' > "$REPO/README.zh-CN.md"
g add -A; g commit -qm "release: v1.0.0"; g tag v1.0.0

g switch -q -c mattstack/1.0.0
printf '# herdr (mattstack fork)\nA fork of herdrdev/herdr 1.0.0.\n[Upstream README at 1.0.0](https://github.com/herdrdev/herdr/blob/v1.0.0/README.md)\n' > "$REPO/README.md"
g rm -q README.zh-CN.md; g add -A; g commit -qm "fork identity: readme"
printf 'x fork\n' > "$REPO/x.txt"; g commit -qam "fork one: x"
printf 'y fork\n' > "$REPO/y.txt"; g commit -qam "fork two: y"

g switch -q main
printf 'version = "1.0.1"\n' > "$REPO/Cargo.toml"; printf 'z new\n' > "$REPO/z.txt"
g commit -qam "release: v1.0.1"; g tag v1.0.1
printf 'version = "1.0.2"\n' > "$REPO/Cargo.toml"; printf 'y upstream\n' > "$REPO/y.txt"
g commit -qam "release: v1.0.2"; g tag v1.0.2
g switch -q --detach v1.0.1
printf 'version = "1.0.3"\n' > "$REPO/Cargo.toml"
printf '# herdr\nupstream readme, edited\n' > "$REPO/README.md"; printf 'upstream translation, edited\n' > "$REPO/README.zh-CN.md"
g commit -qam "release: v1.0.3"; g tag v1.0.3

# Clean case: v1.0.1 touches only an unrelated file.
g switch -q mattstack/1.0.0
if (cd "$REPO" && "$SCRIPT" v1.0.1 >/dev/null 2>&1); then ok "clean rebase exits 0"; else bad "clean rebase exits 0"; fi
if [ "$(g log --format=%s v1.0.1..mattstack/1.0.1 2>/dev/null | tr '\n' '|')" = "fork two: y|fork one: x|fork identity: readme|" ]; then
  ok "mattstack/1.0.1 holds both fork commits on v1.0.1"; else bad "mattstack/1.0.1 holds both fork commits on v1.0.1"; fi
if [ "$(g merge-base v1.0.1 mattstack/1.0.1)" = "$(g rev-parse v1.0.1)" ]; then ok "mattstack/1.0.1 starts at v1.0.1"; else bad "mattstack/1.0.1 starts at v1.0.1"; fi
if [ "$(g log --format=%s v1.0.0..mattstack/1.0.0 | tr '\n' '|')" = "fork two: y|fork one: x|fork identity: readme|" ]; then
  ok "mattstack/1.0.0 is unchanged"; else bad "mattstack/1.0.0 is unchanged"; fi

# Conflict case: v1.0.2 edits the line fork commit two edits.
g switch -q mattstack/1.0.0
ERR="$(cd "$REPO" && "$SCRIPT" v1.0.2 2>&1 >/dev/null)"; CODE=$?
if [ "$CODE" -eq 3 ]; then ok "conflict exits 3"; else bad "conflict exits 3 (got $CODE)"; fi
case "$ERR" in *"fork two: y"*) ok "stderr names the conflicting commit" ;; *) bad "stderr names the conflicting commit (got: $ERR)" ;; esac
if ! g rev-parse -q --verify refs/heads/mattstack/1.0.2 >/dev/null; then ok "no mattstack/1.0.2 left behind"; else bad "no mattstack/1.0.2 left behind"; fi
if [ ! -d "$REPO/.git/rebase-merge" ] && [ ! -d "$REPO/.git/rebase-apply" ] && [ -z "$(g status --porcelain)" ]; then
  ok "the repo is left clean"; else bad "the repo is left clean"; fi

# Upstream edits its README files: the fork's README wins, the translation stays
# deleted, and the README names the new base.
g switch -q mattstack/1.0.0
if (cd "$REPO" && "$SCRIPT" v1.0.3 >/dev/null 2>&1); then ok "README-only conflicts rebase cleanly"; else bad "README-only conflicts rebase cleanly"; fi
if [ "$(g show mattstack/1.0.3:README.md 2>/dev/null)" = "$(printf '# herdr (mattstack fork)\nA fork of herdrdev/herdr 1.0.3.\n[Upstream README at 1.0.3](https://github.com/herdrdev/herdr/blob/v1.0.3/README.md)')" ]; then
  ok "the fork README names the new base"; else bad "the fork README names the new base (got: $(g show mattstack/1.0.3:README.md 2>&1))"; fi
if ! g cat-file -e mattstack/1.0.3:README.zh-CN.md 2>/dev/null; then ok "upstream's translated README stays deleted"; else bad "upstream's translated README stays deleted"; fi
if [ "$(g log --format=%s v1.0.3..mattstack/1.0.3 2>/dev/null | tr '\n' '|')" = "fork two: y|fork one: x|fork identity: readme|" ]; then
  ok "the base update folds into the fork commits"; else bad "the base update folds into the fork commits (got: $(g log --format=%s v1.0.3..mattstack/1.0.3 2>&1 | tr '\n' '|'))"; fi

# An existing branch is not overwritten.
g switch -q mattstack/1.0.0
(cd "$REPO" && "$SCRIPT" v1.0.1 >/dev/null 2>&1); CODE=$?
if [ "$CODE" -ne 0 ] && [ "$CODE" -ne 3 ]; then ok "refuses when mattstack/1.0.1 already exists"; else bad "refuses when mattstack/1.0.1 already exists (got $CODE)"; fi

[ "$FAILS" -eq 0 ] || { echo "rebase-onto.sh: $FAILS check(s) failed" >&2; exit 1; }
echo "PASS: rebase-onto"
