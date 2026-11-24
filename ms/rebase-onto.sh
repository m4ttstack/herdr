#!/bin/bash
# Moves the fork commits on the current mattstack branch onto a new upstream tag,
# as branch mattstack/<version>. The current branch is left as it was.
# Exit 0: rebased cleanly. Exit 3: a fork commit conflicts; its subject is on stderr.
# Exit 4: the rebase failed for another reason; git's output is on stderr.
# Exit 2: bad input. Every failure leaves no rebase state and the start branch checked out.
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

LOG="$(mktemp)"
DONE=""
on_exit() {
  local code=$?
  set +e
  rm -f "$LOG"
  [ -z "$DONE" ] || exit "$code"
  clean_up
  case "$code" in 3|4) exit "$code" ;; *) exit 4 ;; esac
}
trap on_exit EXIT

in_rebase() {
  [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]
}

# Undoes the rebase even when --abort fails, and returns to the start branch.
clean_up() {
  if in_rebase; then
    git rebase --abort >/dev/null 2>&1 || git rebase --quit >/dev/null 2>&1 \
      || rm -rf "$(git rev-parse --git-path rebase-merge)" "$(git rev-parse --git-path rebase-apply)"
  fi
  git reset -q --hard
  git checkout -q -f "$START" --
  git branch -q -D "$NEW_BRANCH" 2>/dev/null || true
}

conflict() { # conflict <subject>
  echo "ms/rebase-onto.sh: fork commit \"$1\" conflicts with $TAG" >&2
  exit 3
}

failed() { # failed <detail>
  echo "ms/rebase-onto.sh: rebase failed onto $TAG: $1" >&2
  exit 4
}

# The fork replaces upstream's README files, so a conflict in one of them always
# resolves to the fork's side: its README.md, and no copy of a file it deleted.
resolve_readmes() {
  local conflicted path
  conflicted="$(git diff --name-only --diff-filter=U)"
  [ -n "$conflicted" ] || return 1
  while IFS= read -r path; do
    case "$path" in README*.md) ;; *) return 1 ;; esac
  done <<<"$conflicted"
  while IFS= read -r path; do
    if git cat-file -e "REBASE_HEAD:$path" 2>/dev/null; then
      git show "REBASE_HEAD:$path" > "$path"
      git add -- "$path"
    else
      git rm -q -- "$path"
    fi
  done <<<"$conflicted"
}

# rebase_through <git rebase args>: runs a rebase to the end, resolving README
# conflicts; any other conflict exits 3, any other failure exits 4.
rebase_through() {
  local subject
  if ! git rebase "$@" >"$LOG" 2>&1; then
    in_rebase || failed "$(cat "$LOG")"
  fi
  while in_rebase; do
    subject="$(git log -1 --format=%s REBASE_HEAD 2>/dev/null || echo "unknown commit")"
    [ -n "$(git diff --name-only --diff-filter=U)" ] || failed "it stopped at \"$subject\" without a conflict: $(cat "$LOG")"
    resolve_readmes || conflict "$subject"
    if ! git rebase --continue >"$LOG" 2>&1; then
      in_rebase || failed "$(cat "$LOG")"
    fi
  done
}

git switch -q -c "$NEW_BRANCH"
export GIT_EDITOR=true
rebase_through -q --onto "$TAG" "$OLD_BASE" "$NEW_BRANCH"

# The README names the upstream version the fork is built on; fold the new one
# into the commit that last changed the README.
README_COMMIT="$(git log -1 --format=%H "$TAG..HEAD" -- README.md)"
if [ -n "$README_COMMIT" ] && grep -qF "$OLD_VERSION" README.md; then
  OLD_PATTERN="$(printf '%s' "$OLD_VERSION" | sed 's/\./\\./g')"
  sed -i.bak "s/$OLD_PATTERN/$VERSION/g" README.md && rm -f README.md.bak
  git commit -q --fixup="$README_COMMIT" -- README.md
  GIT_SEQUENCE_EDITOR=true rebase_through -q -i --autosquash "$TAG"
fi

echo "ms/rebase-onto.sh: $NEW_BRANCH = $TAG + $(git rev-list --count "$TAG..$NEW_BRANCH") fork commits"
DONE=yes
exit 0
