# frozen_string_literal: true

require "open3"
require "rbconfig"
require "json"
require "timeout"
require_relative "test_helper"

class RakefileTest < Minitest::Test
  PROJECT_ROOT = File.expand_path("..", __dir__)
  VALID_YAML = {
    "config.yml" => "---\nrepo_root: ..\n",
    "tasks/T1.yml" => "---\nid: T1\ntitle: Task\n",
    "state/T1.yml" => "---\nstatus: PREPARED\n"
  }.freeze

  def test_validation_accepts_managed_yaml_ignores_other_files_and_is_read_only
    with_data_directory do |data_root|
      managed_paths = write_valid_yaml(data_root)
      ignored_paths = {
        "state/prompts/T1.txt" => "not: [valid YAML",
        "notes.yml" => "also: [not valid",
        "tasks/README.txt" => "neither: [is this"
      }.map do |relative_path, content|
        write_file(data_root, relative_path, content)
      end
      paths = managed_paths + ignored_paths
      old_time = Time.at(1_600_000_000)
      paths.each { |path| File.utime(old_time, old_time, path) }
      before = paths.to_h { |path| [path, [File.binread(path), File.stat(path).mtime]] }

      stdout, stderr, status = run_validation(data_root)

      assert_predicate status, :success?, stderr
      assert_includes stdout, "Validated 3 ACTD YAML files"
      assert_empty stderr
      assert_equal before, paths.to_h { |path| [path, [File.binread(path), File.stat(path).mtime]] }
    end
  end

  def test_validation_reports_each_malformed_managed_surface
    %w[config.yml tasks/T1.yml state/T1.yml].each do |relative_path|
      with_data_directory do |data_root|
        write_valid_yaml(data_root)
        malformed_path = File.join(data_root, relative_path)
        File.write(malformed_path, "broken: [\n")

        _stdout, stderr, status = run_validation(data_root)

        refute_predicate status, :success?
        assert_includes stderr, malformed_path
        assert_match(/line \d+ column \d+/, stderr)
      end
    end
  end

  def test_validation_is_a_clean_skip_when_selected_data_directory_is_absent
    Dir.mktmpdir do |dir|
      missing = File.join(dir, "missing-data")

      stdout, stderr, status = run_validation(missing)

      assert_predicate status, :success?, stderr
      assert_includes stdout, "Skipping ACTD YAML validation"
      assert_includes stdout, missing
      assert_empty stderr
    end
  end

  def test_environment_override_selects_the_alternate_data_directory
    with_data_directory do |data_root|
      malformed_path = write_file(data_root, "config.yml", "broken: [\n")

      _stdout, stderr, status = run_validation(data_root)

      refute_predicate status, :success?
      assert_includes stderr, malformed_path
    end
  end

  private

  # Copies only the entry-point contract into a disposable fixture; yields its
  # root and fixed native inventory. Fixture IO/JSON errors propagate.
  def with_suite_fixture
    Dir.mktmpdir("rake-suites-") do |root|
      %w[lib test].each { |path| FileUtils.mkdir_p(File.join(root, path)) }
      FileUtils.cp(File.join(PROJECT_ROOT, "Rakefile"), root)
      %w[suite_runner.rb suite_reporter.rb required_cases.json].each do |name|
        FileUtils.cp(File.join(PROJECT_ROOT, "test", name), File.join(root, "test", name))
      end
      write_file(root, "lib/agent_coding_tool.rb", "require #{File.join(PROJECT_ROOT, 'lib/agent_coding_tool').inspect}\n")
      inventory = JSON.parse(File.read(File.join(root, "test/required_cases.json")))
      inventory["default"] = { "test/example_test.rb" => ["DefaultExample#test_default"] }
      write_file(root, "test/required_cases.json", JSON.generate(inventory))
      inventory.fetch("integration").each { |path, cases| write_suite(root, path, cases) }
      write_suite(root, "test/example_test.rb", inventory.fetch("default").values.flatten)
      yield root, inventory.fetch("integration")
    end
  end

  # Writes genuine minimal Minitest cases for runner qualification, returning the
  # path. Accepts fixed Class#method identities; IO errors propagate.
  def write_suite(root, path, cases)
    classes = cases.group_by { |name| name.split("#").first }
    source = "require 'minitest/autorun'\nputs #{path.inspect} + ' pid=' + Process.pid.to_s\n"
    classes.each do |class_name, names|
      source << "class #{class_name} < Minitest::Test\n"
      names.each { |name| source << "  def #{name.split('#').last}; assert true; end\n" }
      source << "end\n"
    end
    write_file(root, path, source)
  end

  # Runs real Rake with argv/cwd in an owned process group; returns binary output
  # and Process::Status. Reaps only that group on the 15-second fixture deadline.
  # Spawn/IO errors and Timeout::Error propagate.
  def run_fixture_rake(root, *tasks)
    Dir.mktmpdir("rake-output-") do |output|
      stdout_path, stderr_path = %w[out err].map { |name| File.join(output, name) }
      pid = Process.spawn({ "AGENT_CODING_TOOL_DATA_DIR" => File.join(root, "data") },
                          RbConfig.ruby, Gem.bin_path("rake", "rake"), *tasks,
                          chdir: root, out: stdout_path, err: stderr_path, pgroup: true)
      begin
        status = Timeout.timeout(15) { Process.wait2(pid).last }
      rescue Timeout::Error
        Process.kill("KILL", -pid)
        Process.wait(pid)
        raise
      end
      [File.binread(stdout_path), File.binread(stderr_path), status]
    end
  end

  # Adds a genuine fixture contract through B's file/inventory seam. Returns the
  # created path; filesystem errors propagate.
  def add_fixture_contract(root)
    path = "test/git_contract/example_contract.rb"
    cases = ["ContractExample#test_contract"]
    write_file(root, "test/git_contract/required_cases.json", JSON.generate(path => cases))
    write_suite(root, path, cases)
  end

  public

  # Default rake validates ACTD YAML, then requires every mandatory layer;
  # fast-only `test` remains available and malformed YAML stops before tests.
  def test_default_and_test_keep_existing_selection_and_yaml_prerequisite
    with_suite_fixture do |root, inventory|
      add_fixture_contract(root)
      write_file(root, "data/config.yml", "---\nrepo_root: ..\n")
      stdout, stderr, status = run_fixture_rake(root)
      assert_predicate status, :success?, stderr
      assert_operator stdout.index("Validated 1 ACTD YAML file"), :<, stdout.index("test/example_test.rb")
      assert_includes stdout, "test/git_contract/example_contract.rb"
      inventory.each_key { |path| assert_includes stdout, path }

      native_path, native_cases = inventory.first
      File.unlink(File.join(root, native_path))
      _stdout, stderr, status = run_fixture_rake(root)
      refute_predicate status, :success?
      assert_includes stderr, "discovered files differ"
      write_suite(root, native_path, native_cases)

      write_file(root, "data/config.yml", "broken: [\n")
      stdout, stderr, status = run_fixture_rake(root)
      refute_predicate status, :success?
      assert_includes stderr, "config.yml"
      refute_includes stdout, "test/example_test.rb"
      stdout, stderr, status = run_fixture_rake(root, "test")
      assert_predicate status, :success?, stderr
      assert_includes stdout, "test/example_test.rb"
      refute_includes stdout, "Validated"
      refute_includes stdout, "example_contract.rb"
    end
  end


  # Mandatory native files execute separately; Rake prerequisites execute once,
  # contracts stay outside default discovery, and the aggregate requires all layers.
  def test_real_tasks_execute_isolated_suites_and_aggregate_prerequisites_once
    with_suite_fixture do |root, inventory|
      add_fixture_contract(root)
      stdout, stderr, status = run_fixture_rake(root, "test:integration", "test:all")
      assert_predicate status, :success?, stderr
      inventory.each_key { |path| assert_equal 1, stdout.scan("#{path} pid=").length }
      assert_equal inventory.length + 2, stdout.scan(/pid=(\d+)/).flatten.uniq.length
      assert_includes stdout, "test/git_contract/example_contract.rb"
      assert_includes stdout, "test/example_test.rb"
      refute_includes stdout, "manual_parallel_native_sandbox"
      refute_includes stdout, "terminal_attempt_reproduction"
    end
  end

  # Explicit file and case registration is necessary and sufficient for a new
  # native launcher fixture; unregistered files/cases fail before gate success.
  def test_new_native_launcher_requires_explicit_file_and_case_registration
    with_suite_fixture do |root, native|
      path = "test/integration/launcher_git_integration.rb"
      cases = ["LauncherGitIntegration#test_launcher"]
      write_suite(root, path, cases)
      stdout, stderr, status = run_fixture_rake(root, "test:integration")
      assert_equal 1, status.exitstatus
      assert_includes stderr, "discovered files differ"
      refute_includes stdout, "pid="

      inventory = JSON.parse(File.read(File.join(root, "test/required_cases.json")))
      inventory.fetch("integration")[path] = cases
      write_file(root, "test/required_cases.json", JSON.generate(inventory))
      write_suite(root, path, cases + ["LauncherGitIntegration#test_unregistered"])
      _stdout, stderr, status = run_fixture_rake(root, "test:integration")
      assert_equal 1, status.exitstatus
      assert_includes stderr, "unregistered case"

      write_suite(root, path, cases)
      stdout, stderr, status = run_fixture_rake(root, "test:integration")
      assert_predicate status, :success?, stderr
      (native.keys + [path]).each { |name| assert_equal 1, stdout.scan("#{name} pid=").length }
      assert_equal native.length + 1, stdout.scan(/pid=(\d+)/).flatten.uniq.length
    end
  end

  # Moving an original default identity requires its exact registration at the
  # native destination; missing file, case or reporter evidence prevents success.
  def test_original_default_case_requires_registered_native_replacement_evidence
    with_suite_fixture do |root, _native|
      original_case = "LauncherTest#test_launch_binds_pushed_base_independent_of_dirty_divergent_ordinary_checkout"
      path = "test/integration/launcher_git_integration.rb"
      replacement_case = "LauncherGitIntegration#test_launcher"
      inventory = JSON.parse(File.read(File.join(root, "test/required_cases.json")))
      inventory.fetch("default")["test/example_test.rb"] << original_case
      write_file(root, "test/required_cases.json", JSON.generate(inventory))
      _stdout, stderr, status = run_fixture_rake(root, "test:verified_default")
      assert_equal 1, status.exitstatus
      assert_includes stderr, "missing required case"

      inventory.fetch("default")["test/example_test.rb"].delete(original_case)
      inventory.fetch("integration")[path] = [original_case, replacement_case]
      write_file(root, "test/required_cases.json", JSON.generate(inventory))
      _stdout, stderr, status = run_fixture_rake(root, "test:verified_default", "test:integration")
      assert_equal 1, status.exitstatus
      assert_includes stderr, "discovered files differ"

      write_suite(root, path, [replacement_case])
      _stdout, stderr, status = run_fixture_rake(root, "test:integration")
      assert_equal 1, status.exitstatus
      assert_includes stderr, "missing required case"

      write_suite(root, path, [original_case, replacement_case])
      original = File.binread(File.join(root, path))
      File.write(File.join(root, path), original + "\nMinitest.after_run { File.unlink(ENV.fetch('ACT_SUITE_EVIDENCE')) }\n")
      _stdout, _stderr, status = run_fixture_rake(root, "test:integration")
      refute_predicate status, :success?
      File.binwrite(File.join(root, path), original)
      stdout, stderr, status = run_fixture_rake(root, "test:verified_default", "test:integration")
      assert_predicate status, :success?, stderr
      assert_includes stdout, "#{path} pid="
    end
  end

  # Absent B evidence fails both public entries before any aggregate success.
  def test_missing_git_contracts_fail_closed
    with_suite_fixture do |root, _inventory|
      %w[test:git_contract test:all].each do |task|
        _stdout, stderr, status = run_fixture_rake(root, task)
        assert_equal 1, status.exitstatus
        assert_includes stderr, "required_cases.json"
      end
      write_file(root, "test/git_contract/required_cases.json", "{}")
      _stdout, stderr, status = run_fixture_rake(root, "test:all")
      assert_equal 1, status.exitstatus
      assert_includes stderr, "empty required coverage"
    end
  end

  # Missing files/cases, failed or empty suites and corrupt/missing human and
  # per-case evidence fail real invocation; exact restored bytes pass afterward.
  def test_native_gate_rejects_missing_coverage_and_invalid_results
    with_suite_fixture do |root, inventory|
      inventory.each do |relative_path, cases|
        path = File.join(root, relative_path)
        original = File.binread(path)
        File.unlink(path)
        _stdout, stderr, status = run_fixture_rake(root, "test:integration")
        assert_equal 1, status.exitstatus, relative_path
        assert_includes stderr, "discovered files differ"
        write_suite(root, relative_path, cases.drop(1))
        _stdout, stderr, status = run_fixture_rake(root, "test:integration")
        assert_equal 1, status.exitstatus, relative_path
        assert_includes stderr, "missing required case"
        File.binwrite(path, original)
      end
      relative_path, cases = inventory.first
      path = File.join(root, relative_path)
      original = File.binread(path)
      mutations = {
        "failing case" => original.sub("assert true", "flunk 'injected failure'"),
        "skip" => original.sub("assert true", "skip 'unapproved'"),
        "empty" => "require 'minitest/autorun'\n",
        "missing summary" => "exit 0\n",
        "malformed summary" => original + "\nmodule Minitest; class SummaryReporter; def summary; 'malformed summary'; end; end; end\n",
        "missing evidence" => original + "\nMinitest.after_run { File.unlink(ENV.fetch('ACT_SUITE_EVIDENCE')) }\n",
        "malformed evidence" => original + "\nMinitest.after_run { File.write(ENV.fetch('ACT_SUITE_EVIDENCE'), '{') }\n",
        "duplicate evidence" => original + "\nMinitest.after_run { path = ENV.fetch('ACT_SUITE_EVIDENCE'); rows = JSON.parse(File.read(path)); File.write(path, JSON.generate(rows + rows)) }\n",
        "inconsistent summary" => original + "\nmodule Minitest; class SummaryReporter; def summary; '99 runs, 99 assertions, 0 failures, 0 errors, 0 skips'; end; end; end\n"
      }
      mutations.each do |label, source|
        File.binwrite(path, source)
        _stdout, stderr, status = run_fixture_rake(root, "test:integration")
        refute_predicate status, :success?, "#{label}: #{stderr}"
      end
      File.binwrite(path, original)
      assert_equal original, File.binread(path)
      _stdout, stderr, status = run_fixture_rake(root, "test:integration")
      assert_predicate status, :success?, stderr
    end
  end

  # Raw binary output survives the observer; a nonzero child status is propagated
  # exactly even when that child has otherwise valid passing test evidence.
  def test_process_bytes_status_and_spawn_exception_are_preserved
    with_suite_fixture do |root, inventory|
      path = File.join(root, inventory.keys.first)
      File.open(path, "ab") do |file|
        file.write("\nSTDOUT.binmode; STDERR.binmode; STDOUT.write(\"\\x00\\xFF\\n\".b); STDERR.write(\"\\xFE\\x00\".b)\nMinitest.after_run { exit 23 }\n")
      end
      stdout, stderr, status = run_fixture_rake(root, "test:integration")
      assert_equal 23, status.exitstatus
      assert_includes stdout, "\x00\xFF\n".b
      assert_includes stderr, "\xFE\x00".b
    end
    require_relative "suite_runner"
    error = assert_raises(Errno::ENOENT) do
      TestSuiteRunner.run_process(["missing.rb"], ["Missing#test_case"], root: "/nonexistent-act-tst14-root")
    end
    assert_includes error.message, "nonexistent-act-tst14-root"
  end

  private

  def with_data_directory
    Dir.mktmpdir do |dir|
      data_root = File.join(dir, "actd")
      FileUtils.mkdir_p(data_root)
      yield data_root
    end
  end

  def write_valid_yaml(data_root)
    VALID_YAML.map do |relative_path, content|
      write_file(data_root, relative_path, content)
    end
  end

  def write_file(data_root, relative_path, content)
    path = File.join(data_root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def run_validation(data_root)
    Open3.capture3(
      { "AGENT_CODING_TOOL_DATA_DIR" => data_root },
      RbConfig.ruby,
      Gem.bin_path("rake", "rake"),
      "actd:validate_yaml",
      chdir: PROJECT_ROOT
    )
  end
end
