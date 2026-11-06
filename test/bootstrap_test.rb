# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/child_processes"
require "pathname"

# Qualifies the real bootstrap and public CLI on real task/package files. Native
# Git is prohibited; detached fixture refs are declared source observations.
class BootstrapTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # A correctly hashed scaffold still lacks the capture API. Refuse explicitly
  # before a public command rather than silently using legacy in split mode.
  def test_observability_scaffold_refuses_adoption
    with_composition do |main, components, lock|
      package = File.join(components, "act-observability")
      File.unlink(File.join(package, "lib/act_observability/gate_capture.rb"))
      entry = File.join(package, "lib/act_observability.rb")
      File.write(entry, File.read(entry).sub("require_relative \"act_observability/gate_capture\"\n", ""))
      pin = lock.fetch("packages").fetch("act-observability")
      pin["files"] = Dir.glob("lib/**/*.rb", base: package).to_h do |path|
        [path, Digest::SHA256.file(File.join(package, path)).hexdigest]
      end
      File.write(File.join(main, "split-composition.json"), JSON.generate(lock))
      _out, err, status = cli(main, components, "implementation")
      assert_equal 2, status.exitstatus
      assert_includes err, "pinned act-observability has no GateCapture"
      out, err, status = cli(main, components, "implementation", env: { "ACT_IMPLEMENTATION" => "legacy" })
      assert status.success?, err
      assert_equal "legacy", JSON.parse(out).fetch("mode")
    end
  end

  # The public gate must invoke the package with real binary pipes and retain a
  # failing child's status. This exempt fixture proves capture, not provenance.
  def test_public_gate_capture_delegation_and_broken_handoffs
    with_composition do |main, components, _lock|
      data = File.join(main, "data")
      workspace = File.join(main, "workspace")
      FileUtils.mkdir_p([File.join(data, "tasks"), File.join(data, "state"), workspace])
      File.write(File.join(data, "config.yml"), YAML.dump("repo_root" => main))
      task = { "id" => "T1", "title" => "Capture qualification",
        "repositories" => { "repo" => { "access" => "write" } },
        "checkpoint" => { "mode" => "exempt", "category" => "inspection", "reason" => "Disposable capture proof." } }
      File.write(File.join(data, "tasks/T1.yml"), YAML.dump(task))
      state = { "id" => "T1", "prepared_at" => "2026-11-03T00:00:00Z", "started_at" => "2026-11-03T00:01:00Z",
        "snapshot" => { "repo" => { "path" => workspace, "remote" => "origin",
          "remote_url" => "git@github.com:fixture/repo.git", "branch" => "main", "pushed_sha" => "a" * 40 } } }
      state_path = File.join(data, "state/T1.yml")
      File.write(state_path, YAML.dump(state))
      original_state = File.binread(state_path)
      env = { "AGENT_CODING_TOOL_DATA_DIR" => data,
        "ACT_SPLIT_DEVELOPMENT_ROOT" => nil, "ACT_COMPONENT_ROOT" => components }
      arguments = ["checkpoint", "gate", "T1", "--workspace", workspace, "--",
        RbConfig.ruby, File.join(ChildProcesses::FIXTURES, "checkpoint_validator.rb"), "share"]
      evidence = File.join("#{data}-runs", "checkpoints/T1/*/gate-*.finished.json")
      source = File.join(components, "act-observability/lib/act_observability/gate_capture.rb")
      [0, 7].each do |exit_code|
        out, err, status = cli(main, components, *arguments, exit_code.to_s, env: env)
        assert_equal exit_code.zero? ? 0 : 2, status.exitstatus, err
        assert_includes out.b, "out\x00\xff".b
        assert_includes err.b, "err\x80".b
        assert_includes err, "validation command failed (7)" unless exit_code.zero?
        calls = JSON.parse(err.lines.grep(/^CAPTURE_SOURCE=/).fetch(0).delete_prefix("CAPTURE_SOURCE="))
        assert_equal [source], calls
      end
      receipts = Dir.glob(evidence).map { |path| JSON.parse(File.binread(path)) }
      assert_equal [0, 7], receipts.map { |receipt| receipt.dig("command_outcome", "exit_code") }.sort
      receipts.each do |receipt|
        assert_equal "complete", receipt.dig("output", "status")
        assert_equal 4 * 1024 * 1024, receipt.dig("output", "limit_per_stream")
        assert_nil receipt["candidate"]
        { "stdout" => "out\x00\xff".b, "stderr" => "err\x80".b }.each do |name, bytes|
          stream = receipt.fetch("output").fetch("streams").fetch(name)
          assert_equal bytes.bytesize, stream["bytes"]
          assert_equal bytes.bytesize, stream["observed_bytes"]
          assert_equal Digest::SHA256.hexdigest(bytes), stream["sha256"]
          directory = File.dirname(Dir.glob(evidence).fetch(0))
          captured = File.join(directory, stream.fetch("file"))
          assert_equal bytes, File.binread(captured)
          assert_equal 0o600, File.stat(captured).mode & 0o777
          assert_equal "complete", stream["console"]
        end
      end
      assert_equal original_state, File.binread(state_path)

      # Deliberately bypass the package with the retained legacy implementation.
      # Identical output must still fail the package-source journey assertion.
      _out, err, status = cli(main, components, *arguments, "0", env: env.merge("ACT_IMPLEMENTATION" => "legacy"))
      assert status.success?, err
      assert_includes _out.b, "out\x00\xff".b
      calls = JSON.parse(err.lines.grep(/^CAPTURE_SOURCE=/).fetch(0).delete_prefix("CAPTURE_SOURCE="))
      assert_raises(Minitest::Assertion) { assert_equal [source], calls, "capture delegation missing" }
      _out, err, status = cli(main, components, *arguments, "0", env: env)
      assert status.success?, err
      calls = JSON.parse(err.lines.grep(/^CAPTURE_SOURCE=/).fetch(0).delete_prefix("CAPTURE_SOURCE="))
      assert_equal [source], calls
      count = Dir.glob(evidence).size
      package_bytes = File.binread(source)
      File.open(source, "a") { |file| file.puts "# misbound source" }
      _out, err, status = cli(main, components, *arguments, "0", env: env)
      assert_equal 2, status.exitstatus
      assert_includes err, "act-observability source differs from pinned digest"
      assert_equal count, Dir.glob(evidence).size
      File.binwrite(source, package_bytes)
      package = File.join(components, "act-observability")
      FileUtils.mv(package, "#{package}.unavailable")
      _out, err, status = cli(main, components, *arguments, "0", env: env)
      assert_equal 2, status.exitstatus
      assert_includes err, "required split composition unavailable"
      assert_equal count, Dir.glob(evidence).size
      _out, err, status = cli(main, components, *arguments, "7", env: env.merge("ACT_IMPLEMENTATION" => "legacy"))
      assert_equal 2, status.exitstatus
      assert_includes err, "validation command failed (7)"
      calls = JSON.parse(err.lines.grep(/^CAPTURE_SOURCE=/).fetch(0).delete_prefix("CAPTURE_SOURCE="))
      assert_empty calls
      FileUtils.mv("#{package}.unavailable", package)
      _out, err, status = cli(main, components, *arguments, "0", env: env)
      assert status.success?, err
      calls = JSON.parse(err.lines.grep(/^CAPTURE_SOURCE=/).fetch(0).delete_prefix("CAPTURE_SOURCE="))
      assert_equal [source], calls
      assert_equal original_state, File.binread(state_path)
    end
  end

  # Copies production and byte-identical pinned component sources into a fresh
  # invocation root. Explicit component roots qualify real checkouts; the default
  # offline fixture needs no sibling repositories. No fake replaces TaskStore.
  # Yields main/root/lock; fixture I/O failures propagate. Covered runs retain
  # copied sources under the supervisor's directory until census verification;
  # its owner then cleans up. Standalone focused runs clean up immediately.
  # A test-only temporary_parent can exercise filesystem aliases; canonicalize
  # before any copy/load so Ruby coverage and its source census use one spelling.
  def with_composition(temporary_parent: nil)
    context = ENV["ACT_COVERAGE_CONTEXT"]
    retained = context && JSON.parse(File.read(context)).fetch("directory")
    directory = File.realpath(Dir.mktmpdir("split-bootstrap-", temporary_parent || retained))
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

  # Same-source children retain published/default, development and legacy
  # selection across a clean launch. Replaced roots/refs/bytes still refuse.
  def test_frozen_child_environment_revalidates_its_source
    with_composition do |main, components, lock|
      resolver = AgentCodingTool::Bootstrap
      [nil, "split", "legacy", "development"].each do |mode|
        inputs = { "ACT_COMPONENT_ROOT" => components, "UNRELATED_SECRET" => "never-forward" }
        inputs["ACT_IMPLEMENTATION"] = mode if %w[split legacy].include?(mode)
        inputs["ACT_SPLIT_DEVELOPMENT_ROOT"] = components if mode == "development"
        selected = resolver.resolve(root: main, env: inputs)
        child = resolver.child_environment(root: main, env: inputs, composition: selected)
        assert child.frozen?
        assert child.values.compact.all?(&:frozen?)
        assert_equal %w[ACT_COMPONENT_ROOT ACT_IMPLEMENTATION ACT_RESOLVED_COMPOSITION ACT_SPLIT_DEVELOPMENT_ROOT], child.keys.sort
        inputs.replace("ACT_IMPLEMENTATION" => "invalid", "ACT_COMPONENT_ROOT" => "/absent")
        File.write(File.join(main, ".env"), "ACT_IMPLEMENTATION=invalid\n")
        out, err, status = cli(main, components, "implementation", env: child)
        assert status.success?, err
        assert_equal selected, JSON.parse(out)
        File.unlink(File.join(main, ".env"))
        next if mode == "legacy"

        drift = child.merge("ACT_IMPLEMENTATION" => "legacy")
        _out, err, status = cli(main, components, "implementation", env: drift)
        assert_equal 2, status.exitstatus
        assert_includes err, "inherited composition changed"
        source = File.join(components, "act-tasks", lock.fetch("packages").fetch("act-tasks").fetch("files").keys.first)
        bytes = File.binread(source)
        File.binwrite(source, bytes + "\n# drift\n")
        _out, err, status = cli(main, components, "implementation", env: child)
        assert_equal 2, status.exitstatus
        assert_includes err, "source differs from pinned digest"
        File.binwrite(source, bytes)
        head = File.join(components, "act-tasks/.git/HEAD")
        revision = File.binread(head)
        File.write(head, "0" * 40)
        _out, err, status = cli(main, components, "implementation", env: child)
        assert_equal 2, status.exitstatus
        assert_includes err, "revision differs from pinned"
        File.binwrite(head, revision)
      end
      # A relative selected parent is resolved before a child's unrelated cwd.
      relative = { "ACT_COMPONENT_ROOT" => Pathname.new(components).relative_path_from(Pathname.new(Dir.pwd)).to_s }
      selected = resolver.resolve(root: main, env: relative)
      child = resolver.child_environment(root: main, env: relative, composition: selected)
      assert_equal components, child.fetch("ACT_COMPONENT_ROOT")
      alternate = File.join(main, "other-components")
      FileUtils.cp_r(components, alternate)
      _out, err, status = cli(main, components, "implementation", env: child.merge("ACT_COMPONENT_ROOT" => alternate))
      assert_equal 2, status.exitstatus
      assert_includes err, "inherited composition changed"
      FileUtils.mv(components, components + ".absent")
      _out, err, status = cli(main, components, "implementation", env: child)
      assert_equal 2, status.exitstatus
      assert_includes err, "required split composition unavailable"
      # Explicit rollback does not require any package or component selector.
      selected = resolver.resolve(root: main, env: { "ACT_IMPLEMENTATION" => "legacy" })
      child = resolver.child_environment(root: main, env: {}, composition: selected)
      out, err, status = cli(main, components, "implementation", env: child)
      assert status.success?, err
      assert_equal selected, JSON.parse(out)
      assert_nil child.fetch("ACT_COMPONENT_ROOT")
      assert_nil child.fetch("ACT_SPLIT_DEVELOPMENT_ROOT")
    end
  end

  # Exercises a real symlinked temporary parent and real covered CLI startup.
  # Source copies stay in the supervisor's retained directory after alias cleanup;
  # canonical paths must agree before their independent coverage is collected.
  def test_canonical_fixture_roots_through_temporary_alias
    context = ENV["ACT_COVERAGE_CONTEXT"]
    retained = context && JSON.parse(File.read(context)).fetch("directory")
    Dir.mktmpdir("bootstrap-alias-") do |directory|
      target = retained || File.join(directory, "target")
      FileUtils.mkdir_p(target)
      temporary_alias = File.join(directory, "alias")
      File.symlink(File.realpath(target), temporary_alias)
      with_composition(temporary_parent: temporary_alias) do |main, components, _lock|
        assert_equal File.realpath(main), main
        assert_equal File.realpath(components), components
        out, err, status = cli(main, components, "implementation")
        assert status.success?, err
        assert_equal "split", JSON.parse(out).fetch("mode")
      end
    end
  end

  # Proves env/.env/default precedence, no interpolation or unrelated imports,
  # once-only inheritance, frozen identity, and dependency-.env noninterference.
  def test_mode_resolution_and_inherited_composition
    with_composition do |main, components, _lock|
      resolver = AgentCodingTool::Bootstrap
      default = File.expand_path("../agent-coding-tool-components", main)
      FileUtils.mv(components, default)
      components = default
      selected_default = resolver.resolve(root: main, env: {})
      assert_equal "split", selected_default.fetch("mode")
      assert_equal "published", selected_default.fetch("qualification")
      File.write(File.join(main, ".env"), "UNRELATED=$(touch #{File.join(main, 'forbidden')})\n")
      assert_equal selected_default, resolver.resolve(root: main, env: {})
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
      assert_equal "legacy", resolver.resolve(root: main, env: {}).fetch("mode")
      out, err, status = cli(main, components, "implementation", env: {
        "ACT_IMPLEMENTATION" => "split", "ACT_RESOLVED_COMPOSITION" => JSON.generate(selected) })
      assert status.success?, err
      assert_equal selected, JSON.parse(out)
      inherited = { "ACT_RESOLVED_COMPOSITION" => JSON.generate(selected_default) }
      File.unlink(File.join(main, ".env"))
      assert_equal selected_default, resolver.resolve(root: main, env: inherited)
      assert_raises(resolver::Refused) { resolver.resolve(root: main, env: inherited.merge(
        "ACT_SPLIT_DEVELOPMENT_ROOT" => components)) }
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
      File.unlink(File.join(main, ".env"))
      published = { "ACT_IMPLEMENTATION" => nil, "ACT_SPLIT_DEVELOPMENT_ROOT" => nil,
        "ACT_COMPONENT_ROOT" => components }
      lock_path = File.join(main, "split-composition.json")
      lock_bytes = File.binread(lock_path)
      File.write(lock_path, "invalid JSON")
      _out, err, status = cli(main, components, "implementation", env: published)
      assert_equal 2, status.exitstatus
      assert_includes err, "required split composition unavailable"
      File.binwrite(lock_path, lock_bytes)
      head_path = File.join(components, "act-tasks/.git/HEAD")
      head_bytes = File.binread(head_path)
      { "0" * 40 => "revision differs from pinned", "invalid" => "unsupported package HEAD" }.each do |head, message|
        File.write(head_path, head)
        _out, err, status = cli(main, components, "implementation", env: published)
        assert_equal 2, status.exitstatus
        assert_includes err, message
      end
      File.binwrite(head_path, head_bytes)
      source = File.join(components, "act-tasks/lib/act_tasks.rb")
      File.open(source, "a") { |file| file.puts "# changed default dependency" }
      _out, err, status = cli(main, components, "implementation", env: published)
      assert_equal 2, status.exitstatus
      assert_includes err, "source differs from pinned digest"
      FileUtils.rm_rf(components)
      _out, err, status = cli(main, components, "implementation", env: published)
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
      [nil, "legacy", "split"].each do |mode|
        env = { "ACT_IMPLEMENTATION" => mode, "AGENT_CODING_TOOL_DATA_DIR" => data,
          "ACT_SPLIT_DEVELOPMENT_ROOT" => nil, "ACT_COMPONENT_ROOT" => components }
        implementation, err, status = cli(main, components, "implementation", env: env)
        assert status.success?, err
        composition = JSON.parse(implementation)
        assert_equal mode || "split", composition.fetch("mode")
        assert_equal "published", composition.fetch("qualification") unless mode == "legacy"
        out, err, status = cli(main, components, "status", "T1", env: env)
        assert status.success?, err
        assert_includes out, "T1"
        assert_includes out, "READY"
        calls = JSON.parse(err.lines.grep(/^TASK_SOURCE=/).fetch(0).delete_prefix("TASK_SOURCE="))
        if mode != "legacy"
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
