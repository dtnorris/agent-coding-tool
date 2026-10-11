# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require "yaml"
require "fileutils"

module AgentCodingTool
  # Trusted host-side validation and publication of one NC-02A worktree.
  # The worker cannot write the private contract or evidence directory.
  class DeliveryManager
    SCHEMA = "agent-coding-tool-delivery/v1"
    SHA = /\A[0-9a-f]{40}\z/

    def initialize(data_root:, coordinator:, provider: nil, guard: nil)
      @data_root = File.realpath(data_root)
      @coordinator = coordinator
      @provider = provider || GitHubDeliveryProvider.new
      @guard = guard || ExternalPublicationGuard.new
    end

    def configured?(id)
      File.file?(contract_path(id))
    end

    def deliver(id, run_dir:)
      raise InvalidTask, "delivery: unsafe task ID" unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      run_dir = File.realpath(run_dir)
      expected_parent = File.join("#{@data_root}-runs", id)
      raise InvalidState, "delivery: foreign run" unless File.dirname(run_dir) == expected_parent
      File.open(File.join(run_dir, "delivery.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        raise InvalidState, "delivery: another delivery holds lock" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        deliver_locked(id, run_dir)
      end
    end

    private

    def contract_path(id) = File.join("#{@data_root}-validation", "#{id}.yml")

    def contract!(id)
      path = contract_path(id)
      directory = File.dirname(path)
      raise InvalidState, "delivery: missing/private contract directory" unless
        File.directory?(directory) && !File.symlink?(directory) &&
        File.stat(directory).uid == Process.uid && (File.stat(directory).mode & 0o077).zero?
      raise InvalidState, "delivery: missing trusted validation contract" unless File.file?(path) && !File.symlink?(path)
      raise InvalidState, "delivery: contract must be operator-owned and private" unless
        File.stat(path).uid == Process.uid && (File.stat(path).mode & 0o022).zero? &&
        File.realpath(path) == path
      bytes = File.binread(path)
      contract = YAML.safe_load(bytes, aliases: false)
      unless contract.is_a?(Hash) &&
             (contract.keys - %w[allowed_paths base_branch commands max_seconds min_assertions min_tests publication_guard coverage_min_percent]).empty? &&
             (%w[allowed_paths base_branch commands max_seconds min_assertions min_tests publication_guard] - contract.keys).empty? &&
             contract["allowed_paths"].is_a?(Array) && !contract["allowed_paths"].empty? &&
             contract["allowed_paths"].all? { |p| p.is_a?(String) && p.match?(/\A[A-Za-z0-9_.*\/-]+\z/) && !p.start_with?("/") && !p.include?("..") } &&
             contract["base_branch"] == "main" &&
             contract["commands"].is_a?(Array) && !contract["commands"].empty? &&
             contract["commands"].all? { |args| args.is_a?(Array) && !args.empty? &&
               args.all? { |arg| arg.is_a?(String) && !arg.empty? && !arg.include?("\0") } } &&
             contract["max_seconds"].is_a?(Integer) && contract["max_seconds"].positive? &&
             contract["min_tests"].is_a?(Integer) && contract["min_tests"].positive? &&
             contract["min_assertions"].is_a?(Integer) && contract["min_assertions"].positive? &&
             contract["publication_guard"].is_a?(Hash) &&
             (contract["coverage_min_percent"].nil? ||
              (contract["coverage_min_percent"].is_a?(Numeric) && contract["coverage_min_percent"].between?(0, 100)))
        raise InvalidState, "delivery: invalid trusted validation contract"
      end
      [contract, Digest::SHA256.hexdigest(bytes)]
    rescue Psych::Exception
      raise InvalidState, "delivery: malformed trusted validation contract"
    end

    def deliver_locked(id, run_dir)
      contract, contract_sha = contract!(id)
      report_path = File.join(run_dir, "handoff.json")
      raise InvalidState, "delivery: foreign handoff" if File.symlink?(report_path)
      report = JSON.parse(File.binread(report_path))
      unless report["schema_version"] == Launcher::SCHEMA && report["task_id"] == id &&
             report["status"] == "exited" && report["exit_status"] == 0 && report["final_valid"] == true &&
             report["writable_freshness"] == "fresh_at_exit" && report["worktrees_path"] == File.join(run_dir, "worktrees.json")
        raise InvalidState, "delivery: worker exit/evidence is not eligible"
      end
      verify_worker_artifacts!(report, run_dir)
      name = report.fetch("writable_repository")
      base = report.fetch("preparation").fetch(name)
      workspace = report.fetch("workspace")
      raise InvalidState, "delivery: invalid prepared base" unless base.fetch("pushed_sha").match?(SHA)
      task = TaskStore.new(File.join(@data_root, "tasks")).load(id)
      raise InvalidState, "delivery: only one writer supported" unless
        task.fetch("repositories").select { |_n, spec| spec.fetch("access") == "write" }.keys == [name]
      inventory_path = File.join(run_dir, "worktrees.json")
      manager = WorktreeManager.new(root: Config.load(File.join(@data_root, "config.yml")).worktree_root,
                                    record_path: inventory_path)
      delivery_path = File.join(run_dir, "delivery.json")
      raise InvalidState, "delivery: symlinked evidence" if File.symlink?(delivery_path)
      existing = File.file?(delivery_path) ? JSON.parse(File.binread(delivery_path)) : nil
      if existing
        raise InvalidState, "delivery: foreign delivery evidence" unless existing["schema"] == SCHEMA &&
          existing["task_id"] == id && existing["contract_sha256"] == contract_sha &&
          existing["base_sha"] == base.fetch("pushed_sha") && existing["workspace"] == workspace
      end
      head = git!(workspace, "rev-parse", "HEAD").strip
      override = head == base.fetch("pushed_sha") ? {} : { name => head }
      inventory = manager.inspect!(head_overrides: override)
      writer = inventory.fetch("entries").find { |entry| entry.fetch("access") == "write" }
      unless writer.fetch("name") == name && writer.fetch("path") == workspace &&
             writer.fetch("base_sha") == base.fetch("pushed_sha") &&
             writer.fetch("remote_url") == base.fetch("remote_url") &&
             writer.fetch("source_branch") == base.fetch("branch") &&
             report.fetch("worktrees") == inventory
        raise InvalidState, "delivery: worktree identity changed"
      end
      branch = writer.fetch("branch")
      raise InvalidState, "delivery: unsafe branch" unless branch == "act/#{id}/attempt-#{report.fetch('attempt')}"
      details = existing || { "schema" => SCHEMA, "task_id" => id, "contract_sha256" => contract_sha,
                              "base_sha" => base.fetch("pushed_sha"), "workspace" => workspace,
                              "branch" => branch, "stage" => "pending", "commands" => [] }
      if details["stage"] == "pending"
        raise InvalidState, "delivery: branch advanced before validation" unless head == base.fetch("pushed_sha")
        verify_authority!(id, name, base)
        paths, manifest = snapshot!(workspace, base.fetch("pushed_sha"), contract)
        git!(workspace, "diff", "--check")
        details["paths"] = paths
        details["manifest"] = manifest
        details["tree_sha"] = git!(workspace, "rev-parse", "HEAD^{tree}").strip
        save!(delivery_path, details)
        contract.fetch("commands").each_with_index do |argv, index|
          details["commands"] << run_command!(workspace, run_dir, argv, index, contract)
          save!(delivery_path, details)
          raise InvalidState, "delivery: implementation changed during validation" unless
            snapshot!(workspace, base.fetch("pushed_sha"), contract) == [paths, manifest]
        end
        raise InvalidState, "delivery: trusted contract changed" unless contract!(id).last == contract_sha
        details["stage"] = "validated"
        save!(delivery_path, details)
      end
      raise InvalidState, "delivery: missing validation evidence" unless
        details.fetch("commands").length == contract.fetch("commands").length &&
        details.fetch("commands").each_with_index.all? { |item, i| valid_command!(item, contract.fetch("commands")[i], run_dir, i, contract) }
      # Recovery never reruns the worker or final acceptance. The recorded
      # manifest and full output are checked before each irreversible stage.
      if details["stage"] == "validated"
        if head == base.fetch("pushed_sha")
          raise InvalidState, "delivery: implementation changed since validation" unless
            snapshot!(workspace, base.fetch("pushed_sha"), contract) == details.values_at("paths", "manifest")
          git!(workspace, "diff", "--check")
        else
          verify_commit!(workspace, head, details)
        end
        verify_authority!(id, name, base)
        commit = if head == base.fetch("pushed_sha")
                   commit_validated!(workspace, details)
                 else
                   verify_commit!(workspace, head, details)
                   head
                 end
        details["commit_sha"] = commit
        details["stage"] = "committed"
        save!(delivery_path, details)
      end
      commit = details.fetch("commit_sha")
      verify_commit!(workspace, commit, details)
      body = pr_body(task, details, run_dir, base)
      verify_authority!(id, name, base)
      remote = @provider.branch(base.fetch("remote_url"), branch)
      raise InvalidState, "delivery: competing feature ref" if remote && remote != commit
      if details["stage"] == "committed"
        @guard.verify!(contract.fetch("publication_guard"), base.fetch("remote_url"), :push, commit) unless remote == commit
        @provider.push(workspace, base.fetch("remote"), branch, commit) unless remote == commit
        raise InvalidState, "delivery: pushed ref not verified" unless @provider.branch(base.fetch("remote_url"), branch) == commit
        details["stage"] = "pushed"
        save!(delivery_path, details)
      end
      if details["stage"] == "pushed"
        prs = @provider.pull_requests(base.fetch("remote_url"), branch)
        raise InvalidState, "delivery: competing/ambiguous PR" if prs.length > 1
        if prs.empty?
          @guard.verify!(contract.fetch("publication_guard"), base.fetch("remote_url"), :pr, commit)
          @provider.create_draft(base.fetch("remote_url"), branch, contract.fetch("base_branch"),
                                 task.fetch("title"), body)
          prs = @provider.pull_requests(base.fetch("remote_url"), branch)
        end
        pr = prs.fetch(0)
        unless prs.length == 1 && pr.fetch("draft") == true && pr.fetch("state") == "open" && pr.fetch("head") == commit &&
               pr.fetch("base") == contract.fetch("base_branch")
          raise InvalidState, "delivery: PR identity not verified"
        end
        details["pr"] = pr
        details["stage"] = "draft_pr"
        save!(delivery_path, details)
      end
      raise InvalidState, "delivery: incomplete publication" unless details["stage"] == "draft_pr"
      prs = @provider.pull_requests(base.fetch("remote_url"), branch)
      raise InvalidState, "delivery: PR changed" unless prs == [details.fetch("pr")] &&
        prs.first.values_at("state", "draft", "head", "base") == ["open", true, commit, contract.fetch("base_branch")]
      # A PR is a candidate. Only a human can assert integration with finish.
      state = StateStore.new(File.join(@data_root, "state")).load(id)
      if !state["result"] && state["started_at"]
        @coordinator.record(id, outcome: "candidate_complete", summary: "Verified draft PR #{details.fetch('pr').fetch('url')}",
                            artifact: details.fetch("pr").fetch("url"),
                            tests: details.fetch("commands").map { |c| "#{c.fetch('argv').join(' ')}: exit 0" })
      elsif state.dig("result", "outcome") != "candidate_complete" ||
            state.dig("result", "artifact") != details.fetch("pr").fetch("url")
        raise InvalidState, "delivery: ACT lifecycle changed; operator judgment required"
      end
      details
    rescue JSON::ParserError, KeyError, TypeError, IndexError => e
      raise InvalidState, "delivery: invalid/partial evidence: #{e.class}"
    end

    def verify_worker_artifacts!(report, run_dir)
      items = report.fetch("artifacts")
      %w[prompt_path stdin_path jsonl_path stderr_path final_path].each do |key|
        path = report.fetch(key)
        raise InvalidState, "delivery: foreign artifact" unless File.dirname(path) == run_dir &&
          File.file?(path) && !File.symlink?(path)
        item = items.find { |entry| entry["path"] == path }
        raise InvalidState, "delivery: missing/altered worker artifact" unless item &&
          item["bytes"] == File.size(path) && item["sha256"] == Digest::SHA256.file(path).hexdigest
      end
    end

    def verify_authority!(id, name, base)
      heads = @coordinator.launch_heads(id)
      raise InvalidState, "delivery: STALE INPUT" unless heads.fetch(name).values_at("remote_url", "branch", "pushed_sha") ==
        base.values_at("remote_url", "branch", "pushed_sha")
    end

    def snapshot!(workspace, base_sha, contract)
      raise InvalidState, "delivery: staged changes" unless git!(workspace, "diff", "--cached", "--name-only").empty?
      status = git!(workspace, "status", "--porcelain=v1", "-z", "--untracked-files=all")
      records = status.split("\0")
      raise InvalidState, "delivery: no implementation" if records.empty?
      paths = records.map do |record|
        code, path = record[0, 2], record[3..]
        unless [" M", "??", " D"].include?(code) && path && !path.empty? && !path.start_with?("/") &&
               !path.split("/").include?("..") && contract.fetch("allowed_paths").any? { |glob|
                 File.fnmatch?(glob, path, File::FNM_PATHNAME) }
          raise InvalidState, "delivery: unauthorized or unsupported Git change"
        end
        path
      end.sort
      raise InvalidState, "delivery: HEAD changed" unless git!(workspace, "rev-parse", "HEAD").strip == base_sha
      manifest = paths.to_h do |path|
        absolute = File.join(workspace, path)
        if File.exist?(absolute)
          raise InvalidState, "delivery: nonregular file" unless File.file?(absolute) && !File.symlink?(absolute)
          [path, { "sha256" => Digest::SHA256.file(absolute).hexdigest, "mode" => File.stat(absolute).mode & 0o111 }]
        else
          [path, { "deleted" => true }]
        end
      end
      [paths, manifest]
    end

    def run_command!(workspace, run_dir, argv, index, contract)
      started = Time.now.utc.iso8601
      stdout_path = File.join(run_dir, "validation-#{index}.stdout")
      stderr_path = File.join(run_dir, "validation-#{index}.stderr")
      [stdout_path, stderr_path].each do |path|
        raise InvalidState, "delivery: validation log already exists" if File.exist?(path) || File.symlink?(path)
      end
      pid = nil
      begun = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = nil
      environment = { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME"), "LANG" => "C.UTF-8" }
      File.open(stdout_path, "wb", 0o600) do |out|
        File.open(stderr_path, "wb", 0o600) do |err|
          Open3.popen3(environment,
                       *argv, chdir: workspace, unsetenv_others: true, pgroup: true) do |input, stdout, stderr, wait|
            pid = wait.pid
            input.close
            readers = [[stdout, out], [stderr, err]].map do |stream, target|
              Thread.new { IO.copy_stream(stream, target); target.flush; target.fsync }
            end
            until (status = wait.join(0.05))
              if Process.clock_gettime(Process::CLOCK_MONOTONIC) - begun > contract.fetch("max_seconds")
                Process.kill("KILL", -pid) rescue Errno::ESRCH
                raise InvalidState, "delivery: validation timeout"
              end
            end
            readers.each(&:value)
          end
        end
      end
      outputs = [stdout_path, stderr_path].map { |path| File.binread(path).force_encoding("UTF-8") }
      raise InvalidState, "delivery: non-UTF-8 validation output" unless outputs.all?(&:valid_encoding?)
      combined = outputs.join("\n")
      counts = combined.scan(/(\d+) tests?, (\d+) assertions?, (\d+) failures?, (\d+) errors?, (\d+) skips?/).last
      unless status.value.exitstatus == 0 && counts && counts[0].to_i >= contract.fetch("min_tests") &&
             counts[1].to_i >= contract.fetch("min_assertions") && counts[2..].all? { |n| n.to_i.zero? }
        raise InvalidState, "delivery: failed, skipped or missing mandatory test evidence"
      end
      observed = combined.scan(/(?:Line Coverage|Coverage):\s*(\d+(?:\.\d+)?)%/i).last&.first&.to_f
      if (required_coverage = contract["coverage_min_percent"])
        raise InvalidState, "delivery: missing or low coverage" unless observed && observed >= required_coverage
      end
      { "argv" => argv, "cwd" => workspace, "environment" => environment,
        "started_at" => started, "ended_at" => Time.now.utc.iso8601,
        "elapsed_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - begun,
        "exit_status" => status.value.exitstatus, "counts" => counts.map(&:to_i), "coverage_percent" => observed,
        "logs" => [stdout_path, stderr_path].map { |path|
          { "path" => path, "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path) } } }
    ensure
      Process.kill("KILL", -pid) rescue nil if pid && !status
    end

    def valid_command!(item, argv, run_dir, index, contract)
      return false unless item["argv"] == argv && item["exit_status"] == 0 &&
        item["counts"].is_a?(Array) && item["counts"].length == 5 &&
        item["counts"][2..].all?(&:zero?) && item.fetch("logs").length == 2 &&
        item["counts"][0] >= contract.fetch("min_tests") && item["counts"][1] >= contract.fetch("min_assertions") &&
        item["elapsed_seconds"].is_a?(Numeric) && item["elapsed_seconds"] <= contract.fetch("max_seconds") &&
        (!contract["coverage_min_percent"] || (item["coverage_percent"].is_a?(Numeric) &&
          item["coverage_percent"] >= contract["coverage_min_percent"]))
      item.fetch("logs").each_with_index.all? do |log, i|
        path = File.join(run_dir, "validation-#{index}.#{i.zero? ? 'stdout' : 'stderr'}")
        log.fetch("path") == path && File.file?(path) &&
          !File.symlink?(path) && File.size(path) == log.fetch("bytes") &&
          Digest::SHA256.file(path).hexdigest == log.fetch("sha256")
      end
    end

    def commit_validated!(workspace, details)
      git!(workspace, "-c", "core.hooksPath=/dev/null", "add", "--", *details.fetch("paths"))
      staged = git!(workspace, "diff", "--cached", "--name-only", "-z").split("\0").sort
      raise InvalidState, "delivery: unexpected staged paths" unless staged == details.fetch("paths")
      details.fetch("manifest").each do |path, entry|
        if entry["deleted"]
          raise InvalidState, "delivery: deleted path still staged" unless
            git!(workspace, "ls-files", "--stage", "--", path).empty?
          next
        end
        blob = git!(workspace, "show", ":#{path}")
        raise InvalidState, "delivery: staged bytes differ" unless Digest::SHA256.hexdigest(blob) == entry.fetch("sha256")
        mode = git!(workspace, "ls-files", "--stage", "--", path).split.first
        raise InvalidState, "delivery: staged mode differs" unless mode == (entry.fetch("mode").zero? ? "100644" : "100755")
      end
      git!(workspace, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "-m",
           "ACT #{details.fetch('task_id')}: validated implementation")
      commit = git!(workspace, "rev-parse", "HEAD").strip
      verify_commit!(workspace, commit, details)
      commit
    end

    def verify_commit!(workspace, commit, details)
      raise InvalidState, "delivery: commit changed" unless git!(workspace, "rev-parse", "HEAD").strip == commit &&
        git!(workspace, "rev-parse", "HEAD^").strip == details.fetch("base_sha") &&
        git!(workspace, "status", "--porcelain", "--untracked-files=all").empty?
      paths = git!(workspace, "diff", "--name-only", "-z", "HEAD^", "HEAD").split("\0").sort
      raise InvalidState, "delivery: commit paths differ" unless paths == details.fetch("paths")
      details.fetch("manifest").each do |path, entry|
        if entry["deleted"]
          raise InvalidState, "delivery: deletion absent from commit" unless
            !Open3.capture3("git", "cat-file", "-e", "HEAD:#{path}", chdir: workspace).last.success?
          next
        end
        bytes = git!(workspace, "show", "HEAD:#{path}")
        raise InvalidState, "delivery: commit bytes differ" unless Digest::SHA256.hexdigest(bytes) == entry.fetch("sha256")
        mode = git!(workspace, "ls-tree", "HEAD", "--", path).split.first
        raise InvalidState, "delivery: commit mode differs" unless mode == (entry.fetch("mode").zero? ? "100644" : "100755")
      end
      true
    end

    def pr_body(task, details, run_dir, base)
      lines = ["## Implementation", task.fetch("title").to_s, "",
               "Prepared base: #{base.fetch('pushed_sha')}", "Commit: #{details.fetch('commit_sha')}", "",
               "## Validation Evidence"]
      details.fetch("commands").each do |item|
        raise InvalidState, "delivery: unsafe public command" if item.fetch("argv").any? { |arg| private_output?(arg, run_dir) }
        lines << "Command: #{item.fetch('argv').join(' ')}"
        lines << "Exit: #{item.fetch('exit_status')}; tests/assertions/failures/errors/skips: #{item.fetch('counts').join('/')}"
        item.fetch("logs").each do |log|
          output = File.binread(log.fetch("path")).force_encoding("UTF-8")
          raise InvalidState, "delivery: unsafe public validation output" unless output.valid_encoding? &&
            output.bytesize <= 12_000 && !output.include?("~~~") && !output.include?("\e") &&
            !private_output?(output, run_dir)
          lines << "Output (SHA-256 #{log.fetch('sha256')}):"
          lines << "~~~text\n#{output}\n~~~"
        end
      end
      lines << "Full private logs: retained in the ACT run handoff; hashes above bind each output."
      raise InvalidState, "delivery: unsafe public title" if private_output?(task.fetch("title").to_s, run_dir)
      lines.join("\n")
    end

    def private_output?(value, run_dir)
      value.match?(/(?:gh[pousr]_|github_pat_|xox[baprs]-|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|Bearer |Authorization:|\/Users\/|\/home\/|\/workspace\/|\/tmp\/|\/private\/tmp\/|#{Regexp.escape(@data_root)}|#{Regexp.escape(run_dir)})/i)
    end

    def git!(cwd, *args)
      out, err, status = Open3.capture3("git", *args, chdir: cwd)
      raise RepositoryError, "delivery: Git #{args.first} failed: #{err.strip}" unless status.success?
      out
    end

    def save!(path, data)
      temporary = "#{path}.tmp"
      File.open(temporary, "wb", 0o600) { |f| f.write(JSON.pretty_generate(data) + "\n"); f.flush; f.fsync }
      File.rename(temporary, path)
    end
  end

  # The live provider runs only on the operator's host with explicit gh auth.
  class GitHubDeliveryProvider
    def branch(remote_url, branch)
      repository = repository!(remote_url)
      data = request("GET", "repos/#{repository}/git/ref/heads/#{branch}", missing: true)
      data && data.fetch("object").fetch("sha")
    end

    def push(workspace, remote, branch, commit)
      # Empty lease means the branch must still be absent. A concurrent
      # creator cannot be overwritten even when its commit is an ancestor.
      _out, err, status = Open3.capture3("git", "-c", "core.hooksPath=/dev/null", "push",
                                         "--force-with-lease=refs/heads/#{branch}:",
                                         remote, "#{commit}:refs/heads/#{branch}", chdir: workspace)
      raise RepositoryError, "delivery: push failed: #{err.strip}" unless status.success?
    end

    def pull_requests(remote_url, branch)
      repository = repository!(remote_url)
      owner = repository.split("/").first
      request("GET", "repos/#{repository}/pulls?state=all&head=#{owner}:#{branch}").map do |pr|
        { "url" => pr.fetch("html_url"), "state" => pr.fetch("state"), "draft" => pr.fetch("draft"),
          "head" => pr.fetch("head").fetch("sha"), "base" => pr.fetch("base").fetch("ref") }
      end
    end

    def create_draft(remote_url, branch, base, title, body)
      repository = repository!(remote_url)
      request("POST", "repos/#{repository}/pulls", fields: { title: title, head: branch,
        base: base, body: body, draft: "true" })
    end

    private

    def repository!(remote)
      match = remote.match(/\A(?:git@github\.com:|https:\/\/github\.com\/)([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+?)(?:\.git)?\z/)
      raise InvalidState, "delivery: unsupported publication remote" unless match
      match[1]
    end

    def request(method, endpoint, fields: {}, missing: false)
      argv = ["gh", "api", "-X", method, endpoint]
      fields.each { |key, value| argv += [key == :draft ? "-F" : "-f", "#{key}=#{value}"] }
      out, err, status = Open3.capture3(*argv)
      return nil if missing && !status.success? && err.include?("HTTP 404")
      raise RepositoryError, "delivery: GitHub query failed: #{err.strip}" unless status.success?
      JSON.parse(out)
    end
  end

  # An independent host service must enforce a finite lease, not merely
  # advertise an hourly ceiling. Absence or ambiguity blocks publication.
  class ExternalPublicationGuard
    def verify!(policy, remote, mutation, commit)
      command = policy["lease_check"]
      assessment = policy["trigger_assessment"]
      raise InvalidState, "delivery: independently enforced publication lease required" unless
        assessment.is_a?(String) && !assessment.strip.empty? &&
        command.is_a?(Array) && !command.empty? && command.all? { |arg| arg.is_a?(String) && !arg.empty? } &&
        command.first.start_with?("/") && File.executable?(command.first)
      out, _err, status = Open3.capture3(*command, remote, mutation.to_s, commit)
      data = JSON.parse(out)
      unless status.success? && data["independently_enforced"] == true &&
             data["triggers_classified"] == true && data["crash_surviving"] == true &&
             data["assessment"] == assessment && data["commit_sha"] == commit &&
             data["remaining_usd"].is_a?(Numeric) && data["remaining_usd"].finite? &&
             data["remaining_usd"] >= 0 && data["maximum_additional_loss_usd"].is_a?(Numeric) &&
             data["maximum_additional_loss_usd"].finite? && data["maximum_additional_loss_usd"] >= 0 &&
             data["maximum_additional_loss_usd"] <= data["remaining_usd"] &&
             data["expected_cost_usd"].is_a?(Numeric) && data["expected_cost_usd"].finite? &&
             data["expected_cost_usd"] >= 0 && data["expected_cost_usd"] <= data["remaining_usd"] &&
             data["maximum_hourly_rate_usd"].is_a?(Numeric) && data["maximum_hourly_rate_usd"].finite? &&
             data["maximum_hourly_rate_usd"] >= 0 &&
             data["maximum_runtime_seconds"].is_a?(Numeric) && data["maximum_runtime_seconds"].finite? &&
             data["maximum_runtime_seconds"] > 0 &&
             Time.iso8601(data.fetch("expires_at")) > Time.now.utc
        raise InvalidState, "delivery: finite independent publication lease unverified"
      end
    rescue JSON::ParserError, KeyError, ArgumentError, SystemCallError
      raise InvalidState, "delivery: independent publication lease unavailable"
    end
  end
end
