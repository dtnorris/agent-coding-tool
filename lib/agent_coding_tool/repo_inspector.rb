# frozen_string_literal: true

require "open3"
require "thread"

module AgentCodingTool
  class CommandRunner
    def capture(*command, chdir: nil)
      options = {}
      options[:chdir] = chdir if chdir
      stdout, stderr, status = Open3.capture3(*command, **options)
      [stdout, stderr, status.success?]
    end
  end

  class RepoInspector
    DEFAULT_REMOTE_CONCURRENCY = 4

    def initialize(config, runner: CommandRunner.new, remote_concurrency: DEFAULT_REMOTE_CONCURRENCY)
      @config = config
      @runner = runner
      @remote_concurrency = Integer(remote_concurrency)
      raise ArgumentError, "remote concurrency must be positive" unless @remote_concurrency.positive?
    rescue ArgumentError, TypeError
      raise ArgumentError, "remote concurrency must be a positive integer"
    end

    def snapshot(name, spec)
      path = repository_path(name, spec)
      ensure_repository!(name, path)

      remote = spec.fetch("remote", @config.default_remote)
      branch = spec.fetch("branch", @config.default_branch)
      pushed_sha = pushed_sha!(name, path, remote, branch)
      local_head = git!(name, path, "rev-parse", "HEAD").strip
      dirty = !git!(name, path, "status", "--porcelain").empty?
      remote_url = git!(name, path, "remote", "get-url", remote).strip

      {
        "path" => path,
        "remote" => remote,
        "remote_url" => remote_url,
        "branch" => branch,
        "pushed_sha" => pushed_sha,
        "local_head" => local_head,
        "local_dirty" => dirty
      }
    end

    def repository_authority(name, spec)
      path = repository_path(name, spec)
      ensure_repository!(name, path)

      remote = spec.fetch("remote", @config.default_remote)
      branch = spec.fetch("branch", @config.default_branch)
      remote_url = git!(name, path, "remote", "get-url", remote).strip
      [remote_url, branch]
    end

    def pushed_heads(references)
      targets = Array(references).each_with_object({}) do |reference, out|
        name = reference.fetch("name").to_s
        remote_url = reference.fetch("remote_url").to_s
        branch = reference.fetch("branch").to_s
        if name.empty? || remote_url.empty? || branch.empty?
          raise RepositoryError, "status freshness reference is missing name, remote URL, or branch"
        end

        key = [remote_url, branch]
        target = out[key] ||= { "names" => [], "remote_url" => remote_url, "branch" => branch }
        target.fetch("names") << name unless target.fetch("names").include?(name)
      rescue KeyError
        raise RepositoryError, "status freshness reference is missing name, remote URL, or branch"
      end
      return {} if targets.empty?

      queue = Queue.new
      targets.each { |key, target| queue << [key, target] }
      results = {}
      errors = {}
      lock = Mutex.new
      worker_count = [@remote_concurrency, targets.length].min
      workers = Array.new(worker_count) do
        Thread.new do
          loop do
            key, target = queue.pop(true)
            begin
              sha = pushed_sha_from_url!(
                target.fetch("names").join(", "),
                target.fetch("remote_url"),
                target.fetch("branch")
              )
              lock.synchronize { results[key] = sha }
            rescue StandardError => e
              lock.synchronize { errors[key] = e }
            end
          rescue ThreadError
            break
          end
        end
      end
      workers.each(&:join)

      first_error = targets.each_key.lazy.map { |key| errors[key] }.find(&:itself)
      raise first_error if first_error

      results
    end

    private

    def repository_path(name, spec)
      configured = spec["path"] || name
      File.expand_path(configured, @config.repo_root)
    end

    def ensure_repository!(name, path)
      _stdout, stderr, success = @runner.capture("git", "rev-parse", "--git-dir", chdir: path)
      return if success

      raise RepositoryError, "#{name}: not a git repository at #{path}: #{stderr.strip}"
    rescue Errno::ENOENT
      raise RepositoryError, "#{name}: repository path does not exist: #{path}"
    end

    def pushed_sha!(name, path, remote, branch)
      stdout, stderr, success = @runner.capture(
        "git", "ls-remote", "--exit-code", remote, "refs/heads/#{branch}", chdir: path
      )
      parse_pushed_sha!(name, remote, branch, stdout, stderr, success)
    end

    def pushed_sha_from_url!(name, remote_url, branch)
      stdout, stderr, success = @runner.capture(
        "git", "ls-remote", "--exit-code", remote_url, "refs/heads/#{branch}"
      )
      parse_pushed_sha!(name, remote_url, branch, stdout, stderr, success)
    end

    def parse_pushed_sha!(name, remote, branch, stdout, stderr, success)
      unless success
        raise RepositoryError,
              "#{name}: cannot resolve pushed #{remote}/#{branch}: #{stderr.strip}"
      end

      rows = stdout.lines.map(&:strip).reject(&:empty?)
      unless rows.length == 1
        raise RepositoryError, "#{name}: expected exactly one pushed #{remote}/#{branch} ref, got #{rows.length}"
      end

      sha, ref = rows.first.split(/\s+/, 2)
      expected_ref = "refs/heads/#{branch}"
      unless sha&.match?(/\A[0-9a-f]{40}\z/) && ref == expected_ref
        raise RepositoryError, "#{name}: malformed pushed ref for #{remote}/#{branch}"
      end

      sha
    end

    def git!(name, path, *args)
      stdout, stderr, success = @runner.capture("git", *args, chdir: path)
      return stdout if success

      raise RepositoryError, "#{name}: git #{args.join(' ')} failed: #{stderr.strip}"
    end
  end
end
