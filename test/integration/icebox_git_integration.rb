# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../launcher_support"
require_relative "../git_contract/observations"
require "timeout"

# Cold public CLI proof with disposable Git authorities and a finite fake Codex.
# The fake executable models only the external worker/sandbox boundary.
class IceboxGitIntegrationTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  # Proves deferral, factual inventory, refusal without side effects and explicit
  # restoration continuously, using a fresh process for every public command.
  def test_public_cli_journey
    journey_fixture do
      before = definition_bytes
      initial = JSON.parse(cli!("next", "--json"))
      assert_equal %w[TST-A TST-B], initial.dig("recommendations", "starts").map { |row| row.fetch("id") }
      assert_equal 1, initial.dig("recommendations", "starts", 0, "downstream", "immediate_unlock_count")

      cli!("icebox", "TST-A", "--reason", "Revisit after profiling")
      state = @store.load("TST-A")
      details = cli!("status", "TST-A")
      assert_includes details, "TST-A: ICEBOX"
      assert_includes details, "Revisit after profiling"
      assert_includes details, "act unicebox TST-A"
      assert_includes cli!("status", "--icebox"), "TST-A: ICEBOX"
      document = JSON.parse(cli!("next", "--json"))
      assert_equal "agent-coding-tool-next/v0.1", document.fetch("schema_version")
      deferred = document.dig("facts", "tasks").find { |row| row.fetch("id") == "TST-A" }
      assert_equal "ICEBOX", deferred.fetch("status")
      assert_equal "READY", deferred.fetch("lifecycle_status")
      assert_equal state.fetch("icebox"), deferred.fetch("icebox")
      assert_equal ["TST-B"], document.dig("recommendations", "starts").map { |row| row.fetch("id") }
      assert_empty document.dig("recommendations", "waiting_capacity")
      blocked = document.dig("facts", "tasks").find { |row| row.fetch("id") == "TST-C" }
      assert_equal "BLOCKED", blocked.fetch("status")
      assert_includes blocked.fetch("reason"), "TST-A"
      human_next = cli!("next")
      refute_includes human_next, "act prepare TST-A"
      refute_includes human_next, "act start TST-A"
      assert_includes human_next, "act prepare TST-B"

      [%w[prepare TST-A], %w[launch TST-A --codex]].each do |args|
        _output, error, status = cli(*args)
        assert_equal 2, status.exitstatus, "Icebox guard missing for #{args.inspect}: #{error}"
        assert_includes error, "ICEBOX"
        assert_equal state, @store.load("TST-A")
        assert_empty Dir.glob(File.join(@data, "state/prompts/*"))
        refute File.exist?("#{@data}-runs/TST-A")
        refute File.exist?(File.join(@root, "worker-pid"))
      end
      dashboard = cli!("status")
      refute_match(/^TST-A:/, dashboard)
      assert_equal "1 Icebox task from families (TST)\n", dashboard.lines.last
      assert_equal 1, dashboard.scan(/^\d+ Icebox/).length
      all = cli!("status", "--all")
      assert_operator all.index("TST-C: BLOCKED"), :<, all.index("TST-A: ICEBOX")

      cli!("unicebox", "TST-A")
      assert_equal "READY", JSON.parse(cli!("next", "--json")).dig("facts", "tasks").find { |row| row["id"] == "TST-A" }.fetch("status")
      cli!("prepare", "TST-A")
      assert @store.load("TST-A")["snapshot"]
      assert_equal before, definition_bytes
      # This positive control traverses the same automatic preparation path
      # and fake worker boundary the deferred launch must never reach.
      cli!("launch", "TST-B", "--codex", "--reasoning", "high")
      assert File.file?(File.join(@root, "worker-pid"))
      assert @store.load("TST-B")["started_at"]
    end
  end

  # Removing the preparation guard makes the very same journey fail at its
  # safety assertion, proving a refusal cannot pass due to an unready fixture.
  def test_guard_removal_negative_control
    observer = GitContract::Native.new(environment: { "ACT19_REMOVE_PREPARE_GUARD" => "1" }, seconds: 20)
    output, error, status = observer.capture3(RbConfig.ruby, "-Ilib:test", __FILE__, "--name", "test_public_cli_journey")
    refute status.success?, error
    assert_includes output, "Icebox guard missing"
    assert_includes output, "1 failures"
    assert_includes output, "0 errors"
  end

  # Qualifies exact binary/text streams and real status for the reused observer.
  def test_process_observer_preserves_bytes_and_status
    observer = GitContract::Native.new
    output, error, status = observer.capture3(RbConfig.ruby, "-e", 'STDOUT.binmode; STDERR.binmode; STDOUT.write("text\\n".b + [0,255].pack("C*")); STDERR.write([254,0].pack("C*")); exit 7')
    assert_equal "text\n".b + [0, 255].pack("C*"), output
    assert_equal [254, 0].pack("C*"), error
    assert_equal 7, status.exitstatus
  end

  # File barriers pause a real state writer while it holds the shared launch
  # reservation. Both Icebox/preparation and Icebox/automatic-launch orders have
  # one winner; the losing cold CLI cannot produce a task reservation or worker.
  def test_cli_preparation_and_auto_launch_races
    %w[icebox prepare launch].each do |first|
      journey_fixture do
        barrier = File.join(@root, "barrier")
        command = [first, "TST-A"]
        command << "--codex" if first == "launch"
        worker = Thread.new { cli(*command, environment: { "ACT19_BARRIER" => barrier }) }
        Timeout.timeout(10) { sleep 0.005 until File.file?("#{barrier}.entered") }
        opponents = first == "icebox" ? [%w[prepare TST-A], %w[launch TST-A --codex]] : [%w[icebox TST-A]]
        opponents.each do |opponent|
          _output, error, status = cli(*opponent)
          assert_equal 2, status.exitstatus, error
          assert_includes error, "reservation busy"
          refute File.exist?(File.join(@root, "worker-pid"))
        end
        File.write("#{barrier}.release", "release")
        _output, error, status = Timeout.timeout(20) { worker.value }
        assert status.success?, error
        state = @store.load("TST-A")
        if first == "icebox"
          assert state["icebox"]
          refute state["snapshot"]
        else
          assert state["snapshot"]
          refute state["icebox"]
        end
        assert_equal first == "launch", !!state["started_at"]
        assert_equal first == "launch", File.exist?(File.join(@root, "worker-pid"))
        assert_equal first == "launch", File.directory?("#{@data}-runs/TST-A")
      ensure
        File.write("#{barrier}.release", "release") if barrier
        worker&.join(20)
      end
    end
  end

  private

  # Copies production CLI bytes into a disposable tool root, keeping private
  # test data outside that source as required by Launcher's ownership checks.
  # Uses one immutable local Git seed; never touches operator repositories.
  def journey_fixture
    fixture(git: true, process: true) do
      File.unlink(File.join(@data, "tasks/T.yml"))
      @tool = File.join(@root, "tool")
      FileUtils.mkdir_p(@tool)
      %w[lib bin].each { |path| FileUtils.cp_r(File.expand_path("../../#{path}", __dir__), @tool) }
      FileUtils.mkdir_p(File.join(@tool, "test"))
      FileUtils.cp(File.expand_path("../coding_skill_support.rb", __dir__), File.join(@tool, "test"))
      # B has an independent local authority, so A's preparation cannot reserve it.
      second = File.join(@root, "second")
      second_remote = File.join(@root, "second.git")
      FileUtils.cp_r(File.join(TestHelpers.git_seed.fetch(:root), "ordinary"), second)
      FileUtils.cp_r(File.join(TestHelpers.git_seed.fetch(:root), "remote.git"), second_remote)
      setup_git("remote", "set-url", "origin", second_remote, chdir: second)
      write_task(@data, id: "TST-A", repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      write_task(@data, id: "TST-B", repositories: { "repo" => { "access" => "write", "path" => second } })
      write_task(@data, id: "TST-C", depends_on: ["TST-A"], repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      @preload = File.join(@root, "guard-control.rb")
      File.write(@preload, <<~'RUBY')
        require "agent_coding_tool"
        require "timeout"
        if ENV["ACT19_REMOVE_PREPARE_GUARD"]
          class AgentCodingTool::Coordinator
            # Test-only negative control: remove the lifecycle deferral guard.
            def refuse_icebox!(_id, _state) = nil
          end
        end
        if ENV["ACT19_BARRIER"]
          class AgentCodingTool::StateStore
            alias_method :icebox_fixture_write, :write
            # Test-only rendezvous at a real write, before state replacement.
            def write(id, state)
              if id == "TST-A"
                barrier = ENV.fetch("ACT19_BARRIER")
                File.write("#{barrier}.entered", "entered")
                Timeout.timeout(10) { sleep 0.005 until File.file?("#{barrier}.release") }
              end
              icebox_fixture_write(id, state)
            end
          end
        end
      RUBY
      yield
    end
  end

  # Invokes the actual native binary with raw bytes and a 20-second owned-group
  # deadline. External Codex is always the finite fixture executable.
  def cli(*args, environment: {})
    environment = { "PATH" => "#{@root}:#{ENV.fetch('PATH')}", "AGENT_CODING_TOOL_DATA_DIR" => @data,
                    "GIT_CEILING_DIRECTORIES" => @root,
                    "RUBYOPT" => "-I#{@tool}/lib -r#{@tool}/test/coding_skill_support.rb -r#{@preload}" }.merge(environment)
    GitContract::Native.new(environment: environment, seconds: 20)
                       .capture3(RbConfig.ruby, File.join(@tool, "bin/agent-coding-tool"), *args)
  end

  # Asserts public success and returns raw stdout, retaining diagnostic stderr.
  def cli!(*args)
    output, error, status = cli(*args)
    assert status.success?, "#{args.inspect}: #{error}"
    output
  end

  # Returns exact task-definition bytes for preservation assertions.
  def definition_bytes
    Dir.glob(File.join(@data, "tasks/*.yml")).to_h { |path| [path, File.binread(path)] }
  end
end
