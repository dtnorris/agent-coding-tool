# frozen_string_literal: true

require "fileutils"
require "digest"
require "uri"

module AgentCodingTool
  # Publishes an explicit selection from the data checkout. Lifecycle commands do
  # not call this class. Git's normal fast-forward push remains the final arbiter.
  class Publisher
    MESSAGES = {
      default: "ACTD: publish lifecycle state",
      all: "ACTD: publish working-tree changes"
    }.freeze
    STATE = /\Astate\/[^\/]+\.yml\z/
    PROMPT = /\Astate\/prompts\/[^\/]+\.txt\z/

    def initialize(data_root:, config:, task_store:, runner: CommandRunner.new)
      @root = File.expand_path(data_root)
      @config = config
      @task_store = task_store
      @runner = runner
    end

    def publish(mode:, task_id: nil, dry_run: false)
      unless %i[default task all].include?(mode) && (mode == :task) == !task_id.nil?
        raise Error, "invalid publication mode"
      end
      if task_id
        raise InvalidTask, "invalid task ID: #{task_id}" unless task_id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)

        @task_store.load(task_id)
      end

      if dry_run
        begin
          return perform(mode, task_id, dry_run: true)
        rescue RepositoryError => e
          return {
            mode: mode == :task ? "task #{task_id}" : mode.to_s,
            repository: @config.publish_repository, remote: @config.default_remote,
            branch: @config.default_branch, files: [], staged: [],
            commit_needed: false, push_needed: false, blocker: e.message
          }
        end
      end

      # Verify the destination before creating even the local lock file.
      preview = perform(mode, task_id, dry_run: true)
      raise RepositoryError, preview.fetch(:blocker) if preview[:blocker]

      git_dir = verify_checkout!
      File.open(File.join(git_dir, "act-publish.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        perform(mode, task_id, dry_run: false)
      end
    end

    private

    def perform(mode, task_id, dry_run:)
      verify_checkout!
      remote = @config.default_remote
      branch = @config.default_branch
      url = git!("remote", "get-url", remote).strip
      push_urls = git!("remote", "get-url", "--push", "--all", remote).lines.map(&:strip)
      expected = identity(@config.publish_repository)
      actual = identity(url)
      raise RepositoryError, "ACTD remote identity mismatch: expected #{expected}, got #{actual}" unless actual == expected
      unless push_urls.length == 1 && identity(push_urls.first) == expected
        raise RepositoryError, "ACTD requires exactly one push destination matching #{expected}"
      end

      current_branch = begin
        git!("symbolic-ref", "--quiet", "--short", "HEAD").strip
      rescue RepositoryError
        raise RepositoryError, "detached HEAD or current branch cannot be identified"
      end
      raise RepositoryError, "expected branch #{branch}, got #{current_branch}" unless current_branch == branch

      head = git!("rev-parse", "HEAD").strip
      remote_sha = remote_sha!(remote, branch)
      entries = status_entries
      files = selected_paths(entries, mode, task_id)
      staged = entries.filter_map { |entry| entry.fetch(:path) if entry.fetch(:xy)[0] != " " && entry.fetch(:xy)[0] != "?" }.uniq.sort
      blocker = repository_operation_blocker(entries) || scope_blocker(entries, files, mode, task_id)
      retry_commit = nil
      if head != remote_sha
        retry_commit = retryable_commit(head, remote_sha, mode, task_id, actual, branch)
        blocker ||= "local HEAD #{head} differs from remote #{remote_sha}; existing commits require operator review" unless retry_commit
        blocker ||= "publish the existing ACT commit before selecting additional changes" if retry_commit && !files.empty?
      end
      result = {
        mode: mode == :task ? "task #{task_id}" : mode.to_s,
        repository: actual, remote: remote, branch: branch,
        files: retry_commit && files.empty? ? committed_paths : files,
        staged: staged, commit_needed: !files.empty? && !retry_commit,
        push_needed: head != remote_sha || !files.empty?, blocker: blocker
      }
      return result if dry_run

      raise RepositoryError, blocker if blocker
      return result if files.empty? && !retry_commit

      if retry_commit
        push_and_verify!(remote, branch, head)
        return result.merge(files: committed_paths, sha: head, pushed: true)
      end

      # Recheck immediately before commit. A later race is rejected by Git push.
      raise RepositoryError, "remote branch moved before commit; no commit created" unless remote_sha!(remote, branch) == remote_sha
      raise RepositoryError, "local HEAD moved before commit; no commit created" unless git!("rev-parse", "HEAD").strip == head

      message = mode == :task ? "ACTD: publish #{task_id}" : MESSAGES.fetch(mode)
      trailer = "ACT-Publish: v1\nACT-Publish-Mode: #{mode_key(mode, task_id)}\n" \
                "ACT-Publish-Repository: #{actual}\nACT-Publish-Branch: #{branch}\n" \
                "ACT-Publish-Base: #{remote_sha}\nACT-Publish-Selection: #{selection_digest(files)}"
      untracked = []
      begin
        if mode == :all
          git!("add", "-A", "--", ".")
          git!("commit", "-m", message, "-m", trailer)
        else
          untracked = entries.filter_map { |entry| entry.fetch(:path) if entry.fetch(:xy) == "??" && files.include?(entry.fetch(:path)) }
          git!("add", "-N", "--", *untracked) unless untracked.empty?
          git!("commit", "--only", "-m", message, "-m", trailer, "--", *files)
        end
      rescue RepositoryError
        advanced = git!("rev-parse", "HEAD").strip
        if advanced != head
          committed = advanced
          raise
        end
        # Intent-to-add was the only narrow staging done here.
        git!("reset", "-q", "--", *untracked) unless untracked.empty?
        raise
      end

      committed = git!("rev-parse", "HEAD").strip
      raise RepositoryError, "commit did not advance HEAD; remote publication not attempted" if committed == head
      actual_files = committed_paths
      unless actual_files == files
        raise RepositoryError, "commit file set differs from selected files; inspect local commit #{committed}"
      end

      push_and_verify!(remote, branch, committed)
      result.merge(files: actual_files, sha: committed, pushed: true)
    rescue RepositoryError => e
      raise unless defined?(committed) && committed && !dry_run

      raise RepositoryError, "local commit #{committed} preserved; remote publication not confirmed: #{e.message}. Retry the same act publish command"
    end

    def verify_checkout!
      raise RepositoryError, "ACTD directory does not exist: #{@root}" unless Dir.exist?(@root)

      top = git!("rev-parse", "--show-toplevel").strip
      raise RepositoryError, "configured ACTD directory is not the Git checkout root" unless File.realpath(top) == File.realpath(@root)

      git!("rev-parse", "--absolute-git-dir").strip
    end

    def identity(value)
      text = value.to_s
      github_path = case text
                    when /\Agit@github\.com:(.+)\z/ then Regexp.last_match(1)
                    when /\Assh:\/\/git@github\.com\/(.+)\z/ then Regexp.last_match(1)
                    when /\Ahttps:\/\/github\.com\/(.+)\z/ then Regexp.last_match(1)
                    when /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?\z/ then text
                    end
      return github_path.delete_suffix(".git").downcase if github_path
      return "file://#{File.realpath(URI::DEFAULT_PARSER.unescape(URI(text).path))}" if text.start_with?("file://")
      return "file://#{File.realpath(text)}" if text.start_with?("/")

      raise RepositoryError, "unsupported publication repository identity"
    rescue Errno::ENOENT, URI::InvalidURIError
      raise RepositoryError, "publication repository identity cannot be resolved"
    end

    def remote_sha!(remote, branch)
      output = git!("ls-remote", "--exit-code", remote, "refs/heads/#{branch}")
      rows = output.lines.map(&:strip)
      sha, ref = rows.fetch(0).split(/\s+/, 2)
      unless rows.length == 1 && sha&.match?(/\A[0-9a-f]{40}\z/) && ref == "refs/heads/#{branch}"
        raise RepositoryError, "cannot verify remote #{remote}/#{branch}"
      end
      sha
    rescue IndexError
      raise RepositoryError, "remote branch #{remote}/#{branch} is missing"
    end

    def status_entries
      fields = git!("status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none").split("\0")
      entries = []
      until fields.empty?
        field = fields.shift
        next if field.empty?

        xy = field[0, 2]
        path = field[3..]
        original = nil
        original = fields.shift if xy.include?("R") || xy.include?("C")
        entries << { xy: xy, path: path, original: original }
      end
      entries
    end

    def selected_paths(entries, mode, task_id)
      entries.filter_map do |entry|
        path = entry.fetch(:path)
        next [path, entry[:original]].compact if mode == :all
        next path if mode == :default && (STATE.match?(path) || PROMPT.match?(path))
        next path if mode == :task && (path == "state/#{task_id}.yml" ||
          (PROMPT.match?(path) && /\A#{Regexp.escape(task_id)}-\d{8}T\d{6}Z\.txt\z/.match?(File.basename(path))))
      end.flatten.uniq.sort
    end

    def scope_blocker(entries, files, mode, task_id)
      entries.each do |entry|
        path = entry.fetch(:path)
        touched = entry[:original] && selected_paths(
          [{ xy: entry.fetch(:xy), path: entry.fetch(:original), original: nil }], mode, task_id
        )
        if entry[:original] && mode != :all && (files.include?(path) || !touched.empty?)
          return "renamed selected file #{path} requires explicit --all review"
        end
        next unless mode == :all || files.include?(path)

        if entry.fetch(:xy) == "??" && File.directory?(File.join(@root, path)) &&
           File.exist?(File.join(@root, path, ".git"))
          return "nested Git checkout #{path} requires separate publication"
        end
        mode_line = git!("ls-files", "--stage", "--", path).lines.first
        return "Git submodule #{path} requires separate publication" if mode_line&.start_with?("160000 ")
        next if mode == :all

        staged, unstaged = entry.fetch(:xy).chars
        if staged != " " && staged != "?" && unstaged != " "
          return "selected file #{path} has different staged and working-tree versions"
        end
      end
      nil
    end

    def repository_operation_blocker(entries)
      if entries.any? { |entry| entry.fetch(:xy).include?("U") || %w[AA DD].include?(entry.fetch(:xy)) }
        return "unresolved Git index; finish the merge before publishing"
      end

      %w[MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply].each do |name|
        path = git!("rev-parse", "--git-path", name).strip
        return "Git #{name} operation is in progress" if File.exist?(File.expand_path(path, @root))
      end
      nil
    end

    def retryable_commit(head, remote_sha, mode, task_id, repository, branch)
      return false unless git!("rev-parse", "HEAD^").strip == remote_sha

      message = git!("show", "-s", "--format=%B", "HEAD")
      {
        "ACT-Publish" => "v1",
        "ACT-Publish-Mode" => mode_key(mode, task_id),
        "ACT-Publish-Repository" => repository,
        "ACT-Publish-Branch" => branch,
        "ACT-Publish-Base" => remote_sha,
        "ACT-Publish-Selection" => selection_digest(committed_paths)
      }.all? { |key, value| message.lines.any? { |line| line.chomp == "#{key}: #{value}" } }
    rescue RepositoryError
      false
    end

    def mode_key(mode, task_id) = mode == :task ? "task:#{task_id}" : mode.to_s

    def selection_digest(paths) = Digest::SHA256.hexdigest(paths.join("\0"))

    def committed_paths
      git!("diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "HEAD").split("\0").sort
    end

    def push_and_verify!(remote, branch, sha)
      git!("push", remote, "HEAD:refs/heads/#{branch}")
      observed = remote_sha!(remote, branch)
      raise RepositoryError, "remote reports #{observed}, expected #{sha}" unless observed == sha
    end

    def git!(*args)
      output, error, success = @runner.capture("git", *args, chdir: @root)
      raise RepositoryError, "git #{args.first} failed: #{error.strip}" unless success

      output
    rescue Errno::ENOENT => e
      raise RepositoryError, "git #{args.first} failed: #{e.message}"
    end
  end
end
