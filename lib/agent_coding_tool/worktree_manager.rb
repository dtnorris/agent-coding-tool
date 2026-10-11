# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"

module AgentCodingTool
  # Host-owned worktree inventory. The worker cannot write the private run record.
  class WorktreeManager
    SCHEMA = "agent-coding-tool-worktrees/v1"
    SYSTEM_ALIASES = { "/var" => "/private/var", "/tmp" => "/private/tmp" }.freeze

    def initialize(root:, record_path:)
      @root = canonical_system_path(root)
      @record_path = canonical_system_path(record_path)
    end

    def create(task_id:, attempt:, task:, snapshot:)
      safe_components!(task_id, attempt, task, snapshot)
      safe_path!(@root)
      raise InvalidState, "worktrees: foreign record already exists" if File.exist?(@record_path) || File.symlink?(@record_path)
      task.fetch("repositories").each_key do |name|
        path = File.join(@root, task_id, name)
        safe_path!(path)
        raise InvalidState, "worktrees: occupied path #{path}; inspect manually" if File.exist?(path) || File.symlink?(path)
      end
      FileUtils.mkdir_p(@root)
      entries = task.fetch("repositories").map do |name, spec|
        source = snapshot.fetch(name)
        path = File.join(@root, task_id, name)
        parent, = parent_identity!(source, name)
        {
          "name" => name, "task_id" => task_id, "attempt" => attempt,
          "path" => path, "parent" => parent,
          "remote_url" => source.fetch("remote_url"), "remote" => source.fetch("remote"),
          "source_branch" => source.fetch("branch"), "base_sha" => source.fetch("pushed_sha"),
          "access" => spec.fetch("access"),
          "branch" => spec.fetch("access") == "write" ? "act/#{task_id}/attempt-#{attempt}" : nil,
          "state" => "pending"
        }
      end
      raise InvalidState, "worktrees: exactly one writer required" unless entries.count { |e| e["access"] == "write" } == 1
      if entries.any? { |entry| @root == entry["parent"] || @root.start_with?("#{entry['parent']}/") } ||
         @root == "/Users/davidnorris/code/adventure-finder-components" ||
         @root.start_with?("/Users/davidnorris/code/adventure-finder-components/")
        raise InvalidState, "worktrees: root overlaps an ordinary checkout or canonical component root"
      end
      entries.each do |entry|
        if entry["branch"] && git(entry.fetch("parent"), "show-ref", "--verify", "--quiet", "refs/heads/#{entry['branch']}", allow_failure: true).last
          raise InvalidState, "worktrees: conflicting branch #{entry['branch']}"
        end
      end
      inventory = { "schema_version" => SCHEMA, "task_id" => task_id, "attempt" => attempt, "root" => @root, "entries" => entries }
      save!(inventory)
      entries.each do |entry|
        safe_path!(File.dirname(entry.fetch("path")))
        FileUtils.mkdir_p(File.dirname(entry.fetch("path")))
        raise InvalidState, "worktrees: occupied path #{entry['path']}; inspect manually" if
          File.exist?(entry.fetch("path")) || File.symlink?(entry.fetch("path"))
        entry["state"] = "creating"
        save!(inventory)
        args = ["worktree", "add"]
        args += entry["branch"] ? ["-b", entry.fetch("branch")] : ["--detach"]
        git!(entry.fetch("parent"), *args, "--", entry.fetch("path"), entry.fetch("base_sha"))
        entry["state"] = "ready"
        save!(inventory)
      end
      inspect!
    rescue StandardError => e
      # Preserve all created paths, branches and the last written operation marker.
      raise InvalidState, "worktrees: #{e.message}; inspect #{@record_path}; no automatic repair"
    end

    def inspect!
      raise InvalidState, "worktrees: missing/foreign ownership record" if File.symlink?(@record_path) || !File.file?(@record_path)
      inventory = JSON.parse(File.read(@record_path))
      unless inventory.is_a?(Hash) && inventory["schema_version"] == SCHEMA &&
             inventory["root"] == @root && inventory["entries"].is_a?(Array) &&
             inventory["entries"].count { |e| e["access"] == "write" } == 1
        raise InvalidState, "worktrees: invalid ownership record"
      end
      inventory.fetch("entries").each do |entry|
        unless entry.is_a?(Hash) && entry["state"] == "ready" &&
               entry["task_id"] == inventory["task_id"] && entry["attempt"] == inventory["attempt"] &&
               entry["path"] == File.join(@root, inventory.fetch("task_id"), entry.fetch("name")) &&
               %w[write read_only].include?(entry["access"]) &&
               entry["branch"] == (entry["access"] == "write" ? "act/#{inventory.fetch('task_id')}/attempt-#{inventory.fetch('attempt')}" : nil)
          raise InvalidState, "worktrees: partial or conflicting ownership; inspect #{@record_path}"
        end
        verify_entry!(entry)
      end
      inventory
    rescue JSON::ParserError, KeyError, TypeError
      raise InvalidState, "worktrees: malformed ownership; inspect #{@record_path}"
    end

    def cleanup_preflight
      inventory = inspect!
      inventory.fetch("entries").map do |entry|
        dirty = !git!(entry.fetch("path"), "status", "--porcelain", "--untracked-files=all").empty?
        { "path" => entry.fetch("path"), "branch" => entry["branch"],
          "access" => entry.fetch("access"), "dirty" => dirty,
          "blockers" => dirty ? ["worktree contains changes"] : [] }
      end
    end

    private

    def safe_components!(task_id, attempt, task, snapshot)
      raise InvalidTask, "worktrees: invalid task ID" unless task_id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      raise InvalidTask, "worktrees: invalid attempt" unless attempt.is_a?(Integer) && attempt.positive?
      repos = task.fetch("repositories")
      raise InvalidTask, "worktrees: repository mapping mismatch" unless repos.is_a?(Hash) && repos.keys.sort == snapshot.keys.sort
      repos.each_key do |name|
        raise InvalidTask, "worktrees: unsafe repository key" unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      end
    end

    def safe_path!(path)
      cursor = canonical_system_path(path)
      loop do
        raise InvalidState, "worktrees: symlinked ancestor #{cursor}" if File.symlink?(cursor)
        break if cursor == File.dirname(cursor)
        cursor = File.dirname(cursor)
      end
    end

    def self.canonical_system_path(path)
      expanded = File.expand_path(path)
      SYSTEM_ALIASES.each do |alias_path, canonical|
        next unless expanded == alias_path || expanded.start_with?("#{alias_path}/")
        next unless File.symlink?(alias_path) && File.realpath(alias_path) == canonical
        next unless File.stat(alias_path).uid.zero? && File.stat(canonical).uid.zero?

        return canonical + expanded.delete_prefix(alias_path)
      end
      expanded
    end

    def canonical_system_path(path) = self.class.canonical_system_path(path)

    def parent_identity!(source, name)
      raise InvalidState, "worktrees: ordinary checkout path must be absolute" unless source.fetch("path").start_with?("/")
      parent = canonical_system_path(source.fetch("path"))
      safe_path!(parent)
      raise InvalidState, "worktrees: ordinary checkout missing #{parent}" unless File.directory?(parent)
      top, common, admin = git!(parent, "rev-parse", "--path-format=absolute",
                               "--show-toplevel", "--git-common-dir", "--absolute-git-dir").lines.map(&:strip)
      common = File.expand_path(common)
      admin = File.expand_path(admin)
      raise InvalidState, "worktrees: ambiguous parent repository" unless File.realpath(top) == File.realpath(parent) && common == admin
      safe_path!(common)
      raise InvalidState, "worktrees: remote identity changed" unless git!(parent, "remote", "get-url", source.fetch("remote")) == source.fetch("remote_url")
      raise InvalidState, "worktrees: prepared object missing" unless git(parent, "cat-file", "-e", "#{source.fetch('pushed_sha')}^{commit}", allow_failure: true).last
      [parent, common]
    end

    def verify_entry!(entry)
      path, parent = entry.fetch("path"), entry.fetch("parent")
      safe_path!(path)
      raise InvalidState, "worktrees: missing path #{path}" unless File.directory?(path)
      actual_parent, expected_common = parent_identity!(
        { "path" => parent, "remote" => entry.fetch("remote"), "remote_url" => entry.fetch("remote_url"), "pushed_sha" => entry.fetch("base_sha") },
        entry.fetch("name")
      )
      raise InvalidState, "worktrees: parent changed" unless actual_parent == parent
      common, head = git!(path, "rev-parse", "--path-format=absolute", "--git-common-dir", "HEAD").lines.map(&:strip)
      common = File.expand_path(common)
      raise InvalidState, "worktrees: Git administration changed" unless common == expected_common
      raise InvalidState, "worktrees: base changed" unless head == entry.fetch("base_sha")
      registry = git!(parent, "worktree", "list", "--porcelain", "-z").split("\0")
      rows = registry.slice_before { |row| row.start_with?("worktree ") }
      matches = rows.select { |row| row.first == "worktree #{path}" }.to_a
      raise InvalidState, "worktrees: Git registry mismatch" unless matches.length == 1 &&
        matches.first.include?("HEAD #{entry.fetch('base_sha')}") &&
        matches.first.include?(entry["branch"] ? "branch refs/heads/#{entry['branch']}" : "detached")
      # Git's .git pointer is a file, never a directory controlled by the worker.
      raise InvalidState, "worktrees: foreign Git pointer" unless File.file?(File.join(path, ".git")) && !File.symlink?(File.join(path, ".git"))
      true
    end

    def git(path, *args, allow_failure: false)
      stdout, stderr, status = Open3.capture3("git", *args, chdir: path)
      [stdout.strip, stderr.strip, status.success?]
    end

    def git!(path, *args)
      stdout, stderr, ok = git(path, *args)
      raise RepositoryError, "git #{args.first} failed: #{stderr}" unless ok
      stdout
    end

    def save!(inventory)
      temporary = "#{@record_path}.tmp"
      File.open(temporary, "w", 0o600) { |file| file.write(JSON.pretty_generate(inventory) + "\n"); file.flush; file.fsync }
      File.rename(temporary, @record_path)
    end
  end
end
