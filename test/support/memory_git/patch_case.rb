# frozen_string_literal: true

require "json"
require_relative "objects"

module MemoryGit
  # Reviewed finite transition; binary payloads are never decoded into trees.
  class PatchCase
    attr_reader :bytes, :sha256, :before, :after, :paths, :numstat, :stat, :fragments

    # Binds raw bytes/hash to independent scoped trees, inventory and statistics.
    # Invalid hashes, paths, modes or unchanged entries raise Mismatch; no IO.
    def initialize(bytes:, sha256:, before:, after:, paths:, numstat:, stat:, sections: nil)
      @bytes, @sha256 = bytes.b.freeze, sha256.dup.freeze
      @before, @after = Tree.new(before), Tree.new(after)
      @paths = paths.map { |path| Tree.path!(path).freeze }.sort.freeze
      inventory = (@before.entries.keys | @after.entries.keys).sort
      changed = inventory.select { |path| @before.entries[path] != @after.entries[path] }
      raise Mismatch, "patch hash/scope differs from reviewed record" unless
        @sha256.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.hexdigest(@bytes) == @sha256 &&
        !@bytes.empty? && !@paths.empty? && @paths.uniq == @paths && inventory == @paths && changed == @paths &&
        @paths.none? { |path| path.split("/").any? { |part| part.downcase == ".git" } }
      @numstat, @stat = numstat.b.freeze, stat.b.freeze
      raise Mismatch, "patch inventory differs from numstat" unless numstat_paths == @paths
      @fragments = (sections || []).map do |section|
        selected = section.fetch(:paths)
        self.class.new(**section, before: @before.entries.slice(*selected), after: @after.entries.slice(*selected))
      end.freeze
      unless @fragments.empty?
        raise Mismatch, "patch sections differ from reviewed bytes/scope" unless
          @fragments.map(&:bytes).join == @bytes && @fragments.flat_map(&:paths).sort == @paths
      end
      freeze
    end

    # Loads a reviewed JSON descriptor plus sibling raw patch. Hex preserves
    # arbitrary path/content bytes. IO/JSON/key errors and Mismatch propagate.
    def self.load(path)
      record = JSON.parse(File.binread(path))
      trees = %w[before after].to_h do |side|
        entries = record.fetch(side).map do |entry|
          [hex_bytes(entry.fetch("path_hex")), Entry.new(hex_bytes(entry.fetch("bytes_hex")), mode: entry.fetch("mode"))]
        end
        raise Mismatch, "duplicate fixture tree path" unless entries.map(&:first).uniq.length == entries.length
        [side.to_sym, entries.to_h]
      end
      filename = record.fetch("patch")
      raise Mismatch, "patch fixture must be a basename" unless File.basename(filename) == filename
      bytes = File.binread(File.join(File.dirname(path), filename))
      sections = record.fetch("sections", []).map do |section|
        { bytes: bytes.byteslice(section.fetch("offset"), section.fetch("length")), sha256: section.fetch("sha256"),
          paths: section.fetch("paths_hex").map { |hex| hex_bytes(hex) }, numstat: hex_bytes(section.fetch("numstat_hex")), stat: section.fetch("stat") }
      end
      new(**trees, bytes: bytes, sha256: record.fetch("sha256"), sections: sections,
        paths: record.fetch("paths_hex").map { |hex| hex_bytes(hex) },
        numstat: hex_bytes(record.fetch("numstat_hex")), stat: record.fetch("stat"))
    end

    # Decodes descriptor bytes without accepting odd-length or nonhex spelling.
    # Returns binary String; invalid descriptor input raises Mismatch.
    def self.hex_bytes(hex)
      raise Mismatch, "malformed fixture hex bytes" unless hex.is_a?(String) && hex.match?(/\A(?:[0-9a-f]{2})*\z/)
      [hex].pack("H*")
    end

    private

    # Extracts ordinary or rename NUL-framed numstat paths; malformed rows refuse.
    def numstat_paths
      fields, found = numstat.split("\0"), []
      until fields.empty?
        match = /\A(?:\d+|-)\t(?:\d+|-)\t(.*)\z/mn.match(fields.shift)
        raise Mismatch, "malformed reviewed numstat" unless match
        if match[1].empty?
          raise Mismatch, "incomplete reviewed rename" unless fields.length >= 2
          found.concat(fields.shift(2))
        else
          found << match[1]
        end
      end
      found.sort
    end
  end
end
