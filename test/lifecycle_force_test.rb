# frozen_string_literal: true

require "stringio"
require "minitest/mock"
require_relative "test_helper"

# Public metadata entry points with real state/audit/locks and declared remote
# observations. Native candidate/process checks live in checkpoint integration.
class LifecycleForceTest < Minitest::Test
  include TestHelpers

  # Runs one CLI invocation against fixture stores and a declared remote observer.
  # Returns status/stdout/stderr; production parsing, locking and writes stay real.
  def invoke(dir, coordinator, *argv)
    out, err = StringIO.new, StringIO.new
    cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out: out, err: err)
    cli.instance_variable_set(:@coordinator, coordinator)
    [cli.run(argv), out.string, err.string]
  end

  # Reads the latest declaration's durable result; missing/broken evidence raises.
  def audit_for(state)
    path = state.fetch("administrative_override").fetch("audit_path")
    AgentCodingTool::StateStore.new(File.dirname(path)).load("result")
  end

  # Exercises all administrative operations, multiple refusals and flag ordering.
  # Fails on any lost original bytes, implicit consent or incoherent projection.
  def test_public_metadata_overrides_preserve_bytes_and_report_all_policy_facts
    with_workspace do |dir|
      write_task(dir, id: "D")
      write_task(dir, id: "T", depends_on: ["D"])
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
      store.write("T", { "id" => "T", "result" => { "outcome" => "complete" },
        "icebox" => { "at" => Time.now.utc.iso8601 }, "started_at" => Time.now.utc.iso8601 })
      original = File.binread(store.state_path("T"))
      assert_equal 2, invoke(dir, coordinator, "prepare", "T").first
      assert_equal 0, invoke(dir, coordinator, "prepare", "--force", "T", "--reason", "operator review").first
      prepared = store.load("T")
      audit = audit_for(prepared)
      assert_equal original, File.binread(audit.fetch("recovery"))
      assert_equal Digest::SHA256.hexdigest(original), audit.fetch("original_sha256")
      assert_equal "operator review", audit.fetch("reason")
      assert_equal "published", audit.fetch("write_status")
      rules = audit.fetch("observations").map { |fact| fact.fetch("rule") }
      %w[icebox recorded_outcome already_started dependencies_incomplete].each { |rule| assert_includes rules, rule }
      assert File.file?(prepared.fetch("prompt_path"))
      refute prepared.key?("result")
      refute prepared.key?("icebox")
      assert_equal 2, invoke(dir, coordinator, "start", "T").first
      assert_equal 0, invoke(dir, coordinator, "start", "T", "--force").first
      assert_equal 2, invoke(dir, coordinator, "start", "T").first
      assert_equal 0, invoke(dir, coordinator, "icebox", "--force", "T").first
      status = coordinator.status("T")
      assert_equal "ICEBOX", status.fetch("status")
      assert_equal "IN_FLIGHT", status.fetch("lifecycle_status")
      assert_equal 0, invoke(dir, coordinator, "unicebox", "T", "--force", "--reason", "restore").first
      %w[record received finish].each do |command|
        assert_equal 0, invoke(dir, coordinator, "icebox", "T", "--force").first
        arguments = command == "record" ? ["needs_judgment", "--next", "review"] : []
        assert_equal 2, invoke(dir, coordinator, command, "T", *arguments).first
        assert_equal 0, invoke(dir, coordinator, command, "--force", "T", *arguments,
          "--summary", "operator result", "--artifact", "candidate.patch", "--test", "manual=declared").first
        state = store.load("T")
        refute state.key?("started_at")
        refute state.key?("icebox")
        assert_equal "operator result", state.dig("result", "summary")
        assert_equal ["manual=declared"], state.dig("result", "tests")
      end
      assert_equal "COMPLETE", coordinator.status("T").fetch("status")
      assert_equal 0, invoke(dir, coordinator, "reset", "T", "--force").first
      assert_equal "BLOCKED", coordinator.status("T").fetch("status")
      assert_equal original, File.binread(audit.fetch("recovery"))
      assert_equal 0, invoke(dir, coordinator, "prepare", "T", "--force").first
      assert_equal original, File.binread(audit.fetch("recovery"))
    end
  end

  # Covers missing preparation, malformed reset, unsafe targets and busy locks.
  # Only exact damaged bytes may be recovered; invalid requests never replace state.
  def test_missing_preparation_damaged_reset_and_non_overridable_errors
    with_workspace do |dir|
      write_task(dir, id: "T")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
      assert_equal 2, invoke(dir, coordinator, "received", "T").first
      assert_equal 0, invoke(dir, coordinator, "received", "T", "--force").first
      assert_equal "CANDIDATE", coordinator.status("T").fetch("status")
      bytes = File.binread(store.state_path("T"))
      [%w[record T unknown --force], %w[record T complete --next nope --force],
       %w[reset T --hard --force], %w[reset ../T --force], %w[wat T --force],
       %w[start T --for], %w[finish T --reason unused], %w[reset missing --force]].each do |argv|
        assert_equal 2, invoke(dir, coordinator, *argv).first, argv.inspect
        assert_equal bytes, File.binread(store.state_path("T"))
      end
      AgentCodingTool::ReservationLock.synchronize(dir) do
        assert_equal 2, invoke(dir, coordinator, "reset", "T", "--force").first
        assert_equal bytes, File.binread(store.state_path("T"))
      end
      damaged = "---\n[damaged\x00\xff".b
      File.binwrite(store.state_path("T"), damaged)
      assert_equal 2, invoke(dir, coordinator, "reset", "T").first
      assert_equal 0, invoke(dir, coordinator, "reset", "T", "--force").first
      assert_equal damaged, File.binread(audit_for(store.load("T")).fetch("recovery"))
      File.unlink(store.state_path("T"))
      target = File.join(dir, "unrelated.yml")
      File.binwrite(target, bytes)
      File.symlink(target, store.state_path("T"))
      assert_equal 2, invoke(dir, coordinator, "reset", "T", "--force").first
      assert_equal bytes, File.binread(target)
    end
  end

  # Injects audit/state errors around publication, checking cold-readable outcome.
  # Failures must never become a successful declaration or erase prior recovery.
  def test_audit_and_state_publication_failures_remain_truthful
    with_workspace do |dir|
      write_task(dir, id: "T")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      store = coordinator.instance_variable_get(:@state_store)
      store.write("T", { "id" => "T", "custom" => "preserve" })
      original = File.binread(store.state_path("T"))
      store.stub(:write, ->(*) { raise IOError, "before publication" }) do
        assert_raises(IOError) { coordinator.reset("T", force: true) }
      end
      assert_equal original, File.binread(store.state_path("T"))
      result_paths = Dir.glob(File.join("#{dir}-runs", ".lifecycle-overrides", "T", "*", "result.yml"))
      assert_equal "unchanged", YAML.safe_load_file(result_paths.fetch(0)).fetch("write_status")
      writer = store.method(:write)
      store.stub(:write, ->(*args) { writer.call(*args); raise IOError, "after publication" }) do
        assert_raises(IOError) { coordinator.reset("T", force: true) }
      end
      assert_equal "published_durability_uncertain", audit_for(store.load("T")).fetch("write_status")
      assert_equal original, File.binread(audit_for(store.load("T")).fetch("recovery"))
      before = File.binread(store.state_path("T"))
      publisher = AgentCodingTool::StateStore.instance_method(:publish_bytes)
      fault_name = "original"
      replacement = lambda do |name, bytes|
        raise IOError, "audit unavailable" if name == fault_name
        publisher.bind_call(self, name, bytes)
      end
      AgentCodingTool::StateStore.class_eval { alias_method :original_publish_bytes_for_test, :publish_bytes }
      begin
        AgentCodingTool::StateStore.define_method(:publish_bytes, replacement)
        assert_raises(IOError) { coordinator.reset("T", force: true) }
        assert_equal before, File.binread(store.state_path("T"))
        fault_name = "result"
        error = assert_raises(AgentCodingTool::InvalidState) { coordinator.reset("T", force: true) }
        assert_includes error.message, "override state published; result audit failed"
        state = store.load("T")
        audit_path = state.fetch("administrative_override").fetch("audit_path")
        intent = YAML.safe_load_file(audit_path)
        assert_equal Digest::SHA256.file(store.state_path("T")).hexdigest, intent.fetch("requested_sha256")
        assert_equal before, File.binread(intent.fetch("recovery"))
      ensure
        AgentCodingTool::StateStore.class_eval do
          alias_method :publish_bytes, :original_publish_bytes_for_test
          remove_method :original_publish_bytes_for_test
        end
      end
    end
  end

  # Distinguishes stale observed heads, changed scope and unavailable optional
  # completion observations. No force declaration manufactures a fresh source.
  def test_stale_scope_and_unobserved_completion_are_explicit
    with_workspace do |dir|
      write_task(dir, id: "T")
      heads = { "alpha" => "a" * 40 }
      coordinator = coordinator_for(dir, heads)
      store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
      coordinator.prepare("T")
      heads["alpha"] = "b" * 40
      assert_equal 2, invoke(dir, coordinator, "start", "T").first
      assert_equal 0, invoke(dir, coordinator, "start", "--force", "T").first
      facts = audit_for(store.load("T")).fetch("observations")
      assert facts.any? { |fact| fact["rule"] == "stale_source" && fact["repositories"] == ["alpha"] }
      assert_equal "STALE", coordinator.status("T").fetch("status")
      write_task(dir, id: "T", repositories: { "different" => { "access" => "write" } })
      inspector = coordinator.instance_variable_get(:@repo_inspector)
      inspector.stub(:snapshot, ->(*) { flunk "pure result must not require remote observations" }) do
        inspector.stub(:pushed_heads, ->(*) { flunk "pure result must not require remote freshness" }) do
          assert_equal 0, invoke(dir, coordinator, "finish", "T", "--force").first
        end
      end
      state = store.load("T")
      assert_equal "not_observed", state.dig("completion_observations", "status")
      assert_equal "COMPLETE", coordinator.status("T").fetch("status")
      assert audit_for(state).fetch("observations").any? { |fact| fact["rule"] == "task_scope_changed" }
    end
  end
  # Models only the platform alias table and root ownership on a real symlink
  # fixture. Public forced writes must share canonical lock/audit paths, while
  # unapproved aliases and prompt/state directory or file links still refuse.
  def test_system_alias_preserves_canonical_audit_and_rejects_other_symlinks
    with_workspace do |fixture|
      root = File.realpath(fixture)
      physical = File.join(root, "physical")
      alias_root = File.join(root, "system-alias")
      data = File.join(physical, "data")
      FileUtils.mkdir_p([File.join(data, "tasks"), File.join(data, "state")])
      File.symlink(physical, alias_root)
      aliased_data = File.join(alias_root, "data")
      write_task(data, id: "T")
      coordinator = coordinator_for(aliased_data, "alpha" => "a" * 40)
      store = AgentCodingTool::StateStore.new(File.join(data, "state"))
      code, _out, error = invoke(aliased_data, coordinator, "received", "T", "--force")
      assert_equal 2, code
      assert_includes error, "unsafe override state target"
      refute File.exist?(store.state_path("T"))

      manager = AgentCodingTool::WorktreeManager
      aliases = manager::SYSTEM_ALIASES
      native_stat = File.method(:stat)
      system_stat = lambda do |path, *arguments|
        value = native_stat.call(path, *arguments)
        if [alias_root, physical].include?(path)
          value.define_singleton_method(:uid) { 0 }
        end
        value
      end
      begin
        manager.send(:remove_const, :SYSTEM_ALIASES)
        manager.const_set(:SYSTEM_ALIASES, { alias_root => physical }.freeze)
        File.stub(:stat, system_stat) do
          code, _out, error = invoke(aliased_data, coordinator, "received", "T", "--force")
          assert_equal 0, code, error
          code, _out, error = invoke(aliased_data, coordinator, "prepare", "T", "--force")
          assert_equal 0, code, error
          prompt = store.load("T").fetch("prompt_path")
          assert_equal File.realpath(prompt), prompt
          assert File.binread(prompt).include?("Fixture instructions")
          original = File.binread(store.state_path("T"))
          prompt_root = File.join(data, "state", "prompts")
          saved_prompts = File.join(data, "saved-prompts")
          File.rename(prompt_root, saved_prompts)
          File.symlink(saved_prompts, prompt_root)
          code, _out, error = invoke(aliased_data, coordinator, "prepare", "T", "--force")
          assert_equal 2, code
          assert_includes error, "unsafe prompt root"
          assert_equal original, File.binread(store.state_path("T"))
          assert_equal [File.basename(prompt)], Dir.children(saved_prompts)
          File.unlink(prompt_root)
          File.rename(saved_prompts, prompt_root)
          code, _out, error = invoke(aliased_data, coordinator, "reset", "T", "--force")
          assert_equal 0, code, error
          audit = audit_for(store.load("T"))
          assert_equal original, File.binread(audit.fetch("recovery"))
          audit_root = File.join("#{data}-runs", ".lifecycle-overrides")
          assert audit.fetch("recovery").start_with?(audit_root + "/")
          assert File.file?(File.join("#{data}-runs", "launch.lock"))
          retained = Dir.glob(File.join(audit_root, "**", "*.yml")).to_h { |path| [path, File.binread(path)] }
          bytes = File.binread(store.state_path("T"))

          state_root = File.join(data, "state")
          moved = File.join(data, "saved-state")
          File.rename(state_root, moved)
          File.symlink(moved, state_root)
          assert_equal 2, invoke(aliased_data, coordinator, "reset", "T", "--force").first
          assert_equal bytes, File.binread(store.state_path("T"))
          File.unlink(state_root)
          File.rename(moved, state_root)
          target = File.join(data, "unrelated.yml")
          File.rename(store.state_path("T"), target)
          File.symlink(target, store.state_path("T"))
          assert_equal 2, invoke(aliased_data, coordinator, "reset", "T", "--force").first
          assert_equal bytes, File.binread(target)
          assert_equal retained, Dir.glob(File.join(audit_root, "**", "*.yml")).to_h { |path| [path, File.binread(path)] }
        end
      ensure
        manager.send(:remove_const, :SYSTEM_ALIASES)
        manager.const_set(:SYSTEM_ALIASES, aliases)
      end
    end
  end

end
