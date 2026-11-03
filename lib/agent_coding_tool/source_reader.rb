# frozen_string_literal: true

require_relative "source_git"

module AgentCodingTool
  # Live tracked source only. Internal paths/Git administration never leave this
  # boundary; results carry repository IDs, relative paths and observed versions.
  class SourceReader
    Refused = RunEvidenceReader::Refused
    FILE_LIMIT = 1_048_576
    SCAN_BYTES = 2_097_152
    SCAN_FILES = 256
    ENTRIES = 10_000
    PAGE = 64
    CHUNK = 16_384
    SECONDS = 2

    # Resolves one local explicit repository beneath a canonical code root.
    # Returns private root/admin bindings. Hidden/nonrepository/aliased roots,
    # unknown owners, Git failures or deadline exceedance raise Refused.
    def self.admit(code_root, repository)
      raise Refused, "source.root" unless code_root.is_a?(String) && !SourceFiles.denied?(code_root) && File.realpath(code_root) == code_root &&
        repository.is_a?(String) && File.realpath(repository) == repository && repository.start_with?("#{code_root}/")
      relative = repository.delete_prefix("#{code_root}/")
      SourceFiles.relative!(relative)
      raise Refused, "source.root" if relative.split("/").any? { |part| part.start_with?(".") } || SourceFiles.denied?(relative)
      code_identity = SourceFiles.open(code_root, directory: true) { |file| SourceFiles.identity(file.stat) }
      identity = SourceFiles.open(repository, directory: true) do |file|
        raise Refused, "source.owner" unless file.stat.uid == Process.uid
        SourceFiles.identity(file.stat)
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SECONDS
      git = SourceGit.new
      raise Refused, "source.repository" unless git.call(repository, %w[rev-parse --show-toplevel], deadline: deadline).strip == repository
      admin = git.call(repository, %w[rev-parse --absolute-git-dir], deadline: deadline).strip
      admin_identity = SourceFiles.open(admin, directory: true) { |file| SourceFiles.identity(file.stat) }
      binding = { "root" => repository, "identity" => identity, "code_root" => code_root,
        "code_identity" => code_identity, "admin" => admin, "admin_identity" => admin_identity }
      new(binding).inventory
      binding
    rescue SystemCallError, ArgumentError
      raise Refused, "source.root", cause: nil
    end

    # Binds a previously admitted private root, with a fresh per-operation total
    # deadline and bounded verification inventory. Construction performs no IO.
    def initialize(binding, deadline: nil)
      @binding = binding
      @root = binding.fetch("root")
      @deadline = deadline || Process.clock_gettime(Process::CLOCK_MONOTONIC) + SECONDS
      @git = SourceGit.new
      @files = {}
      @read_bytes = 0
    end

    # Refuses work after the shared per-operation wall bound. Returns nil;
    # kernel filesystem stalls are subject to the host filesystem's IO semantics.
    def deadline!
      raise Refused, "source.deadline" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline
    end

    # Verifies local root/admin identity and tracked inventory without returning
    # raw Git output. Returns admitted mode/blob records; unsupported paths,
    # sensitive names, ignored entries and nonregular index modes are excluded.
    def inventory
      deadline!
      { "root" => "identity", "code_root" => "code_identity", "admin" => "admin_identity" }.each do |path, expected|
        observed = SourceFiles.open(@binding.fetch(path), directory: true) { |file| SourceFiles.identity(file.stat) }
        raise Refused, "source.root_changed" unless observed == @binding.fetch(expected)
      end
      pointer = File.join(@root, ".git")
      if File.directory?(pointer) && !File.symlink?(pointer)
        raise Refused, "source.admin_changed" unless pointer == @binding.fetch("admin")
      else
        bytes, = SourceFiles.read(pointer, limit: 4096)
        raise Refused, "source.admin_changed" unless bytes == "gitdir: #{@binding.fetch('admin')}\n"
      end
      index_before, = SourceFiles.read(File.join(@binding.fetch("admin"), "index"), limit: SourceGit::LIMIT)
      revision = @git.call(@root, %w[rev-parse HEAD], deadline: @deadline).strip
      raise Refused, "source.revision" unless revision.match?(/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/)
      raw = @git.call(@root, %w[ls-files --stage -z], deadline: @deadline)
      ignored = @git.call(@root, %w[ls-files --cached --ignored --exclude-standard -z], deadline: @deadline).split("\0").to_h { |path| [path, true] }
      raise Refused, "source.inventory_limit" unless raw.empty? || raw.end_with?("\0")
      rows = raw.split("\0")
      raise Refused, "source.inventory_limit" if rows.length > ENTRIES
      entries = {}
      rows.each do |row|
        deadline!
        match = row.match(/\A(100644|100755) ([0-9a-f]{40}(?:[0-9a-f]{24})?) 0\t(.+)\z/)
        next unless match
        path = match[3].force_encoding(Encoding::UTF_8)
        next unless path.valid_encoding?
        begin
          SourceFiles.relative!(path)
        rescue Refused
          next
        end
        next if SourceFiles.denied?(path) || ignored.key?(path)
        entries[path] = { "mode" => match[1], "blob" => match[2] }
      end
      index_after, = SourceFiles.read(File.join(@binding.fetch("admin"), "index"), limit: SourceGit::LIMIT)
      raise Refused, "source.changed" unless index_before == index_after &&
        @git.call(@root, %w[rev-parse HEAD], deadline: @deadline).strip == revision
      @observation = { "revision" => revision, "index_sha256" => Digest::SHA256.hexdigest(index_before),
        "worktree" => "live; repository cleanliness not asserted" }
      @entries = entries
    end

    # Returns a live-source result for a closed list/search/read query. Raises
    # fixed Refused for unavailable, denied, changed, binary or oversized reads.
    # Private release facts are stripped by the session before remote delivery.
    def call(request)
      inventory
      operation = request.fetch("operation")
      result = case operation
               when "list" then list(request)
               when "search" then search(request)
               when "read" then read(request)
               else raise Refused, "source.operation"
               end
      deadline!
      result.merge("kind" => "live_source", "git" => @observation,
        "_snapshot" => { "git" => @observation, "files" => @files })
    end

    # Confirms the same tracked inventory/Git revision and every referenced file
    # immediately before a wire fragment. No changed source can join old chunks.
    def verify(snapshot)
      inventory
      raise Refused, "source.changed" unless snapshot.fetch("git") == @observation
      snapshot.fetch("files").each do |path, version|
        raise Refused, "source.changed" unless file(path).fetch("version") == version
      end
      deadline!
    end

    # Reads one admitted tracked regular UTF-8 file using pinned descriptors.
    # Returns whole bytes plus version/digest/worktree facts. Denied files are
    # rejected before opening; unsupported binary content raises fixed Refused.
    def file(path, budget: false)
      deadline!
      SourceFiles.relative!(path)
      entry = @entries[path]
      raise Refused, "source.scope" if !entry || SourceFiles.denied?(path)
      bytes, identity = SourceFiles.read(File.join(@root, path), limit: FILE_LIMIT) do |size|
        if budget
          raise Refused, "source.scan_limit" if @read_bytes + size > SCAN_BYTES
          @read_bytes += size
        end
      end
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Refused, "source.binary" unless text.valid_encoding? && !text.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
      digest = Digest::SHA256.hexdigest(bytes)
      object_digest = (entry.fetch("blob").length == 40 ? Digest::SHA1 : Digest::SHA256).hexdigest("blob #{bytes.bytesize}\0".b + bytes)
      version = Digest::SHA256.hexdigest(JSON.generate([digest, identity, @observation, @binding["lease"]]))
      @files[path] = version
      matches_index = object_digest == entry.fetch("blob") && ((identity[2] & 0o111).positive? == (entry.fetch("mode") == "100755"))
      { "bytes" => bytes, "sha256" => digest, "version" => version,
        "worktree" => matches_index ? "matches_index" : "modified_from_index" }
    end

    # Paginates only policy-admitted immediate children. A bounded prefix scan
    # excludes missing, special, aliased and inaccessible entries before names
    # are returned. Offsets count examined tracked paths, not denied filenames.
    def list(request)
      path = SourceFiles.relative!(request.fetch("path", ""), empty: true)
      raise Refused, "source.scope" if SourceFiles.denied?(path)
      prefix = path.empty? ? "" : "#{path}/"
      candidates = @entries.keys.sort.select { |name| name.start_with?(prefix) }
      offset = request.fetch("offset", 0)
      raise Refused, "source.offset" unless offset <= candidates.length
      entries = {}
      examined = 0
      candidates.drop(offset).each do |name|
        break if examined >= SCAN_FILES || entries.length >= PAGE
        examined += 1
        deadline!
        begin
          SourceFiles.open(File.join(@root, name)) { |_file| nil }
        rescue Refused
          next
        end
        child = name.delete_prefix(prefix).split("/").first
        entries[child] = { "path" => prefix + child, "type" => name == prefix + child ? "file" : "directory" }
      end
      next_offset = offset + examined
      { "path" => path, "entries" => entries.values, "truncated" => next_offset < candidates.length,
        "next_offset" => next_offset < candidates.length ? next_offset : nil }
    end

    # Searches literal UTF-8 text in bounded admitted files. Never opens denied
    # paths, invokes grep or interprets regexes. Returns digest-bound snippets;
    # limits/unsupported or changed sources set incomplete, never exhaustive.
    def search(request)
      query = request.fetch("query")
      raise Refused, "source.query" unless query.is_a?(String) && query.valid_encoding? &&
        query.bytesize.between?(1, 128) && !query.match?(/[\x00-\x1f\x7f]/)
      path = SourceFiles.relative!(request.fetch("path", ""), empty: true)
      raise Refused, "source.scope" if SourceFiles.denied?(path)
      candidates = @entries.keys.sort.select { |name| path.empty? || name == path || name.start_with?("#{path}/") }
      offset = request.fetch("offset", 0)
      raise Refused, "source.offset" unless offset <= candidates.length
      matches, scanned, incomplete = [], 0, false
      candidates.drop(offset).each do |name|
        break if scanned >= SCAN_FILES || @read_bytes >= SCAN_BYTES || matches.length >= 32
        deadline!
        scanned += 1
        begin
          observed = file(name, budget: true)
          content = observed.fetch("bytes")
          # A bounded byte excerpt around the first match avoids unbounded lines.
          location = content.index(query.b)
          next unless location
          snippet = content.byteslice([location - 40, 0].max, 160).force_encoding(Encoding::UTF_8).scrub
          matches << { "path" => name, "sha256" => observed.fetch("sha256"), "byte_offset" => location, "snippet" => snippet }
        rescue Refused
          incomplete = true
        end
      end
      next_offset = offset + scanned
      { "matches" => matches, "match_policy" => "first_per_file", "scanned_files" => scanned, "scanned_bytes" => @read_bytes,
        "truncated" => incomplete || next_offset < candidates.length,
        "next_offset" => next_offset < candidates.length ? next_offset : nil }
    end

    # Returns one lossless base64 chunk with whole-file digest and an opaque live
    # version. Noninitial offsets require the previous version; edits anywhere,
    # index changes and HEAD movement refuse instead of combining versions.
    def read(request)
      path = request.fetch("path")
      offset, length = request.fetch("offset", 0), request.fetch("length", CHUNK)
      observed = file(path)
      version = request["version"]
      raise Refused, "source.version" if (offset.positive? && !version) || (version && version != observed.fetch("version"))
      bytes = observed.delete("bytes")
      raise Refused, "source.offset" if offset > bytes.bytesize
      chunk = bytes.byteslice(offset, length) || "".b
      next_offset = offset + chunk.bytesize
      observed.merge("path" => path, "encoding" => "base64", "data" => [chunk].pack("m0"),
        "chunk_sha256" => Digest::SHA256.hexdigest(chunk), "bytes" => bytes.bytesize,
        "offset" => offset, "next_offset" => next_offset < bytes.bytesize ? next_offset : nil,
        "status" => next_offset < bytes.bytesize ? "truncated" : "complete")
    end
  end
end
