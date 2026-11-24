#!/bin/bash
# ms/upstream-issue.sh keeps one issue per upstream version, found by its label
# and marker rather than its title: it opens it, updates it when the outcome
# changes, and stays quiet when a night repeats the last outcome.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/ms/upstream-issue.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1" >&2; FAILS=$((FAILS + 1)); }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1 $2" = "issue list" ]; then case "$*" in *"--state all"*) cat "$STUB_ISSUES" ;; *) jq "map(select(.state == \"OPEN\"))" "$STUB_ISSUES" ;; esac; exit 0; fi
{ printf '%s' "$1 $2"; shift 2; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "$STUB_LOG"
STUB
chmod 755 "$TMP/bin/gh"
export STUB_LOG="$TMP/gh.log" STUB_ISSUES="$TMP/issues.json"

night() { # night <issues json> <env assignments>...: one run of the issue step
  printf '%s' "$1" > "$STUB_ISSUES"; shift
  : > "$STUB_LOG"
  env PATH="$TMP/bin:$PATH" REPO=m4ttstack/herdr UPSTREAM=https://github.com/herdrdev/herdr.git \
    CURRENT=0.9.5 NEWEST=0.9.6 RUN_URL=https://example.invalid/run REBASE_CODE= REBASE_DETAIL= \
    FAILED= TEST_OUTCOME= PUSHED= "$@" bash "$SCRIPT" >/dev/null 2>"$TMP/err" || { bad "the script exits 0 ($(cat "$TMP/err"))"; return 1; }
}
issue() { # issue <number> <title> <outcome> [OPEN|CLOSED]: a labelled issue for 0.9.6
  printf '{"number":%s,"title":"%s","state":"'"${4:-OPEN}"'","body":"old body\\n\\n<!-- ms-upstream v0.9.6 state=%s -->"}' "$1" "$2" "$3"
}
has() { grep -qF -- "$2" "$STUB_LOG" && ok "$1" || bad "$1 (gh calls: $(cat "$STUB_LOG"))"; }
lacks() { grep -qF -- "$2" "$STUB_LOG" && bad "$1 (gh calls: $(cat "$STUB_LOG"))" || ok "$1"; }

# A conflict with no issue yet opens one, labelled and marked.
night '[]' REBASE_CODE=3 "REBASE_DETAIL=fork commit \"x\" conflicts"
has "a conflict opens an issue" "issue create"
has "the issue carries the ms-upstream label" "[--label] [ms-upstream]"
has "the issue says it needs a hand" "[herdr 0.9.6 needs a hand]"
has "the issue body carries the version and outcome marker" "<!-- ms-upstream v0.9.6 state=conflict -->"
has "the issue body quotes the conflict" 'fork commit "x" conflicts'

# The same outcome the next night: no new issue, no comment, no edit.
night "[$(issue 7 "herdr 0.9.6 needs a hand" conflict)]" REBASE_CODE=3 "REBASE_DETAIL=fork commit \"x\" conflicts"
[ ! -s "$STUB_LOG" ] && ok "a repeated outcome touches nothing" || bad "a repeated outcome touches nothing (gh calls: $(cat "$STUB_LOG"))"

# A refused push comments once, then stays quiet.
night "[$(issue 7 "herdr 0.9.6 needs a hand" conflict)]" REBASE_CODE=0 TEST_OUTCOME=success PUSHED=no
has "a new outcome updates the same issue" "issue edit [7]"
has "the updated issue says ready to publish" "[herdr 0.9.6 ready to publish]"
has "the update comments once" "issue comment [7]"
has "the update marks the refused push" "state=unpushed"
lacks "the update opens no second issue" "issue create"
night "[$(issue 7 "herdr 0.9.6 ready to publish" unpushed)]" REBASE_CODE=0 TEST_OUTCOME=success PUSHED=no
[ ! -s "$STUB_LOG" ] && ok "a refused push does not comment nightly" || bad "a refused push does not comment nightly (gh calls: $(cat "$STUB_LOG"))"

# The issue is found by its marker even after someone retitles it.
night "[$(issue 9 "renamed by hand" conflict)]" REBASE_CODE=0 TEST_OUTCOME=success PUSHED=yes
has "a retitled issue is still found by its marker" "issue edit [9]"
has "a pushed branch gives the publish command" "gh workflow run ms-release.yml -R m4ttstack/herdr -f branch=mattstack/0.9.6"
lacks "a retitled issue gets no twin" "issue create"

# Another version's issue is not this one.
night '[{"number":3,"state":"OPEN","title":"herdr 0.9.6 needs a hand","body":"<!-- ms-upstream v0.9.5 state=conflict -->"}]' REBASE_CODE=0 TEST_OUTCOME=success FAILED=ms/tests/x.sh
has "an issue for another version is left alone" "issue create"
lacks "an issue for another version is not edited" "issue edit [3]"
has "failed tests are named" "ms/tests/x.sh"
has "failed tests are marked" "state=tests"

# A test step that died before reporting still counts as failed tests.
night '[]' REBASE_CODE=0 TEST_OUTCOME=failure
has "a broken test setup needs a hand" "[herdr 0.9.6 needs a hand]"
has "a broken test setup is named" "the test setup"

# A rebase that failed for another reason.
night '[]' REBASE_CODE=4 "REBASE_DETAIL=rebase failed onto v0.9.6: boom"
has "another rebase failure is marked as stopped" "state=stopped"
has "another rebase failure quotes git" "rebase failed onto v0.9.6: boom"

# A candidate job that died before the rebase reported nothing.
night '[]'
has "a candidate with no rebase result is marked incomplete" "state=incomplete"
has "a candidate with no rebase result needs a hand" "[herdr 0.9.6 needs a hand]"
lacks "a candidate with no rebase result is not called a rebase failure" "The rebase failed"

# Tests passed but the push job never reported: nothing may say to publish.
night '[]' REBASE_CODE=0 TEST_OUTCOME=success PUSHED=
has "a push job that failed is marked" "state=pushfailed"
has "a push job that failed needs a hand" "[herdr 0.9.6 needs a hand]"
lacks "a push job that failed gives no publish command" "gh workflow run"

# A closed issue stays closed while nothing changes, and reopens when it does.
night "[$(issue 7 "herdr 0.9.6 needs a hand" conflict CLOSED)]" REBASE_CODE=3 REBASE_DETAIL=x
[ ! -s "$STUB_LOG" ] && ok "a closed issue with the same outcome stays closed" || bad "a closed issue with the same outcome stays closed (gh calls: $(cat "$STUB_LOG"))"
night "[$(issue 7 "herdr 0.9.6 needs a hand" conflict CLOSED)]" REBASE_CODE=0 TEST_OUTCOME=success PUSHED=yes
has "a closed issue reopens on a new outcome" "issue reopen [7]"
has "a reopened issue is updated" "issue edit [7]"
lacks "a reopened issue gets no twin" "issue create"
night "[$(issue 8 "newer" conflict CLOSED),$(issue 7 "older" tests OPEN)]" REBASE_CODE=0 TEST_OUTCOME=success PUSHED=yes
has "an open issue wins over a closed one" "issue edit [7]"
lacks "an open issue is not reopened" "issue reopen"

[ "$FAILS" -eq 0 ] || { echo "upstream-issue: $FAILS check(s) failed" >&2; exit 1; }
echo "PASS: one issue per upstream version, updated only when the outcome changes"
