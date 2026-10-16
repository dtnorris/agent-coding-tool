# frozen_string_literal: true

module AgentCodingTool
  # The host validates the coordinated source set before publishing any writer.
  # Per-repository records make partial publication recoverable without replaying
  # the coding worker or silently treating one PR as the whole task.
  class MultiDeliveryManager < DeliveryManager
    # Validates/delivers a grouped host run under the inherited reservation lock.
    # Returns per-repository PRs; refusals retain truthful partial-stage evidence.
    def deliver_multi_locked(id, run_dir, report)
      @run_dir = run_dir
      verify_overlap!(id)
      contract, contract_sha = multi_contract!(id, report.fetch("writable_repositories"))
      task = TaskStore.new(File.join(@data_root, "tasks")).load(id)
      writers = task.fetch("repositories").filter_map { |name, spec| name if spec.fetch("access") == "write" }
      raise InvalidState, "delivery: writable authority changed" unless writers == report.fetch("writable_repositories")
      bases = report.fetch("preparation")
      workspaces = report.fetch("workspaces")
      raise InvalidState, "delivery: workspace mapping changed" unless workspaces.keys == writers
      record_root = File.join(run_dir, "repositories")
      if File.exist?(record_root) || File.symlink?(record_root)
        raise InvalidState, "delivery: foreign repository evidence" unless
          File.directory?(record_root) && !File.symlink?(record_root) && (File.stat(record_root).mode & 0o077).zero?
      else
        Dir.mkdir(record_root, 0o700)
      end
      records = writers.to_h do |name|
        evidence_dir = File.join(record_root, name)
        if File.exist?(evidence_dir) || File.symlink?(evidence_dir)
          raise InvalidState, "delivery: foreign repository evidence" unless
            File.directory?(evidence_dir) && !File.symlink?(evidence_dir) && (File.stat(evidence_dir).mode & 0o077).zero?
        else
          Dir.mkdir(evidence_dir, 0o700)
        end
        path = File.join(evidence_dir, "delivery.json")
        raise InvalidState, "delivery: symlinked repository evidence" if File.symlink?(path)
        base = bases.fetch(name)
        workspace = workspaces.fetch(name)
        detail = File.file?(path) ? JSON.parse(File.binread(path)) : nil
        if detail && detail.values_at("schema", "task_id", "repository", "contract_sha256", "base_sha", "workspace") !=
                     [SCHEMA, id, name, contract_sha, base.fetch("pushed_sha"), workspace]
          raise InvalidState, "delivery: foreign repository evidence"
        end
        [name, { path: path, directory: evidence_dir, detail: detail,
                 workspace: workspace, base: base, contract: contract.fetch("repositories").fetch(name) }]
      end
      manager = WorktreeManager.new(root: Config.load(File.join(@data_root, "config.yml")).worktree_root,
                                    record_path: File.join(run_dir, "worktrees.json"))
      overrides = writers.to_h do |name|
        info = records.fetch(name)
        head = git!(info.fetch(:workspace), "rev-parse", "HEAD").strip
        [name, head == info.fetch(:base).fetch("pushed_sha") ? info.fetch(:base).fetch("pushed_sha") : head]
      end
      inventory = manager.inspect!(head_overrides: overrides)
      raise InvalidState, "delivery: worktree record changed" unless inventory == report.fetch("worktrees")
      verify_readers!(inventory)
      writers.each do |name|
        info = records.fetch(name)
        entry = inventory.fetch("entries").find { |item| item["name"] == name }
        base = info.fetch(:base)
        unless entry && entry.values_at("access", "path", "base_sha", "remote_url", "source_branch") ==
                        ["write", info.fetch(:workspace), base.fetch("pushed_sha"), base.fetch("remote_url"), base.fetch("branch")] &&
               entry["branch"] == "act/#{id}/attempt-#{report.fetch('attempt')}"
          raise InvalidState, "delivery: repository worktree identity changed"
        end
        verify_authority!(id, name, base)
      end

      # A failure here leaves every remote untouched. Existing validated
      # evidence is checked again on recovery, including each changed byte.
      writers.each { |name| validate_repository!(id, name, records.fetch(name), contract_sha) }
      validate_cross_checks!(id, run_dir, inventory, records, contract, contract_sha)
      verify_readers!(inventory)
      writers.each do |name|
        raise InvalidState, "delivery: trusted contract changed" unless multi_contract!(id, writers).last == contract_sha
        verify_readers!(inventory)
        publish_repository!(id, name, records.fetch(name), task)
      end
      modified = writers.filter_map do |name|
        detail = records.fetch(name).fetch(:detail)
        [name, detail.fetch("pr")] if detail["stage"] == "draft_pr"
      end.to_h
      raise InvalidState, "delivery: no modified writable repository" if modified.empty?
      link_prs!(id, records, modified)
      state = StateStore.new(File.join(@data_root, "state")).load(id)
      urls = modified.values.map { |pr| pr.fetch("url") }.sort
      if !state["result"] && state["started_at"]
        @coordinator.record(id, outcome: "candidate_complete",
                            summary: "Verified draft PRs: #{urls.join(', ')}",
                            artifact: urls.join(" "),
                            tests: records.values.flat_map { |info|
                              info.fetch(:detail).fetch("commands", []).map { |item| "#{item.fetch('argv').join(' ')}: exit 0" } })
      elsif state.dig("result", "outcome") != "candidate_complete" || state.dig("result", "artifact") != urls.join(" ")
        raise InvalidState, "delivery: ACT lifecycle changed; operator judgment required"
      end
      { "stage" => "draft_pr", "task_id" => id, "prs" => modified }
    rescue JSON::ParserError, KeyError, TypeError, IndexError => e
      raise InvalidState, "delivery: invalid/partial multi-repository evidence: #{e.class}"
    end

    # Reads grouped validation for advanced sibling candidates without executing
    # commands or changing records. Inputs are pinned host evidence/contracts;
    # returns true, or raises InvalidState for changed/missing cross-check logs.
    def verify_candidate_cross_checks!(id, report, run_dir, contract, contract_sha)
      root = File.join(run_dir, "cross-repository")
      path = File.join(root, "validation.json")
      raise InvalidState, "delivery: missing/foreign cross-checks" unless File.file?(path) && File.realpath(path) == path
      evidence = JSON.parse(File.binread(path))
      inventory = report.fetch("worktrees")
      signature = inventory.fetch("entries").to_h { |entry|
        [entry.fetch("name"), entry.values_at("path", "base_sha", "remote_url", "access")] }
      paths = inventory.fetch("entries").to_h { |entry| [entry.fetch("name"), entry.fetch("path")] }
      checks = contract.fetch("cross_repository_checks")
      policy = contract.fetch("repositories").values.first
      unless evidence.values_at("task_id", "contract_sha256", "worktrees") == [id, contract_sha, signature] &&
             evidence.fetch("commands").length == checks.length && checks.each_with_index.all? { |check, index|
               argv = check.fetch("argv").map { |arg|
                 arg.gsub(/\{worktree:([A-Za-z0-9_-]+)\}/) { paths.fetch(Regexp.last_match(1)) } }
               valid_command!(evidence.fetch("commands")[index], argv, root, index, policy) }
        raise InvalidState, "delivery: cross-repository validation changed"
      end
      verify_readers!(inventory)
      true
    end

    private

    def verify_readers!(inventory)
      inventory.fetch("entries").each do |entry|
        next unless entry["access"] == "read_only"
        raise InvalidState, "delivery: read-only dependency changed" unless
          git!(entry.fetch("path"), "rev-parse", "HEAD").strip == entry.fetch("base_sha") &&
          git!(entry.fetch("path"), "--no-optional-locks", "status", "--porcelain", "--untracked-files=all").empty?
      end
    end

    def multi_pr_body(task, detail, info)
      run_dir = File.dirname(File.dirname(info.fetch(:directory)))
      cross = JSON.parse(File.binread(File.join(run_dir, "cross-repository", "validation.json")))
      summaries = cross.fetch("commands").map { |item|
        "Exit #{item.fetch('exit_status')}; tests/assertions/failures/errors/skips: #{item.fetch('counts').join('/')}; " \
          "log SHA-256: #{item.fetch('logs').map { |log| log.fetch('sha256') }.join(', ')}" }
      pr_body(task, detail, info.fetch(:directory), info.fetch(:base)) +
        "\n\nACT task: #{task.fetch('id')}\nCross-repository validation:\n#{summaries.join("\n")}"
    end

    def multi_contract!(id, writers)
      path = contract_path(id)
      directory = File.dirname(path)
      raise InvalidState, "delivery: missing/private contract directory" unless
        File.directory?(directory) && !File.symlink?(directory) &&
        File.stat(directory).uid == Process.uid && (File.stat(directory).mode & 0o077).zero?
      raise InvalidState, "delivery: untrusted validation contract" unless
        File.file?(path) && !File.symlink?(path) && File.stat(path).uid == Process.uid &&
        (File.stat(path).mode & 0o022).zero? && File.realpath(path) == path
      bytes = File.binread(path)
      contract = YAML.safe_load(bytes, aliases: false)
      unless contract.is_a?(Hash) && (contract.keys - %w[repositories cross_repository_checks]).empty? &&
             contract.fetch("repositories").is_a?(Hash) && contract.fetch("repositories").keys == writers &&
             contract.fetch("repositories").values.all? { |value| valid_repository_contract?(value) } &&
             contract.fetch("cross_repository_checks").is_a?(Array) &&
             !contract.fetch("cross_repository_checks").empty? &&
             contract.fetch("cross_repository_checks").all? { |check|
               check.is_a?(Hash) && check.keys.sort == %w[argv cwd] &&
               writers.include?(check["cwd"]) && check["argv"].is_a?(Array) && !check["argv"].empty? &&
               check["argv"].all? { |arg| arg.is_a?(String) && !arg.empty? && !arg.include?("\0") }
             }
        raise InvalidState, "delivery: invalid multi-repository contract"
      end
      [contract, Digest::SHA256.hexdigest(bytes)]
    rescue Psych::Exception
      raise InvalidState, "delivery: malformed multi-repository contract"
    end

    def valid_repository_contract?(item)
      item.is_a?(Hash) &&
        (item.keys - %w[allowed_paths base_branch commands max_seconds min_assertions min_tests publication_guard coverage_min_percent]).empty? &&
        (%w[allowed_paths base_branch commands max_seconds min_assertions min_tests publication_guard] - item.keys).empty? &&
        item["allowed_paths"].is_a?(Array) && !item["allowed_paths"].empty? &&
        item["allowed_paths"].all? { |path| path.is_a?(String) && path.match?(/\A[A-Za-z0-9_.*\/-]+\z/) &&
          !path.start_with?("/") && !path.include?("..") } &&
        item["base_branch"] == "main" && item["commands"].is_a?(Array) && !item["commands"].empty? &&
        item["commands"].all? { |argv| argv.is_a?(Array) && !argv.empty? &&
          argv.all? { |arg| arg.is_a?(String) && !arg.empty? && !arg.include?("\0") } } &&
        %w[max_seconds min_tests min_assertions].all? { |key| item[key].is_a?(Integer) && item[key].positive? } &&
        item["publication_guard"].is_a?(Hash) &&
        (item["coverage_min_percent"].nil? ||
          (item["coverage_min_percent"].is_a?(Numeric) && item["coverage_min_percent"].between?(0, 100)))
    end

    def validate_repository!(id, name, info, contract_sha)
      detail = info[:detail] || { "schema" => SCHEMA, "task_id" => id, "repository" => name,
        "contract_sha256" => contract_sha, "base_sha" => info.fetch(:base).fetch("pushed_sha"),
        "workspace" => info.fetch(:workspace), "stage" => "pending", "commands" => [] }
      workspace, base, policy, path = info.values_at(:workspace, :base, :contract, :path)
      head = git!(workspace, "rev-parse", "HEAD").strip
      if detail["stage"] == "pending"
        raise InvalidState, "delivery: repository advanced before validation" unless head == base.fetch("pushed_sha")
        dirty = git!(workspace, "status", "--porcelain", "--untracked-files=all")
        if dirty.empty?
          detail["stage"] = "unchanged"
          save!(path, detail)
        else
          paths, manifest = snapshot!(workspace, base.fetch("pushed_sha"), policy)
          git!(workspace, "diff", "--check")
          detail["paths"], detail["manifest"] = paths, manifest
          save!(path, detail)
          while detail.fetch("commands").length < policy.fetch("commands").length
            index = detail.fetch("commands").length
            detail["commands"] << run_command!(workspace, info.fetch(:directory),
                                                 policy.fetch("commands")[index], index, policy)
            save!(path, detail)
            raise InvalidState, "delivery: implementation changed during validation" unless
              snapshot!(workspace, base.fetch("pushed_sha"), policy) == [paths, manifest]
          end
          detail["stage"] = "validated"
          save!(path, detail)
        end
      end
      if detail["stage"] != "unchanged"
        raise InvalidState, "delivery: invalid validation evidence" unless
          detail.fetch("commands").length == policy.fetch("commands").length &&
          detail.fetch("commands").each_with_index.all? { |item, index|
            valid_command!(item, policy.fetch("commands")[index], info.fetch(:directory), index, policy) }
        if head == base.fetch("pushed_sha")
          raise InvalidState, "delivery: repository bytes changed" unless
            snapshot!(workspace, base.fetch("pushed_sha"), policy) == detail.values_at("paths", "manifest")
        else
          verify_commit!(workspace, head, detail)
        end
      else
        raise InvalidState, "delivery: unchanged repository changed" unless
          head == base.fetch("pushed_sha") &&
          git!(workspace, "status", "--porcelain", "--untracked-files=all").empty?
      end
      info[:detail] = detail
    end

    def validate_cross_checks!(id, run_dir, inventory, records, contract, contract_sha)
      root = File.join(run_dir, "cross-repository")
      if File.exist?(root) || File.symlink?(root)
        raise InvalidState, "delivery: foreign cross-repository evidence" unless File.directory?(root) && !File.symlink?(root)
      else
        Dir.mkdir(root, 0o700)
      end
      path = File.join(root, "validation.json")
      raise InvalidState, "delivery: foreign cross-repository record" if File.symlink?(path)
      evidence = File.file?(path) ? JSON.parse(File.binread(path)) : nil
      signature = inventory.fetch("entries").to_h { |entry|
        [entry.fetch("name"), entry.values_at("path", "base_sha", "remote_url", "access")] }
      evidence ||= { "task_id" => id, "contract_sha256" => contract_sha,
                     "worktrees" => signature, "commands" => [] }
      raise InvalidState, "delivery: cross-repository authority changed" unless
        evidence.values_at("task_id", "contract_sha256", "worktrees") == [id, contract_sha, signature]
      checks = contract.fetch("cross_repository_checks")
      policy = records.values.first.fetch(:contract)
      while evidence.fetch("commands").length < checks.length
        index = evidence.fetch("commands").length
        check = checks[index]
        paths = inventory.fetch("entries").to_h { |entry| [entry.fetch("name"), entry.fetch("path")] }
        argv = check.fetch("argv").map { |arg|
          arg.gsub(/\{worktree:([A-Za-z0-9_-]+)\}/) { paths.fetch(Regexp.last_match(1)) } }
        cwd = records.fetch(check.fetch("cwd")).fetch(:workspace)
        evidence["commands"] << run_command!(cwd, root, argv, index, policy)
        save!(path, evidence)
        records.each { |name, info| validate_repository!(id, name, info, contract_sha) }
      end
      raise InvalidState, "delivery: cross-repository validation changed" unless
        evidence.fetch("commands").length == checks.length && checks.each_with_index.all? { |check, index|
          paths = inventory.fetch("entries").to_h { |entry| [entry.fetch("name"), entry.fetch("path")] }
          argv = check.fetch("argv").map { |arg|
            arg.gsub(/\{worktree:([A-Za-z0-9_-]+)\}/) { paths.fetch(Regexp.last_match(1)) } }
          valid_command!(evidence.fetch("commands")[index], argv, root, index, policy)
        }
      raise InvalidState, "delivery: trusted contract changed" unless multi_contract!(id, records.keys).last == contract_sha
    end

    # Advances one validated repository's idempotent delivery stages, rechecking
    # authority after external guards. Failures raise with prior evidence retained.
    def publish_repository!(id, name, info, task)
      detail = info.fetch(:detail)
      return if detail["stage"] == "unchanged"
      workspace, base, policy, path = info.values_at(:workspace, :base, :contract, :path)
      branch = "act/#{id}/attempt-#{task_attempt(info.fetch(:directory))}"
      if detail["stage"] == "validated"
        verify_authority!(id, name, base)
        head = git!(workspace, "rev-parse", "HEAD").strip
        if head == base.fetch("pushed_sha")
          raise InvalidState, "delivery: implementation changed since validation" unless
            snapshot!(workspace, base.fetch("pushed_sha"), policy) == detail.values_at("paths", "manifest")
          git!(workspace, "diff", "--check")
        end
        commit = head == base.fetch("pushed_sha") ? commit_validated!(workspace, detail) : head
        verify_commit!(workspace, commit, detail)
        detail["commit_sha"], detail["stage"] = commit, "committed"
        detail["branch"] = branch
        save!(path, detail)
      end
      commit = detail.fetch("commit_sha")
      verify_commit!(workspace, commit, detail)
      raise InvalidState, "delivery: branch identity changed" unless detail.fetch("branch") == branch
      verify_authority!(id, name, base)
      remote = @provider.branch(base.fetch("remote_url"), branch)
      raise InvalidState, "delivery: competing feature ref" if remote && remote != commit
      if detail["stage"] == "committed"
        @guard.verify!(policy.fetch("publication_guard"), base.fetch("remote_url"), :push, commit) unless remote == commit
        verify_authority!(id, name, base)
        @provider.push(workspace, base.fetch("remote"), branch, commit) unless remote == commit
        raise InvalidState, "delivery: pushed ref not verified" unless @provider.branch(base.fetch("remote_url"), branch) == commit
        detail["stage"] = "pushed"
        save!(path, detail)
      end
      if detail["stage"] == "pushed"
        prs = @provider.pull_requests(base.fetch("remote_url"), branch)
        raise InvalidState, "delivery: competing PR" if prs.length > 1
        if prs.empty?
          body = multi_pr_body(task, detail, info)
          @guard.verify!(policy.fetch("publication_guard"), base.fetch("remote_url"), :pr, commit)
          verify_authority!(id, name, base)
          @provider.create_draft(base.fetch("remote_url"), branch, policy.fetch("base_branch"),
                                 "#{id}: #{task.fetch('title')} (#{name})", body)
          prs = @provider.pull_requests(base.fetch("remote_url"), branch)
        end
        pr = prs.fetch(0)
        raise InvalidState, "delivery: PR identity not verified" unless
          prs.length == 1 && pr.values_at("draft", "state", "head", "base") ==
            [true, "open", commit, policy.fetch("base_branch")]
        detail["pr"], detail["stage"] = pr, "draft_pr"
        save!(path, detail)
      end
      prs = @provider.pull_requests(base.fetch("remote_url"), branch)
      raise InvalidState, "delivery: PR changed" unless
        detail["stage"] == "draft_pr" && prs == [detail.fetch("pr")]
    end

    def task_attempt(directory)
      path = File.join(File.dirname(File.dirname(directory)), "handoff.json")
      JSON.parse(File.binread(path)).fetch("attempt")
    end

    # Updates grouped PR references after rechecking guard and source/overlap
    # authority. Inputs are validated records/PRs; failed verification raises.
    def link_prs!(id, records, prs)
      urls = prs.values.map { |pr| pr.fetch("url") }.sort
      records.each do |name, info|
        detail = info.fetch(:detail)
        next unless detail["stage"] == "draft_pr"
        siblings = urls - [detail.fetch("pr").fetch("url")]
        next if siblings.empty?
        base = info.fetch(:base)
        body = multi_pr_body(TaskStore.new(File.join(@data_root, "tasks")).load(id), detail, info) +
               "\nRelated PRs:\n#{siblings.map { |url| "- #{url}" }.join("\n")}"
        if detail["cross_links"] != siblings
          @guard.verify!(info.fetch(:contract).fetch("publication_guard"), base.fetch("remote_url"),
                         :pr, detail.fetch("commit_sha"))
          verify_authority!(id, name, base)
          @provider.update_body(base.fetch("remote_url"), detail.fetch("pr").fetch("url"), body)
          updated = @provider.pull_requests(base.fetch("remote_url"), detail.fetch("branch"))
          raise InvalidState, "delivery: PR links not verified" unless
            updated.length == 1 && updated.first.fetch("body") == body &&
            updated.first.values_at("url", "head", "base") == detail.fetch("pr").values_at("url", "head", "base")
          detail["pr"] = updated.first
          detail["cross_links"] = siblings
          save!(info.fetch(:path), detail)
        else
          current = @provider.pull_requests(base.fetch("remote_url"), detail.fetch("branch"))
          raise InvalidState, "delivery: PR links changed" unless
            current == [detail.fetch("pr")] && siblings.all? { |url| current.first.fetch("body").include?(url) }
        end
      end
    end
  end
end
