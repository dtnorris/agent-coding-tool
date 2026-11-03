# frozen_string_literal: true

require_relative "../../lib/agent_coding_tool/source_reader"
require "fileutils"

# Offline Git metadata only. The production filesystem/policy/reader/session,
# transport and adapter remain real; no native Git is permitted by this fixture.
module SourceFixture
  # Creates a disposable repository inventory without launching Git. Returns its
  # path; tracked names/modes/blob IDs and ignored names are explicit fixture data.
  def self.repository(root, files, ignored: [])
    FileUtils.mkdir_p(File.join(root, ".git"))
    entries = files.to_h do |path, bytes|
      destination = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(destination))
      File.binwrite(destination, bytes)
      [path, { "mode" => "100644", "blob" => Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes.b) }]
    end
    File.write(File.join(root, ".git", "index"), JSON.generate(entries))
    File.write(File.join(root, ".git", "source-fixture.json"), JSON.generate("revision" => "a" * 40, "ignored" => ignored))
    root
  end

  # Replaces only closed external Git queries for an explicitly marked fixture.
  # Unknown queries/roots fail through the production boundary and process guard.
  module Git
    # Returns independently written fixture metadata; source content is never
    # read by this fake. Query validation and the total deadline remain required.
    def call(root, query, deadline:)
      marker = File.join(root, ".git", "source-fixture.json")
      return super unless File.file?(marker)
      raise "undeclared source query" unless AgentCodingTool::SourceGit::QUERIES.include?(query)
      raise AgentCodingTool::RunEvidenceReader::Refused, "source.deadline" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      fixture = JSON.parse(File.binread(marker))
      case query
      when %w[rev-parse --show-toplevel] then root + "\n"
      when %w[rev-parse --absolute-git-dir] then File.join(root, ".git") + "\n"
      when %w[rev-parse HEAD] then fixture.fetch("revision") + "\n"
      when %w[ls-files --stage -z]
        JSON.parse(File.binread(File.join(root, ".git", "index"))).map do |path, entry|
          "#{entry.fetch('mode')} #{entry.fetch('blob')} 0\t#{path}\0"
        end.join
      when %w[ls-files --cached --ignored --exclude-standard -z]
        fixture.fetch("ignored").map { |path| path + "\0" }.join
      end
    end
  end
end

AgentCodingTool::SourceGit.prepend(SourceFixture::Git)
