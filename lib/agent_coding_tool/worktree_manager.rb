# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require "tempfile"

module AgentCodingTool
  # Host-owned worktree inventory. The worker cannot write the private run record.
  class WorktreeManager
    SCHEMA = "agent-coding-tool-worktrees/v1"
    SYSTEM_ALIASES = { "/var" => "/private/var", "/tmp" => "/private/tmp" }.freeze

    # Returns unexpected immediate/attempt-directory children for verified owned
    # paths. Supports legacy fixed paths and recorded attempt containers only;
    # symlinked/foreign task directories raise. Does not recurse into worktrees.
    def self.foreign_task_paths(root:, task_id:, paths:)
      task_path = File.join(canonical_system_path(root), task_id)
      return [] unless File.exist?(task_path) || File.symlink?(task_path)
      raise InvalidState, "worktrees: foreign task path" unless File.directory?(task_path) && !File.symlink?(task_path)
      containers = paths.map { |path| File.dirname(path) }.reject { |path| path == task_path }.uniq
      actual = IncidentalMetadata.children(task_path).map { |name| File.join(task_path, name) }
      containers.each do |container|
        next unless actual.include?(container)
        raise InvalidState, "worktrees: foreign attempt container" unless File.directory?(container) && !File.symlink?(container)
        actual.concat(IncidentalMetadata.children(container).map { |name| File.join(container, name) })
      end
      actual - paths - containers
    end

    # Selects legacy or attempt paths and an optional host inventory witness.
    # The witness must persist before any native addition; failures preserve the
    # inventory and prevent mutation. No filesystem work occurs on initialization.
    def initialize(root:, record_path:, attempt_paths: false, invocation_id: nil, inventory_written: nil)
      @root = canonical_system_path(root)
      @record_path = canonical_system_path(record_path)
      @attempt_paths = attempt_paths
      @invocation_id = invocation_id
      @inventory_written = inventory_written
    end

    # Checks only sources consumed by imminent worktree creation, without writes
    # or fetching. Returns repository/object identities; unsafe or missing parents
    # raise InvalidState. Manual preparation/start need not consume these objects.
    def creation_readiness!(task:, snapshot:)
      task.fetch("repositories").keys.map do |name|
        source = snapshot.fetch(name)
        parent_identity!(source, name)
        { "repository" => name, "path" => source.fetch("path"),
          "object" => source.fetch("pushed_sha"), "action" => "worktree creation", "status" => "verified" }
      end
    end

    # Creates exact prepared writer/read-only worktrees and returns the verified
    # inventory. Refuses collisions/foreign authority; errors retain every marker,
    # resource and branch without repair, including interrupted native additions.
    def create(task_id:, attempt:, task:, snapshot:)
      safe_components!(task_id, attempt, task, snapshot)
      safe_path!(@root)
      raise InvalidState, "worktrees: foreign record already exists" if File.exist?(@record_path) || File.symlink?(@record_path)
      if @attempt_paths
        container = File.join(@root, task_id, "attempt-#{attempt}")
        safe_path!(container)
        raise InvalidState, "worktrees: occupied attempt container #{container}; inspect manually" if
          File.exist?(container) || File.symlink?(container)
      end
      task.fetch("repositories").each_key do |name|
        path = worktree_path(task_id, attempt, name, @attempt_paths)
        safe_path!(path)
        raise InvalidState, "worktrees: occupied path #{path}; inspect manually" if File.exist?(path) || File.symlink?(path)
      end
      FileUtils.mkdir_p(@root)
      entries = task.fetch("repositories").map do |name, spec|
        source = snapshot.fetch(name)
        path = worktree_path(task_id, attempt, name, @attempt_paths)
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
      raise InvalidState, "worktrees: at least one writer required" unless entries.any? { |e| e["access"] == "write" }
      writers = entries.select { |entry| entry["access"] == "write" }
      raise InvalidState, "worktrees: writable repositories share an authority" unless
        writers.map { |entry| entry.fetch("parent") }.uniq.length == writers.length &&
        writers.map { |entry| entry.fetch("remote_url") }.uniq.length == writers.length
      if entries.any? { |entry| @root == entry["parent"] || @root.start_with?("#{entry['parent']}/") } ||
         @root == "/Users/davidnorris/code/adventure-finder-components" ||
         @root.start_with?("/Users/davidnorris/code/adventure-finder-components/")
        raise InvalidState, "worktrees: root overlaps an ordinary checkout or canonical component root"
      end
      entries.each do |entry|
        # A separate worktree nested inside another checkout still shares its
        # candidate filesystem. Inspect only each new path's nearest existing
        # ancestor, not an inventory of external workers or their activity.
        ancestor = File.dirname(entry.fetch("path"))
        ancestor = File.dirname(ancestor) until File.exist?(ancestor)
        if git(ancestor, "rev-parse", "--show-toplevel").last
          raise InvalidState, "worktrees: target overlaps an existing Git checkout"
        end
        if entry["branch"] && git(entry.fetch("parent"), "show-ref", "--verify", "--quiet", "refs/heads/#{entry['branch']}", allow_failure: true).last
          raise InvalidState, "worktrees: conflicting branch #{entry['branch']}"
        end
      end
      inventory = { "schema_version" => SCHEMA, "task_id" => task_id, "attempt" => attempt, "root" => @root, "entries" => entries }
      inventory["layout"] = "attempt" if @attempt_paths
      inventory["invocation_id"] = @invocation_id if @invocation_id
      save!(inventory)
      @inventory_written&.call
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

    # Returns verified native ownership without writes. Explicit pre-worker
    # inspection may verify pending/creating markers; ordinary consumers still
    # refuse partial creation. Wrong identity, absent or ambiguous resources raise.
    def inspect!(head_overrides: {}, allow_partial: false)
      raise InvalidState, "worktrees: missing/foreign ownership record" if File.symlink?(@record_path) || !File.file?(@record_path)
      inventory = JSON.parse(File.read(@record_path))
      unless inventory.is_a?(Hash) && inventory["schema_version"] == SCHEMA &&
             inventory["root"] == @root && [nil, "attempt"].include?(inventory["layout"]) && inventory["entries"].is_a?(Array) &&
             inventory["entries"].any? { |e| e["access"] == "write" }
        raise InvalidState, "worktrees: invalid ownership record"
      end
      repositories = inventory.fetch("entries").to_h { |entry| [entry.fetch("name"), {}] }
      safe_components!(inventory.fetch("task_id"), inventory.fetch("attempt"), { "repositories" => repositories }, repositories)
      names = inventory.fetch("entries").map { |entry| entry.fetch("name") }
      writers = inventory.fetch("entries").select { |entry| entry["access"] == "write" }
      raise InvalidState, "worktrees: duplicate repository identity" unless
        names.uniq == names &&
        writers.map { |entry| entry.fetch("parent") }.uniq.length == writers.length &&
        writers.map { |entry| entry.fetch("remote_url") }.uniq.length == writers.length
      inventory.fetch("entries").each do |entry|
        unless entry.is_a?(Hash) && (%w[ready removing removed] + (allow_partial ? %w[pending creating] : [])).include?(entry["state"]) &&
               entry["task_id"] == inventory["task_id"] && entry["attempt"] == inventory["attempt"] &&
               entry["path"] == worktree_path(inventory.fetch("task_id"), inventory.fetch("attempt"), entry.fetch("name"), inventory["layout"] == "attempt") &&
               %w[write read_only].include?(entry["access"]) &&
               entry["branch"] == (entry["access"] == "write" ? "act/#{inventory.fetch('task_id')}/attempt-#{inventory.fetch('attempt')}" : nil)
          raise InvalidState, "worktrees: partial or conflicting ownership; inspect #{@record_path}"
        end
        if %w[pending creating].include?(entry["state"])
          if entry["state"] == "creating" && File.directory?(entry.fetch("path"))
            verify_entry!(entry, expected_head: entry.fetch("base_sha"))
          else
            verify_absent_entry!(entry)
            if entry["branch"] && git(entry.fetch("parent"), "show-ref", "--verify", "--quiet", "refs/heads/#{entry['branch']}").last
              raise InvalidState, "worktrees: unaccounted creation branch"
            end
          end
        elsif entry["state"] == "removed" || (entry["state"] == "removing" && !File.exist?(entry.fetch("path")) && !File.symlink?(entry.fetch("path")))
          verify_absent_entry!(entry)
        else
          verify_entry!(entry, expected_head: head_overrides.fetch(entry.fetch("name"), entry.fetch("base_sha")))
        end
      end
      inventory
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError
      raise InvalidState, "worktrees: malformed ownership; inspect #{@record_path}"
    end

    def cleanup_preflight(head_overrides: {})
      inventory = inspect!(head_overrides: head_overrides)
      inventory.fetch("entries").map do |entry|
        next { "path" => entry.fetch("path"), "branch" => entry["branch"], "access" => entry.fetch("access"),
               "dirty" => false, "blockers" => [], "state" => "removed" } if
          entry["state"] == "removed" || (entry["state"] == "removing" && !File.exist?(entry.fetch("path")))
        dirty = !IncidentalMetadata.git_status(entry.fetch("path"), ignored: true) { |*args| git!(entry.fetch("path"), *args) }.empty?
        { "path" => entry.fetch("path"), "branch" => entry["branch"],
          "access" => entry.fetch("access"), "dirty" => dirty, "state" => entry.fetch("state"),
          "blockers" => dirty ? ["worktree contains changes"] : [] }
      end
    end

    # Called only after a task-wide, read-only cleanup preflight. The marker
    # distinguishes an interrupted native removal from an unowned missing path.
    def remove_entry!(name, head_overrides: {})
      inventory = inspect!(head_overrides: head_overrides)
      entry = inventory.fetch("entries").find { |item| item["name"] == name }
      raise InvalidState, "worktrees: unrecorded cleanup target" unless entry
      return inventory if entry["state"] == "removed"
      if entry["state"] == "ready"
        entry["state"] = "removing"
        save!(inventory)
      end
      if File.directory?(entry.fetch("path"))
        verify_entry!(entry, expected_head: head_overrides.fetch(name, entry.fetch("base_sha")))
        raise InvalidState, "worktrees: worktree contains changes" unless
          IncidentalMetadata.git_status(entry.fetch("path"), ignored: true) { |*args| git!(entry.fetch("path"), *args) }.empty?
        # Native Git otherwise refuses untracked Finder files. A command-local
        # exclude is safe only after the complete ignored/untracked inventory
        # above is clear. No force, persistent ignore change or individual file
        # removal is permitted; Git still checks native ownership and dirtiness.
        Tempfile.create("act-metadata-excludes-") do |excludes|
          excludes.write(".DS_Store\n")
          excludes.flush
          raise InvalidState, "worktrees: worktree contains changes" unless
            IncidentalMetadata.git_status(entry.fetch("path"), ignored: true) { |*args| git!(entry.fetch("path"), *args) }.empty?
          git!(entry.fetch("parent"), "-c", "core.excludesFile=#{excludes.path}", "worktree", "remove", "--", entry.fetch("path"))
        end
      end
      verify_absent_entry!(entry)
      entry["state"] = "removed"
      save!(inventory)
      inventory
    end

    private

    # Returns the exact inventory path. Legacy v1 records omit layout and retain
    # fixed paths; new launch inventories explicitly select attempt directories.
    def worktree_path(task_id, attempt, name, attempt_paths)
      parts = [@root, task_id]
      parts << "attempt-#{attempt}" if attempt_paths
      File.join(*parts, name)
    end

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

    # Returns verified local parent/common Git paths for a snapshot and repo name.
    # Unsafe paths, changed identity or a missing prepared commit raise without
    # fetching or repairing; the ordinary checkout need not be at that commit.
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
      raise InvalidState, "Local #{name} repo is missing required commit #{source.fetch('pushed_sha')} (likely not fetched from remote). " \
        "ACT creates worker worktrees from existing local Git storage and cannot create the worker workspace from #{parent}; " \
        "blocked action: worktree creation. Fetch the required commit from the configured remote #{source.fetch('remote')} " \
        "(#{source.fetch('remote_url')}) into that local repository, then retry launch. " \
        "Pulling, resetting or switching the ordinary checkout is unnecessary for this barrier. ACT performed no fetch or repair." unless
        git(parent, "--no-replace-objects", "cat-file", "-e", "#{source.fetch('pushed_sha')}^{commit}",
            allow_failure: true, env: { "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0" }).last
      [parent, common]
    end

    # Checks an entry's native path, common/admin backpointer, registry, branch,
    # remote and exact expected HEAD. Returns true or raises without mutation.
    def verify_entry!(entry, expected_head:)
      path, parent = entry.fetch("path"), entry.fetch("parent")
      safe_path!(path)
      raise InvalidState, "worktrees: missing path #{path}" unless File.directory?(path)
      actual_parent, expected_common = parent_identity!(
        { "path" => parent, "remote" => entry.fetch("remote"), "remote_url" => entry.fetch("remote_url"), "pushed_sha" => entry.fetch("base_sha") },
        entry.fetch("name")
      )
      raise InvalidState, "worktrees: parent changed" unless actual_parent == parent
      common, head, admin = git!(path, "rev-parse", "--path-format=absolute", "--git-common-dir", "HEAD", "--absolute-git-dir").lines.map(&:strip)
      common = File.expand_path(common)
      raise InvalidState, "worktrees: Git administration changed" unless common == expected_common
      safe_path!(admin)
      pointer = File.join(admin, "gitdir")
      raise InvalidState, "worktrees: native Git backpointer changed" unless
        admin.start_with?("#{expected_common}/worktrees/") && File.file?(pointer) && !File.symlink?(pointer) &&
        File.binread(pointer).strip == File.join(path, ".git")
      raise InvalidState, "worktrees: HEAD changed" unless head == expected_head
      registry = git!(parent, "worktree", "list", "--porcelain", "-z").split("\0")
      rows = registry.slice_before { |row| row.start_with?("worktree ") }
      matches = rows.select { |row| row.first == "worktree #{path}" }.to_a
      raise InvalidState, "worktrees: Git registry mismatch" unless matches.length == 1 &&
        matches.first.include?("HEAD #{expected_head}") &&
        matches.first.include?(entry["branch"] ? "branch refs/heads/#{entry['branch']}" : "detached")
      # Git's .git pointer is a file, never a directory controlled by the worker.
      raise InvalidState, "worktrees: foreign Git pointer" unless File.file?(File.join(path, ".git")) && !File.symlink?(File.join(path, ".git"))
      true
    end

    def verify_absent_entry!(entry)
      path, parent = entry.fetch("path"), entry.fetch("parent")
      safe_path!(path)
      parent_identity!({ "path" => parent, "remote" => entry.fetch("remote"),
                         "remote_url" => entry.fetch("remote_url"), "pushed_sha" => entry.fetch("base_sha") },
                       entry.fetch("name"))
      raise InvalidState, "worktrees: cleanup path reoccupied" if File.exist?(path) || File.symlink?(path)
      registry = git!(parent, "worktree", "list", "--porcelain", "-z")
      raise InvalidState, "worktrees: removed path remains registered" if registry.split("\0").include?("worktree #{path}")
      true
    end

    def git(path, *args, allow_failure: false, env: {})
      command = ["git", *args]
      command.unshift(env) unless env.empty?
      stdout, stderr, status = Open3.capture3(*command, chdir: path)
      [args.include?("-z") ? stdout : stdout.strip, stderr.strip, status.success?]
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
