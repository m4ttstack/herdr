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
  jobs = YAML.load_file(ARGV[0]).fetch("jobs")
  wanted = Array(jobs.dig("build", "runs-on"))
  hosted = jobs.reject { |name, _| name == "build" }.map { |name, job| [name, job["runs-on"]] }
  unless wanted == ["herdr-signer"] && hosted.all? { |_, on| on == "ubuntu-latest" }
    warn "FAIL only the build job may run on herdr-signer (build: #{wanted}, others: #{hosted})"
    exit 1
  end
  given = File.read(ARGV[1])[/--labels (\S+)/, 1].to_s.split(",")
  missing = wanted - given
  if missing.empty?
    puts "PASS: only the build job runs on the signing Mac, and it asks only for labels the runner has"
  else
    warn "FAIL the release job asks for #{missing.join(", ")}, which install.sh never registers"
    exit 1
  end
' "$ROOT/.github/workflows/ms-release.yml" "$ROOT/ms/runner/install.sh" || exit 1

# Build code in a release job runs as herdr-signer, so the signing key is
# root-only: the job signs through the root-owned helper and no step reads the key.
ruby -ryaml -e '
  steps = YAML.load_file(ARGV[0]).dig("jobs", "build", "steps")
  sign = (steps.find { |s| s["name"] == "Sign and notarize" } || {})["run"].to_s
  plist = File.read(ARGV[1])[/<plist.*<\/plist>/m].to_s
  fails = []
  fails << "no Sign and notarize step calls sudo -n /usr/local/herdr-signer/sign.sh" unless sign =~ %r{sudo -n /usr/local/herdr-signer/sign\.sh}
  %w[herdr-macos-aarch64 herdr-macos-x86_64].each do |asset|
    fails << "the Sign and notarize step does not hand the helper #{asset}" unless sign =~ %r{"\$PWD/dist/#{asset}"}
  end
  key = /developer-id\.p12|p12-password|\.herdr-signing|HERDR_SIGNING|herdr-signer\/keys|notary-api-key|rcodesign/
  steps.each do |s|
    fails << "#{s["name"] || s["uses"]} references the signing key or rcodesign" if s.to_yaml =~ key
  end
  fails << "the runner launchd job hands jobs a signing key path" if plist =~ key
  fails << "a release step still uses the keychain" if steps.any? { |s| s["run"].to_s =~ /security |codesign --force|KEYCHAIN/ }
  if fails.empty?
    puts "PASS: release jobs sign through the root-owned helper and never read the key"
  else
    fails.each { |f| warn "FAIL #{f}" }
    exit 1
  end
' "$ROOT/.github/workflows/ms-release.yml" "$ROOT/ms/runner/install.sh" || exit 1

# codesign --verify --strict alone passes ad-hoc and non-runtime signatures, so
# Verify runs ms/verify-release.sh on each asset.
ruby -ryaml -e '
  steps = YAML.load_file(ARGV[0]).dig("jobs", "build", "steps")
  verify = (steps.find { |s| s["name"].to_s.start_with?("Verify") } || {})["run"].to_s
  missing = %w[herdr-macos-aarch64:arm64 herdr-macos-x86_64:x86_64].reject do |pair|
    asset, arch = pair.split(":")
    verify.include?("ms/verify-release.sh \"dist/$asset\" \"$arch\"") && verify.include?(pair)
  end
  if verify =~ /verify-release\.sh.*(\|\||;)/ || verify !~ /^set -euo pipefail/
    warn "FAIL a refused binary does not fail the Verify step"
    exit 1
  end
  if missing.empty?
    puts "PASS: Verify checks each asset for a notarized Developer ID signature"
  else
    warn "FAIL Verify does not run ms/verify-release.sh on #{missing.join(", ")}"
    exit 1
  end
' "$ROOT/.github/workflows/ms-release.yml" || exit 1

# Build code must not get a token that can push to the branch (the installer it
# holds runs with sudo) or publish: only the publish job, on a fresh machine that
# runs no build, can write, and it publishes only the binaries the build hashed.
ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  jobs = wf.fetch("jobs")
  fails = []
  fails << "the release workflow grants more than contents: read by default" unless wf["permissions"] == { "contents" => "read" }
  jobs.each do |name, job|
    fails << "#{name} has a job-wide token" if job["env"].to_s =~ /github\.token|secrets\./
    job["steps"].each do |s|
      next unless s["uses"].to_s.start_with?("actions/checkout")
      fails << "#{name} keeps credentials in .git/config" unless s.dig("with", "persist-credentials") == false
    end
  end
  build, publish = jobs["build"], jobs["publish"]
  fails << "the build job can write to the repo" unless build["permissions"] == { "contents" => "read" }
  fails << "a build step gets a token" if build["steps"].any? { |s| s.to_yaml =~ /github\.token|secrets\.|GH_TOKEN/ }
  writers = jobs.select { |_, job| (job["permissions"] || {}).values.include?("write") }.keys
  fails << "jobs that can write: #{writers}, expected only publish" unless writers == ["publish"]
  if publish
    fails << "the publish job does not wait for the build" unless (Array(publish["needs"]) & %w[version build]).size == 2
    fails << "the publish job builds" if publish["steps"].any? { |s| s["run"].to_s =~ /cargo|ms\/build|sign\.sh|rustup/ }
    names = publish["steps"].map { |s| s["name"].to_s }
    check = publish["steps"].find { |s| s["run"].to_s.include?("shasum -a 256 -c") } || {}
    fails << "the publish job does not check the binaries against the hashes the build reported" unless
      check["env"].to_s.include?("needs.build.outputs.arm64_sha256") && check["env"].to_s.include?("needs.build.outputs.x86_64_sha256")
    fails << "the hash check lets an empty or malformed hash through" unless check["run"].to_s.include?("^[0-9a-f]{64}$")
    fails << "the hash check comes after the manifests" unless names.index(check["name"].to_s).to_i.between?(1, names.index("Write manifests").to_i - 1)
    order = build["steps"].map { |s| s["name"].to_s }
    fails << "the build hashes before it verifies" unless order.index("Report the hashes").to_i > order.index { |n| n.start_with?("Verify") }.to_i
  else
    fails << "no publish job"
  end
  if fails.empty?
    puts "PASS: build code gets no write token, and publish takes only the binaries the build hashed"
  else
    fails.each { |f| warn "FAIL #{f}" }
    exit 1
  end
' "$ROOT/.github/workflows/ms-release.yml" || exit 1

# The nightly's rebase step stops on any failure but the rebase's own exit code,
# and the issue is written by its own job from a clean checkout, never on the
# machine that ran upstream's build code.
ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  jobs = wf.fetch("jobs")
  rebase = jobs.dig("candidate", "steps").find { |s| s["id"] == "rebase" }["run"].to_s
  fails = []
  fails << "the rebase step does not run with set -e" unless rebase =~ /^set -[a-z]*e[a-z]* pipefail/
  fails << "the rebase step does not catch the rebase exit code under set -e" unless rebase =~ %r{ms/rebase-onto\.sh .*\|\| code=\$\?}
  report = jobs.find { |_, j| (j["steps"] || []).any? { |s| s["name"] == "Open or update the issue" } }
  if report.nil?
    fails << "no job opens the issue"
  else
    name, job = report
    fails << "the issue is written in the candidate job, after upstream code ran" if name == "candidate"
    fails << "the issue job does not run after a failure" unless job["if"].to_s.include?("always()")
    fails << "the issue job does not wait for the candidate job" unless Array(job["needs"]).include?("candidate")
    fails << "the issue job runs upstream code" if job["steps"].any? { |s| s.to_yaml =~ /cargo|ms\/tests|rebase-onto/ }
    step = job["steps"].find { |s| s["name"] == "Open or update the issue" }
    fails << "the issue step does not run ms/upstream-issue.sh" unless step["run"].to_s.include?("ms/upstream-issue.sh")
  end
  fails << "the candidate job can still write issues" if jobs.dig("candidate", "permissions", "issues")
  candidate = jobs.fetch("candidate")
  %w[candidate push].each do |name|
    step = (jobs.dig(name, "steps") || []).find { |s| s["run"].to_s.include?("ms/rebase-onto.sh") } || {}
    fails << "the #{name} job does not rebase the commit find picked" unless
      step.dig("env", "SOURCE_SHA") == "${{ needs.find.outputs.source_sha }}" && step["run"].to_s.include?(%q(git switch -q -C "$SOURCE" "$SOURCE_SHA"))
  end
  fails << "find does not pick the source commit" unless jobs.dig("find", "outputs", "source_sha")
  fails << "the candidate job is granted a token scope" unless candidate["permissions"] == {}
  fails << "the candidate job has a post step that gets the job token" if candidate["steps"].any? { |s| s["uses"].to_s.start_with?("actions/checkout") }
  zig = candidate["steps"].find { |s| s["uses"].to_s.start_with?("mlugg/setup-zig") }
  fails << "setup-zig saves a cache after upstream code ran" unless zig.dig("with", "use-cache") == false
  fails << "the candidate job gets a token" if candidate["steps"].any? { |s| s.to_yaml =~ /secrets\.|github\.token/ }
  push = jobs["push"]
  if push.nil?
    fails << "no push job pushes the candidate branch"
  else
    fails << "the push job does not wait for the candidate job" unless Array(push["needs"]).include?("candidate")
    fails << "the push job runs when the candidate tests did not pass" unless push["if"].to_s =~ /candidate\.outputs\.test_outcome == .success./ && push["if"].to_s =~ /candidate\.outputs\.failed == ../
    fails << "the push job builds or tests upstream code" if push["steps"].any? { |s| s.to_yaml =~ /cargo|ms\/tests|setup-zig|install-action|download-artifact/ }
    fails << "the push job does not rebase for itself" unless push["steps"].any? { |s| s["run"].to_s.include?("ms/rebase-onto.sh") }
    guard = push["steps"].find { |s| s["run"].to_s.include?("ms/rebase-onto.sh") } || {}
    fails << "the push job does not check it pushes the tested tree" unless
      guard.dig("env", "TESTED_TREE") == "${{ needs.candidate.outputs.tree }}" &&
      guard["run"].to_s =~ /^\[ "\$tree" = "\$TESTED_TREE" \] \|\| \{.*exit 1; \}$/
    fails << "the issue job does not wait for the push job" if report && !Array(report[1]["needs"]).include?("push")
  end
  if fails.empty?
    puts "PASS: the nightly stops on failures and reports from a clean job"
  else
    fails.each { |f| warn "FAIL #{f}" }
    exit 1
  end
' "$ROOT/.github/workflows/ms-upstream.yml" || exit 1

# A fixed heredoc delimiter in GITHUB_OUTPUT lets output that contains it end
# the value early and inject outputs of its own.
ruby -ryaml -e '
  fails = []
  ARGV.each do |path|
    YAML.load_file(path).fetch("jobs").each_value do |job|
      (job["steps"] || []).each do |s|
        s["run"].to_s.scan(/<<([^\s"$]+)/).flatten.each do |delim|
          next if delim.start_with?("\x27", "-")
          fails << "#{File.basename(path)}: #{s["name"] || s["id"]} ends a multi-line output with the fixed delimiter #{delim}" if s["run"].include?("GITHUB_OUTPUT")
        end
      end
    end
  end
  if fails.empty?
    puts "PASS: multi-line step outputs use a random delimiter"
  else
    fails.each { |f| warn "FAIL #{f}" }
    exit 1
  end
' "$ROOT/.github/workflows/ms-upstream.yml" "$ROOT/.github/workflows/ms-release.yml" || exit 1

# A tag can be moved to other code; the fork's workflows pin third-party actions
# by full commit SHA, with the version in a comment.
ruby -e '
  fails = []
  ARGV.each do |path|
    File.readlines(path).each_with_index do |line, i|
      next unless line =~ /^\s*(-\s+)?uses:\s*(\S+)(.*)$/
      ref, rest = $2, $3
      next if ref.start_with?("./")
      fails << "#{File.basename(path)}:#{i + 1} #{ref} is not pinned by a full commit SHA" unless ref =~ /@[0-9a-f]{40}$/
      fails << "#{File.basename(path)}:#{i + 1} #{ref} has no # vX.Y.Z comment" unless rest =~ /#\s*v\d+\.\d+\.\d+/
    end
  end
  if fails.empty?
    puts "PASS: third-party actions are pinned by commit SHA"
  else
    fails.each { |f| warn "FAIL #{f}" }
    exit 1
  end
' "$ROOT/.github/workflows/ms-upstream.yml" "$ROOT/.github/workflows/ms-release.yml" || exit 1
