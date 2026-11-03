# frozen_string_literal: true

require "fiddle/import"
require "digest"
require_relative "run_evidence_store"

module AgentCodingTool
  # Descriptor-relative, no-follow access. Every directory is pinned while its
  # child is opened; hard links, special files and replaced ancestors fail closed.
  module SourceFiles
    Refused = RunEvidenceReader::Refused
    extend Fiddle::Importer
    dlload Fiddle::Handle::DEFAULT
    extern "int openat(int, const char*, int)"

    # Opens an absolute canonical path from the filesystem root without following
    # any symlink. Yields an IO; returns the block result. Replaced ancestry,
    # unsupported types and access errors raise a fixed refusal without paths.
    def self.open(path, directory: false)
      raise Refused, "source.path" unless path.is_a?(String) && path.start_with?("/") && File.expand_path(path) == path
      handles = [File.open("/", File::RDONLY)]
      names = path.split("/").reject(&:empty?)
      names.each_with_index do |name, index|
        descriptor = openat(handles.last.fileno, name, File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
        raise Refused, "source.open" if descriptor.negative?
        child = IO.for_fd(descriptor, autoclose: true)
        child.close_on_exec = true
        handles << child
        stat = child.stat
        last = index == names.length - 1
        raise Refused, "source.type" unless last && !directory ? stat.file? && stat.nlink == 1 && stat.uid == Process.uid : stat.directory?
      end
      result = yield handles.last
      names.each_with_index do |name, index|
        descriptor = openat(handles[index].fileno, name, File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
        raise Refused, "source.changed" if descriptor.negative?
        current = IO.for_fd(descriptor, autoclose: true)
        begin
          raise Refused, "source.changed" unless identity(current.stat) == identity(handles[index + 1].stat)
        ensure
          current.close
        end
      end
      result
    rescue SystemCallError, IOError, ArgumentError
      raise Refused, "source.unavailable", cause: nil
    ensure
      handles&.reverse_each { |handle| handle.close unless handle.closed? }
    end

    # Returns stable identity/type/owner facts without timestamps or filenames.
    # Directory link counts change with unrelated child entries; only regular
    # file link counts are identity facts. Accepts File::Stat and returns an
    # array for exact comparisons; filesystem/stat errors propagate.
    def self.identity(stat)
      [stat.dev, stat.ino, stat.mode, stat.uid, stat.directory? ? nil : stat.nlink]
    end

    # Reads at most limit bytes from one pinned owned regular file. Returns bytes
    # and version facts; size, in-place writes and replacement raise Refused.
    # An optional block reserves the observed size before any file bytes are read.
    def self.read(path, limit:)
      open(path) do |file|
        before = file.stat
        raise Refused, "source.limit" if before.size > limit
        yield before.size + 1 if block_given?
        bytes = file.binmode.read(before.size + 1) || "".b
        after = file.stat
        raise Refused, "source.changed" unless bytes.bytesize == before.size &&
          before == after && before.mtime == after.mtime && before.ctime == after.ctime
        [bytes, identity(before) + [before.size, before.mtime.to_r.to_s, before.ctime.to_r.to_s]]
      end
    end

    # Validates a portable relative source path. Empty is allowed only for a
    # directory query. Absolute paths, traversal, aliases and control bytes refuse.
    def self.relative!(path, empty: false)
      raise Refused, "source.path" unless path.is_a?(String) && path.bytesize <= 512 &&
        ((empty && path.empty?) || path.match?(%r{\A[A-Za-z0-9_.@+ -]+(?:/[A-Za-z0-9_.@+ -]+)*\z})) &&
        path.split("/").none? { |part| %w[. ..].include?(part) }
      path
    end

    # Sensitive exclusions always precede tracked admission. Conservative names
    # cover environment files, Git/admin/config stores, keys and credential files.
    # This policy cannot detect secrets embedded in otherwise admitted source.
    def self.denied?(path)
      path.downcase.split("/").any? do |part|
        part.start_with?(".env", ".yarnrc") || %w[.git .config .ssh .aws .azure .kube .gnupg .netrc .npmrc .pypirc .gitconfig .git-credentials .gitmodules .lfsconfig .docker .bundle .terraform .vault-token .s3cfg .boto .authinfo .htpasswd .pgpass .my.cnf .curlrc pip.conf].include?(part) ||
          part.match?(/\A(?:id_(?:rsa|dsa|ecdsa|ed25519)(?:\..*)?|authorized_keys|known_hosts)\z/) ||
          part.match?(/(?:credential|secret|token|password|keystore|keychain|private[_-]?key|service[_-]?account)/) ||
          part.match?(/\.(?:pem|key|p8|ppk|der|p12|pfx|jks|kdbx|tfstate|tfvars|mobileprovision)\z/)
      end
    end
  end
end
