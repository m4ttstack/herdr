#!/bin/bash
# Reports one ms-upstream.yml night on the issue for that upstream version. One
# issue per version, found by the ms-upstream label and the marker in its body:
# opened the first night, edited and commented when the outcome changes, left
# alone when a night repeats the last outcome.
# Reads REPO UPSTREAM CURRENT NEWEST RUN_URL REBASE_CODE REBASE_DETAIL FAILED
# TEST_OUTCOME PUSHED from the environment; needs GH_TOKEN with issues: write.
set -euo pipefail

LABEL=ms-upstream
T='`'
F='```'
compare="https://github.com/herdrdev/herdr/compare/v$CURRENT...v$NEWEST"
publish="gh workflow run ms-release.yml -R $REPO -f branch=mattstack/$NEWEST"
released="Upstream released [herdr $NEWEST]($compare)."
if [ "$REBASE_CODE" = "0" ] && [ "$TEST_OUTCOME" != "success" ]; then
  FAILED="${FAILED:-the test setup (see the run)}"
fi

if [ "$PUSHED" = "yes" ]; then
  state=pushed
  title="herdr $NEWEST ready to publish"
  body="$released The fork commits rebased onto it cleanly and every test passed, so ${T}mattstack/$NEWEST${T} is pushed.

To publish it:

${F}bash
$publish
${F}"
elif [ "$REBASE_CODE" = "0" ] && [ -z "$FAILED" ]; then
  state=unpushed
  title="herdr $NEWEST ready to publish"
  body="$released The fork commits rebased onto it cleanly and every test passed, but the nightly could not push the branch. Usually its token cannot push upstream workflow changes (an ${T}MS_PUSH_TOKEN${T} secret, a fine-grained token for this repo with Contents and Workflows write, fixes that). Push it from a clone, then publish:

${F}bash
git fetch --no-tags $UPSTREAM refs/tags/v$CURRENT:refs/tags/v$CURRENT refs/tags/v$NEWEST:refs/tags/v$NEWEST
git switch mattstack/$CURRENT && ms/rebase-onto.sh v$NEWEST && git push -u origin mattstack/$NEWEST
$publish
${F}"
elif [ "$REBASE_CODE" = "3" ]; then
  state=conflict
  title="herdr $NEWEST needs a hand"
  body="$released Rebasing the fork commits onto it conflicts:

${F}
$REBASE_DETAIL
${F}"
elif [ "$REBASE_CODE" = "0" ]; then
  state=tests
  title="herdr $NEWEST needs a hand"
  body="$released The fork commits rebased onto it cleanly, but these tests failed: $FAILED."
elif [ -z "$REBASE_CODE" ]; then
  state=incomplete
  title="herdr $NEWEST needs a hand"
  body="$released The nightly stopped before it could report on the rebase; see the run."
else
  state=stopped
  title="herdr $NEWEST needs a hand"
  body="$released The rebase failed:

${F}
$REBASE_DETAIL
${F}"
fi
marker="<!-- ms-upstream v$NEWEST state="
body="$body

[Run]($RUN_URL)

$marker$state -->"

existing="$(gh issue list -R "$REPO" --label "$LABEL" --state open --limit 100 --json number,body \
  | jq -r --arg m "$marker" 'map(select(.body | contains($m))) | .[0] // empty | "\(.number) \(.body | split($m)[1] | split(" -->")[0])"')"
if [ -z "$existing" ]; then
  gh label create "$LABEL" -R "$REPO" --force --color 5319e7 --description "ms-upstream.yml's report on an upstream release"
  gh issue create -R "$REPO" --label "$LABEL" --title "$title" --body "$body"
  exit 0
fi
number="${existing%% *}"
if [ "${existing#* }" = "$state" ]; then
  echo "Issue #$number already reports $state."
  exit 0
fi
gh issue edit "$number" -R "$REPO" --title "$title" --body "$body"
gh issue comment "$number" -R "$REPO" --body "$body"
