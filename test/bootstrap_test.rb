# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/child_processes"

# Qualifies the real bootstrap and public CLI on real task/package files. Native
# Git is prohibited; detached fixture refs are declared source observations.
class BootstrapTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # Copies production and byte-identical pinned component sources into a fresh
  # invocation root. Explicit component roots qualify real checkouts; the default
  # offline fixture needs no sibling repositories. No fake replaces TaskStore.
  # Yields main/root/lock; fixture I/O failures propagate. Covered runs retain
  # copied sources under the supervisor's directory until census verification;
  # its owner then cleans up. Standalone focused runs clean up immediately.
  def with_composition
    context = ENV["ACT_COVERAGE_CONTEXT"]
    retained = context && JSON.parse(File.read(context)).fetch("directory")
    directory = Dir.mktmpdir("split-bootstrap-", retained)
    begin
      main = File.join(directory, "main")
      FileUtils.mkdir_p(main)
      FileUtils.cp_r([File.join(ROOT, "lib"), File.join(ROOT, "bin")], main)
      FileUtils.cp(File.join(ROOT, "split-composition.json"), main)
      lock = JSON.parse(File.read(File.join(main, "split-composition.json")))
      parent = ENV["ACT_SPLIT_DEVELOPMENT_ROOT"] || ENV["ACT_COMPONENT_ROOT"]
      snapshot = JSON.parse(File.binread(File.join(ROOT,
        "test/support/fixtures/bootstrap_components.json"))) unless parent
      components = File.join(directory, "components")
      lock.fetch("packages").each do |name, pin|
        package = File.join(components, name)
        FileUtils.mkdir_p(File.join(package, ".git"))
        if parent
          FileUtils.cp_r(File.join(parent, name, "lib"), package)
        else
          sources = snapshot.fetch("packages").fetch(name).fetch("files")
          expected = pin.fetch("development_files", pin.fetch("files"))
          assert_equal expected, sources.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) },
            "offline component fixture differs from reviewed composition: #{name}"
          sources.each do |path, bytes|
            destination = File.join(package, path)
            FileUtils.mkdir_p(File.dirname(destination))
            File.binwrite(destination, bytes)
          end
        end
        File.write(File.join(package, ".git/HEAD"), pin.fetch("revision") + "\n")
      end
      yield main, components, lock
    ensure
      FileUtils.remove_entry(directory) unless retained
    end
  end

  # Builds an explicit fresh process environment. Child roots and composition
  # are inherited only when a test requests them, never from the parent suite.
  def environment(components, mode = "split")
    { "ACT_IMPLEMENTATION" => mode, "ACT_RESOLVED_COMPOSITION" => nil,
      "ACT_COMPONENT_ROOT" => nil, "ACT_SPLIT_DEVELOPMENT_ROOT" => components }
  end

  # Runs the exact reviewed observer under the existing bounded child boundary.
  # Returns original binary stdout/stderr and genuine status; timeouts propagate.
  def cli(main, components, *arguments, env: {})
    ChildProcesses.capture("bootstrap_cli", arguments: [main, *arguments],
      environment: environment(components).merge(env))
  end

  # Proves env/.env/default precedence, no interpolation or unrelated imports,
  # once-only inheritance, frozen identity, and dependency-.env noninterference.
  def test_mode_resolution_and_inherited_composition
    with_composition do |main, components, _lock|
      resolver = AgentCodingTool::Bootstrap
      assert_equal "legacy", resolver.resolve(root: main, env: {}).fetch("mode")
      File.write(File.join(main, ".env"), "UNRELATED=$(touch #{File.join(main, 'forbidden')})\n")
      assert_equal "legacy", resolver.resolve(root: main, env: {}).fetch("mode")
      File.open(File.join(main, ".env"), "a") { |file| file.puts "ACT_IMPLEMENTATION='split' # opt in" }
      env = { "ACT_SPLIT_DEVELOPMENT_ROOT" => components }
      selected = resolver.resolve(root: main, env: env)
      assert_equal "split", selected.fetch("mode")
      assert selected.frozen?
      assert selected.fetch("packages").fetch("act-tasks").frozen?
      File.write(File.join(components, "act-tasks/.env"), "ACT_IMPLEMENTATION=invalid\n")
      assert_equal selected, resolver.resolve(root: main, env: env)
      assert_equal "legacy", resolver.resolve(root: main, env: env.merge("ACT_IMPLEMENTATION" => "legacy")).fetch("mode")
      File.write(File.join(main, ".env"), "ACT_IMPLEMENTATION=legacy\n")
      out, err, status = cli(main, components, "implementation", env: {
        "ACT_IMPLEMENTATION" => "split", "ACT_RESOLVED_COMPOSITION" => JSON.generate(selected) })
      assert status.success?, err
      assert_equal selected, JSON.parse(out)
      assert_raises(resolver::Refused) { resolver.resolve(root: main, env: env.merge(
        "ACT_IMPLEMENTATION" => "legacy", "ACT_RESOLVED_COMPOSITION" => JSON.generate(selected))) }
      refute File.exist?(File.join(main, "forbidden"))
      refute ENV.key?("UNRELATED")
    end
  end

  # Invalid/ambiguous modes and required missing/mismatched package identities
  # refuse before loading production, while the actual legacy CLI still starts.
  def test_invalid_modes_and_package_refusals
    with_composition do |main, components, _lock|
      ["", "SPLIT", "other", "$(touch forbidden)"].each do |mode|
        _out, err, status = cli(main, components, "implementation", env: { "ACT_IMPLEMENTATION" => mode })
        assert_equal 2, status.exitstatus
        assert_includes err, "ACT_IMPLEMENTATION must be legacy or split"
      end
      ["ACT_IMPLEMENTATION=other\n", "ACT_IMPLEMENTATION=split\nACT_IMPLEMENTATION=legacy\n"].each do |text|
        File.write(File.join(main, ".env"), text)
        _out, err, status = cli(main, components, "implementation", env: { "ACT_IMPLEMENTATION" => nil })
        assert_equal 2, status.exitstatus
        assert_includes err, "ACT_IMPLEMENTATION in .env"
      end
      File.write(File.join(components, "act-tasks/.git/HEAD"), "0" * 40 + "\n")
      _out, err, status = cli(main, components, "implementation")
      assert_equal 2, status.exitstatus
      assert_includes err, "revision differs from pinned"
      FileUtils.rm_rf(components)
      _out, err, status = cli(main, components, "implementation")
      assert_equal 2, status.exitstatus
      assert_includes err, "required split composition unavailable"
      out, err, status = cli(main, components, "implementation", env: { "ACT_IMPLEMENTATION" => "legacy" })
      assert status.success?, err
      assert_equal({ "mode" => "legacy", "packages" => {} }, JSON.parse(out))
    end
  end

  # Runs real public status in both modes, observes the actual package load,
  # and verifies schema diagnostics through the main compatibility rescue.
  def test_public_status_delegation_and_compatible_refusals
    with_composition do |main, components, _lock|
      data = File.join(main, "data")
      FileUtils.mkdir_p(File.join(data, "tasks"))
      File.write(File.join(data, "config.yml"), YAML.dump("repo_root" => main))
      task = { "id" => "T1", "title" => "Bootstrap status", "repositories" => { "alpha" => { "access" => "write" } } }
      path = File.join(data, "tasks/T1.yml")
      File.write(path, YAML.dump(task))
      %w[legacy split].each do |mode|
        env = { "ACT_IMPLEMENTATION" => mode, "AGENT_CODING_TOOL_DATA_DIR" => data }
        out, err, status = cli(main, components, "status", "T1", env: env)
        assert status.success?, err
        assert_includes out, "T1"
        assert_includes out, "READY"
        calls = JSON.parse(err.lines.grep(/^TASK_SOURCE=/).fetch(0).delete_prefix("TASK_SOURCE="))
        if mode == "split"
          assert_includes calls, { "method" => "load", "path" => File.join(components, "act-tasks/lib/act_tasks/task_store.rb") }
        else
          assert_empty calls
        end
        [{ "planning_guidance" => false }, { "checkpoint" => { "mode" => "exempt" } },
          { "worker_recommendation" => [] }].each do |invalid|
          File.write(path, YAML.dump(task.merge(invalid)))
          _out, err, status = cli(main, components, "status", "T1", env: env)
          assert_equal 2, status.exitstatus
          assert_includes err, "ERROR: #{path}: #{invalid.keys.first}"
        end
        File.write(path, YAML.dump(task))
      end
      FileUtils.rm_rf(components)
      env = { "ACT_IMPLEMENTATION" => "legacy", "AGENT_CODING_TOOL_DATA_DIR" => data }
      out, err, status = cli(main, components, "status", "T1", env: env)
      assert status.success?, err
      assert_includes out, "READY"
      _out, err, status = cli(main, components, "status", "T1", env: env.merge("ACT_IMPLEMENTATION" => "split"))
      assert_equal 2, status.exitstatus
      assert_includes err, "required split composition unavailable"
    end
  end

  # The compatibility adapter preserves collection/path behavior, missing-file
  # messages, native YAML failures and the original package exception as cause.
  def test_adapter_collection_errors_and_yaml_exceptions
    with_composition do |main, components, _lock|
      data = File.join(main, "tasks")
      FileUtils.mkdir_p(data)
      task = { "id" => "T1", "title" => "Task", "repositories" => { "alpha" => { "access" => "write" } } }
      path = File.join(data, "T1.yml")
      File.write(path, YAML.dump(task))
      out, err, status = cli(main, components, "store", data)
      assert status.success?, err
      assert_equal({ "path" => path, "tasks" => [task], "task" => task }, JSON.parse(out))
      File.write(path, YAML.dump(task.merge("planning_guidance" => nil)))
      _out, err, status = cli(main, components, "store", data)
      assert_equal 2, status.exitstatus
      assert_includes err, "cause=ActTasks::InvalidTask"
      File.unlink(path)
      _out, err, status = cli(main, components, "store", data)
      assert_equal 2, status.exitstatus
      assert_includes err, "task not found: T1; cause=ActTasks::InvalidTask"
      File.write(path, "id: [\n")
      _out, err, status = cli(main, components, "store", data)
      refute status.success?
      assert_includes err, "Psych::SyntaxError"
    end
  end

  # Published roots use only publication pins. All packages must be present,
  # and the initial scaffold cannot masquerade as the migrated task API.
  def test_published_composition_and_scaffold_api_refusal
    with_composition do |main, components, lock|
      lock.fetch("packages").each_value do |pin|
        pin["files"] = pin.fetch("development_files", pin.fetch("files"))
      end
      path = File.join(main, "split-composition.json")
      File.write(path, JSON.generate(lock))
      env = environment(components).merge("ACT_SPLIT_DEVELOPMENT_ROOT" => nil, "ACT_COMPONENT_ROOT" => components)
      result = AgentCodingTool::Bootstrap.resolve(root: main, env: env)
      assert_equal "published", result.fetch("qualification")
      assert_equal 3, result.fetch("packages").size
      default = File.expand_path("../agent-coding-tool-components", main)
      FileUtils.mv(components, default)
      assert_equal "split", AgentCodingTool::Bootstrap.resolve(root: main, env: { "ACT_IMPLEMENTATION" => "split" }).fetch("mode")
      components = default
      env["ACT_COMPONENT_ROOT"] = components
      File.unlink(File.join(components, "act-tasks/lib/act_tasks/task_store.rb"))
      lock.fetch("packages").fetch("act-tasks").fetch("files").delete("lib/act_tasks/task_store.rb")
      File.write(path, JSON.generate(lock))
      error = assert_raises(AgentCodingTool::Bootstrap::Refused) { AgentCodingTool::Bootstrap.resolve(root: main, env: env) }
      assert_includes error.message, "scaffold has no TaskStore"
      lock.fetch("packages").delete("act-lifecycle")
      File.write(path, JSON.generate(lock))
      error = assert_raises(AgentCodingTool::Bootstrap::Refused) { AgentCodingTool::Bootstrap.resolve(root: main, env: env) }
      assert_includes error.message, "composition must pin"
    end
  end

  # Revision lookup covers ordinary/linked, loose/packed and invalid identities
  # with filesystem observations only; no Git process supplies a result.
  def test_revision_files_and_source_digest_refusal
    with_composition do |main, components, lock|
      package = File.join(components, "act-tasks")
      sha = lock.fetch("packages").fetch("act-tasks").fetch("revision")
      metadata = File.join(package, ".git")
      File.write(File.join(metadata, "HEAD"), "ref: refs/heads/main\n")
      File.write(File.join(metadata, "packed-refs"), "# pack-refs\n#{sha} refs/heads/main\n#{sha} refs/heads/other\n")
      assert_equal sha, AgentCodingTool::Bootstrap.revision(package)
      FileUtils.mkdir_p(File.join(metadata, "refs/heads"))
      File.write(File.join(metadata, "refs/heads/main"), sha + "\n")
      assert_equal sha, AgentCodingTool::Bootstrap.revision(package)
      linked = File.join(components, "linked")
      FileUtils.mkdir_p(linked)
      File.write(File.join(linked, ".git"), "gitdir: #{metadata}\n")
      assert_equal sha, AgentCodingTool::Bootstrap.revision(linked)
      File.write(File.join(metadata, "commondir"), ".\n")
      assert_equal sha, AgentCodingTool::Bootstrap.revision(linked)
      File.write(File.join(linked, ".git"), "malformed\n")
      assert_raises(AgentCodingTool::Bootstrap::Refused) { AgentCodingTool::Bootstrap.revision(linked) }
      File.write(File.join(metadata, "HEAD"), "ref: ../foreign\n")
      assert_raises(AgentCodingTool::Bootstrap::Refused) { AgentCodingTool::Bootstrap.revision(package) }
      File.write(File.join(metadata, "HEAD"), "ref: refs/heads/main\n")
      File.write(File.join(metadata, "refs/heads/main"), "not-a-revision\n")
      assert_raises(AgentCodingTool::Bootstrap::Refused) { AgentCodingTool::Bootstrap.revision(package) }
      File.write(File.join(metadata, "HEAD"), sha + "\n")
      source = File.join(package, "lib/act_tasks.rb")
      bytes = File.binread(source)
      escaped = File.join(components, "escaped.rb")
      File.binwrite(escaped, bytes)
      File.unlink(source)
      File.symlink(escaped, source)
      error = assert_raises(AgentCodingTool::Bootstrap::Refused) do
        AgentCodingTool::Bootstrap.resolve(root: main, env: environment(components))
      end
      assert_includes error.message, "package source escapes root"
      File.unlink(source)
      File.binwrite(source, bytes + "# unexpected drift\n")
      _out, err, status = cli(main, components, "implementation")
      assert_equal 2, status.exitstatus
      assert_includes err, "source differs from pinned digest"
    end
  end
end
