# frozen_string_literal: true

require 'zlib'
require_relative 'patch_capabilities'

module MemoryGit
  # Finite native-derived reset stores. Only the declared seed/binary/unmerged
  # fixture states are admitted; no index/pack bytes are manufactured at runtime.
  module ResetFixtures
    PATH = File.join(__dir__, 'fixtures/reset-native.json').freeze
    HASH = 'fc47fa2e8689cb17cb2a90981103a32e6e1876e9805ed28dae9e4e008cb3b669'

    # Loads immutable native evidence; changed fixture bytes fail closed.
    def self.data
      raise Mismatch, 'reset fixture bytes changed' unless Digest::SHA256.file(PATH).hexdigest == HASH
      @data ||= JSON.parse(File.binread(PATH))
    end

    # Imports the native seed commit identity for reset-only test authorities.
    def self.seed
      pin = data.fetch('commits').fetch('seed')
      Template.new(commits: [Commit.new(tree: Tree.new('file.txt' => "base\n"), message: pin.fetch('message'), oid: pin.fetch('oid'))])
    end

    # Parses a native no-delta pack independently: trailer, every compressed
    # object's length/type/SHA1 and all commit/tree references must corroborate.
    # Returns object IDs; corrupt/truncated/unsupported packs raise Mismatch.
    def self.pack_objects(bytes)
      raise Mismatch, 'native pack header/checksum' unless bytes.start_with?('PACK') && bytes[4, 4].unpack1('N') == 2 &&
        Digest::SHA1.digest(bytes[0...-20]) == bytes[-20, 20]
      position, objects = 12, {}
      bytes[8, 4].unpack1('N').times do
        byte = bytes.getbyte(position); position += 1
        type, size, shift = (byte >> 4) & 7, byte & 15, 4
        while byte & 128 != 0
          byte = bytes.getbyte(position); position += 1
          size |= (byte & 127) << shift
          shift += 7
        end
        kind = { 1 => 'commit', 2 => 'tree', 3 => 'blob' }[type]
        raise Mismatch, 'native pack unsupported object' unless kind
        inflater = Zlib::Inflate.new
        content = inflater.inflate(bytes[position...-20])
        position += inflater.total_in
        raise Mismatch, 'native pack object size' unless inflater.finished? && content.bytesize == size
        inflater.close
        oid = Digest::SHA1.hexdigest("#{kind} #{size}\0".b + content)
        objects[oid] = [kind, content]
      end
      raise Mismatch, 'native pack trailing bytes' unless position == bytes.bytesize - 20
      objects.each_value do |kind, content|
        references = if kind == 'commit'
          content.lines.take_while { |line| line != "\n" }.filter_map { |line| line.split.last if line.start_with?('tree ', 'parent ') }
        elsif kind == 'tree'
          remaining, ids = content, []
          until remaining.empty?
            offset = remaining.index("\0")
            raise Mismatch, 'native tree framing' unless offset && remaining.bytesize >= offset + 21
            ids << remaining[offset + 1, 20].unpack1('H*')
            remaining = remaining[(offset + 21)..]
          end
          ids
        else []
        end
        raise Mismatch, 'native object closure incomplete' unless references.all? { |oid| objects.key?(oid) }
      end
      objects
    rescue Zlib::Error, NoMethodError, TypeError => error
      raise Mismatch, "native pack invalid: #{error.class}"
    end

    # Verifies physical copied stores, independently of the mutable world. Native
    # index checksum and pinned full bytes, pack closure and every native file hash
    # are required. Corruption is never healed by observation.
    def self.verify_store(directory)
      raise Mismatch, 'native store unsafe root' unless File.realpath(directory) == directory
      %w[HEAD index].each do |path|
        absolute = File.join(directory, path)
        raise Mismatch, 'native store unsafe identity file' unless File.file?(absolute) && !File.symlink?(absolute)
      end
      head = File.binread(File.join(directory, 'HEAD')).strip
      index = File.binread(File.join(directory, 'index'))
      state = data.fetch('states').values.find { |row| row.fetch('head') == head && [row.fetch('index_hex')].pack('H*') == index }
      raise Mismatch, 'native store index/head not a fixture state' unless state
      raise Mismatch, 'native index checksum' unless index.start_with?('DIRC') && Digest::SHA1.digest(index[0...-20]) == index[-20, 20]
      state.fetch('store_sha256').each do |path, digest|
        next if path == 'config' # reconstruction may change exactly core.bare
        absolute = File.join(directory, path)
        raise Mismatch, 'native store file corruption' unless File.file?(absolute) && !File.symlink?(absolute) && Digest::SHA256.file(absolute).hexdigest == digest
      end
      expected_config = state.fetch('store').fetch('config').unpack1('m0')
      config = File.binread(File.join(directory, 'config'))
      raise Mismatch, 'native store configuration' unless [expected_config, expected_config.sub('bare = true', 'bare = false')].include?(config)
      actual = Dir.glob('**/*', base: directory).select { |path| File.file?(File.join(directory, path)) }.sort
      raise Mismatch, 'native store extra/missing files' unless actual == state.fetch('store').keys.sort
      pack_path = state.fetch('store').keys.find { |path| path.end_with?('.pack') }
      objects = pack_objects(File.binread(File.join(directory, pack_path)))
      raise Mismatch, 'native head/stage closure' unless objects[head]&.first == 'commit' && state.fetch('stages').all? { |row| objects[row[2]]&.first == 'blob' }
      if ENV['ACT_RESET_STORE_EVIDENCE']
        key = Digest::SHA256.hexdigest(head + index + config)
        destination = File.join(ENV.fetch('ACT_RESET_STORE_EVIDENCE'), key)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp_r(directory, destination, preserve: true) unless File.exist?(destination)
      end
      state
    end

    # Formats exact native stage rows, including unresolved stage 1/2/3 entries.
    def self.stages(row, nul: true)
      row.fetch('stages').map { |path, mode, oid, stage| "#{mode} #{oid} #{stage}\t".b + [path].pack('H*') + (nul ? "\0" : "\n") }.join.b
    end

    # Adds only native-derived reset transitions to an explicitly opted-in world.
    module World
      # Pins the two finite commit builders used by reset tests to native evidence.
      def build_commit(checkout, files:, parents: nil, message: 'change', oid: nil, advance: false)
        parents ||= [checkout.head].compact
        pin = ResetFixtures.data.fetch('commits').values.find { |row| row.fetch('message') == message.chomp + "\n" && row.fetch('parents') == parents }
        raise Mismatch, 'undeclared native reset commit' unless pin
        expected = pin == ResetFixtures.data.fetch('commits').fetch('seed') ? { 'file.txt' => "base\n" } : { 'file.txt' => "base\n", 'delete.bin' => "delete\0\xff".b }
        raise Mismatch, 'native reset commit tree differs' unless Tree.new(files).entries == Tree.new(expected).entries
        super(checkout, files: files, parents: parents, message: message, oid: pin.fetch('oid'), advance: advance)
      end

      # Handles only archive init/import/verification and copied reconstruction.
      # All other commands retain the existing finite dispatcher and fault checks.
      def call(argv, cwd: nil, env: {}, input: '', timeout: nil, **options)
        if argv == ['git', 'rev-parse', 'HEAD'] && cwd && @checkouts.key?(cwd) && File.symlink?(cwd)
          raise Mismatch, 'undeclared symlink fixture query' unless File.readlink(cwd) == cwd + '-parked' &&
            supported_environment?(env) && input.empty? && options.keys == [:binmode] && options[:binmode] == true && timeout.nil?
          check_pointer!(@checkouts.fetch(cwd))
          return result(@checkouts.fetch(cwd).head + "\n")
        end
        if argv == ['git', 'rev-parse', '--git-dir'] && cwd == File.join(root, 'fixture/missing-repository') && !File.exist?(cwd)
          File.stat(cwd) # genuine ENOENT at the explicit fixture boundary
        end
        special = argv[1]&.start_with?('--git-dir=') || %w[init index-pack].include?(argv[1]) || argv[1, 2] == ['--no-replace-objects', 'pack-objects'] ||
          (cwd && !@checkouts.key?(cwd) && File.file?(File.join(cwd, '.git', 'index')))
        return super unless special
        @lock.synchronize do
          validate_envelope!(argv, cwd, env, input, timeout, options)
          @requests << envelope(argv, cwd, env, input, timeout, options)
          reset_archive_command(argv, cwd, input)
        end
      end

      private

      # Selects exact native index bytes by full path/mode/blob/stage identity.
      def native_state(checkout)
        rows = checkout.index.sort.map { |path, entry| [path.unpack1('H*'), entry.mode, entry.blob.oid, 0] }
        rows += @reset_unmerged&.fetch(checkout.path, []) || []
        rows.sort_by! { |row| [[row[0]].pack('H*'), row[3]] }
        ResetFixtures.data.fetch('states').values.find { |state| state.fetch('stages') == rows } || (raise Mismatch, 'undeclared native index state')
      end

      # Materializes only a known native fixture transition; existing index bytes
      # must still equal the previously emitted state before an authorized write.
      def native_index(checkout, transition: false)
        @reset_indexes ||= {}
        path = File.join(checkout.admin, 'index')
        prior = @reset_indexes[path]
        if prior && (!File.file?(path) || File.binread(path) != prior)
          raise Mismatch, 'native index physical corruption'
        end
        bytes = [native_state(checkout).fetch('index_hex')].pack('H*')
        if !prior || transition
          raise Mismatch, 'unexpected preexisting native index' if !prior && File.exist?(path)
          File.binwrite(path, bytes)
          File.chmod(0o644, path)
          @reset_indexes[path] = bytes
        elsif prior != bytes
          raise Mismatch, 'native index transition missing'
        end
        path
      end

      # Index creation belongs to explicit checkout materialization, never reads.
      def materialize!(checkout, before, after)
        super
        native_index(checkout, transition: true)
      end

      # Validates actual native index bytes before returning its path; split
      # indexes are absent only for these explicitly recorded native fixtures.
      def command_rev_parse(checkout, arguments, input, settings)
        if arguments == ['--shared-index-path']
          no_input!(input)
          native_index(checkout)
          return result("\n")
        end
        native_index(checkout) if arguments == ['--path-format=absolute', '--git-path', 'index']
        super
      end

      # Retains normal staging effects, followed by a finite native index write.
      def command_add(checkout, arguments, input, settings)
        native_index(checkout)
        response = super
        native_index(checkout, transition: true)
        response
      end

      # The binary-baseline fixture commit uses its native parent/tree/message pin.
      def command_commit(checkout, arguments, input, settings)
        return super unless arguments == ['-m', 'fixture binary baseline']
        no_input!(input)
        commit = build_commit(checkout, files: checkout.index, message: arguments.last)
        effect!(:commit) { checkout.move_head!(commit.oid) }
        result("[native fixture #{commit.oid[0, 7]}] #{arguments.last}\n")
      end

      # Admits exact fixture-only chmod and index-info transitions. Unknown input
      # bytes or blob/state identities refuse; unmerged rows are not collapsed.
      def command_update_index(checkout, arguments, input, settings)
        native_index(checkout)
        if arguments == ['--chmod=+x', 'file.txt']
          no_input!(input)
          raise Mismatch, 'chmod fixture source' unless checkout.index['file.txt'] == Entry.new("base\n")
          checkout.index['file.txt'] = Entry.new("base\n", mode: '100755')
        elsif arguments == ['--index-info']
          raise Mismatch, 'index-info fixture input' unless input.unpack1('H*') == ResetFixtures.data.fetch('unmerged_input_hex') &&
            native_state(checkout) == ResetFixtures.data.fetch('states').fetch('staged')
          @reset_unmerged ||= {}
          @reset_unmerged[checkout.path] = ResetFixtures.data.fetch('states').fetch('unmerged').fetch('stages').select { |row| row[3] != 0 }
        else
          response = super
        end
        native_index(checkout, transition: true)
        response || result
      end

      # Inventories every declared ref so sibling/reference preservation remains
      # observable, rather than returning a partial or empty constant transcript.
      def command_show_ref(checkout, arguments, input, settings)
        return super unless arguments.empty?
        no_input!(input)
        rows = checkout.repository.refs.sort.map { |ref, oid| "#{oid} #{ref}\n" }
        result(rows.join, '', rows.empty? ? 1 : 0)
      end

      # Serves native stage observations including conflict stages and exact NULs.
      def command_ls_files(checkout, arguments, input, settings)
        return super unless arguments == ['--stage', '-z'] || arguments == ['--stage']
        no_input!(input)
        native_index(checkout)
        result(ResetFixtures.stages(native_state(checkout), nul: arguments.include?('-z')))
      end

      # Forced retirement is confined to the exact archived linked fixture. Its
      # native store, retained index and both physical pointers must still verify.
      def worktree_remove(checkout, arguments, settings)
        return super unless arguments.first == '--force'
        raise Mismatch, 'forced fixture retirement envelope' unless arguments.length == 3 && arguments[1] == '--'
        target = owned_path!(arguments.last)
        item = checkout.repository.worktrees[target]
        raise Mismatch, 'forced fixture retirement authority' unless item && item.admin != item.repository.common && @reset_archived&.key?(target)
        check_pointer!(item)
        native_index(item)
        archive_path = @reset_archived.fetch(target)
        archive_path = archive_path.sub(/\.[0-9a-f]{16}\.partial\z/, '') unless File.directory?(archive_path)
        state = ResetFixtures.verify_store(archive_path)
        raise Mismatch, 'forced fixture retirement archive changed' unless state.fetch('head') == item.head && state.fetch('stages') == native_state(item).fetch('stages')
        effect!(:worktree_remove) do
          FileUtils.remove_entry(target)
          FileUtils.remove_entry(item.admin)
          checkout.repository.worktrees.delete(target)
          @checkouts.delete(target)
          @reset_indexes.delete(File.join(item.admin, 'index'))
        end
        result
      end

      # Copies native-generated bare administration and pack/index files only for
      # the exact recorded archive request. Verification reads physical bytes.
      def reset_archive_command(argv, cwd, input)
        if argv[1, 3] == ['init', '--bare', '--template='] && argv.length == 5 && cwd.nil? && input.empty?
          directory = owned_path!(argv.last)
          raise Mismatch, 'archive init destination occupied' if File.exist?(directory)
          %w[objects/info objects/pack refs/heads refs/tags].each { |path| FileUtils.mkdir_p(File.join(directory, path)) }
          state = ResetFixtures.data.fetch('states').fetch('seed')
          File.binwrite(File.join(directory, 'config'), state.fetch('store').fetch('config').unpack1('m0'))
          File.binwrite(File.join(directory, 'HEAD'), "ref: refs/heads/main\n")
          (@reset_stores ||= {})[directory] = nil
          return result
        end
        if argv == ['git', '--no-replace-objects', 'pack-objects', '--stdout', '--revs']
          checkout = @checkouts.fetch(cwd)
          check_pointer!(checkout)
          native_index(checkout)
          state = ResetFixtures.data.fetch('states').values.find { |row| row.fetch('head') == checkout.head && row.fetch('stages') == native_state(checkout).fetch('stages') && row.fetch('request_hex') == input.unpack1('H*') }
          raise Mismatch, 'undeclared native pack request' unless state
          return result([state.fetch('pack_hex')].pack('H*'))
        end
        if argv == ['git', 'index-pack', '--strict', '--stdin'] && @reset_stores&.key?(cwd)
          state = ResetFixtures.data.fetch('states').values.find { |row| row.fetch('pack_hex') == input.unpack1('H*') }
          raise Mismatch, 'undeclared native pack import' unless state
          ResetFixtures.pack_objects(input)
          state.fetch('store').each do |path, value|
            next unless path.start_with?('objects/pack/')
            File.binwrite(File.join(cwd, path), value.unpack1('m0'))
          end
          @reset_stores[cwd] = state
          pack = state.fetch('store').keys.find { |path| path.end_with?('.pack') }
          return result("pack\t#{File.basename(pack, '.pack').delete_prefix('pack-')}\n")
        end
        if argv[1]&.start_with?('--git-dir=')
          directory = owned_path!(argv[1].delete_prefix('--git-dir='))
          state = ResetFixtures.verify_store(directory)
          tail = argv.drop(2)
          if tail.length == 4 && tail.first.start_with?('--work-tree=') && tail.drop(1) == ['ls-files', '--stage', '-z'] && input.empty?
            (@reset_store_sources ||= {})[directory] = tail.first.delete_prefix('--work-tree=')
            return result(ResetFixtures.stages(state))
          end
          return result(state.fetch('head') + "\n") if tail == ['rev-parse', 'HEAD'] && input.empty?
          if tail == ['fsck', '--full', '--no-reflogs'] && input.empty?
            source = @reset_store_sources&.fetch(directory, nil)
            raise Mismatch, 'unbound native store verification' unless source && @checkouts.key?(source)
            (@reset_archived ||= {})[source] = directory
            return result([state.fetch('fsck_stdout_hex')].pack('H*'))
          end
        elsif cwd && File.file?(File.join(cwd, '.git', 'index'))
          directory = owned_path!(File.join(cwd, '.git'))
          state = ResetFixtures.verify_store(directory)
          return result(state.fetch('head') + "\n") if argv == ['git', 'rev-parse', 'HEAD'] && input.empty?
          return result(ResetFixtures.stages(state, nul: argv.last == '-z')) if [ ['git', 'ls-files', '--stage'], ['git', 'ls-files', '--stage', '-z'] ].include?(argv) && input.empty?
          if argv == ['git', 'config', 'core.bare', 'false'] && input.empty?
            path = File.join(directory, 'config')
            File.binwrite(path, File.binread(path).sub('bare = true', 'bare = false'))
            return result
          end
        end
        raise Mismatch, 'undeclared native reset storage request'
      end
    end
  end
end
