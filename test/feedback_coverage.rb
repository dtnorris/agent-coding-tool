# frozen_string_literal: true

require "coverage"
require "digest"
require "json"
require "securerandom"

# ACT-owned line/branch coverage. The denominator is every lib/**/*.rb and the
# public bin/agent-coding-tool entry, including files never required by a test.
# Dependencies, harness code and fixture implementations are excluded.
module FeedbackCoverage
  # Returns source hashes for the explicit production denominator at root.
  # Missing entry points and unreadable source raise instead of shrinking scope.
  def self.sources(root)
    paths = Dir.glob("lib/**/*.rb", base: root).sort + ["bin/agent-coding-tool"]
    raise "coverage: empty production library" if paths.length == 1

    paths.to_h { |path| [path, Digest::SHA256.file(File.join(root, path)).hexdigest] }
  end

  # Normalizes Coverage's arrays and branch coordinates into JSON-safe nodes.
  # Returns executable line/branch hit counts; nil lines never enter the total.
  def self.nodes(result)
    lines = result.fetch(:lines).each_with_index.filter_map { |hits, index| ["line:#{index + 1}", hits] unless hits.nil? }
    branches = result.fetch(:branches).flat_map do |origin, targets|
      targets.map { |target, hits| ["branch:#{origin.inspect}:#{target.inspect}", hits] }
    end
    (lines + branches).to_h
  end

  # Independently compiles the current all-file denominator in the outer runner
  # before any child executes. Returns zero-hit node layouts without evaluating
  # production code. An existing observer permits only new, disjoint fixture
  # paths, so native verifier controls cannot reset their own production hits.
  # Records those compile-only layouts separately from observed production.
  def self.layout(root)
    existing = Coverage.running?
    paths = sources(root).keys
    if existing && paths.any? { |path| Coverage.peek_result.key?(File.join(root, path)) }
      raise "coverage: denominator compilation would reset observed source"
    end

    Coverage.start(lines: true, branches: true) unless existing
    paths.each do |path|
      RubyVM::InstructionSequence.compile_file(File.join(root, path), coverage_enabled: true)
    end
    results = existing ? Coverage.peek_result : Coverage.result
    layout = sources(root).to_h { |path, _hash| [path, nodes(results.fetch(File.join(root, path)))] }
    if existing
      @compiled_fixtures ||= {}
      layout.each { |path, values| @compiled_fixtures[File.join(root, path)] = values.dup.freeze }
    end
    layout
  end

  # Resolves exact source bytes, including identical disposable cold-CLI copies.
  # Returns the canonical relative path, nil for dependencies/fixture code, or
  # raises for changed production bytes. No fixture implementation is inferred
  # to be a production file merely from its basename.
  def self.relative(path, context)
    absolute = File.expand_path(path)
    relative = context.fetch("sources").keys.find { |candidate| absolute.end_with?("/#{candidate}") }
    return nil unless relative
    raise "coverage: changed source #{absolute}" unless File.file?(absolute) &&
      Digest::SHA256.file(absolute).hexdigest == context.fetch("sources").fetch(relative)

    relative
  end

  # Starts before helpers/production loading in each selected Ruby interpreter.
  # Compiles unloaded files without evaluating them, then records fresh coverage
  # at exit, after Minitest. A killed ACT-executing child leaves an active marker
  # without a result and cannot silently contribute partial coverage.
  def self.start(context_path)
    context = JSON.parse(File.binread(context_path))
    raise "coverage: source changed before child startup" unless sources(context.fetch("root")) == context.fetch("sources")
    raise "coverage: already running before ACT preload" if Coverage.running?
    raise "coverage: instrumentation started after production load" if $LOADED_FEATURES.any? { |path|
      context.fetch("sources").keys.any? { |source| File.expand_path(path).end_with?("/#{source}") } }

    Coverage.start(lines: true, branches: true)
    context.fetch("sources").each_key do |path|
      RubyVM::InstructionSequence.compile_file(File.join(context.fetch("root"), path), coverage_enabled: true)
    end
    identifier = "#{Process.pid}-#{SecureRandom.hex(12)}"
    prefix = File.join(context.fetch("directory"), identifier)
    File.write("#{prefix}.started", JSON.generate("pid" => Process.pid, "argv" => [$PROGRAM_NAME, *ARGV], "cwd" => Dir.pwd), mode: "wx")
    active = false
    trace = TracePoint.new(:line) do |event|
      next unless context.fetch("sources").keys.any? { |path| File.expand_path(event.path).end_with?("/#{path}") }

      relative(event.path, context)
      File.write("#{prefix}.active", "ACT source executed\n", mode: "wx")
      active = true
      trace.disable
    end
    trace.enable
    original_pid = Process.pid
    at_exit do
      trace.disable
      raise "coverage: forked interpreter lacks fresh coverage context" unless Process.pid == original_pid
      raise "coverage: source changed during execution" unless sources(context.fetch("root")) == context.fetch("sources")

      files = {}
      Coverage.result.each do |path, result|
        # Nested verifier layouts share the observer but are not production.
        # Only exact, still-zero layouts are excluded; executed files must pass
        # the same byte identity check as any other observed source.
        next if @compiled_fixtures&.key?(path) && @compiled_fixtures.fetch(path) == nodes(result)

        relative_path = relative(path, context)
        next unless relative_path

        observed = nodes(result)
        previous = files[relative_path]
        raise "coverage: contradictory executable layout" if previous && previous.keys.sort != observed.keys.sort
        files[relative_path] = observed.to_h { |node, hits| [node, [hits, previous&.fetch(node, 0) || 0].max] }
      end
      result = { "invocation" => context.fetch("invocation"), "selection" => context.fetch("selection"),
                 "stage" => context.fetch("stage"), "sources" => context.fetch("sources"),
                 "pid" => Process.pid, "active" => active, "files" => files }
      File.write("#{prefix}.json", JSON.generate(result), mode: "wx")
    end
  end

  # Merges fresh child evidence by union of executed source nodes. Returns an
  # all-file map, or raises on missing, stale, duplicate or contradictory data.
  # Every ACT-executing interpreter must finish, including cold children.
  # Deliberately killed fixture-only interpreters cannot contribute coverage.
  def self.collect(context)
    directory = context.fetch("directory")
    starts = Dir.glob(File.join(directory, "*.started")).sort
    raise "coverage: no instrumented interpreter" if starts.empty?

    records = starts.filter_map do |path|
      result_path = path.delete_suffix(".started") + ".json"
      active = File.file?(path.delete_suffix(".started") + ".active")
      unless File.file?(result_path)
        raise "coverage: incomplete ACT-executing child evidence #{path}" if active
        next
      end

      result = JSON.parse(File.binread(result_path))
      %w[invocation selection stage sources].each do |key|
        raise "coverage: stale or contradictory #{key}" unless result.fetch(key) == context.fetch(key)
      end
      raise "coverage: contradictory child identity" unless result.fetch("pid") == JSON.parse(File.binread(path)).fetch("pid")
      raise "coverage: contradictory production execution marker" unless result.fetch("active") == active
      result
    end
    extras = Dir.glob(File.join(directory, "*.json")) - starts.map { |path| path.delete_suffix(".started") + ".json" }
    raise "coverage: unregistered child evidence" unless extras.empty?
    raise "coverage: no production execution observed" unless records.any? { |record| record.fetch("active") }

    merged = {}
    records.each do |record|
      raise "coverage: incomplete production denominator" unless record.fetch("files").keys.sort == context.fetch("sources").keys.sort

      record.fetch("files").each do |path, values|
        raise "coverage: malformed hits" unless values.is_a?(Hash) && values.values.all? { |hits| hits.is_a?(Integer) && hits >= 0 }
        raise "coverage: denominator differs from independently compiled source" unless values.keys.sort == context.fetch("layout").fetch(path).keys.sort
        previous = merged[path]
        raise "coverage: contradictory line/branch layout" if previous && previous.keys.sort != values.keys.sort

        merged[path] = values.to_h { |node, hits| [node, [hits, previous&.fetch(node, 0) || 0].max] }
      end
    end
    merged
  end

  # Returns covered/total counts, percentages, unloaded files and uncovered
  # coordinates. Nodes are unioned rather than adding parent/child hit totals.
  def self.summary(files)
    totals = %w[line branch].to_h do |kind|
      values = files.values.flat_map { |nodes| nodes.select { |node, _hits| node.start_with?("#{kind}:") }.values }
      covered = values.count(&:positive?)
      [kind, { "covered" => covered, "total" => values.length,
               "percent" => values.empty? ? 100.0 : covered * 100.0 / values.length }]
    end
    totals.merge("files" => files.length,
      "zero_hit_files" => files.select { |_path, nodes| nodes.values.none?(&:positive?) }.keys,
      "uncovered" => files.to_h { |path, nodes| [path, nodes.select { |_node, hits| hits.zero? }.keys] })
  end

  # Unions compatible all-file maps; raises rather than accepting a reduced or
  # changed denominator. Intended for ordinary/native/fresh combined reporting.
  def self.merge(maps)
    raise "coverage: empty required layer" if maps.empty?

    maps.reduce do |combined, addition|
      raise "coverage: layer denominator changed" unless combined.keys.sort == addition.keys.sort
      combined.to_h do |path, nodes|
        other = addition.fetch(path)
        raise "coverage: layer layout changed" unless nodes.keys.sort == other.keys.sort
        [path, nodes.to_h { |node, hits| [node, [hits, other.fetch(node)].max] }]
      end
    end
  end
end

FeedbackCoverage.start(ENV.fetch("ACT_COVERAGE_CONTEXT")) if ENV["ACT_COVERAGE_CONTEXT"]
