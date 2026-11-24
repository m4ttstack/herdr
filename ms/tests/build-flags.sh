#!/bin/bash
# ms/build.sh refuses a flag with no value, naming the flag, before it builds.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILS=0
for case in "--arch|--arch" "--revision|--revision" "--out|--out" "--arch arm64 --revision|--revision" \
  "--arch --revision 1 --out x|--arch"; do
  args="${case%|*}"; flag="${case#*|}"
  # shellcheck disable=SC2086
  out="$(bash "$ROOT/ms/build.sh" $args 2>&1)"; code=$?
  if [ "$code" -eq 2 ] && [[ "$out" == *"$flag needs a value"* ]]; then
    echo "ok   build.sh $args: refuses, naming $flag"
  else
    echo "FAIL build.sh $args: refuses, naming $flag (exit $code, got: $out)" >&2; FAILS=1
  fi
done
[ "$FAILS" -eq 0 ] || exit 1
echo "PASS: build.sh names a flag given no value"
