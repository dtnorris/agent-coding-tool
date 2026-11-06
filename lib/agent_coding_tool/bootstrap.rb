# frozen_string_literal: true

require "json"
require "digest"

module AgentCodingTool
  # Resolves one process-wide implementation before production loads. The lock
  # binds three exact source trees; only tasks supplies behavior in this seed.
  module Bootstrap
    # Startup configuration or source identity could not be verified.
    class Refused < StandardError; end
    ROOT = File.expand_path("../..", __dir__).freeze
    PACKAGES = %w[act-tasks act-observability act-lifecycle].freeze

    # Returns the allowlisted mode from this checkout's .env, or nil. No shell,
    # interpolation, dependency discovery or unrelated environment loading occurs.
    # Duplicate or malformed selected entries raise Refused; I/O errors propagate.
    def self.file_mode(root)
      path = File.join(root, ".env")
      return nil unless File.file?(path)

      entries = File.readlines(path).select { |line| line.match?(/\A\s*(?:export\s+)?ACT_IMPLEMENTATION\b/) }
      raise Refused, "bootstrap: duplicate ACT_IMPLEMENTATION in .env" if entries.size > 1
      return nil if entries.empty?

      match = entries.first.match(/\A\s*(?:export\s+)?ACT_IMPLEMENTATION\s*=\s*(?:"(legacy|split)"|'(legacy|split)'|(legacy|split))\s*(?:#.*)?\r?\n?\z/)
      raise Refused, "bootstrap: invalid ACT_IMPLEMENTATION in .env" unless match

      match.captures.compact.first
    end

    # Reads a checkout's exact SHA-1 HEAD without running Git. Supports ordinary
    # and linked worktrees with loose/packed branch refs; unsupported identities
    # refuse rather than being reported as an observed revision.
    def self.revision(root)
      pointer = File.join(root, ".git")
      directory = if File.directory?(pointer)
                    pointer
                  else
                    value = File.binread(pointer)
                    raise Refused, "bootstrap: malformed package gitdir" unless value.match?(/\Agitdir: [^\r\n\0]+\n?\z/)
                    File.expand_path(value.delete_prefix("gitdir: ").strip, root)
                  end
      head = File.read(File.join(directory, "HEAD")).strip
      return head if head.match?(/\A[0-9a-f]{40}\z/)

      reference = head.delete_prefix("ref: ")
      unless head.start_with?("ref: ") && reference.match?(/\Arefs\/(?:[A-Za-z0-9_.-]+\/)*[A-Za-z0-9_.-]+\z/) && !reference.include?("..")
        raise Refused, "bootstrap: unsupported package HEAD"
      end
      common = File.join(directory, "commondir")
      directory = File.expand_path(File.read(common).strip, directory) if File.file?(common)
      loose = File.join(directory, reference)
      value = if File.file?(loose)
                File.read(loose).strip
              else
                File.readlines(File.join(directory, "packed-refs")).filter_map do |line|
                  sha, name = line.split
                  sha if name == reference
                end.fetch(0)
              end
      raise Refused, "bootstrap: unsupported package revision" unless value.match?(/\A[0-9a-f]{40}\z/)

      value
    end

    # Returns a source-bound composition from explicit env, this checkout's .env
    # or published split default. Development roots are explicit and never prove
    # publication. Missing/mismatched packages and inherited composition drift raise
    # Refused before production loads; the caller publishes the resolved env.
    def self.resolve(root:, env:)
      mode = env.key?("ACT_IMPLEMENTATION") ? env["ACT_IMPLEMENTATION"] : file_mode(root) || "split"
      raise Refused, "bootstrap: ACT_IMPLEMENTATION must be legacy or split" unless %w[legacy split].include?(mode)

      result = { "mode" => mode, "packages" => {} }
      if mode == "split"
        lock = JSON.parse(File.read(File.join(root, "split-composition.json")))
        unless lock.fetch("packages").keys.sort == PACKAGES.sort
          raise Refused, "bootstrap: composition must pin tasks, observability and lifecycle"
        end
        development = env["ACT_SPLIT_DEVELOPMENT_ROOT"]
        parent = development || env["ACT_COMPONENT_ROOT"] || File.expand_path("../agent-coding-tool-components", root)
        result["qualification"] = development ? "development candidate; publication pending" : "published"
        lock.fetch("packages").each do |name, pin|
          package = File.realpath(File.join(parent, name))
          actual_revision = revision(package)
          raise Refused, "bootstrap: #{name} revision differs from pinned #{pin.fetch('revision')}" unless actual_revision == pin.fetch("revision")

          files = Dir.glob("lib/**/*.rb", base: package).sort.to_h do |path|
            absolute = File.join(package, path)
            raise Refused, "bootstrap: package source escapes root" unless File.realpath(absolute).start_with?(package + "/")
            [path, Digest::SHA256.file(absolute).hexdigest]
          end
          expected = development ? pin.fetch("development_files", pin.fetch("files")) : pin.fetch("files")
          raise Refused, "bootstrap: #{name} source differs from pinned digest" unless files == expected

          result.fetch("packages")[name] = { "root" => package, "revision" => actual_revision,
            "sha256" => Digest::SHA256.hexdigest(JSON.generate(files)) }
        end
        tasks = result.fetch("packages").fetch("act-tasks").fetch("root")
        unless File.file?(File.join(tasks, "lib/act_tasks/task_store.rb"))
          raise Refused, "bootstrap: pinned act-tasks scaffold has no TaskStore; publish the reviewed candidate and update the composition"
        end
      end
      encoded = JSON.generate(result)
      if env["ACT_RESOLVED_COMPOSITION"] && env["ACT_RESOLVED_COMPOSITION"] != encoded
        raise Refused, "bootstrap: inherited composition changed"
      end
      immutable(result)
    rescue SystemCallError, KeyError, IndexError, JSON::ParserError => error
      raise Refused, "bootstrap: required split composition unavailable: #{error.message}"
    end

    # Deep-freezes composition data so later environment edits cannot change the
    # selected implementation. Returns the value; only JSON-shaped data is used.
    def self.immutable(value)
      value.each { |key, item| immutable(key); immutable(item) } if value.is_a?(Hash)
      value.freeze
    end

    # Snapshots only bootstrap inputs for descendants loading this same source
    # checkout. Takes an already validated composition and its original resolver
    # inputs; returns frozen settings, with relative component parents made
    # absolute before a child changes cwd. Descendants still validate every pin
    # and digest against their own lock; this is not a cross-checkout override.
    def self.child_environment(root:, env:, composition:)
      settings = { "ACT_IMPLEMENTATION" => composition.fetch("mode"),
        "ACT_RESOLVED_COMPOSITION" => JSON.generate(composition),
        "ACT_COMPONENT_ROOT" => nil, "ACT_SPLIT_DEVELOPMENT_ROOT" => nil }
      if composition.fetch("mode") == "split"
        key = env["ACT_SPLIT_DEVELOPMENT_ROOT"] ? "ACT_SPLIT_DEVELOPMENT_ROOT" : "ACT_COMPONENT_ROOT"
        settings[key] = env[key] ? File.expand_path(env.fetch(key)) : File.expand_path("../agent-coding-tool-components", root)
      end
      immutable(settings)
    end

    COMPOSITION = resolve(root: ROOT, env: ENV)
    CHILD_ENVIRONMENT = child_environment(root: ROOT, env: ENV, composition: COMPOSITION)
    ENV["ACT_IMPLEMENTATION"] = COMPOSITION.fetch("mode")
    ENV["ACT_RESOLVED_COMPOSITION"] = JSON.generate(COMPOSITION)
  end
end
