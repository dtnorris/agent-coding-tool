# frozen_string_literal: true

require_relative "test_helper"
require_relative "launcher_support"
require "stringio"

# Ordinary lifecycle/negative tests use fake Codex boundaries, never a native
# sandbox. A real Ruby worker verifies temporary-file behavior independently.
class LauncherFixtureTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  # Returns the sole private attempt record in this disposable fixture.
  def report
    JSON.parse(File.binread(Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)))
  end

  # Checks a pre-reservation refusal with no child or lifecycle start.
  def assert_fixture_refusal(worker = launcher)
    error = assert_raises(AgentCodingTool::Error) { worker.launch("T") }
    assert_match(/fixture/, error.message)
    refute @store.load("T")["started_at"]
    refute File.exist?(File.join(@root, "worker-pid"))
    assert_equal "preflight_failed", report.fetch("status")
  end

  # Proves TMPDIR and the exact extra-root list agree across probe and worker;
  # ordinary create/read/write/delete works and evidence stays outside fixtures.
  def test_scoped_fixture_environment_permissions_and_retention
    fixture(process: true) do
      worker = launcher(real_sandbox_probe: true)
      host_tmpdir = worker.send(:worker_env)["TMPDIR"]
      assert_equal 0, worker.launch("T")
      record = report
      temporary = record.fetch("fixture")
      path = temporary.fetch("path")
      assert_equal File.join("#{@data}-fixtures", record.fetch("invocation_id")), path
      assert_equal File.realpath(path), path
      assert_equal Process.uid, File.stat(path).uid
      assert_equal 0, File.stat(path).mode & 0o077
      assert_equal File.stat(path).ino, temporary.fetch("inode")
      assert_equal "ready", temporary.fetch("state")
      observed = JSON.parse(File.binread(File.join(@root, "worker-temp")))
      assert_equal path, observed.fetch("TMPDIR")
      assert observed.fetch("directory").start_with?("#{path}/")
      refute File.exist?(observed.fetch("directory"))
      assert_equal "fixture content", File.binread(File.join(path, "retained.txt"))
      assert_equal [path], @observed_sandbox_roots
      assert_equal path, @observed_sandbox_tmpdir
      assert_equal host_tmpdir, worker.send(:worker_env)["TMPDIR"]
      assert_includes record.fetch("argv"), "sandbox_workspace_write.writable_roots=#{JSON.generate([path])}"
      %w[approval_policy=never sandbox_workspace_write.network_access=false sandbox_workspace_write.exclude_tmpdir_env_var=true sandbox_workspace_write.exclude_slash_tmp=true features.multi_agent=false].each do |setting|
        assert_includes record.fetch("argv"), setting
      end
      record.values_at("prompt_path", "stdin_path", "final_path", "stderr_path", "worktrees_path").each do |evidence|
        refute evidence.start_with?("#{path}/")
      end
      assert_includes File.binread(record.fetch("stdin_path")), "Temporary fixtures: #{JSON.generate(path)} (TMPDIR)"
      # Cleanup/recovery gain no permission to recursively delete worker content.
      assert File.directory?(path)
    end
  end

  # No symlinked or permissive container is adopted or repaired.
  def test_foreign_container_refuses_without_repair
    %i[symlink dangling_symlink file permissive foreign_owner].each do |kind|
      fixture do
        container = "#{@data}-fixtures"
        case kind
        when :symlink then File.symlink(@ordinary, container)
        when :dangling_symlink then File.symlink(File.join(@root, "absent"), container)
        when :file then File.write(container, "foreign")
        else Dir.mkdir(container, kind == :permissive ? 0o755 : 0o700)
        end
        if kind == :foreign_owner
          real_stat = File.method(:stat)
          File.stub(:stat, ->(path) {
            stat = real_stat.call(path)
            stat.define_singleton_method(:uid) { Process.uid + 1 } if path == container
            stat
          }) { assert_fixture_refusal }
        else
          assert_fixture_refusal
        end
        assert File.symlink?(container) if %i[symlink dangling_symlink].include?(kind)
        assert_equal "foreign", File.binread(container) if kind == :file
        assert_equal 0o755, File.stat(container).mode & 0o777 if kind == :permissive
        refute File.exist?(File.join(@ordinary, report.fetch("invocation_id")))
      end
    end
  end

  # Protect both containment directions, local remotes, authentication and shared
  # Git administration even when those paths live outside ordinary checkouts.
  def test_protected_paths_cannot_be_inside_fixture_container
    %i[source worktree ordinary remote auth shared_admin validation_symlink auth_symlink].each do |kind|
      fixture do
        container = "#{@data}-fixtures"
        nested = File.join(container, "protected")
        FileUtils.mkdir_p(nested, mode: 0o700)
        worker = launcher
        prior_home = ENV["CODEX_HOME"]
        case kind
        when :source then worker.instance_variable_set(:@source_root, nested)
        when :worktree
          File.write(File.join(@data, "config.yml"), YAML.dump("worktree_root" => nested))
        when :ordinary
          task_path = File.join(@data, "tasks", "T.yml")
          task = YAML.safe_load_file(task_path)
          task.fetch("repositories").fetch("repo")["path"] = nested
          File.write(task_path, YAML.dump(task))
        when :remote
          @remote = nested
          @inspector.remote_urls["repo"] = nested
        when :auth then ENV["CODEX_HOME"] = nested
        when :validation_symlink then File.symlink(nested, "#{@data}-validation")
        when :auth_symlink
          File.symlink(File.join(@root, "outside-auth"), File.join(nested, "auth"))
          FileUtils.mkdir_p(File.join(@root, "outside-auth"))
          ENV["CODEX_HOME"] = File.join(nested, "auth")
        when :shared_admin
          original_git = worker.method(:git!)
          worker.define_singleton_method(:git!) do |*args, **options|
            args.include?("--git-common-dir") ? nested : original_git.call(*args, **options)
          end
        end
        assert_fixture_refusal(worker)
        assert_equal ["protected"], Dir.children(container)
      ensure
        ENV["CODEX_HOME"] = prior_home
      end
    end
    fixture do
      prior_home = ENV["CODEX_HOME"]
      ENV["CODEX_HOME"] = @root
      assert_fixture_refusal
      refute File.exist?("#{@data}-fixtures")
    ensure
      ENV["CODEX_HOME"] = prior_home
    end
  end

  # Exclusive creation refuses occupied roots and leaves their bytes untouched.
  def test_occupied_invocation_directory_is_never_reused
    fixture do
      invocation = "12345678-1234-1234-1234-123456789abc"
      path = File.join("#{@data}-fixtures", invocation)
      FileUtils.mkdir_p(path, mode: 0o700)
      File.binwrite(File.join(path, "sentinel"), "\x00\xff".b)
      SecureRandom.stub(:uuid, invocation) { assert_fixture_refusal }
      assert_equal "\x00\xff".b, File.binread(File.join(path, "sentinel"))
      assert_equal "creating", report.fetch("fixture").fetch("state")
    end
  end

  # A fixture-denying sandbox still blocks reservation; merely authorizing it in
  # argv cannot stand in for the host's required native positive probe.
  def test_denied_fixture_probe_refuses_worker
    %w[fixture_denied fixture_parent_leaky].each do |mode|
      fixture do
        write_fake(mode)
        assert_fixture_refusal(launcher(real_sandbox_probe: true))
        assert_equal "ready", report.fetch("fixture").fetch("state")
        assert File.directory?(report.fetch("fixture").fetch("path"))
      end
    end
  end

  # Replacing an established directory between probe and reservation fails
  # closed. The displaced original and replacement both survive for judgment.
  def test_root_identity_change_before_reservation_refuses_worker
    %i[child container].each do |kind|
      fixture do
        worker = launcher
        worker.define_singleton_method(:sandbox_probe!) do |_inventory, _workspace, _run_dir|
          path = @report.fetch("fixture").fetch("path")
          path = File.dirname(path) if kind == :container
          File.rename(path, "#{path}-preserved")
          Dir.mkdir(path, 0o700)
        end
        assert_fixture_refusal(worker)
      end
    end
  end

  # Errors after provisioning retain the exact per-attempt directory and do not
  # recursively remove symlinks that point at protected evidence.
  def test_worker_failure_retains_fixture_and_evidence
    fixture(process: true) do
      write_fake("failure")
      assert_equal 7, launcher.launch("T")
      record = report
      path = record.fetch("fixture").fetch("path")
      File.symlink(@data, File.join(path, "protected-link"))
      assert_equal "fixture content", File.binread(File.join(path, "retained.txt"))
      assert File.file?(record.fetch("final_path"))
      assert File.file?(File.join(@data, "tasks", "T.yml"))
    end
  end
end
