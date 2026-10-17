# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require 'timeout'

module AgentCodingTool
  # A short-lived operator assertion plus a read-only Git/filesystem observation.
  # This never authenticates an external process or changes the older lifecycle.
  class QuiescenceReview
    SCHEMA = 'agent-coding-tool-quiescence/v1'
    NAMESPACE = '.quiescence'
    TTL = 300
    ID = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

    # Selects private local evidence; construction performs no writes.
    def initialize(data_root:, coordinator:, source_root:)
      @data = File.realpath(data_root)
      @coordinator, @source = coordinator, source_root
      @root = "#{@data}-runs"
      @directory = File.join(@root, NAMESPACE)
    end

    # Captures both preparations, exact shared writers and all reported/native
    # checkouts under the reservation lock. Returns private review data or raises.
    def review(older, target, repositories:, workspaces: [])
      with_lock do
        ids!(older, target)
        observation = observe(older, target, repositories, workspaces)
        value = { 'schema' => SCHEMA, 'older' => older, 'target' => target,
                  'reviewed_at' => Time.now.utc.iso8601(6), 'status' => 'review',
                  'observation' => observation }
        value['review_sha256'] = digest(value)
        write(value)
        value
      end
    end

    # Approves only the exact fresh review after an explicit complete-scope,
    # ended-agent assertion and reason. Returns the committed private record.
    # No PID/process termination is inferred; active/unknown assertions refuse.
    def approve(older, target, review_sha256:, activity:, all_writers_accounted_for:, reason:)
      with_lock do
        value = record!(older, target)
        unless activity == 'ended' && all_writers_accounted_for == true
          raise InvalidState, 'quiescence: explicitly attest ended activity and all writer locations, including other hosts'
        end
        unless reason.is_a?(String) && reason.dup.force_encoding('UTF-8').valid_encoding? && reason.bytesize.between?(1, 512) &&
               !reason.strip.empty? && !reason.match?(/[[:cntrl:]]/)
          raise InvalidTask, 'quiescence: reason must be 1-512 UTF-8 bytes without control characters'
        end
        unless value['status'] == 'review' && value['review_sha256'] == review_sha256
          raise InvalidState, 'quiescence: wrong, superseded or already approved review'
        end
        fresh!(value)
        reobserve!(value)
        fresh!(value)
        value.merge!('status' => 'approved', 'approved_at' => Time.now.utc.iso8601(6),
                     'activity' => 'operator_attested_ended', 'all_writers_accounted_for' => true,
                     'reason' => reason, 'operator_uid' => Process.uid)
        write(value)
        value
      end
    end

    # Returns a revalidated approved record for one manual sibling under the
    # caller's reservation lock. Own entries must already pass WorktreeManager.
    # Record changes, expiry, consumed approvals or any observed drift refuse.
    def verify!(older, target, own_entries: [])
      safe!(File.join(@root, 'launch.lock'))
      value = record!(older, target)
      raise InvalidState, 'quiescence: explicit approval absent or already consumed' unless value['status'] == 'approved'
      fresh!(value)
      reobserve!(value, own_entries: own_entries)
      fresh!(value)
      value
    end

    # Burns a verified approval before reserving/starting the worker. Atomic
    # replacement leaves old or consumed evidence on interruption, never a token
    # reusable after execution. Returns a public-safe identity, without paths/reason.
    def consume!(value, invocation_id:, own_entries: [])
      current = verify!(value.fetch('older'), value.fetch('target'), own_entries: own_entries)
      raise InvalidState, 'quiescence: authorization changed during launch' unless current == value
      current.merge!('status' => 'consumed', 'invocation_id' => invocation_id,
                     'consumed_at' => Time.now.utc.iso8601(6))
      write(current)
      current.slice('older', 'target', 'review_sha256', 'approved_at', 'activity')
    end

    # Validates the entire precise namespace before Launcher ignores it as a
    # non-attempt entry. Corruption, foreign owners, symlinks or partial writes
    # refuse; expired/consumed records remain audit data, never launch authority.
    def records!
      return [] unless File.exist?(@directory) || File.symlink?(@directory)
      safe!(@directory, directory: true)
      Dir.children(@directory).sort.map do |entry|
        raise InvalidState, 'quiescence: foreign evidence entry' unless entry.match?(/\A[0-9a-f]{64}\.yml\z/)
        path = File.join(@directory, entry)
        safe!(path)
        value = YAML.safe_load_file(path, aliases: false)
        validate!(value)
        raise InvalidState, 'quiescence: record identity mismatch' unless entry == "#{key(value.fetch('older'), value.fetch('target'))}.yml"
        value
      end
    rescue Psych::Exception, KeyError, TypeError, NoMethodError, ArgumentError
      raise InvalidState, 'quiescence: damaged private review evidence', cause: nil
    end

    private

    # Acquires the same nonblocking reservation lock used by launch/start/delivery.
    # Only the private namespace is created; an unsafe lock/root refuses first.
    def with_lock
      Launcher.new(coordinator: @coordinator, data_root: @data, source_root: @source).send(:safe_root!)
      path = File.join(@root, 'launch.lock')
      safe!(path) if File.exist?(path) || File.symlink?(path)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
        raise InvalidState, 'quiescence: launch reservation busy' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        safe!(path)
        records!
        yield
      end
    end

    # Rejects unsafe/same task identities before any record path is constructed.
    def ids!(older, target)
      raise InvalidTask, 'quiescence: distinct safe task IDs required' unless
        older.is_a?(String) && target.is_a?(String) && older.match?(ID) && target.match?(ID) && older != target
    end

    # Produces a collision-free record filename from the ordered pair of IDs.
    def key(older, target) = Digest::SHA256.hexdigest(JSON.generate([older, target]))

    # Hashes structured evidence without making its private contents publishable.
    def digest(value) = Digest::SHA256.hexdigest(JSON.generate(value))

    # Returns exactly one integrity-checked record; absence never means consent.
    def record!(older, target)
      ids!(older, target)
      records!.find { |value| value.values_at('older', 'target') == [older, target] } ||
        raise(InvalidState, 'quiescence: no reviewed authorization; manual worker isolation and activity are unverified')
    end

    # Validates self-checksums and the bounded schema. Checksums detect damage;
    # trust comes from host ownership/private permissions, not a signature.
    def validate!(value)
      raise InvalidState, 'quiescence: malformed authorization' unless value.is_a?(Hash) &&
        value['schema'] == SCHEMA && %w[review approved consumed].include?(value['status']) &&
        value['observation'].is_a?(Hash) && value['seal'] == digest(value.reject { |name, _| name == 'seal' })
      ids!(value['older'], value['target'])
      original = value.slice('schema', 'older', 'target', 'reviewed_at', 'status', 'observation').merge('status' => 'review')
      raise InvalidState, 'quiescence: review checksum mismatch' unless value['review_sha256'] == digest(original)
      if value['status'] != 'review'
        raise InvalidState, 'quiescence: incomplete approval' unless value['activity'] == 'operator_attested_ended' &&
          value['all_writers_accounted_for'] == true && value['operator_uid'] == Process.uid && value['reason'].is_a?(String) &&
          Time.iso8601(value.fetch('approved_at')) >= Time.iso8601(value.fetch('reviewed_at'))
      end
      if value['status'] == 'consumed'
        raise InvalidState, 'quiescence: partial consumption' unless value['invocation_id'].is_a?(String) && value['consumed_at'].is_a?(String)
      end
    end

    # Enforces a five-minute window from inspection, never extended by approval.
    def fresh!(value)
      age = Time.now.utc - Time.iso8601(value.fetch('reviewed_at'))
      raise InvalidState, 'quiescence: review expired or clock moved; inspect again' unless age.between?(0, TTL)
    end

    # Atomically replaces one private record using existing StateStore durability.
    # A post-rename fsync failure is reported as published uncertainty by StateStore.
    def write(value)
      FileUtils.mkdir_p(@directory, mode: 0o700)
      safe!(@directory, directory: true)
      path = File.join(@directory, "#{key(value.fetch('older'), value.fetch('target'))}.yml")
      safe!(path) if File.exist?(path) || File.symlink?(path)
      value['seal'] = digest(value.reject { |name, _| name == 'seal' })
      validate!(value)
      # StateStore creates with the process umask; isolate permissions without
      # changing the application's global umask or modifying another file.
      unless File.exist?(path)
        Tempfile.create(['.quiescence-', '.tmp'], @directory) do |file|
          bytes = YAML.dump(value)
          raise IOError, 'quiescence: partial private write' unless file.write(bytes) == bytes.bytesize
          file.flush
          file.fsync
          file.close
          File.rename(file.path, path)
          begin
            File.open(@directory) { |directory| directory.fsync }
          rescue SystemCallError, IOError, NotImplementedError
            raise InvalidState, 'quiescence: record published; directory sync failed; inspect before retrying'
          end
        end
        return
      end
      StateStore.new(@directory).write(key(value.fetch('older'), value.fetch('target')), value)
    end

    # Refuses path links (except macOS system aliases), foreign owners and
    # non-private evidence. Filesystem failures propagate as a refusal.
    def safe!(path, directory: false)
      canonical_path!(path)
      stat = File.lstat(path)
      raise InvalidState, 'quiescence: foreign/private evidence layout' unless stat.uid == Process.uid &&
        (directory ? stat.directory? : stat.file? && stat.nlink == 1) && (stat.mode & 0o077).zero?
    end

    # Rejects unexpected symlinks in a host-observed path or its ancestors.
    # macOS system aliases use the same normalization as WorktreeManager.
    def canonical_path!(path)
      cursor = WorktreeManager.canonical_system_path(path)
      loop do
        raise InvalidState, 'quiescence: symlinked filesystem location' if File.symlink?(cursor)
        break if cursor == File.dirname(cursor)
        cursor = File.dirname(cursor)
      end
    end

    # Repeats the complete inspection, excluding only the newly verified B
    # inventory from native registration. It must equal the reviewed observation.
    def reobserve!(value, own_entries: [])
      old = value.fetch('observation')
      current = observe(value.fetch('older'), value.fetch('target'), old.fetch('repositories'),
                        old.fetch('supplied_workspaces'), own_entries: own_entries)
      raise InvalidState, 'quiescence: task, checkout or native worktree inventory changed; review again' unless current == old
    end

    # Inspects real tasks, preparations and native Git inventories. Legitimate
    # dirty/divergent external work is hashed and preserved, never cleaned.
    def observe(older, target, repositories, workspaces, own_entries: [])
      ids!(older, target)
      tasks = TaskStore.new(File.join(@data, 'tasks'))
      store = StateStore.new(File.join(@data, 'state'))
      older_task, target_task = tasks.load(older), tasks.load(target)
      older_state, target_state = store.load(older), store.load(target)
      unless older_task['id'] == older && older_state['id'] == older && target_task['id'] == target && target_state['id'] == target &&
             older_state['started_at'].is_a?(String) && older_state['prepared_at'].is_a?(String) &&
             !older_state['result'] && older_state['snapshot'].is_a?(Hash) &&
             older_state['snapshot'].keys.sort == older_task.fetch('repositories').keys.sort &&
             @coordinator.status(target).fetch('status') == 'PREPARED'
        raise InvalidState, 'quiescence: requires a manual IN_FLIGHT task and a fresh PREPARED target'
      end
      Time.iso8601(older_state.fetch('prepared_at'))
      Time.iso8601(older_state.fetch('started_at'))
      reports = Launcher.new(coordinator: @coordinator, data_root: @data, source_root: @source).send(:reports)
      raise InvalidState, 'quiescence: managed/unknown attempt requires its existing ownership checks' if
        reports.any? { |report| report['task_id'] == older }
      writers = ->(task, state) { task.fetch('repositories').filter_map { |name, spec|
        [name, state.fetch('snapshot').fetch(name)] if spec.fetch('access') == 'write' }.to_h }
      older_writers, target_writers = writers.call(older_task, older_state), writers.call(target_task, target_state)
      shared = target_writers.select { |_, base| older_writers.values.any? { |other| other.values_at('remote_url', 'branch') == base.values_at('remote_url', 'branch') } }
      unless repositories.is_a?(Array) && !repositories.empty? && repositories.uniq.sort == repositories.sort &&
             repositories.sort == shared.keys.sort && shared.values.all? { |base|
               older_writers.values.any? { |other| other.values_at('remote_url', 'branch', 'pushed_sha') == base.values_at('remote_url', 'branch', 'pushed_sha') } }
        raise InvalidState, 'quiescence: exact shared writable repository set and compatible prepared bases required'
      end
      config = Config.load(File.join(@data, 'config.yml'))
      inspector = RepoInspector.new(config)
      [[older_task, older_state], [target_task, target_state]].each do |task, state|
        task.fetch('repositories').each do |name, spec|
          base = state.fetch('snapshot').fetch(name)
          unless inspector.repository_authority(name, spec) == base.values_at('remote_url', 'branch')
            raise InvalidState, 'quiescence: repository authority changed'
          end
        end
      end
      bases = (older_writers.values + target_writers.values).uniq
      locations = (bases.map { |base| base.fetch('path') } + workspaces).uniq.sort
      own_paths = own_entries.map { |entry| entry.fetch('path') }
      rows = locations.map do |path|
        checkout(path, bases, locations, own_paths, File.join(WorktreeManager.canonical_system_path(config.worktree_root), target))
      end
      files = [File.join(@data, 'config.yml'), *[older, target].flat_map { |id|
        [File.join(@data, 'tasks', "#{id}.yml"), store.state_path(id), store.load(id).fetch('prompt_path')] }]
      { 'repositories' => repositories.sort, 'authorities' => shared.transform_values { |base| base.slice('remote_url', 'branch', 'pushed_sha') },
        'supplied_workspaces' => workspaces.sort, 'files' => files.to_h { |path| [path, host_file_identity!(path)] },
        'checkouts' => rows }
    end

    # Observes a registered, operator-owned checkout and all its native siblings.
    # Source/index/content fingerprints detect edits; no optional Git index refresh
    # occurs. Unknown registry entries, symlinked paths and execution overlap refuse.
    def checkout(path, bases, locations, own_paths, execution_root)
      raise InvalidState, 'quiescence: absolute workspace required' unless path.is_a?(String) && path.start_with?('/')
      canonical = WorktreeManager.canonical_system_path(path)
      raise InvalidState, 'quiescence: noncanonical workspace' unless canonical == path
      canonical_path!(path)
      raise InvalidState, 'quiescence: foreign workspace owner' unless File.stat(path).uid == Process.uid
      if path == execution_root || path.start_with?("#{execution_root}/") || execution_root.start_with?("#{path}/")
        raise InvalidState, 'quiescence: external workspace overlaps proposed managed task paths'
      end
      top, common, admin = git(path, 'rev-parse', '--path-format=absolute', '--show-toplevel', '--git-common-dir', '--absolute-git-dir').lines.map(&:strip)
      raise InvalidState, 'quiescence: foreign Git workspace' unless top == path &&
        File.realpath(common) == common && File.realpath(admin) == admin && File.stat(common).uid == Process.uid
      base = bases.find { |candidate| git(path, 'remote', 'get-url', candidate.fetch('remote')).strip == candidate.fetch('remote_url') }
      raise InvalidState, 'quiescence: foreign repository authority' unless base
      registry = git(path, 'worktree', 'list', '--porcelain', '-z').split("\0\0").map { |row| row.split("\0") }
      registry.reject! { |row| own_paths.include?(row.first&.delete_prefix('worktree ')) }
      native = registry.map { |row| row.first&.delete_prefix('worktree ') }
      unless native.include?(path) && native.uniq == native && (native - locations).empty? &&
             registry.all? { |row| row.first&.start_with?('worktree ') && row.none? { |item| item.start_with?('prunable', 'bare') } }
        raise InvalidState, 'quiescence: unknown or incomplete native worktree authority'
      end
      head = git(path, 'rev-parse', 'HEAD').strip
      raise InvalidState, 'quiescence: native HEAD mismatch' unless registry.any? { |row| row.first == "worktree #{path}" && row.include?("HEAD #{head}") }
      pointer = File.join(path, '.git')
      raise InvalidState, 'quiescence: symlinked Git pointer' if File.symlink?(pointer)
      if admin != common
        back = File.join(admin, 'gitdir')
        raise InvalidState, 'quiescence: foreign native backpointer' unless admin.start_with?("#{common}/worktrees/") &&
          !File.symlink?(back) && File.binread(back).strip == pointer
      end
      local_activity!(path)
      paths = git(path, 'ls-files', '-z', '--cached', '--others').split("\0").uniq.sort
      { 'path' => path, 'head' => head, 'registry' => registry,
        'common' => [common, File.stat(common).dev, File.stat(common).ino],
        'admin' => [admin, File.stat(admin).dev, File.stat(admin).ino],
        'git_head' => host_file_identity!(File.join(admin, 'HEAD')),
        'git_config' => host_file_identity!(File.join(common, 'config')),
        'index' => File.exist?(File.join(admin, 'index')) ? host_file_identity!(File.join(admin, 'index')) : nil,
        'pointer' => File.file?(pointer) ? host_file_identity!(pointer) : nil,
        'status' => git(path, 'status', '--porcelain=v1', '-z', '--untracked-files=all'),
        'contents' => paths.to_h { |relative| [relative, file_identity(File.join(path, relative), missing: true)] } }
    end

    # Uses the existing conservative local open-file convention as a contradiction
    # check only. Empty lsof output is not remote termination/containment proof;
    # activity or unavailable/incomplete diagnostics refuse the exception.
    def local_activity!(path)
      output, error, status = Open3.popen3('lsof', '-n', '-P', '+D', path, pgroup: true) do |input, stdout, stderr, child|
        input.close
        readers = [stdout, stderr].map { |stream| Thread.new { stream.read } }
        begin
          status = Timeout.timeout(5) { child.value }
          [*readers.map(&:value), status]
        rescue Timeout::Error
          Process.kill('KILL', -child.pid) rescue Errno::ESRCH
          child.value
          readers.each(&:join)
          raise InvalidState, 'quiescence: local activity probe timed out; activity unknown'
        end
      end
      raise InvalidState, 'quiescence: workspace has observable local activity' if status.exitstatus == 0 && !output.strip.empty?
      unless status.exitstatus == 1 && output.empty? && error.empty?
        raise InvalidState, 'quiescence: local workspace activity unknown; inspect locally'
      end
    rescue Errno::ENOENT
      raise InvalidState, 'quiescence: lsof unavailable; local workspace activity unknown'
    end

    # Binds trusted preparation/Git metadata as regular operator-owned files,
    # refusing links in either the file or ancestry. Returns the fingerprint.
    def host_file_identity!(path)
      canonical_path!(path)
      identity = file_identity(path)
      raise InvalidState, 'quiescence: foreign/symlinked host file' unless identity.first == 'file' && File.stat(path).uid == Process.uid
      identity
    end

    # Returns bytes/type/metadata for a file without following a candidate symlink.
    # Missing tracked files are valid dirty work; unsafe special files refuse.
    def file_identity(path, missing: false)
      stat = File.lstat(path)
      content = if stat.symlink?
                  File.readlink(path)
                elsif stat.file?
                  Digest::SHA256.file(path).hexdigest
                else
                  raise InvalidState, 'quiescence: unsupported file type'
                end
      [stat.ftype, stat.dev, stat.ino, stat.mode, stat.size, stat.mtime.to_r.to_s, content]
    rescue Errno::ENOENT
      raise unless missing
      nil
    end

    # Runs Git read-only with optional index updates disabled; failures refuse.
    def git(path, *arguments)
      output, _error, status = Open3.capture3({ 'GIT_OPTIONAL_LOCKS' => '0' }, 'git', '--no-replace-objects', *arguments, chdir: path)
      raise InvalidState, 'quiescence: Git inspection failed' unless status.success?
      output
    end
  end
end
