# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "rbconfig"
require "shellwords"

module AgentCodingTool
  # Applies one downloaded proposal with separate, invocation-local operator
  # consent for application, bounded validation and an optional local commit.
  # A manifest is untrusted data; it never supplies shell code or consent.
  class ApplyHandoff
    SCHEMA = "agent-coding-tool-apply/v1"
    GENERATED = %w[coverage/ tmp/ test/tmp/ test/version_tmp/].freeze

    # Binds configured repository discovery and terminal streams. No I/O occurs
    # until run; streams must support gets/tty? or write/flush as appropriate.
    def initialize(config:, input: $stdin, out: $stdout, err: $stderr)
      @config, @input, @out, @err = config, input, out, err
      @phase = "not applied"
    end

    # Reads a JSON path, previews and independently confirms each phase. Returns
    # zero for completed/declined workflows, exact failed child status (128+signal)
    # or 2 for refusal. Interrupt returns 130; failures never roll back changes.
    def run(path)
      load_manifest!(path)
      @initial = nil
      @initial = repository_states!
      @repositories.each do |name, repo|
        head = @initial.fetch(name).fetch(:head)
        if head != repo.fetch(:baseline)
          @out.puts "WARN: #{name}: baseline differs; expected #{repo.fetch(:baseline)}; actual #{head}"
        end
        warn_initial_changes!(name, repo)
      end
      @patch = artifact!
      check_patch!
      @out.puts "Target: #{@target.fetch(:path)} at #{@initial.fetch(@manifest.fetch('target')).fetch(:head)}"
      @out.puts "Files: #{@paths.join(', ')}"
      @out.write git!(@target, "apply", "--stat", input: @patch)
      return declined("application") unless confirm?("Apply patch?")

      @phase = "not applied; validation and commit not run"
      unchanged!(@initial)
      check_patch!
      @phase = "application started; result unverified; validation and commit not run"
      git!(@target, "apply", input: @patch)
      @phase = "applied; validation pending; commit pending"
      applied = repository_states!
      expected_changes!(applied)
      report
      @steps.each_with_index do |step, index|
        @out.puts "Validation #{index + 1}: #{Shellwords.join(step.fetch(:argv))}"
        @out.puts "  cwd: #{step.fetch(:cwd)}; environment changes: #{step.fetch(:env).inspect}"
      end
      @out.puts "Validation executes repository code with your privileges; it is not a sandbox."
      return declined("validation") unless confirm?("Run validation?")

      @phase = "applied; validation not run; commit not run"
      unchanged!(applied)
      @steps.each_with_index do |step, index|
        raise Error, "validation execution scope changed" unless validation_step!(@manifest.fetch("validation").fetch(index)) == step
        begin
          stdout, stderr, status = execute(step.fetch(:argv), cwd: step.fetch(:cwd), env: step.fetch(:env))
        rescue SystemCallError => error
          @phase = "applied; validation #{index + 1} could not start; commit not run"
          @err.puts "Validation #{index + 1}: #{error.class}; exit 127; #{@steps.length - index - 1} remaining unrun"
          return 127
        end
        @out.write stdout
        @err.write stderr
        code = status.exitstatus || 128 + status.termsig
        @out.puts "Validation #{index + 1}: exit #{code}"
        @phase = "applied; validation #{index + 1} failed; commit not run" unless code.zero?
        @out.puts "Validation #{index + 1}: exit #{code}; #{@steps.length - index - 1} remaining unrun" unless code.zero?
        # Check source even on a failing step, retaining the original exit code.
        begin
          unchanged!(applied)
        rescue Error, SystemCallError => error
          @phase = "applied; validation changed source; commit not run"
          @err.puts "ERROR: validation changed repository state: #{error.message}"
          @out.puts "#{@steps.length - index - 1} remaining validation steps unrun"
          return code.zero? ? 2 : code
        end
        return code unless code.zero?
      end
      @phase = "applied; validated; commit pending"
      report
      @out.write git!(@target, "diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", *@paths)
      @out.puts "Files (including new files): #{@paths.join(', ')}"
      @out.puts "Suggested commit message: #{@manifest.fetch('commit_message')}"
      return declined("commit") unless confirm?("Stage these files and commit?")

      @phase = "applied; validated; commit not run"
      unchanged!(applied)
      expected_changes!
      git!(@target, "add", "--", *@paths)
      @phase = "applied; validated; staged; commit pending"
      staged = repository_states!
      unless staged.all? { |name, state|
        keys = name == @manifest.fetch("target") ? %i[index index_diff] : []
        state.reject { |key, _| keys.include?(key) } == applied.fetch(name).reject { |key, _| keys.include?(key) }
      }
        raise Error, "repository content changed during staging"
      end
      unless unrelated_index(staged.fetch(@manifest.fetch("target"))) == unrelated_index(@initial.fetch(@manifest.fetch("target")))
        raise Error, "unrelated index entries changed during staging"
      end
      unless git!(@target, "diff", "--cached", "--name-only", "-z", "--", *@paths).split("\0").sort == @paths.sort
        raise Error, "staged paths differ from proposal"
      end
      tree = git!(@target, "write-tree").strip
      unchanged!(staged)
      @phase = "applied; validated; commit started; result unverified; inspect HEAD/index/worktree"
      stdout, stderr, status = execute(["git", "commit", "--only", "-m", @manifest.fetch("commit_message"), "--", *@paths], cwd: @target.fetch(:path))
      @out.write stdout
      @err.write stderr
      unless status.success?
        @phase = "applied; validated; commit failed; inspect index/worktree"
        return status.exitstatus || 128 + status.termsig
      end

      raise Error, "commit parent changed" unless git!(@target, "rev-parse", "HEAD^").strip == @initial.fetch(@manifest.fetch("target")).fetch(:head)
      unless git!(@target, "diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "HEAD").split("\0").sort == @paths.sort
        raise Error, "commit files differ from proposal"
      end
      unless git!(@target, "diff", "--no-ext-diff", "--no-textconv", tree, "HEAD", "--", *@paths).empty?
        raise Error, "committed proposal differs from validated index"
      end
      after = repository_states!
      target_after = after.fetch(@manifest.fetch("target"))
      unless unrelated_index(target_after) == unrelated_index(@initial.fetch(@manifest.fetch("target"))) &&
             target_after.fetch(:index_diff) == @initial.fetch(@manifest.fetch("target")).fetch(:index_diff) &&
             git!(@target, "diff", "--cached", "--name-only", "--", *@paths).empty?
        raise Error, "commit left unexpected index changes"
      end
      unless after.all? { |name, state|
        keys = name == @manifest.fetch("target") ? %i[head index index_diff] : []
        state.reject { |key, _| keys.include?(key) } == applied.fetch(name).reject { |key, _| keys.include?(key) }
      }
        raise Error, "source changed during commit"
      end
      @phase = "applied; validated; committed locally"
      0
    rescue Interrupt
      @err.puts "Interrupted; changes and any staged files remain inspectable."
      130
    rescue Error, JSON::ParserError, SystemCallError, ArgumentError, TypeError => error
      @err.puts "ERROR: apply: #{error.message}"
      2
    ensure
      report
    end

    private

    # Parses the complete strict v1 contract and resolves configured repositories
    # and validation actions. Missing/unknown fields or unsafe inputs raise Error.
    def load_manifest!(path)
      @manifest_path = File.realpath(path)
      @manifest_bytes = File.binread(@manifest_path)
      @manifest = JSON.parse(@manifest_bytes)
      fields!(@manifest, %w[schema target repositories patch paths validation commit_message])
      raise Error, "unsupported manifest schema" unless @manifest["schema"] == SCHEMA
      repositories = @manifest.fetch("repositories")
      raise Error, "repositories must be a nonempty object" unless repositories.is_a?(Hash) && !repositories.empty?
      @repositories = repositories.to_h do |name, spec|
        raise Error, "invalid repository name" unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
        fields!(spec, %w[path remote_url baseline])
        relative!(spec.fetch("path"))
        hash!(spec.fetch("baseline"), 40)
        raise Error, "invalid remote identity" unless spec["remote_url"].is_a?(String) && !spec["remote_url"].empty?
        path = contained!(@config.repo_root, spec.fetch("path"))
        [name, { path: path, baseline: spec.fetch("baseline"), identity: RepositoryIdentity.resolve(spec.fetch("remote_url")) }]
      end
      roots = @repositories.values.map { |repo| repo.fetch(:path) }
      raise Error, "repository roots overlap" if roots.combination(2).any? { |first, second| first == second || first.start_with?("#{second}/") || second.start_with?("#{first}/") }
      @target = @repositories[@manifest["target"]]
      raise Error, "target must name a declared repository" unless @target
      fields!(@manifest["patch"], %w[file sha256])
      basename = @manifest.fetch("patch").fetch("file")
      relative!(basename)
      raise Error, "patch must be a basename" unless File.basename(basename) == basename
      hash!(@manifest.fetch("patch").fetch("sha256"), 64)
      @artifact_path = File.join(File.dirname(@manifest_path), basename)
      @paths = @manifest.fetch("paths")
      raise Error, "paths must be nonempty and unique" unless @paths.is_a?(Array) && !@paths.empty? && @paths.uniq == @paths
      @paths.each { |entry| relative!(entry) }
      message = @manifest.fetch("commit_message")
      raise Error, "commit_message must be one nonempty line" unless message.is_a?(String) && !message.strip.empty? && !message.match?(/[[:cntrl:]]/)
      validation = @manifest.fetch("validation")
      raise Error, "validation must be a nonempty ordered array" unless validation.is_a?(Array) && !validation.empty?
      @steps = validation.map { |step| validation_step!(step) }
    end

    # Requires exactly the listed string keys on an object; returns nil or raises.
    def fields!(value, keys)
      raise Error, "missing or unknown manifest fields (expected #{keys.join(', ')})" unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    # Accepts an exact lowercase hexadecimal digest of length; otherwise raises.
    def hash!(value, length)
      raise Error, "malformed hash" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{#{length}}\z/)
    end

    # Accepts portable relative file components, including spaces and dotfiles.
    # Traversal, Git administration, option/pathspec syntax and controls raise.
    def relative!(value)
      unless value.is_a?(String) && value.split("/", -1).all? { |part|
        part.match?(/\A[A-Za-z0-9_. -]+\z/) && !%w[. .. .git].include?(part.downcase)
      } && !value.empty?
        raise Error, "unsafe relative path"
      end
    end

    # Resolves a portable manifest path (or root cwd) with repository containment.
    # Returns the absolute path; unsafe syntax or symlink components raise Error.
    def contained!(root, relative)
      relative!(relative) unless relative == "."
      repository_path!(root, relative)
    end

    # Resolves Git-discovered names without imposing manifest portability rules.
    # Returns an absolute contained path; empty, traversal, Git administration,
    # NUL or symlink components raise Error. A single dot denotes the root cwd.
    def repository_path!(root, relative)
      root = File.realpath(root)
      unless relative.is_a?(String) && !relative.empty? && !relative.include?("\0") &&
             (relative == "." || relative.split("/", -1).all? { |component| !["", ".", "..", ".git"].include?(component.downcase) })
        raise Error, "unsafe relative path"
      end
      path = root
      relative.split("/").each do |component|
        path = File.join(path, component)
        raise Error, "symlink path refused" if File.symlink?(path)
      end
      File.expand_path(path)
    end

    # Translates one supported action to fixed argv/cwd/environment, without a
    # shell. Only ACTD selection by declared repository name is permitted.
    def validation_step!(step)
      raise Error, "invalid validation action" unless step.is_a?(Hash)
      action = step["action"]
      extra = case action
              when "bundle_rake" then %w[tasks]
              when "ruby_test" then %w[files]
              when "git_diff_check" then []
              else raise Error, "unknown validation action"
              end
      fields!(step, %w[action repository cwd env] + extra)
      repo = @repositories[step["repository"]]
      raise Error, "validation repository is undeclared" unless repo
      cwd = contained!(repo.fetch(:path), step.fetch("cwd"))
      raise Error, "validation cwd must exist" unless File.directory?(cwd)
      environment = step.fetch("env")
      unless environment.is_a?(Hash) && (environment.keys - ["AGENT_CODING_TOOL_DATA_DIR"]).empty?
        raise Error, "unsupported validation environment"
      end
      env = environment.to_h do |key, name|
        selected = @repositories[name]
        raise Error, "ACTD environment must name a declared repository" unless selected
        [key, selected.fetch(:path)]
      end
      argv = case action
             when "bundle_rake"
               tasks = step.fetch("tasks")
               unless tasks.is_a?(Array) && !tasks.empty? && tasks.all? { |task| task.is_a?(String) && task.match?(/\A[A-Za-z0-9_][A-Za-z0-9_:]*\z/) }
                 raise Error, "invalid Rake task names"
               end
               ["bundle", "exec", "rake", *tasks]
             when "ruby_test"
               files = step.fetch("files")
               raise Error, "ruby_test requires one test file" unless files.is_a?(Array) && files.length == 1
               relative!(files.first)
               raise Error, "ruby_test requires a .rb file" unless files.first.end_with?(".rb")
               contained!(cwd, files.first)
               [RbConfig.ruby, "-Ilib:test", "--", files.first]
             when "git_diff_check" then ["git", "diff", "--check"]
             end
      { argv: argv, cwd: cwd, env: env }
    end

    # Returns original checked artifact bytes. Any symlink, changed manifest or
    # hash mismatch raises before application; caller cwd is never used.
    def artifact!
      raise Error, "manifest changed after preview" unless File.binread(@manifest_path) == @manifest_bytes
      raise Error, "patch must be a regular, nonsymlink file" unless File.file?(@artifact_path) && !File.symlink?(@artifact_path)
      bytes = File.binread(@artifact_path)
      raise Error, "patch SHA-256 mismatch" unless Digest::SHA256.hexdigest(bytes) == @manifest.fetch("patch").fetch("sha256")
      bytes
    end

    # Verifies exact patch paths, ordinary file modes, safe parents and native
    # applicability. No target bytes or index entries are changed by these reads.
    def check_patch!
      raise Error, "rename/copy patches are unsupported; use --no-renames" if @patch.match?(/^(?:rename|copy) (?:from|to) /)
      modes = @patch.scan(/^(?:old mode|new mode|new file mode|deleted file mode) (\d+)\r?$/).flatten
      raise Error, "only ordinary file patches are supported" unless (modes - %w[100644 100755]).empty?
      rows = git!(@target, "apply", "--numstat", "-z", input: @patch).split("\0")
      actual = rows.map do |row|
        match = /\A(?:\d+|-)\t(?:\d+|-)\t(.+)\z/m.match(row)
        raise Error, "unsupported patch path/rename" unless match
        relative!(match[1])
        match[1]
      end
      raise Error, "patch paths differ from manifest" unless actual.sort == @paths.sort
      @paths.each do |path|
        absolute = contained!(@target.fetch(:path), path)
        parent = File.dirname(absolute)
        until parent == @target.fetch(:path)
          raise Error, "patch parent is already occupied: #{path}" if File.exist?(parent) && !File.directory?(parent)
          parent = File.dirname(parent)
        end
        if File.exist?(absolute) && git!(@target, "ls-files", "-z", "--", path).empty?
          raise Error, "patch path is already occupied: #{path}"
        end
        _stdout, _stderr, status = execute(["git", "check-ignore", "--quiet", "--", path], cwd: @target.fetch(:path))
        raise Error, "ignored patch path refused: #{path}" unless status.exitstatus == 1
      end
      git!(@target, "apply", "--check", input: @patch)
    end

    # Captures actual HEAD, identity, index and file bytes/modes in
    # every declared repo. Ignored generated output is narrowly excluded only
    # when untracked; initial tree paths stay observed across deletion/commit.
    # Returns repository snapshots; unsafe entries raise Error.
    def repository_states!
      @repositories.to_h do |name, repo|
        root = repo.fetch(:path)
        raise Error, "repository root moved" unless File.realpath(root) == root
        raise Error, "repository root mismatch" unless git!(repo, "rev-parse", "--show-toplevel").strip == root
        identity = RepositoryIdentity.resolve(git!(repo, "remote", "get-url", @config.default_remote).strip)
        raise Error, "wrong repository identity" unless identity == repo.fetch(:identity)
        head = git!(repo, "rev-parse", "HEAD").strip
        tracked = git!(repo, "ls-files", "-z", "--cached").split("\0")
        unmerged = git!(repo, "ls-files", "--unmerged", "-z").split("\0").map { |entry| entry.split("\t", 2).last }.uniq
        raise Error, "#{name}: unresolved merge/index entries: #{unmerged.map(&:dump).join(', ')}" unless unmerged.empty?
        flags = git!(repo, "ls-files", "-v", "-z")
        raise Error, "hidden index flags (assume-unchanged/skip-worktree) are unsupported" unless flags.split("\0").all? { |entry| entry.start_with?("H ") }
        initial_head = @initial ? @initial.fetch(name).fetch(:head) : head
        initial_paths = git!(repo, "ls-tree", "-r", "--name-only", "-z", initial_head).split("\0")
        others = git!(repo, "ls-files", "-z", "--others", "--exclude-standard").split("\0")
        ignored = git!(repo, "ls-files", "-z", "--others", "--ignored", "--exclude-standard").split("\0")
        ignored.reject! { |path| GENERATED.any? { |prefix| path.start_with?(prefix) } }
        files = (initial_paths + tracked + others + ignored).uniq.sort.to_h do |path|
          absolute = repository_path!(root, path)
          value = if File.file?(absolute)
                    [File.stat(absolute).mode & 0o777, Digest::SHA256.file(absolute).hexdigest]
                  elsif !File.exist?(absolute)
                    nil
                  else
                    raise Error, "nonregular repository entry: #{path}"
                  end
          [path, value]
        end
        [name, { head: head, identity: identity, files: files,
                 directory: [File.stat(root).dev, File.stat(root).ino],
                 git_directory: git!(repo, "rev-parse", "--absolute-git-dir"),
                 branch: git!(repo, "rev-parse", "--symbolic-full-name", "HEAD"),
                 index: git!(repo, "ls-files", "--stage", "-z"),
                 index_diff: git!(repo, "diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv") }]
      end
    end

    # Requires current bytes/identity/index to equal a phase snapshot and rechecks
    # artifact integrity. Returns nil or raises on changed source/artifact state.
    def unchanged!(expected)
      raise Error, "repository changed since review/validation" unless repository_states! == expected
      raise Error, "artifact changed after preview" unless artifact! == @patch
    end

    # Warns with classified initial dirty paths in a declared repository. Raises
    # for proposal overlap, including file/directory prefixes; Git errors propagate.
    def warn_initial_changes!(name, repo)
      changes = {
        "staged" => git!(repo, "diff", "--cached", "--name-only", "--no-renames", "-z").split("\0"),
        "unstaged" => git!(repo, "diff", "--name-only", "--no-renames", "-z").split("\0"),
        "untracked" => git!(repo, "ls-files", "--others", "--exclude-standard", "-z").split("\0")
      }
      changes.each do |kind, paths|
        if repo == @target
          paths.each do |path|
            overlap = @paths.find { |proposal| path == proposal || path.start_with?("#{proposal}/") || proposal.start_with?("#{path}/") }
            raise Error, "#{name}: proposal conflict: #{path.dump} (pre-existing #{kind} change) overlaps #{overlap.dump}" if overlap
          end
        end
        @out.puts "WARN: #{name}: preserving initial #{kind} files: #{paths.map(&:dump).join(', ')}" unless paths.empty?
      end
    end

    # Returns exact raw stage/blob/mode/path entries outside the proposal from a
    # target snapshot. NUL parsing preserves nonportable names; no I/O occurs.
    def unrelated_index(state)
      state.fetch(:index).split("\0").reject { |entry| @paths.include?(entry.split("\t", 2).last) }
    end

    # Requires exactly the proposal's effects from the initial reviewed state,
    # preserving the complete original index and unrelated/sibling file state.
    # Accepts an optional current snapshot; unrelated/missing effects raise Error.
    def expected_changes!(states = repository_states!)
      target_name = @manifest.fetch("target")
      unless @paths.all? { |path| states.fetch(target_name).fetch(:files)[path] != @initial.fetch(target_name).fetch(:files)[path] }
        raise Error, "changed paths differ from patch"
      end
      unless states.all? { |name, state|
        initial = @initial.fetch(name)
        protected_files = lambda do |files|
          files.reject { |path, _value| name == @manifest.fetch("target") && @paths.include?(path) }
        end
        state.reject { |key, _value| key == :files } == initial.reject { |key, _value| key == :files } &&
          protected_files.call(state.fetch(:files)) == protected_files.call(initial.fetch(:files))
      }
        raise Error, "repository changed outside proposal"
      end
    end

    # Reads explicit yes from a terminal only. EOF, blank and noninteractive input
    # all decline; no manifest or CLI option can supply automatic approval.
    def confirm?(question)
      @out.print "#{question} [y/N] "
      @out.flush
      return false unless @input.respond_to?(:tty?) && @input.tty?
      %w[y yes].include?(@input.gets.to_s.strip.downcase)
    end

    # Reports a declined phase without advancing; returns successful workflow exit.
    def declined(phase)
      @out.puts "#{phase.capitalize} declined; later phases not run."
      0
    end

    # Prints phase truth without rollback/publication claims; output errors propagate.
    def report
      @out.puts "Apply outcome: #{@phase}; publication not performed."
      if @target
        @out.puts "Current HEAD: #{git!(@target, 'rev-parse', 'HEAD').strip}"
        @out.write git!(@target, "status", "--short", "--untracked-files=all")
      end
    rescue Error, SystemCallError => error
      @err.puts "Status inspection unavailable: #{error.class}"
    end

    # Executes argv directly, preserving binary streams and Process::Status.
    # Interrupt kills only this invocation's subprocess group and replays captured
    # output before propagating. Ambient Git redirection and spawn errors raise.
    def execute(argv, cwd:, env: {}, input: "")
      raise Error, "ambient GIT_* overrides are unsupported" if ENV.keys.any? { |key| key.start_with?("GIT_") && !%w[GIT_PAGER GIT_TERMINAL_PROMPT].include?(key) }
      environment = argv.first == "git" ? env.merge("GIT_TERMINAL_PROMPT" => "0", "GIT_PAGER" => "cat") : env
      Open3.popen3(environment, *argv, chdir: cwd, pgroup: true) do |stdin, stdout, stderr, child|
        [stdin, stdout, stderr].each(&:binmode)
        readers = [stdout, stderr].map { |stream| Thread.new { stream.read } }
        begin
          begin
            stdin.write(input)
          rescue Errno::EPIPE
            # A rejecting child may close stdin before reading the whole patch;
            # retain that child's diagnostic and status rather than hiding them.
          end
          stdin.close
          status = child.value
          [readers[0].value, readers[1].value, status]
        rescue Interrupt
          begin
            Process.kill("KILL", -child.pid)
          rescue Errno::ESRCH
            # The child may have exited immediately before interruption.
          end
          child.value
          @out.write readers[0].value
          @err.write readers[1].value
          raise
        ensure
          stdin.close unless stdin.closed?
        end
      end
    end

    # Runs local Git reads/mutations with checked status; returns raw stdout or
    # raises Error with the native diagnostic. There are no network operations.
    def git!(repo, *arguments, input: "")
      stdout, stderr, status = execute(["git", *arguments], cwd: repo.fetch(:path), input: input)
      raise Error, "git #{arguments.first} failed (#{status.exitstatus || 128 + status.termsig}): #{stderr.dump}" unless status.success?
      stdout
    end
  end
end
