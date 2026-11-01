# frozen_string_literal: true

require "fileutils"
require "monitor"
require_relative "objects"
require_relative "../../../lib/agent_coding_tool/command_transport"

module MemoryGit
  # Mutable shared repository authority, distinct from each checkout's index/HEAD.
  class Repository
    attr_reader :objects, :refs, :config, :remotes, :worktrees, :common

    # Copies immutable template objects into fresh stores; performs no IO.
    def initialize(common:, template:)
      @common = common.freeze
      @objects, @refs, @config, @remotes, @worktrees = {}, {}, {}, {}, {}
      template.commits.each { |commit| store(commit) }
    end

    # Stores an immutable blob/tree/commit and descendants; collision raises Mismatch.
    # Returns its ID. Parent existence is checked by builders, not import ordering.
    def store(object)
      if @objects.key?(object.oid) && @objects.fetch(object.oid) != object
        existing = @objects.fetch(object.oid)
        same = case object
               when Blob then existing.is_a?(Blob) && existing.bytes == object.bytes
               when Tree then existing.is_a?(Tree) && existing.entries == object.entries
               when Commit then existing.is_a?(Commit) && [existing.tree.oid, existing.parents, existing.message] == [object.tree.oid, object.parents, object.message]
               end
        raise Mismatch, "object ID collision #{object.oid}" unless same
      end
      case object
      when Commit then store(object.tree)
      when Tree then object.entries.each_value { |entry| store(entry.blob) }
      end
      @objects[object.oid] = object
      object.oid
    end
  end

  # Per-worktree HEAD/index/ignore state; ordinary checkout uses common == admin.
  class Checkout
    attr_reader :path, :repository, :admin, :index, :ignored
    attr_accessor :head_ref, :detached

    # Takes authority, absolute identities and a symbolic or detached HEAD.
    # Copies the committed tree into an independent mutable index; no IO.
    def initialize(path:, repository:, admin:, head_ref: nil, detached: nil)
      @path, @repository, @admin = path.freeze, repository, admin.freeze
      @head_ref, @detached = head_ref, detached
      @index = tree.entries.dup
      @ignored = []
    end

    # Returns the current commit ID, or nil for an unborn branch.
    def head = head_ref ? repository.refs[head_ref] : detached

    # Returns HEAD's immutable tree or an empty tree when unborn.
    def tree
      return Tree.new({}) unless head
      commit = repository.objects[head]
      tree = repository.objects[commit.tree.oid] if commit.is_a?(Commit)
      raise Refusal, "HEAD tree unavailable" unless tree.is_a?(Tree)
      tree
    end

    # Updates symbolic target or detached HEAD; returns ID, without materializing.
    def move_head!(oid)
      head_ref ? repository.refs[head_ref] = oid : self.detached = oid
    end
  end

  # Independent remote object/ref store. Advertisement does not require local objects.
  class Remote
    attr_reader :url, :objects, :refs
    attr_accessor :available

    # Copies source immutable objects/refs into new stores; no native repository.
    def initialize(url:, repository: nil)
      @url = url.dup.freeze
      @objects = repository ? repository.objects.dup : {}
      @refs = repository ? repository.refs.dup : {}
      @available = true
    end
  end

  # Fresh case world and strict CommandTransport implementation. Only declared
  # finite commands exist; TST-36 may define command_diff/apply/etc in its own files.
  class World
    COMMANDS = %w[rev-parse show cat-file symbolic-ref show-ref merge-base config remote
      ls-remote fetch push status ls-files ls-tree check-ignore add write-tree commit
      branch worktree diff diff-tree apply read-tree update-index hash-object reset].freeze
    attr_reader :root

    # Takes an existing private fixture root; canonicalizes it and initializes
    # independent stores/faults. Missing roots raise filesystem exceptions.
    def initialize(root:)
      @root = File.realpath(root)
      @checkouts, @remotes, @faults, @requests, @git_identities = {}, {}, [], [], {}
      @lock = Monitor.new
    end

    # Builds a materialized ordinary checkout from an immutable template. Paths
    # must be absent/empty beneath root; collisions/unsafe parents raise Mismatch.
    def repository(path:, template: Template.new(commits: []), branch: "main")
      path = owned_path!(path)
      vacant!(path)
      ref!("refs/heads/#{branch}")
      authority = Repository.new(common: File.join(path, ".git"), template: template)
      authority.refs["refs/heads/#{branch}"] = template.head if template.head
      checkout = Checkout.new(path: path, repository: authority, admin: authority.common, head_ref: "refs/heads/#{branch}")
      @checkouts[path] = checkout
      authority.worktrees[path] = checkout
      FileUtils.mkdir_p(checkout.admin)
      File.binwrite(File.join(checkout.admin, "MEMORY_GIT"), "test-only; authoritative state is in Ruby memory\n")
      materialize!(checkout, {}, checkout.index)
      @git_identities[path] = File.lstat(checkout.admin).then { |stat| [stat.dev, stat.ino] }
      checkout
    end

    # Creates a fresh remote, optionally seeded from a checkout, and returns it.
    # Duplicate URLs raise Mismatch; remote paths are identities, never native repos.
    def remote(url:, from: nil)
      raise Mismatch, "duplicate remote #{url}" if @remotes.key?(url)
      @remotes[url.dup.freeze] = Remote.new(url: url, repository: from&.repository)
    end

    # Binds a named remote/config explicitly. Returns remote; unknown worlds refuse.
    def connect(checkout, remote, name: "origin")
      raise Mismatch, "unknown remote" unless @remotes[remote.url].equal?(remote)
      checkout.repository.remotes[name.dup.freeze] = remote.url
      configure(checkout, "remote.#{name}.url", remote.url)
      remote
    end

    # Mutates authoritative config; direct .git/config bytes are deliberately not
    # reparsed. Returns value. Callers must use this adapter for setup mutations.
    def configure(checkout, key, value)
      raise Mismatch, "config requires String key/value" unless key.is_a?(String) && value.is_a?(String)
      checkout.repository.config[key.dup.freeze] = value.dup.freeze
      if key.match?(/\Aremote\.[^.]+\.url\z/)
        checkout.repository.remotes[key.split(".")[1]] = value.dup.freeze
      end
      value
    end

    # Copies a world checkout's ordinary authority, index, ignores and physical
    # working bytes into fresh independent state. Registered linked sources refuse.
    def copy(checkout, path:)
      raise Mismatch, "copy requires ordinary checkout" unless checkout.admin == checkout.repository.common
      clone = repository(path: path, template: Template.new(commits: checkout.repository.objects.values.grep(Commit), head: checkout.head),
        branch: (checkout.head_ref || "refs/heads/main").delete_prefix("refs/heads/"))
      clone.repository.refs.replace(checkout.repository.refs)
      clone.repository.objects.replace(checkout.repository.objects)
      clone.repository.config.replace(checkout.repository.config)
      clone.repository.remotes.replace(checkout.repository.remotes)
      clone.head_ref, clone.detached = checkout.head_ref, checkout.detached
      clone.index.replace(checkout.index)
      clone.ignored.replace(checkout.ignored.map(&:dup))
      materialize!(clone, scan(clone), scan(checkout))
      clone
    end

    # Builds/stores a commit directly, optionally advancing HEAD and projecting
    # files. Explicit imported OIDs bind fixture pins, never real source provenance.
    def build_commit(checkout, files:, parents: nil, message: "change", oid: nil, advance: false)
      parents ||= [checkout.head].compact
      raise Mismatch, "missing parent" unless parents.all? { |parent| checkout.repository.objects[parent].is_a?(Commit) }
      commit = Commit.new(tree: Tree.new(files), parents: parents, message: message, oid: oid)
      checkout.repository.store(commit)
      if advance
        previous = checkout.index.dup
        checkout.move_head!(commit.oid)
        checkout.index.replace(commit.tree.entries)
        materialize!(checkout, previous, checkout.index)
      end
      commit
    end

    # Schedules one exact request/effect fault. phase is before/after command or
    # before_effect/after_effect; skip suppresses only a named required mutation.
    # Returns schedule; unknown phases or ambiguous outcomes raise Mismatch.
    def fault(argv:, cwd: nil, env: {}, input: "", timeout: nil, options: {}, phase: :before,
              effect: nil, skip: false, result: nil, required: true, &action)
      raise Mismatch, "unknown fault phase" unless %i[before after before_effect after_effect].include?(phase)
      raise Mismatch, "effect fault needs name" if phase.to_s.end_with?("effect") && !effect
      raise Mismatch, "skip requires before_effect" if skip && phase != :before_effect
      raise Mismatch, "fault result requires CommandResult" if result && !result.is_a?(AgentCodingTool::CommandResult)
      raise Mismatch, "result override requires after command" if result && phase != :after
      record = { request: envelope(argv, cwd, env, input, timeout, options), phase: phase,
        effect: effect, skip: skip, result: result, required: required, action: action, consumed: false }
      @faults << record
      record
    end

    # Returns detached request observations, not canned results or process statuses.
    def requests = Marshal.load(Marshal.dump(@requests))

    # Refuses any unconsumed required fault. Returns true; call from every teardown.
    def verify!
      pending = @faults.count { |fault| fault[:required] && !fault[:consumed] }
      raise Mismatch, "#{pending} required faults unconsumed" unless pending.zero?
      true
    end

    # Executes one serialized finite request and returns CommandResult. Unsupported
    # argv/env/cwd/options raise Mismatch outside StandardError, with no fallback.
    # Modeled Git refusals become nonzero results; genuine filesystem errors remain.
    def call(argv, cwd: nil, env: {}, input: "", timeout: nil, **options)
      @lock.synchronize do
        previous_request = @current_request
        validate_envelope!(argv, cwd, env, input, timeout, options)
        request = envelope(argv, cwd, env, input, timeout, options)
        arguments, directory, settings = prefix(argv.drop(1), cwd)
        command = arguments.shift
        method = "command_#{command.to_s.tr('-', '_')}"
        raise Mismatch, "unsupported memory Git command #{command.inspect}" unless COMMANDS.include?(command) && respond_to?(method, true)
        checkout = directory && locate(directory)
        if directory && directory != root && !directory.start_with?(root + "/")
          raise Mismatch, "cwd outside memory world"
        end
        unless command == "ls-remote" || checkout || (command == "rev-parse" && directory)
          raise Mismatch, "undeclared repository cwd #{directory.inspect}"
        end
        @requests << request
        @current_request = request
        check_pointer!(checkout) if checkout
        run_faults(:before)
        response = send(method, checkout_for_command(checkout, env), arguments, input, settings)
        override = run_faults(:after)
        override&.fetch(:result) || response
      rescue Refusal => error
        result("", "fatal: #{error.message}\n", error.code)
      ensure
        @current_request = previous_request
      end
    end

    # Produces raw binary streams and the shared result protocol; no fake PID.
    def result(stdout = "", stderr = "", code = 0)
      AgentCodingTool::CommandResult.new(stdout: stdout.b, stderr: stderr.b, exitstatus: code)
    end

    # Captures physical files/modes/links independently of index/HEAD. Does not
    # follow symlink directories or read special files; omits root .git only.
    def scan(checkout, directory = checkout.path, relative = "")
      Dir.children(directory, encoding: Encoding::BINARY).sort.each_with_object({}) do |name, files|
        next if relative.empty? && name == ".git"
        path = relative.empty? ? name : "#{relative}/#{name}".b
        absolute = File.join(directory, name)
        stat = File.lstat(absolute)
        if stat.symlink?
          files[path] = Entry.new(File.readlink(absolute).b, mode: "120000")
        elsif stat.directory?
          files.merge!(scan(checkout, absolute, path))
        elsif stat.file?
          files[path] = Entry.new(File.binread(absolute), mode: (stat.mode & 0o111).zero? ? "100644" : "100755")
        end
      end
    end

    # Projects a declared tree transition using real bytes/modes/symlinks. Checks
    # every ancestor before writes; unsafe paths or special entries raise Mismatch.
    # This is the materialization seam for TST-36, not a patch parser.
    def materialize!(checkout, before, after)
      (before.keys - after.keys).sort_by { |path| -path.bytesize }.each do |path|
        target = safe_file!(checkout, path)
        File.unlink(target) if File.file?(target) || File.symlink?(target)
        parent = File.dirname(target)
        while parent != checkout.path && File.directory?(parent) && Dir.empty?(parent)
          Dir.rmdir(parent)
          parent = File.dirname(parent)
        end
      end
      after.each do |path, entry|
        target = safe_file!(checkout, path)
        raise Mismatch, "materialization directory collision" if File.directory?(target) && !File.symlink?(target)
        if File.exist?(target) && !File.symlink?(target)
          stat = File.lstat(target)
          raise Mismatch, "materialization special/hardlinked entry" unless stat.file? && stat.nlink == 1
        end
        FileUtils.mkdir_p(File.dirname(target))
        File.unlink(target) if File.symlink?(target) || (entry.mode == "120000" && File.exist?(target))
        if entry.mode == "120000"
          File.symlink(entry.blob.bytes, target)
        else
          File.binwrite(target, entry.blob.bytes)
          File.chmod(entry.mode == "100755" ? 0o755 : 0o644, target)
        end
      end
    end

    private

    # Deep-copies the exact request envelope so caller mutation cannot change faults.
    def envelope(argv, cwd, env, input, timeout, options)
      Marshal.load(Marshal.dump([argv, { cwd: cwd, env: env, input: input, timeout: timeout }.merge(options)]))
    end

    # Validates supported process fields before any effect/fault can execute.
    def validate_envelope!(argv, cwd, env, input, timeout, options)
      valid = argv.is_a?(Array) && argv.first == "git" && argv.all? { |part| part.is_a?(String) && !part.include?("\0") } &&
        input.is_a?(String) && (cwd.nil? || (cwd.is_a?(String) && !cwd.include?("\0"))) && supported_environment?(env) &&
        (options.keys - %i[binmode pgroup]).empty? && options.values.all? { |value| value == true } &&
        (timeout.nil? || (timeout.is_a?(Numeric) && timeout.real? && timeout.finite? && timeout.positive?))
      raise Mismatch, "unsupported memory Git request envelope" unless valid
      if cwd && (!File.directory?(cwd) || File.expand_path(cwd) != cwd || File.realpath(cwd) != cwd)
        raise Mismatch, "unknown/unsafe cwd #{cwd.inspect}"
      end
    end

    # Defines the finite base environment. A separately owned capability may
    # prepend an exact additional envelope check and delegate remaining keys here;
    # process/cwd/argv validation still runs. Default rejects scratch-index overrides.
    def supported_environment?(environment)
      environment.is_a?(Hash) && environment.all? do |key, value|
        { "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0", "GIT_PAGER" => "cat" }[key] == value && !value.nil?
      end
    end

    # Returns the ordinary checkout command context. TST-36 may prepend a declared
    # scratch-index context using its own files after validating that environment;
    # it must retain shared authority/path and never replace production decisions.
    def checkout_for_command(checkout, _environment) = checkout

    # Parses only observed global flags, -C and command-local config overrides.
    # Returns remaining args, absolute directory and settings; unknown flags refuse.
    def prefix(arguments, cwd)
      directory, settings = cwd, {}
      while arguments.first&.start_with?("-")
        case arguments.shift
        when "--no-replace-objects", "--no-optional-locks", "--literal-pathspecs" then next
        when "-C"
          directory = arguments.shift
          raise Mismatch, "undeclared -C" unless directory && directory.start_with?("/") &&
            (directory == root || directory.start_with?(root + "/")) && File.directory?(directory) && File.realpath(directory) == directory
        when "-c"
          setting = arguments.shift
          key, value = setting.to_s.split("=", 2)
          allowed = (key == "core.hooksPath" && value == "/dev/null") || (key == "commit.gpgsign" && value == "false") ||
            (key == "core.excludesFile" && value && File.file?(value) && value.start_with?(root + "/") && File.realpath(value) == value)
          raise Mismatch, "unknown command config #{setting.inspect}" unless allowed
          settings[key] = value
        else raise Mismatch, "unknown global Git option"
        end
      end
      [arguments, directory, settings]
    end

    # Locates registered authority without deriving authority from copied .git bytes.
    def locate(directory)
      @checkouts.values.select { |checkout| directory == checkout.path || directory.start_with?(checkout.path + "/") }
        .max_by { |checkout| checkout.path.length }
    end

    # Resolves a write path strictly beneath the owned canonical fixture root.
    def owned_path!(path)
      path = File.expand_path(path, root)
      raise Mismatch, "path outside memory world" unless path.start_with?(root + "/")
      cursor = path
      until cursor == root
        raise Mismatch, "symlinked world path" if File.symlink?(cursor)
        cursor = File.dirname(cursor)
      end
      path
    end

    # Checks a target is absent or an empty real directory; never borrows content.
    def vacant!(path)
      raise Mismatch, "occupied world path #{path}" if @checkouts.key?(path) || File.symlink?(path) ||
        (File.exist?(path) && (!File.directory?(path) || !Dir.empty?(path)))
    end

    # Checks a relative file and each real ancestor before materializing content.
    def safe_file!(checkout, path)
      target = File.join(checkout.path, Tree.path!(path))
      owned_path!(File.dirname(target))
      cursor = File.dirname(target)
      until cursor == root
        raise Mismatch, "unsafe file ancestor" if File.symlink?(cursor) || (File.exist?(cursor) && !File.directory?(cursor))
        cursor = File.dirname(cursor)
      end
      target
    end

    # Requires the real root .git type/pointer to remain bound to registered
    # authority. Raw copies cannot register themselves by copying pointer bytes.
    def check_pointer!(checkout)
      pointer = File.join(checkout.path, ".git")
      valid = if checkout.admin == checkout.repository.common
                File.directory?(pointer) && !File.symlink?(pointer) &&
                  File.lstat(pointer).then { |stat| [stat.dev, stat.ino] } == @git_identities[checkout.path]
              else
                File.file?(pointer) && !File.symlink?(pointer) && File.binread(pointer) == "gitdir: #{checkout.admin}\n"
              end
      raise Refusal, "Git pointer missing or changed" unless valid
    end

    # Checks an explicit full ref name. Unsupported spelling raises Mismatch.
    def ref!(name)
      raise Mismatch, "unsupported ref #{name.inspect}" unless name.is_a?(String) &&
        name.match?(/\Arefs\/(heads|remotes|tags)\/[A-Za-z0-9_\/-]+(?:\.[A-Za-z0-9_-]+)*\z/) && !name.include?("..") && !name.end_with?("/", ".lock")
      name
    end

    # Consumes the next exact fault once; repeated envelopes target successive
    # commands/effects. Unrelated query order is not constrained. Returns record/nil.
    def run_faults(phase, effect = nil)
      fault = @faults.find { |entry| !entry[:consumed] && entry.values_at(:request, :phase, :effect) == [@current_request, phase, effect] }
      return unless fault
      fault[:consumed] = true
      fault[:action]&.call(self)
      fault
    end

    # Executes a named command mutation unless a deliberate fault suppresses it.
    # Returns block value/override, allowing independent journey fault controls.
    def effect!(name)
      fault = run_faults(:before_effect, name)
      value = yield unless fault && fault[:skip]
      run_faults(:after_effect, name)
      fault&.fetch(:result) || value
    end

    # Refuses nonempty stdin for all commands that do not consume input.
    def no_input!(input)
      raise Mismatch, "unexpected command stdin" unless input.empty?
    end

    # Requires one of an exact set of argv variants; unknown options never succeed.
    def exact!(arguments, *variants)
      raise Mismatch, "unsupported arguments #{arguments.inspect}" unless variants.include?(arguments)
    end
  end
end
