#!/bin/bash
# Moves the fork commits on the current mattstack branch onto a new upstream tag,
# as branch mattstack/<version>. The current branch is left as it was.
# Exit 0: rebased cleanly. Exit 3: a fork commit conflicts; its subject is on stderr.
set -euo pipefail

TAG="${1:-}"
case "$TAG" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: ms/rebase-onto.sh v<x.y.z>" >&2; exit 2 ;;
esac
VERSION="${TAG#v}"
NEW_BRANCH="mattstack/$VERSION"

[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "ms/rebase-onto.sh: the working tree has changes" >&2; exit 2; }
OLD_VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' Cargo.toml | head -1)"
OLD_BASE="v$OLD_VERSION"
git rev-parse -q --verify "refs/tags/$OLD_BASE" >/dev/null || { echo "ms/rebase-onto.sh: no tag $OLD_BASE (the current base)" >&2; exit 2; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "ms/rebase-onto.sh: no tag $TAG" >&2; exit 2; }
if git rev-parse -q --verify "refs/heads/$NEW_BRANCH" >/dev/null; then
  echo "ms/rebase-onto.sh: $NEW_BRANCH already exists" >&2; exit 2
fi

START="$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)"
git switch -q -c "$NEW_BRANCH"
if git -c core.editor=true rebase -q --onto "$TAG" "$OLD_BASE" "$NEW_BRANCH" >/dev/null 2>&1; then
  echo "ms/rebase-onto.sh: $NEW_BRANCH = $TAG + $(git rev-list --count "$TAG..$NEW_BRANCH") fork commits"
  exit 0
fi

SUBJECT="$(git log -1 --format=%s REBASE_HEAD 2>/dev/null || echo "unknown commit")"
git rebase --abort
git switch -q "$START"
git branch -q -D "$NEW_BRANCH"
echo "ms/rebase-onto.sh: fork commit \"$SUBJECT\" conflicts with $TAG" >&2
exit 3
