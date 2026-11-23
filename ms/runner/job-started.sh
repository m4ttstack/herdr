#!/bin/bash
# Runs before every job on the herdr-signer runner; a non-zero exit fails the job
# before checkout. The signing keychain is reachable from every job this runner
# takes, so it takes only a manual ms-release.yml run on a mattstack branch.
set -u

refuse() {
  echo "herdr-signer: refusing this job: $*" >&2
  exit 1
}

[ "${GITHUB_REPOSITORY:-}" = "m4ttstack/herdr" ] || refuse "repository ${GITHUB_REPOSITORY:-unset} is not m4ttstack/herdr"
[ "${GITHUB_EVENT_NAME:-}" = "workflow_dispatch" ] || refuse "event ${GITHUB_EVENT_NAME:-unset} is not workflow_dispatch"
case "${GITHUB_WORKFLOW_REF:-}" in
  m4ttstack/herdr/.github/workflows/ms-release.yml@refs/heads/mattstack/*) ;;
  *) refuse "workflow ${GITHUB_WORKFLOW_REF:-unset} is not ms-release.yml on a mattstack/* branch" ;;
esac
exit 0
