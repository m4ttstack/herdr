#!/bin/bash
# The herdr-signer runner's job-started hook admits only a manual ms-release.yml
# run on a mattstack/* branch of m4ttstack/herdr.
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/../.." && pwd)/ms/runner/job-started.sh"
FAILS=0

run_hook() { # run_hook <repository> <event> <workflow ref>
  env -i PATH=/usr/bin:/bin GITHUB_REPOSITORY="$1" GITHUB_EVENT_NAME="$2" GITHUB_WORKFLOW_REF="$3" \
    bash "$HOOK" >/dev/null 2>&1
}
expect() { # expect <admit|refuse> <description> <args...>
  local want=$1 what=$2; shift 2
  if run_hook "$@"; then got=admit; else got=refuse; fi
  if [ "$got" = "$want" ]; then echo "ok   $what"; else echo "FAIL $what: got $got" >&2; FAILS=$((FAILS + 1)); fi
}

REL=m4ttstack/herdr/.github/workflows/ms-release.yml
expect admit "manual release on mattstack/0.9.5" m4ttstack/herdr workflow_dispatch "$REL@refs/heads/mattstack/0.9.5"
expect refuse "release from a non-mattstack branch" m4ttstack/herdr workflow_dispatch "$REL@refs/heads/feature"
expect refuse "pull request event" m4ttstack/herdr pull_request "$REL@refs/heads/mattstack/0.9.5"
expect refuse "push event" m4ttstack/herdr push "$REL@refs/heads/mattstack/0.9.5"
expect refuse "another workflow" m4ttstack/herdr workflow_dispatch "m4ttstack/herdr/.github/workflows/release.yml@refs/heads/mattstack/0.9.5"
expect refuse "another repository" someone/herdr workflow_dispatch "someone/herdr/.github/workflows/ms-release.yml@refs/heads/mattstack/0.9.5"
expect refuse "nothing set" "" "" ""

[ "$FAILS" -eq 0 ] || { echo "job-started.sh: $FAILS check(s) failed" >&2; exit 1; }
echo "PASS: job-started hook"
