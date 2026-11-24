#!/bin/bash
# The nightly runs upstream's build and test code, so no token may reach the
# steps that run it, and it never publishes.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  fails = []
  fails << "the workflow grants more than contents: read by default" unless wf["permissions"] == { "contents" => "read" }
  fails << "a token is in the workflow-wide env" if (wf["env"] || {}).values.any? { |v| v.to_s.include?("token") || v.to_s.include?("secrets.") }
  steps = wf.fetch("jobs").values.flat_map do |job|
    fails << "a token is in a job-wide env" if (job["env"] || {}).values.any? { |v| v.to_s.include?("token") || v.to_s.include?("secrets.") }
    job.fetch("steps")
  end
  steps.select { |s| s["uses"].to_s.start_with?("actions/checkout") }.each do |checkout|
    fails << "checkout keeps credentials in .git/config" unless checkout.dig("with", "persist-credentials") == false
  end
  steps.each do |s|
    text = s.to_yaml
    name = s["name"] || s["uses"]
    if text.include?("secrets.") && name != "Push the candidate branch"
      fails << "#{name} can read a secret"
    end
    if text.include?("github.token") && !["Push the candidate branch", "Open or update the issue"].include?(name)
      fails << "#{name} can read the job token"
    end
    fails << "#{name} publishes a release" if text.include?("gh release")
  end
  if fails.empty?
    puts "PASS: the nightly keeps tokens away from upstream code and never publishes"
  else
    fails.each { |f| warn "FAIL #{f}" }
    exit 1
  end
' "$ROOT/.github/workflows/ms-upstream.yml" || exit 1

# The runner registers with --no-default-labels, so the release job may ask
# only for labels install.sh gives it, or it queues forever.
ruby -ryaml -e '
  wanted = Array(YAML.load_file(ARGV[0]).dig("jobs", "release", "runs-on"))
  given = File.read(ARGV[1])[/--labels (\S+)/, 1].to_s.split(",")
  missing = wanted - given
  if missing.empty?
    puts "PASS: the release job asks only for labels the runner has"
  else
    warn "FAIL the release job asks for #{missing.join(", ")}, which install.sh never registers"
    exit 1
  end
' "$ROOT/.github/workflows/ms-release.yml" "$ROOT/ms/runner/install.sh" || exit 1

# A launchd runner's user starts with an empty keychain search list, and
# codesign cannot find the identity's key outside that list.
ruby -ryaml -e '
  sign = YAML.load_file(ARGV[0]).dig("jobs", "release", "steps").find { |s| s["name"] == "Sign" }["run"]
  if sign =~ /security list-keychains -d user -s "\$HERDR_SIGNING_KEYCHAIN"/
    puts "PASS: the Sign step puts the signing keychain on the search list"
  else
    warn "FAIL the Sign step leaves the signing keychain off the user search list"
    exit 1
  end
' "$ROOT/.github/workflows/ms-release.yml" || exit 1
