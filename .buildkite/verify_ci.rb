# frozen_string_literal: true

require_relative "../test/support/no_git_execution"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "digest"
require_relative "prepare_components"
require_relative "../lib/agent_coding_tool/bootstrap"
require_relative "../test/feedback"
Minitest::Assertions.diff = nil

# Focused offline CI controls. Synthetic refs prove refusal/command planning,
# never remote publication. No Git or other subprocess executes in these tests.
class CIQualificationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # Materializes only the byte-checked offline fixture at the real composition's
  # revisions in a disposable directory; yields parent/lock and removes it later.
  def components
    Dir.mktmpdir("act-ci-control-") do |directory|
      parent = File.join(directory, "components")
      snapshot = JSON.parse(File.binread(File.join(ROOT, "test/support/fixtures/bootstrap_components.json")))
      lock = JSON.parse(File.binread(File.join(ROOT, "split-composition.json")))
      lock.fetch("packages").each do |name, pin|
        package = File.join(parent, name)
        FileUtils.mkdir_p(File.join(package, ".git"))
        File.write(File.join(package, ".git/HEAD"), pin.fetch("revision") + "\n")
        snapshot.fetch("packages").fetch(name).fetch("files").each do |path, bytes|
          destination = File.join(package, path)
          FileUtils.mkdir_p(File.dirname(destination))
          File.binwrite(destination, bytes)
        end
      end
      yield parent, lock
    end
  end

  # Every remote and full SHA must come from the published lock; a failed fetch
  # stops provisioning, and existing storage is never reused or overwritten.
  def test_exact_fetches_and_no_fallback
    Dir.mktmpdir do |directory|
      parent = File.join(directory, "components")
      commands = []
      CIComponents.prepare(root: ROOT, parent: parent, run: ->(*argv) { commands << argv })
      lock = JSON.parse(File.binread(File.join(ROOT, "split-composition.json")))
      assert_equal lock.fetch("packages").map { |name, pin|
        ["-C", File.join(parent, name), "fetch", "--depth=1", "origin", pin.fetch("revision")]
      }, commands.select { |argv| argv.include?("fetch") }
      assert_equal lock.fetch("packages").map { |name, pin|
        ["-C", File.join(parent, name), "remote", "add", "origin", pin.fetch("remote_url")]
      }, commands.select { |argv| argv.include?("remote") }
      assert_raises(Errno::EEXIST) { CIComponents.prepare(root: ROOT, parent: parent, run: ->(*) { flunk "reused root" }) }
      attempts = []
      assert_raises(IOError) do
        CIComponents.prepare(root: ROOT, parent: File.join(directory, "failed"), run: lambda { |*argv|
          attempts << argv
          raise IOError, "fetch failed" if argv.include?("fetch")
        })
      end
      assert_equal 3, attempts.length
    end
  end

  # Published resolution validates ALL packages. Wrong refs, extra/changed Ruby
  # source and a missing package refuse without accepting the offline snapshot
  # as proof of publication or using any sibling developer checkout.
  def test_every_package_revision_and_digest_is_required
    components do |parent, lock|
      env = { "ACT_IMPLEMENTATION" => "split", "ACT_COMPONENT_ROOT" => parent }
      result = AgentCodingTool::Bootstrap.resolve(root: ROOT, env: env)
      assert_equal "published", result.fetch("qualification")
      assert_equal lock.fetch("packages").keys.sort, result.fetch("packages").keys.sort
      lock.fetch("packages").each do |name, pin|
        package = File.join(parent, name)
        head = File.join(package, ".git/HEAD")
        File.write(head, "0" * 40)
        assert_raises(AgentCodingTool::Bootstrap::Refused) { AgentCodingTool::Bootstrap.resolve(root: ROOT, env: env) }
        File.write(head, pin.fetch("revision"))
        source = File.join(package, pin.fetch("files").keys.first)
        bytes = File.binread(source)
        File.binwrite(source, bytes + "\n# changed\n")
        assert_raises(AgentCodingTool::Bootstrap::Refused) { AgentCodingTool::Bootstrap.resolve(root: ROOT, env: env) }
        File.binwrite(source, bytes)
        extra = File.join(package, "lib/extra.rb")
        File.write(extra, "# extra\n")
        assert_raises(AgentCodingTool::Bootstrap::Refused) { AgentCodingTool::Bootstrap.resolve(root: ROOT, env: env) }
        File.unlink(extra)
        FileUtils.mv(package, package + ".absent")
        assert_raises(AgentCodingTool::Bootstrap::Refused) { AgentCodingTool::Bootstrap.resolve(root: ROOT, env: env) }
        FileUtils.mv(package + ".absent", package)
      end
      assert_equal result, AgentCodingTool::Bootstrap.resolve(root: ROOT, env: env)
    end
  end

  # Runs the collector in-process against fresh declared reports, preserving
  # binary raw evidence even when status, completeness or identity refuses.
  def collect_fixture(status: "0", accepted: true, complete: true, drift: false, qualification: false)
    Dir.mktmpdir do |directory|
      evidence = File.join(directory, "artifacts")
      feedback = File.join(directory, "feedback")
      FileUtils.mkdir_p([evidence, feedback])
      composition = { "mode" => "legacy", "packages" => {} }
      lock = File.binread(File.join(ROOT, "split-composition.json"))
      File.binwrite(File.join(evidence, "split-composition.json"), lock)
      File.binwrite(File.join(evidence, "implementation.json"), JSON.generate("composition" => composition))
      File.binwrite(File.join(evidence, "acceptance.log"), "ACT feedback evidence: #{feedback}\n\x00\xff".b)
      File.binwrite(File.join(feedback, "raw"), "\x00\xff\x80".b)
      report = { "accepted" => accepted, "complete_offline_gate" => complete, "qualification" => qualification,
        "implementation" => drift ? { "mode" => "split" } : composition, "invocation" => "fresh",
        "source_files" => { "split-composition.json" => Digest::SHA256.hexdigest(lock) },
        "stages" => %w[ordinary git_contract native_default native_integration].map { |layer| { "layer" => layer, "complete" => true } } }
      File.write(File.join(feedback, "report.json"), JSON.generate(report))
      original_argv = ARGV.dup
      ARGV.replace([evidence, "legacy", status])
      begin
        capture_io { load File.join(__dir__, "collect_evidence.rb") }
      ensure
        ARGV.replace(original_argv)
        assert_equal "\x00\xff\x80".b, File.binread(File.join(feedback, "raw"))
        refute File.exist?(File.join(evidence, "feedback")), "must not duplicate local evidence"
      end
    end
  end

  # Human log markers or a zero exit cannot replace the independent complete,
  # accepted report; development qualification and composition drift fail.
  def test_collector_rejects_false_acceptance_and_preserves_failures
    collect_fixture
    [{ status: "7" }, { accepted: false }, { complete: false }, { drift: true }, { qualification: true }].each do |invalid|
      assert_raises(RuntimeError) { collect_fixture(**invalid) }
    end
  end

  # Adding CI provenance must preserve the legacy accepted comparator, while a
  # split run cannot reuse its runtime reference as if the implementation matched.
  def test_runtime_reference_retains_legacy_and_distinguishes_split
    current = { "runtime" => RUBY_DESCRIPTION, "source_files" => { "Gemfile.lock" => "locked" }, "stages" => [] }
    previous = TestFeedback.conditions(current)
    current["implementation"] = { "mode" => "legacy", "packages" => {} }
    assert_equal previous, TestFeedback.conditions(current)
    reference = { "qualified" => true, "conditions" => previous, "source_sha256" => "a" * 64, "outer_seconds" => 10 }
    assert TestFeedback.runtime_report(11, TestFeedback.conditions(current), reference).fetch("comparable")
    current["implementation"] = { "mode" => "split", "qualification" => "published", "packages" => {} }
    comparison = TestFeedback.runtime_report(11, TestFeedback.conditions(current), reference)
    refute comparison.fetch("comparable")
    assert_equal ["implementation"], comparison.fetch("changed_conditions")
  end
end
