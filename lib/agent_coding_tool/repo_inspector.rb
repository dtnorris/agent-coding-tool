# frozen_string_literal: true

require "open3"

module AgentCodingTool
  class CommandRunner
    def capture(*command, chdir: nil)
      stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
      [stdout, stderr, status.success?]
    end
  end

  class RepoInspector
    def initialize(config, runner: CommandRunner.new)
      @config = config
      @runner = runner
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
