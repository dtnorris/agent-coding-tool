# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "open3"
require "rbconfig"

module AgentCodingTool
  # Execution evidence is deliberately separate from canonical lifecycle state.
  class Launcher
    SCHEMA = "agent-coding-tool-run/v1"
    TERMINAL = %w[exited invalid_final interrupted child_start_failed preflight_failed].freeze
    REASONING = %w[minimal low medium high xhigh].freeze

    def initialize(coordinator:, data_root:, source_root:, out: $stdout, err: $stderr,
                   codex: "codex", spawner: Process.method(:spawn))
      @coordinator, @data_root, @source_root = coordinator, File.realpath(data_root), File.realpath(source_root)
      @out, @err, @codex, @spawner = out, err, codex, spawner
      @run_root = "#{@data_root}-runs"
    end

    def launch(id, model: nil, reasoning: nil)
      raise InvalidTask, "launch: unsafe task ID" unless id&.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      safe_root!
      raise InvalidState, "launch: foreign/symlinked lock" if File.symlink?(File.join(@run_root, "launch.lock"))
      File.open(File.join(@run_root, "launch.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        raise InvalidState, "launch: another launcher holds the reservation lock" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        run_locked(id, model, reasoning, lock)
      end
    rescue Psych::Exception, KeyError, TypeError, ArgumentError => e
      raise InvalidTask, "launch: malformed task/preparation: #{e.message}"
    rescue SystemCallError => e
      raise Error, "launch: #{e.class}: #{e.message}"
    end

    private

    def safe_root!
      # Refuse symlinked evidence paths, including ancestors; never repair them.
      current = @run_root
      loop do
        raise InvalidState, "launch: symlinked evidence path: #{current}" if File.symlink?(current)
        break if current == File.dirname(current)
        current = File.dirname(current)
      end
      if @run_root == @source_root || @run_root.start_with?("#{@source_root}/")
        raise InvalidState, "launch: evidence must live outside public source"
      end
      FileUtils.mkdir_p(@run_root, mode: 0o700)
      raise InvalidState, "launch: evidence root must be private and owned by the operator" unless
        File.stat(@run_root).uid == Process.uid && (File.stat(@run_root).mode & 0o077).zero?
    end

    def run_locked(id, model, reasoning, lock)
      task = TaskStore.new(File.join(@data_root, "tasks")).load(id)
      validate_task!(id, task)
      state_store = StateStore.new(File.join(@data_root, "state"))
      state = state_store.load(id)
      raise InvalidState, "#{id}: malformed state" unless state.is_a?(Hash)
      prior_runs!(id, state)
      preflight_codex!(model, reasoning)
      raise InvalidState, "#{id}: already in flight; operator judgment required" if state["started_at"]
      raise InvalidState, "#{id}: recorded outcome; explicit prepare --retry required" if state["result"]
      if state["snapshot"]
        validate_preparation!(task, state)
      else
        raise InvalidState, "#{id}: partial preparation; operator judgment required" unless state.empty? || state == { "id" => id }
        state = @coordinator.prepare(id).fetch("state")
      end
      validate_preparation!(task, state)
      checked_status!(id)
      prompt = File.binread(state.fetch("prompt_path"))
      raise InvalidState, "#{id}: generated prompt changed; explicitly prepare again" unless prompt == @coordinator.launch_prompt(id)
      names = task.fetch("repositories").filter_map { |key, spec| key if spec.fetch("access") == "write" }
      bases = names.map { |name| state.fetch("snapshot").fetch(name) }
      validate_authorities!(task, state)
      reject_unknown_reservations!(bases)
      config = Config.load(File.join(@data_root, "config.yml"))
      root = WorktreeManager.canonical_system_path(config.worktree_root)
      [@source_root, @data_root, @run_root].map { |path| WorktreeManager.canonical_system_path(path) }.each do |protected|
        if root == protected || root.start_with?("#{protected}/") || protected.start_with?("#{root}/")
          raise InvalidState, "launch: worktree root overlaps source or private task data"
        end
      end
      task_root = File.join(@run_root, id)
      raise InvalidState, "#{id}: symlinked task evidence" if File.symlink?(task_root)
      FileUtils.mkdir_p(task_root, mode: 0o700)
      attempt = Dir.children(task_root).length + 1
      run_dir = File.join(task_root, "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(6)}")
      Dir.mkdir(run_dir, 0o700)
      @report_path = File.join(run_dir, "handoff.json")
      manager = WorktreeManager.new(root: config.worktree_root, record_path: File.join(run_dir, "worktrees.json"))
      @report = {
        "schema_version" => SCHEMA, "task_id" => id, "attempt" => attempt,
        "invocation_id" => SecureRandom.uuid, "host_pid" => Process.pid,
        "created_at" => Time.now.utc.iso8601, "prepared_at" => state.fetch("prepared_at"),
        "preparation" => state.fetch("snapshot"), "workspace" => nil,
        "worktrees_path" => File.join(run_dir, "worktrees.json"), "worktrees" => nil,
        "writable_repository" => names.first,
        "writable_authority" => bases.first.slice("remote_url", "branch", "pushed_sha"),
        "writable_repositories" => names,
        "writable_authorities" => names.to_h { |name| [name, state.fetch("snapshot").fetch(name).slice("remote_url", "branch", "pushed_sha")] },
        "status" => "preflight", "session_id" => nil, "session_transcript_path" => nil,
        "jsonl_path" => File.join(run_dir, "stdout.jsonl"),
        "stderr_path" => File.join(run_dir, "stderr.txt"),
        "final_path" => File.join(run_dir, "final.txt"),
        "prompt_path" => File.join(run_dir, "prompt.txt"), "stdin_path" => File.join(run_dir, "stdin.txt"),
        "codex" => @codex, "model" => model, "reasoning" => reasoning,
        "codex_executable_sha256" => @codex_digest, "exec_help_sha256" => @help_digest,
        "worker_recommendation" => task["worker_recommendation"],
        "freshness_source" => "host git ls-remote; CLI has no connected GitHub integration"
      }
      save_report
      begin
        File.binwrite(@report.fetch("prompt_path"), prompt)
        inventory = manager.create(task_id: id, attempt: attempt, task: task, snapshot: state.fetch("snapshot"))
        @report["worktrees"] = inventory
        workspaces = inventory.fetch("entries").select { |entry| entry.fetch("access") == "write" }.to_h { |entry| [entry.fetch("name"), entry.fetch("path")] }
        workspace = workspaces.fetch(names.first)
        @report["workspace"] = workspace
        @report["workspaces"] = workspaces
        save_report
        names.each { |name| verify_checkout!(workspaces.fetch(name), state.fetch("snapshot").fetch(name)) }
        heads = checked_status!(id)
        @report["launch_checked_at"] = Time.now.utc.iso8601
        @report["launch_heads"] = heads
        changed_write!(task, state, @report.fetch("launch_heads"))
        manager.inspect!
        sandbox_probe!(inventory, workspace, run_dir)
        envelope = execution_envelope(workspaces, @report.fetch("launch_heads"))
        File.binwrite(@report.fetch("stdin_path"), prompt + envelope)
        command = codex_command(workspace, model, reasoning, extra_roots: workspaces.values.drop(1))
        @report["argv"] = command
        @report["status"] = "reserving"
        save_report
        @coordinator.start(id)
        @report["status"] = "reserved"
        save_report
        result = execute(command, lock)
        if result == 0 && @report["status"] == "exited"
          delivery = DeliveryManager.new(data_root: @data_root, coordinator: @coordinator)
          if delivery.configured?(id)
            begin
              delivered = delivery.deliver(id, run_dir: run_dir)
              urls = delivered["prs"] ? delivered.fetch("prs").values.map { |pr| pr.fetch("url") } :
                                          [delivered.fetch("pr").fetch("url")]
              @out.puts "Draft PR#{delivered["prs"] ? "s" : ""}: #{urls.join(', ')} (CANDIDATE)"
            rescue StandardError => e
              @err.puts "DELIVERY BLOCKED: #{e.class}: #{e.message}; implementation and evidence retained"
              return 2
            end
          end
        end
        result
      rescue StandardError => e
        @report["status"] = @report["status"] == "preflight" ? "preflight_failed" : "judgment_required"
        @report["error"] = "#{e.class}: #{e.message}"
        save_report
        raise
      ensure
        @err.puts "Run evidence: #{@report_path} (#{@report['status']}); ACT lifecycle requires human review."
      end
    end

    def validate_task!(id, task)
      raise InvalidTask, "#{id}: task identity mismatch" unless task.fetch("id") == id
      writes = task.fetch("repositories").count { |_name, spec| spec.fetch("access") == "write" }
      raise InvalidTask, "#{id}: launch requires a writable repository" unless writes.positive?
      %w[depends_on constraints acceptance].each do |key|
        raise InvalidTask, "#{id}: #{key} must contain strings" unless task.fetch(key, []).all? { |value| value.is_a?(String) }
      end
      task.fetch("repositories").each_value do |spec|
        %w[path remote branch].each do |field|
          raise InvalidTask, "#{id}: invalid repository #{field}" if spec.key?(field) && (!spec[field].is_a?(String) || spec[field].empty?)
        end
        branch = spec.fetch("branch", Config.load(File.join(@data_root, "config.yml")).default_branch)
        raise InvalidTask, "#{id}: unsupported branch (requires main)" unless branch == "main"
      end
    end

    def validate_preparation!(task, state)
      snapshot = state["snapshot"]
      unless snapshot.is_a?(Hash) && snapshot.keys.sort == task.fetch("repositories").keys.sort &&
             state["id"] == task.fetch("id") && state["prepared_at"].is_a?(String) && state["prompt_path"].is_a?(String)
        raise InvalidState, "launch: incompatible preparation"
      end
      begin
        Time.iso8601(state.fetch("prepared_at"))
      rescue ArgumentError
        raise InvalidState, "launch: incompatible preparation timestamp"
      end
      snapshot.each_value do |repo|
        unless repo.is_a?(Hash) && %w[remote_url branch path].all? { |key| repo[key].is_a?(String) && !repo[key].empty? } &&
               repo["pushed_sha"].is_a?(String) && repo["pushed_sha"].match?(/\A[0-9a-f]{40}\z/)
          raise InvalidState, "launch: missing repository identity/base"
        end
        # V1's authoritative branch contract is main. URL credentials cannot enter evidence.
        raise InvalidState, "launch: unsupported branch (requires main)" unless repo["branch"] == "main"
        remote = repo.fetch("remote_url")
        unless remote.match?(/\Agit@github\.com:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\.git\z/) ||
               remote.match?(/\Ahttps:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?\z/) ||
               remote.start_with?("/")
          raise InvalidState, "launch: unsupported or ambiguous repository remote"
        end
      end
      path = state.fetch("prompt_path")
      expected = File.join(@data_root, "state", "prompts")
      unless File.file?(path) && !File.symlink?(path) && File.realpath(path).start_with?("#{File.realpath(expected)}/")
        raise InvalidState, "launch: missing/foreign prompt artifact"
      end
    end

    def validate_authorities!(task, state)
      config = Config.load(File.join(@data_root, "config.yml"))
      inspector = RepoInspector.new(config)
      task.fetch("repositories").each do |name, spec|
        old = state.fetch("snapshot").fetch(name)
        unless inspector.repository_authority(name, spec) == [old.fetch("remote_url"), old.fetch("branch")]
          raise InvalidState, "#{name}: repository authority changed since preparation"
        end
      end
      writers = state.fetch("snapshot").select { |name, _repo| task.fetch("repositories").fetch(name).fetch("access") == "write" }.values
      readers = state.fetch("snapshot").reject { |name, _repo| task.fetch("repositories").fetch(name).fetch("access") == "write" }.values
      if readers.any? { |repo| writers.any? { |writer| repo.values_at("remote_url", "branch") == writer.values_at("remote_url", "branch") } }
        raise InvalidState, "launch: ambiguous read/write repository aliases"
      end
      if writers.map { |repo| repo.values_at("remote_url", "branch") }.uniq.length != writers.length
        raise InvalidState, "launch: ambiguous writable repository aliases"
      end
    end

    def checked_status!(id)
      heads = nil
      status = @coordinator.statuses([id], strict_freshness: true) { |observed| heads = observed }.first
      raise InvalidState, "#{id}: launch blocked: #{status['status']} #{status['reason']}" unless status.fetch("status") == "PREPARED"
      raise InvalidState, "#{id}: unresolved write collision" unless status.fetch("write_collisions", []).empty?
      status.fetch("state").fetch("snapshot").to_h do |name, repo|
        [name, repo.slice("remote_url", "branch").merge("pushed_sha" => heads.fetch(repo.values_at("remote_url", "branch")))]
      end
    end

    def reports
      paths = Dir.children(@run_root).reject { |entry| entry == "launch.lock" }.flat_map do |task_id|
        task_path = File.join(@run_root, task_id)
        unless File.directory?(task_path) && !File.symlink?(task_path)
          raise InvalidState, "launch: foreign evidence entry; operator judgment required"
        end
        Dir.children(task_path).map do |entry|
          run_path = File.join(task_path, entry)
          path = File.join(run_path, "handoff.json")
          unless File.directory?(run_path) && !File.symlink?(run_path) && File.file?(path)
            raise InvalidState, "launch: partial/foreign run artifacts; operator judgment required"
          end
          path
        end
      end
      paths.map do |path|
        raise InvalidState, "launch: foreign/symlinked evidence" if File.symlink?(path)
        report = JSON.parse(File.read(path))
        unless report.is_a?(Hash) && report["schema_version"] == SCHEMA && report["task_id"].is_a?(String) &&
               report["preparation"].is_a?(Hash) && report["status"].is_a?(String)
          raise InvalidState, "launch: unknown/malformed evidence schema"
        end
        report
      end
    rescue JSON::ParserError
      raise InvalidState, "launch: partial evidence; operator judgment required"
    end

    def prior_runs!(id, state)
      task_root = File.join(@run_root, id)
      if File.exist?(task_root)
        raise InvalidState, "#{id}: foreign/symlinked task evidence" if File.symlink?(task_root) || !File.directory?(task_root)
        Dir.children(task_root).each do |entry|
          path = File.join(task_root, entry)
          unless File.directory?(path) && !File.symlink?(path) && File.file?(File.join(path, "handoff.json"))
            raise InvalidState, "#{id}: partial/foreign run artifacts; operator judgment required"
          end
        end
      end
      reports.select { |report| report["task_id"] == id }.each do |report|
        unless TERMINAL.include?(report["status"])
          raise InvalidState, "#{id}: previous run liveness unknown; operator judgment required"
        end
        if report["prepared_at"] == state["prepared_at"]
          raise InvalidState, "#{id}: preparation already attempted; explicit operator recovery required"
        end
      end
    end

    def reject_unknown_reservations!(bases)
      # A stale manual reservation is not proof that its worker has stopped.
      store = StateStore.new(File.join(@data_root, "state"))
      @coordinator.tasks.each do |task|
        state = store.load(task.fetch("id"))
        next unless state.is_a?(Hash) && state["started_at"]

        snapshot = state.fetch("snapshot")
        if task.fetch("repositories").any? { |name, spec|
          spec.fetch("access") == "write" && bases.any? { |base|
            snapshot.fetch(name).values_at("remote_url", "branch") == base.values_at("remote_url", "branch") }
        }
          raise InvalidState, "launch: #{task.fetch('id')} has an unresolved in-flight reservation; operator judgment required"
        end
      end
      reports.each do |report|
        next if TERMINAL.include?(report["status"])
        if report.fetch("preparation").values.any? { |repo| bases.any? { |base|
          repo.values_at("remote_url", "branch") == base.values_at("remote_url", "branch") } }
          raise InvalidState, "launch: #{report['task_id']} has unresolved execution evidence; operator judgment required"
        end
      end
    end

    def preflight_codex!(model, reasoning)
      raise InvalidTask, "launch: invalid explicit model" if model && !model.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
      raise InvalidTask, "launch: unsupported reasoning" if reasoning && !REASONING.include?(reasoning)
      candidate = if @codex.include?(File::SEPARATOR)
                    @codex
                  else
                    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |directory| File.join(directory, @codex) }
                       .find { |path| File.file?(path) && File.executable?(path) }
                  end
      raise Errno::ENOENT unless candidate && File.file?(candidate) && File.executable?(candidate)
      @codex = File.realpath(candidate)
      @codex_digest = Digest::SHA256.file(@codex).hexdigest
      help, stderr, status = Open3.capture3(worker_env, @codex, "exec", "--help", unsetenv_others: true)
      unless status.success? && %w[--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model].all? { |flag| help.include?(flag) }
        raise Error, "launch: installed Codex lacks required safe exec flags"
      end
      @help_digest = Digest::SHA256.hexdigest(help)
      login_text, _err, login_help = Open3.capture3(worker_env, @codex, "login", "--help", unsetenv_others: true)
      raise Error, "launch: unsupported Codex login command" unless login_help.success? && login_text.include?("status")
      stdout, stderr, status = Open3.capture3(worker_env, @codex, "login", "status", unsetenv_others: true)
      unless status.success? && (stdout + stderr).lines.any? { |line| line.strip == "Logged in using ChatGPT" }
        raise Error, "launch: locally authenticated ChatGPT account required; run codex login (API-key login unsupported)"
      end
    rescue Errno::ENOENT
      raise Error, "launch: Codex CLI missing; install/authenticate locally before launch"
    end

    def worker_env
      %w[HOME PATH TMPDIR CODEX_HOME LANG LC_ALL].to_h { |key| [key, ENV[key]] }.compact
    end

    def codex_command(workspace, model, reasoning, extra_roots: [])
      command = [@codex, "exec", "--ignore-user-config", "--ignore-rules", "--sandbox", "workspace-write",
                 "-c", "approval_policy=never", "-c", 'model_provider="openai"', "-c", 'forced_login_method="chatgpt"',
                 "-c", "sandbox_workspace_write.network_access=false", "-c", "sandbox_workspace_write.writable_roots=#{JSON.generate(extra_roots)}",
                 "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true", "-c", "sandbox_workspace_write.exclude_slash_tmp=true",
                 "-c", "features.multi_agent=false", "--json", "--output-last-message", @report.fetch("final_path")]
      command += ["--model", model] if model
      command += ["-c", "model_reasoning_effort=#{reasoning}"] if reasoning
      command << "-"
    end

    def execution_envelope(workspaces, heads)
      "\n\n--- ACT LOCAL CLI EXECUTION ENVELOPE ---\n" \
        "The exact ACT prompt above retains task authority. Writable worktrees: #{JSON.generate(workspaces)}. Original paths are observations, not writable roots.\n" \
        "Verified worktrees: #{JSON.generate(@report.fetch('worktrees').fetch('entries').map { |entry| entry.slice('name', 'path', 'access', 'branch', 'base_sha', 'remote_url') })}. Read-only worktrees and shared Git administration are outside the writable sandbox.\n" \
        "Host verified remote_url/branch using git ls-remote before launch: #{JSON.generate(heads)}. This is host evidence, not a CLI refresh.\n" \
        "This CLI has no ChatGPT connected GitHub integration. Shell network is disabled; approvals are never allowed. Do not escalate or enable network.\n" \
        "If required external reads, prerequisites or final freshness cannot be established, stop and report that limitation. Do not claim refreshed GitHub refs.\n" \
        "Run one foreground worker only. Do not delegate, commit, stage, push, publish, or change ACT lifecycle/task data. Return a local patch and review handoff.\n" \
        "--- END ACT LOCAL CLI EXECUTION ENVELOPE ---\n"
    end

    def sandbox_probe!(inventory, workspace, run_dir)
      platform = RbConfig::CONFIG.fetch("host_os").match?(/darwin/) ? "macos" :
                 RbConfig::CONFIG.fetch("host_os").match?(/linux/) ? "linux" : nil
      raise InvalidState, "launch: unsupported sandbox platform" unless platform
      help, _stderr, status = Open3.capture3(worker_env, @codex, "sandbox", platform, "--help", unsetenv_others: true)
      raise InvalidState, "launch: installed CLI lacks sandbox probe" unless status.success? && help.include?("--full-auto")
      marker = "ACT sandbox probe #{SecureRandom.hex(12)}"
      targets = [[File.join(run_dir, "sandbox-deny-#{SecureRandom.hex(6)}"), false]]
      inventory.fetch("entries").each do |entry|
        targets << [File.join(entry.fetch("path"), ".act-probe-#{SecureRandom.hex(6)}"), entry.fetch("access") == "write"]
        targets << [File.join(entry.fetch("parent"), ".act-probe-#{SecureRandom.hex(6)}"), false]
      end
      inventory.fetch("entries").map { |entry| entry.fetch("parent") }.uniq.each do |parent|
        admin = git!("rev-parse", "--path-format=absolute", "--git-common-dir", chdir: parent)
        targets << [File.join(admin, "act-probe-#{SecureRandom.hex(6)}"), false]
      end
      begin
        created = []
        targets.each do |path, _allowed|
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(marker) }
          created << path
        end
        stdout, _stderr, result = Open3.capture3(
          worker_env, @codex, "--ignore-user-config",
          "-c", "sandbox_workspace_write.network_access=false",
          "-c", "sandbox_workspace_write.writable_roots=#{JSON.generate(inventory.fetch('entries').select { |entry| entry['access'] == 'write' }.map { |entry| entry.fetch('path') }.drop(1))}",
          "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true",
          "-c", "sandbox_workspace_write.exclude_slash_tmp=true",
          "sandbox", platform, "--full-auto", "--",
          "/bin/sh", "-c", 'for path; do if printf breach > "$path" 2>/dev/null; then printf "1\\n"; else printf "0\\n"; fi; done',
          "act-probe", *targets.map(&:first),
          chdir: workspace, unsetenv_others: true
        )
        results = stdout.lines.map(&:strip)
        targets.each_with_index do |(path, allowed), index|
          actual = File.binread(path)
          unless result.success? && results.length == targets.length &&
                 results[index] == (allowed ? "1" : "0") && actual == (allowed ? "breach" : marker)
            raise InvalidState, "launch: sandbox boundary unverified for #{path}; worker not started"
          end
        end
      ensure
        created.each { |path| File.unlink(path) if File.file?(path) && !File.symlink?(path) }
      end
      @report["sandbox_probe"] = { "platform" => platform, "checked_at" => Time.now.utc.iso8601,
                                   "protected_paths" => targets.count { |_path, allowed| !allowed } }
      save_report
    end

    def git!(*args, chdir: nil)
      stdout, stderr, status = Open3.capture3("git", *args, **(chdir ? { chdir: chdir } : {}))
      raise RepositoryError, "launch git failed: #{stderr.strip}" unless status.success?
      stdout.strip
    end

    def verify_checkout!(workspace, base)
      unless git!("remote", "get-url", base.fetch("remote"), chdir: workspace) == base.fetch("remote_url") &&
             git!("rev-parse", "HEAD", chdir: workspace) == base.fetch("pushed_sha") &&
             git!("status", "--porcelain", "--untracked-files=all", chdir: workspace).empty?
        raise InvalidState, "launch: unsafe checkout identity/state"
      end
      _stdout, _stderr, status = Open3.capture3("git", "symbolic-ref", "-q", "HEAD", chdir: workspace)
      raise InvalidState, "launch: workspace must have a dedicated feature branch" unless status.success?
      directory = workspace
      loop do
        # HOME/.codex is the normal authentication store, not project configuration.
        if directory != File.expand_path(ENV.fetch("HOME", "/nonexistent")) && File.exist?(File.join(directory, ".codex"))
          raise InvalidState, "launch: project/ancestor Codex configuration requires operator judgment"
        end
        break if directory == File.dirname(directory)
        directory = File.dirname(directory)
      end
      if File.exist?(File.join(workspace, ".gitmodules"))
        raise InvalidState, "launch: project Codex configuration or submodules require operator judgment"
      end
    end

    def changed_write!(task, state, heads)
      task.fetch("repositories").each do |name, spec|
        next unless spec.fetch("access") == "write"
        raise InvalidState, "#{name}: STALE INPUT" unless heads.fetch(name).fetch("pushed_sha") == state.fetch("snapshot").fetch(name).fetch("pushed_sha")
      end
    end

    def save_report
      temporary = "#{@report_path}.tmp"
      File.open(temporary, "w", 0o600) { |file| file.write(JSON.pretty_generate(@report) + "\n"); file.flush; file.fsync }
      File.rename(temporary, @report_path)
    end

    def execute(command, lock)
      input_r, input_w = IO.pipe
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      pid = nil
      interrupted = nil
      old_traps = {}
      begin
        %w[INT TERM HUP].each do |signal|
          old_traps[signal] = Signal.trap(signal) do
            interrupted ||= signal
            Process.kill(signal, -pid) if pid
          rescue Errno::ESRCH
            nil
          end
        end
        begin
          pid = @spawner.call(worker_env, *command, chdir: @report.fetch("workspace"),
                              in: input_r, out: stdout_w, err: stderr_w, pgroup: true, unsetenv_others: true)
        rescue SystemCallError => e
          @report.merge!("status" => "child_start_failed", "exit_status" => 127, "error" => e.message)
          save_report
          @err.puts "ERROR: child failed to start; reservation retained, operator recovery required"
          return 127
        end
        [input_r, stdout_w, stderr_w].each(&:close)
        @report.merge!("status" => "running", "child_pid" => pid, "child_started_at" => Time.now.utc.iso8601)
        Process.kill(interrupted, -pid) if interrupted
        save_report
        lock.flock(File::LOCK_UN)
        writer = Thread.new do
          IO.copy_stream(@report.fetch("stdin_path"), input_w)
        rescue Errno::EPIPE, IOError
          nil
        ensure
          input_w.close unless input_w.closed?
        end
        streams = [
          Thread.new { capture_stream(stdout_r, @report.fetch("jsonl_path"), @out) },
          Thread.new { capture_stream(stderr_r, @report.fetch("stderr_path"), @err) }
        ]
        deadline = nil
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          if waited
            @report["exit_status"] = waited.last.exitstatus || 128 + waited.last.termsig
            @report["signal"] = waited.last.termsig
            break
          end
          deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3 if interrupted
          if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            Process.kill("KILL", -pid) rescue Errno::ESRCH
          end
          sleep 0.02
        end
        # Kill surviving descendants before draining pipes; never leave detached work.
        Process.kill("KILL", -pid) rescue Errno::ESRCH
        writer.join
        streams.each(&:value)
        final = File.file?(@report.fetch("final_path")) ? File.binread(@report.fetch("final_path")).force_encoding("UTF-8") : nil
        valid = final && final.valid_encoding? && !final.strip.empty?
        @report["final_valid"] = !!valid
        @report["status"] = interrupted ? "interrupted" : valid ? "exited" : "invalid_final"
        @err.puts "ERROR: worker produced missing/invalid final output" unless valid
        @out.puts final if valid
        @report["ended_at"] = Time.now.utc.iso8601
        File.foreach(@report.fetch("jsonl_path")) do |line|
          event = JSON.parse(line) rescue nil
          @report["session_id"] ||= event["thread_id"] if event.is_a?(Hash) && event["type"] == "thread.started"
        end
        @report["artifacts"] = %w[prompt_path stdin_path jsonl_path stderr_path final_path].filter_map do |key|
          path = @report.fetch(key)
          { "path" => path, "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path) } if File.file?(path)
        end
        begin
          @report["exit_heads"] = @coordinator.launch_heads(@report.fetch("task_id"))
          @report["exit_checked_at"] = Time.now.utc.iso8601
          changed = @report.fetch("preparation").keys.select do |name|
            @report.fetch("preparation").fetch(name).fetch("pushed_sha") != @report.fetch("exit_heads").fetch(name).fetch("pushed_sha")
          end
          @report["exit_changed_repositories"] = changed
          @report["writable_freshness"] = (changed & @report.fetch("writable_repositories")).empty? ? "fresh_at_exit" : "stale"
          @err.puts "STALE INPUT: writable pushed head moved during execution; review exit provenance" if @report["writable_freshness"] == "stale"
        rescue Error => e
          @report["exit_freshness_error"] = e.message
          @report["writable_freshness"] = "unavailable"
          @err.puts "ERROR: host exit freshness unavailable: #{e.message}"
        end
        save_report
        @report.fetch("exit_status")
      ensure
        old_traps.each { |signal, old| Signal.trap(signal, old) }
        [input_r, input_w, stdout_r, stdout_w, stderr_r, stderr_w].each { |io| io.close unless io.closed? }
        if pid
          Process.kill("KILL", -pid) rescue Errno::ESRCH
          Process.waitpid(pid) rescue Errno::ECHILD
        end
      end
    end

    def capture_stream(stream, path, terminal)
      File.open(path, "wb", 0o600) do |file|
        loop do
          bytes = stream.readpartial(4096)
          file.write(bytes)
          file.flush
          terminal.write(bytes)
          terminal.flush if terminal.respond_to?(:flush)
        end
      rescue EOFError
        nil
      end
    end
  end
end
