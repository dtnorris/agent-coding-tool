# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'launcher_support'
require 'timeout'

# Disposable native Git and public CLI; Codex and lsof are declared fake boundaries.
class QuiescentLaunchTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  # Calls the public CLI in a cold process, with a finite timeout and fixture data.
  def cli(*arguments)
    Open3.popen3({ 'PATH' => "#{@root}:#{ENV.fetch('PATH')}", 'AGENT_CODING_TOOL_DATA_DIR' => @data },
                RbConfig.ruby, File.join(Dir.pwd, 'bin/agent-coding-tool'), *arguments, pgroup: true) do |input, output, error, child|
      input.close
      readers = [output, error].map { |stream| Thread.new { stream.read } }
      begin
        status = Timeout.timeout(15) { child.value }
        [*readers.map(&:value), status]
      rescue Timeout::Error
        Process.kill('KILL', -child.pid) rescue Errno::ESRCH
        child.value
        readers.each(&:join)
        raise
      end
    end
  end

  # Prepares B beside a manually reserved A and preserves dirty candidate bytes.
  def manual_pair
    File.write(File.join(@root, 'lsof'), "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, File.join(@root, 'lsof'))
    write_task(@data, id: 'A', repositories: { 'repo' => { 'access' => 'write', 'path' => @ordinary } })
    %w[A T].each { |id| assert cli('prepare', id).last.success? }
    assert cli('start', 'A').last.success?
    File.binwrite(File.join(@ordinary, 'file.txt'), "staged\n")
    setup_git('add', 'file.txt', chdir: @ordinary)
    File.binwrite(File.join(@ordinary, 'file.txt'), "unstaged\n")
    File.binwrite(File.join(@ordinary, 'candidate.bin'), "\x00\xffcandidate".b)
    @preserved = [@store.state_path('A'), @store.load('A').fetch('prompt_path'),
                  File.join(@ordinary, '.git/index'), File.join(@ordinary, 'file.txt'),
                  File.join(@ordinary, 'candidate.bin')].to_h { |path| [path, File.binread(path)] }
  end

  # Compares lifecycle, prompt, index and candidate bytes; liveness is not inferred.
  def assert_a_preserved
    assert_equal @preserved, @preserved.to_h { |path, _| [path, File.binread(path)] }
    assert_equal 'IN_FLIGHT', @coordinator.status('A').fetch('status')
    refute File.exist?("#{@data}-runs/A")
  end

  # Initial incident reproduction: an override does not authenticate manual work.
  def test_unattested_manual_reservation_refuses_without_touching_a
    fixture(git: true, process: true) do
      manual_pair
      _out, error, status = cli('launch', 'T', '--codex', '--allow-write-collision')
      assert_equal 2, status.exitstatus
      assert_match(/manual worker isolation and activity are unverified/, error)
      refute @store.load('T')['started_at']
      refute File.exist?(File.join(@root, 'worker-pid'))
      assert_a_preserved
    end
  end

  # Exercises review and explicit assertion as separate cold CLI handoffs.
  def authorize
    out, error, status = cli('quiescence', 'review', 'A', '--for', 'T', '--repository', 'repo')
    assert status.success?, error
    review = JSON.parse(out)
    out, error, status = cli('quiescence', 'approve', 'A', '--for', 'T', '--review', review.fetch('review_sha256'),
                            '--activity', 'ended', '--all-writers-accounted-for', '--reason', 'External fixture exited; preserve candidate')
    assert status.success?, error
    JSON.parse(out)
  end

  # Continuous cold CLI journey: real worktrees/branches/prompt/process/locks;
  # Codex and lsof supply deterministic execution, sandbox and observation responses.
  def test_reviewed_quiescence_launches_isolated_worker_without_delivery
    fixture(git: true, process: true) do
      manual_pair
      authorize
      FileUtils.mkdir_p("#{@data}-validation", mode: 0o700)
      File.write("#{@data}-validation/T.yml", 'must not be consulted or published')
      out, error, status = cli('launch', 'T', '--codex', '--allow-write-collision', '--reasoning', 'high')
      assert status.success?, error
      path = Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)
      report = JSON.parse(File.binread(path))
      assert_equal 'exited', report.fetch('status')
      assert_equal @base, setup_git('rev-parse', 'HEAD', chdir: report.fetch('workspace'))
      assert_equal 'act/T/attempt-1', setup_git('branch', '--show-current', chdir: report.fetch('workspace'))
      refute_equal @ordinary, report.fetch('workspace')
      assert_includes File.binread(report.fetch('stdin_path')), File.binread(@store.load('T').fetch('prompt_path'))
      assert_equal 'Final worker response', File.binread(report.fetch('final_path'))
      assert_equal [], report.dig('collision_authorization', 'verified_conflicts')
      assert_equal 'operator_attested_ended', report.fetch('quiescent_manual_authorization').first.fetch('activity')
      assert_operator report.dig('sandbox_probe', 'protected_paths'), :>=, 4
      assert_includes error, 'DELIVERY DEFERRED'
      refute File.exist?(File.join(File.dirname(path), 'delivery.json'))
      assert_equal 'IN_FLIGHT', @coordinator.status('T').fetch('status')
      assert_a_preserved
      _out, error, status = cli('deliver', 'T')
      assert_equal 2, status.exitstatus
      assert_includes error, 'managed delivery is disabled'
      out, error, status = cli('status', 'T')
      assert status.success?, error
      assert_includes out, 'operator-attested quiescence'
      public_state = File.binread(@store.state_path('T'))
      refute_includes public_state, 'External fixture exited'
      refute_includes public_state, 'supplied_workspaces'
      refute_includes File.binread(report.fetch('prompt_path')), 'External fixture exited'
      record = YAML.safe_load_file(Dir.glob("#{@data}-runs/.quiescence/*.yml").fetch(0))
      assert_equal 'consumed', record.fetch('status')
      assert_equal report.fetch('invocation_id'), record.fetch('invocation_id')
      assert_a_preserved
    end
  end

  # Refusal helper checks no new managed process or mutation of A's bytes.
  def assert_launch_refused(pattern = nil)
    _out, error, status = cli('launch', 'T', '--codex', '--allow-write-collision')
    assert_equal 2, status.exitstatus, error
    assert_match(pattern, error) if pattern
    refute File.exist?(File.join(@root, 'worker-pid'))
    refute @store.load('T')['started_at']
    assert_a_preserved
  end

  # Rewrites fixture evidence, optionally resealing to exercise semantic checks
  # beyond damage detection. This is a test producer, never operator guidance.
  def alter_review
    path = Dir.glob("#{@data}-runs/.quiescence/*.yml").fetch(0)
    value = YAML.safe_load_file(path)
    yield value
    File.binwrite(path, YAML.dump(value))
  end

  # Unknown, incomplete and explicitly active assertions never become approvals.
  def test_explicit_assertions_and_exact_scope_are_required
    %w[active unknown incomplete wrong_review wrong_target wrong_repository].each do |scenario|
      fixture(git: true, process: true) do
        manual_pair
        repo = scenario == 'wrong_repository' ? 'other' : 'repo'
        out, error, status = cli('quiescence', 'review', 'A', '--for', 'T', '--repository', repo)
        if scenario == 'wrong_repository'
          assert_equal 2, status.exitstatus
        else
          assert status.success?, error
          value = JSON.parse(out)
          activity = %w[active unknown].include?(scenario) ? scenario : 'ended'
          args = ['quiescence', 'approve', 'A', '--for', scenario == 'wrong_target' ? 'B' : 'T',
                  '--review', scenario == 'wrong_review' ? 'f' * 64 : value.fetch('review_sha256'),
                  '--activity', activity, '--reason', 'fixture']
          args << '--all-writers-accounted-for' unless scenario == 'incomplete'
          assert_equal 2, cli(*args).last.exitstatus, scenario
        end
        assert_launch_refused
      end
    end
  end

  # Corrupt, partial, altered, expired and duplicate approvals fail before work.
  def test_approval_integrity_expiry_and_replay
    %w[tamper partial corrupt expired duplicate consumed].each do |scenario|
      fixture(git: true, process: true) do
        manual_pair
        value = authorize
        path = Dir.glob("#{@data}-runs/.quiescence/*.yml").fetch(0)
        case scenario
        when 'tamper' then alter_review { |row| row['reason'] = 'changed' }
        when 'partial' then alter_review { |row| row.delete('activity') }
        when 'corrupt' then File.write(path, 'broken: [')
        when 'expired'
          alter_review do |row|
            row['reviewed_at'] = (Time.now.utc - 301).iso8601(6)
            original = row.slice('schema', 'older', 'target', 'reviewed_at').merge('status' => 'review', 'observation' => row['observation'])
            row['review_sha256'] = Digest::SHA256.hexdigest(JSON.generate(original))
            row['seal'] = Digest::SHA256.hexdigest(JSON.generate(row.reject { |name, _| name == 'seal' }))
          end
        when 'duplicate'
          assert_equal 2, cli('quiescence', 'approve', 'A', '--for', 'T', '--review', value.fetch('review_sha256'),
                              '--activity', 'ended', '--all-writers-accounted-for', '--reason', 'again').last.exitstatus
          File.unlink(path) # Negative control: removing the handoff breaks the same journey.
        when 'consumed'
          alter_review do |row|
            row.merge!('status' => 'consumed', 'invocation_id' => 'already-used', 'consumed_at' => Time.now.utc.iso8601(6))
            row['seal'] = Digest::SHA256.hexdigest(JSON.generate(row.reject { |name, _| name == 'seal' }))
          end
        end
        assert_launch_refused
      end
    end
  end

  # Freshness binds actual preparation/configuration and preserved source state.
  def test_preparation_authority_head_and_source_drift
    %w[preparation head authority content new_worker].each do |scenario|
      fixture(git: true, process: true, mutable_remote: true) do
        manual_pair
        authorize
        case scenario
        when 'preparation'
          state = @store.load('T'); state['snapshot']['repo']['pushed_sha'] = 'e' * 40; @store.write('T', state)
        when 'head'
          setup_git('commit', '-m', 'fixture head drift', chdir: @ordinary)
          # The operator's changed index is now the expected preserved data.
          @preserved[File.join(@ordinary, '.git/index')] = File.binread(File.join(@ordinary, '.git/index'))
        when 'authority'
          setup_git('remote', 'set-url', 'origin', File.join(@root, 'missing.git'), chdir: @ordinary)
        when 'content'
          File.binwrite(File.join(@ordinary, 'candidate.bin'), 'concurrent change')
          @preserved[File.join(@ordinary, 'candidate.bin')] = 'concurrent change'
        when 'new_worker'
          write_task(@data, id: 'C', repositories: { 'repo' => { 'access' => 'write', 'path' => @ordinary } })
          assert cli('prepare', 'C').last.success?
          assert cli('start', 'C').last.success?
        end
        _out, _error, status = cli('launch', 'T', '--codex', '--allow-write-collision')
        assert_equal 2, status.exitstatus, scenario
        refute File.exist?(File.join(@root, 'worker-pid'))
        refute @store.load('T')['started_at']
        # Authority/preparation drift may make status unavailable; byte retention
        # remains independently checked without inventing a current lifecycle.
        assert_equal @preserved, @preserved.to_h { |path, _| [path, File.binread(path)] }
      end
    end
  end

  # Native registry completeness, path ownership and links are checked at review.
  def test_unknown_foreign_symlinked_and_overlapping_workspaces
    %w[unknown foreign symlink overlap].each do |scenario|
      fixture(git: true, process: true) do
        manual_pair
        extra = File.join(@root, 'external')
        args = ['quiescence', 'review', 'A', '--for', 'T', '--repository', 'repo']
        case scenario
        when 'unknown'
          setup_git('worktree', 'add', '--detach', extra, @base, chdir: @ordinary)
        when 'foreign'
          FileUtils.mkdir_p(extra)
          setup_git('init', extra)
          args += ['--workspace', extra]
        when 'symlink'
          File.symlink(@ordinary, extra)
          args += ['--workspace', extra]
        when 'overlap'
          config = YAML.safe_load_file(File.join(@data, 'config.yml'))
          config['worktree_root'] = File.dirname(@ordinary)
          # The target container now covers the external workspace.
          setup_git('worktree', 'add', '--detach', File.join(@root, 'T'), @base, chdir: @ordinary)
          File.write(File.join(@data, 'config.yml'), YAML.dump(config))
          args += ['--workspace', File.join(@root, 'T')]
        end
        assert_equal 2, cli(*args).last.exitstatus, scenario
        assert_launch_refused
      end
    end
  end

  # All known native external locations may be dirty; none is imported/cleaned.
  def test_dirty_external_worktree_is_preserved_when_explicitly_reviewed
    fixture(git: true, process: true) do
      manual_pair
      external = File.join(@root, 'external')
      setup_git('worktree', 'add', '--detach', external, @base, chdir: @ordinary)
      File.binwrite(File.join(external, 'unfinished'), 'keep')
      out, error, status = cli('quiescence', 'review', 'A', '--for', 'T', '--repository', 'repo', '--workspace', external)
      assert status.success?, error
      review = JSON.parse(out)
      assert_equal 0, cli('quiescence', 'approve', 'A', '--for', 'T', '--review', review.fetch('review_sha256'),
                         '--activity', 'ended', '--all-writers-accounted-for', '--reason', 'all locations reviewed').last.exitstatus
      assert_equal 0, cli('launch', 'T', '--codex', '--allow-write-collision').last.exitstatus
      assert_equal 'keep', File.binread(File.join(external, 'unfinished'))
      handoff = JSON.parse(File.binread(Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)))
      refute_includes File.binread(handoff.fetch('stdin_path')), external
      refute_includes File.binread(@store.state_path('T')), external
      assert_a_preserved
    end
  end

  # A real finite external process supplies a contradictory local open-file fact;
  # incomplete/unavailable lsof also refuses instead of treating silence as proof.
  def test_live_and_unknown_local_activity_block_even_after_approval
    %w[live unknown missing timeout].each do |scenario|
      fixture(git: true, process: true) do
        manual_pair
        authorize
        probe = File.join(@root, 'lsof')
        if scenario == 'live'
          child = Process.spawn(RbConfig.ruby, '-e', 'sleep 5', chdir: @ordinary)
          # Declare the OS probe boundary; the finite process is independently
          # alive, but no unauthenticated PID is promoted to managed identity.
          File.write(probe, "#!/bin/sh\nprintf 'fixture active process\\n'\nexit 0\n")
        elsif scenario == 'unknown'
          File.write(probe, "#!/bin/sh\nprintf 'incomplete' >&2\nexit 1\n")
        elsif scenario == 'timeout'
          File.write(probe, "#!/bin/sh\nsleep 30\nexit 1\n")
        else
          File.write(probe, "#!/bin/sh\nexit 127\n")
        end
        assert_launch_refused(/activity|workspace/)
      ensure
        Process.waitpid(child) if child
        child = nil
      end
    end
  end

  # Mutates a fixture boundary during the real post-worktree/sandbox handoff.
  # Admission must recheck and refuse before process spawn or A state mutation.
  def test_post_worktree_races_refuse_changed_authorization_scope_and_writers
    %w[approval worktree new_worker].each do |scenario|
      fixture(git: true, process: true) do
        manual_pair
        authorize
        instance = launcher(real_sandbox_probe: true)
        original = instance.method(:sandbox_probe!)
        test = self
        data, ordinary, coordinator = @data, @ordinary, @coordinator
        instance.define_singleton_method(:sandbox_probe!) do |*args|
          original.call(*args)
          case scenario
          when 'approval'
            path = Dir.glob("#{data}-runs/.quiescence/*.yml").fetch(0)
            File.write(path, 'changed: approval')
          when 'worktree'
            File.write(File.join(ordinary, 'candidate.bin'), 'race')
          when 'new_worker'
            test.write_task(data, id: 'C', repositories: { 'repo' => { 'access' => 'write', 'path' => ordinary } })
            coordinator.prepare('C')
            coordinator.start('C')
          end
        end
        # lsof is a declared external boundary for native fixture tests too.
        previous = ENV['PATH']
        ENV['PATH'] = "#{@root}:#{previous}"
        assert_raises(AgentCodingTool::InvalidState) { instance.launch('T', allow_write_collision: true) }
        refute @store.load('T')['started_at']
        refute File.exist?(File.join(@root, 'worker-pid'))
        if scenario == 'worktree'
          @preserved[File.join(@ordinary, 'candidate.bin')] = 'race'
        end
        assert_a_preserved
      ensure
        ENV['PATH'] = previous if previous
      end
    end
  end

  # Lock ownership serializes review/approval/start/launch; a competing launcher
  # loses before creating evidence or a worker. Neither contender mutates A.
  def test_shared_reservation_lock_and_concurrent_launch
    fixture(git: true, process: true) do
      manual_pair
      value = authorize
      lock_path = "#{@data}-runs/launch.lock"
      File.open(lock_path, File::RDWR) do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
        assert_equal 2, cli('quiescence', 'review', 'A', '--for', 'T', '--repository', 'repo').last.exitstatus
        assert_equal 2, cli('quiescence', 'approve', 'A', '--for', 'T', '--review', value.fetch('review_sha256'),
                            '--activity', 'ended', '--all-writers-accounted-for', '--reason', 'competing').last.exitstatus
        assert_launch_refused(/reservation lock/)
      end
      # Two cold CLI attempts contend on the same reservation boundary.
      results = 2.times.map { Thread.new { cli('launch', 'T', '--codex', '--allow-write-collision') } }.map(&:value)
      assert_equal [0, 2], results.map { |row| row.last.exitstatus }.sort
      assert_equal 1, Dir.glob("#{@data}-runs/T/*/handoff.json").length
      assert_a_preserved
    end
  end

  # A managed attempt without verifiable ownership cannot use a manual approval.
  # Fake authentication/sandbox failures retain every older byte and no process.
  def test_unknown_managed_attempt_authentication_and_sandbox_refuse
    %w[managed auth sandbox].each do |scenario|
      fixture(git: true, process: true) do
        manual_pair
        authorize
        if scenario == 'managed'
          directory = "#{@data}-runs/A/unknown"
          FileUtils.mkdir_p(directory)
          File.write(File.join(directory, 'handoff.json'), JSON.generate(
            'schema_version' => AgentCodingTool::Launcher::SCHEMA, 'task_id' => 'A',
            'preparation' => @store.load('A').fetch('snapshot'), 'status' => 'running'))
        elsif scenario == 'auth'
          actual = File.realpath(@fake)
          File.unlink(@fake)
          File.write(@fake, "#!/bin/sh\nif [ \"$1 $2\" = \"login status\" ]; then exit 1; fi\nexec '#{actual}' \"$@\"\n")
          File.chmod(0o755, @fake)
        else
          write_fake('leaky')
        end
        _out, error, status = cli('launch', 'T', '--codex', '--allow-write-collision')
        assert_equal 2, status.exitstatus, error
        refute @store.load('T')['started_at']
        refute File.exist?(File.join(@root, 'worker-pid'))
        assert_equal @preserved, @preserved.to_h { |path, _| [path, File.binread(path)] }
      end
    end
  end

  # Atomic private approval reuses StateStore: failure before rename retains the
  # complete old review. A cold retry is explicit and creates no lifecycle state.
  def test_atomic_approval_failure_preserves_original_review
    fixture(git: true, process: true) do
      manual_pair
      value = authorize
      path = Dir.glob("#{@data}-runs/.quiescence/*.yml").fetch(0)
      original = File.binread(path)
      previous = ENV['PATH']; ENV['PATH'] = "#{@root}:#{previous}"
      facility = AgentCodingTool::QuiescenceReview.new(data_root: @data, coordinator: @coordinator, source_root: Dir.pwd)
      File.stub(:rename, ->(*) { raise IOError, 'injected rename failure' }) do
        assert_raises(IOError) { facility.review('A', 'T', repositories: ['repo']) }
      end
      assert_equal original, File.binread(path)
      assert_equal value.fetch('review_sha256'), facility.verify!('A', 'T').fetch('review_sha256')
      assert_a_preserved
    ensure
      ENV['PATH'] = previous if previous
    end
  end

  # Initial publication is atomic too: no partial approval survives a failed
  # rename; post-rename sync uncertainty retains a complete inspectable record.
  def test_initial_review_atomicity_and_postpublication_uncertainty
    fixture(git: true, process: true) do
      manual_pair
      previous = ENV['PATH']; ENV['PATH'] = "#{@root}:#{previous}"
      facility = AgentCodingTool::QuiescenceReview.new(data_root: @data, coordinator: @coordinator, source_root: Dir.pwd)
      File.stub(:rename, ->(*) { raise IOError, 'injected first rename failure' }) do
        assert_raises(IOError) { facility.review('A', 'T', repositories: ['repo']) }
      end
      assert_empty facility.records!
      directory = "#{@data}-runs/.quiescence"
      assert_empty Dir.children(directory)
      original = File.method(:open)
      broken = Object.new
      broken.define_singleton_method(:fsync) { raise IOError, 'injected directory sync' }
      replacement = lambda do |path, *args, **options, &block|
        path == directory ? block.call(broken) : original.call(path, *args, **options, &block)
      end
      error = File.stub(:open, replacement) do
        assert_raises(AgentCodingTool::InvalidState) { facility.review('A', 'T', repositories: ['repo']) }
      end
      assert_includes error.message, 'published'
      assert_equal 'review', facility.records!.fetch(0).fetch('status')
      assert_a_preserved
    ensure
      ENV['PATH'] = previous if previous
    end
  end

  # A foreign/link/nonprivate namespace or lock is never accepted as private
  # authorization. These manipulations are confined to the disposable evidence.
  def test_unsafe_private_namespace_and_lock_refuse
    %w[namespace_symlink record_symlink nonprivate_lock].each do |scenario|
      fixture(git: true, process: true) do
        manual_pair
        authorize
        directory = "#{@data}-runs/.quiescence"
        if scenario == 'namespace_symlink'
          File.rename(directory, "#{directory}-original")
          File.symlink("#{directory}-original", directory)
        elsif scenario == 'record_symlink'
          path = Dir.glob("#{directory}/*.yml").fetch(0)
          File.rename(path, "#{@root}/record.yml")
          File.symlink("#{@root}/record.yml", path)
        else
          File.chmod(0o644, "#{@data}-runs/launch.lock")
        end
        assert_launch_refused
      end
    end
  end

end
