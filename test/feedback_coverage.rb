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
    @line_names ||= []
    @branch_names ||= {}
    observed = {}
    result.fetch(:lines).each_with_index do |hits, index|
      observed[(@line_names[index] ||= "line:#{index + 1}")] = hits unless hits.nil?
    end
    result.fetch(:branches).each do |origin, targets|
      names = (@branch_names[origin] ||= {})
      targets.each do |target, hits|
        observed[(names[target] ||= "branch:#{origin.inspect}:#{target.inspect}")] = hits
      end
    end
    observed
  end

  # Binds the invocation's independent all-file, zero-hit layout to its source
  # hashes. Missing files/nodes or a changed binding raise before reuse. Hits
  # never enter this identity and are always collected afresh by each observer.
  def self.denominator_identity(context)
    layout = context.fetch("layout")
    raise "coverage: incomplete production denominator" unless layout.is_a?(Hash) && context.fetch("sources").is_a?(Hash) &&
      layout.keys.sort == context.fetch("sources").keys.sort &&
      layout.values.all? { |values| values.is_a?(Hash) && values.values.all? { |hits| hits.is_a?(Integer) && hits.zero? } }
    identity = Digest::SHA256.hexdigest(JSON.generate([context.fetch("sources"), layout]))
    raise "coverage: denominator identity changed" if context["denominator_sha256"] && context.fetch("denominator_sha256") != identity

    identity
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
    sources = context.fetch("sources")
    unless @relative_sources.equal?(sources)
      @relative_sources = sources
      @relative_candidates = sources.keys.group_by { |candidate| File.basename(candidate) }
    end
    candidates = @relative_candidates.fetch(File.basename(path), [])
    return nil if candidates.empty?
    absolute = File.expand_path(path)
    return nil if @probe_contexts&.any? { |probe| probe.equal?(context) } && !absolute.start_with?(context.fetch("root") + "/")
    return nil if @probe_contexts&.any? { |probe| !probe.equal?(context) && absolute.start_with?(probe.fetch("root") + "/") }
    relative = candidates.find { |candidate| absolute.end_with?("/#{candidate}") }
    return nil unless relative
    raise "coverage: changed source #{absolute}" unless File.file?(absolute) &&
      Digest::SHA256.file(absolute).hexdigest == context.fetch("sources").fetch(relative)

    relative
  end

  # Starts before helpers/production loading in each selected Ruby interpreter.
  # Reuses only the parent's immutable zero-hit denominator, with an independent
  # compilation census for loaded source. Records fresh coverage at exit, after
  # Minitest. A killed ACT-executing child leaves an active marker
  # without a result and cannot silently contribute partial coverage.
  def self.start(context_path)
    begun = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    context = JSON.parse(File.binread(context_path))
    raise "coverage: source changed before child startup" unless sources(context.fetch("root")) == context.fetch("sources")
    hashed = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    denominator_identity(context)
    validated = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise "coverage: already running before ACT preload" if Coverage.running?
    raise "coverage: instrumentation started after production load" if $LOADED_FEATURES.any? { |path|
      context.fetch("sources").keys.any? { |source| File.expand_path(path).end_with?("/#{source}") } }

    Coverage.start(lines: true, branches: true)
    register(context)
    @observer[:timing] = { "startup_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - begun,
      "context_read_and_source_hash_seconds" => hashed - begun, "layout_validation_seconds" => validated - hashed,
      "compile_seconds" => 0 }
    at_exit { finish }
  end

  # Registers the contract's fixed three-file synthetic denominator alongside
  # inherited real-source instrumentation. No environment context is replaced;
  # roots must be disjoint and all synthetic bytes/layout are validated first.
  def self.start_probe(context_path)
    context = JSON.parse(File.binread(context_path))
    expected = %w[bin/agent-coding-tool lib/loaded.rb lib/unloaded.rb]
    raise "coverage: invalid synthetic probe layout" unless context.fetch("sources").keys.sort == expected &&
      sources(context.fetch("root")) == context.fetch("sources")
    denominator_identity(context)
    root = File.realpath(context.fetch("root"))
    raise "coverage: overlapping probe root" if (@observers || []).any? { |state|
      other = state.fetch(:context).fetch("root")
      root == other || root.start_with?(other + "/") || other.start_with?(root + "/") }
    raise "coverage: instrumentation started after production load" if $LOADED_FEATURES.any? { |path| path.start_with?(root + "/lib/") }
    Coverage.start(lines: true, branches: true) unless Coverage.running?
    (@probe_contexts ||= []) << context
    register(context)
    at_exit { finish }
  end

  # Registers a fresh interpreter identity and production activity trace. Returns
  # nil; exclusive marker creation and source validation failures propagate.
  def self.register(context)
    identifier = "#{Process.pid}-#{SecureRandom.hex(12)}"
    prefix = File.join(context.fetch("directory"), identifier)
    identity = denominator_identity(context)
    File.write("#{prefix}.started", JSON.generate("pid" => Process.pid, "argv" => [$PROGRAM_NAME, *ARGV], "cwd" => Dir.pwd,
      "denominator_sha256" => identity), mode: "wx")
    File.write("#{prefix}.census", "", mode: "wx")
    state = { context: context, prefix: prefix, pid: Process.pid, active: false, finished: false, loaded: {} }
    @observer = state
    (@observers ||= []) << state
    # Forks inherit compiled code but clear its counters. Capture that layout
    # before the owner block; subsequent compilations are recorded separately.
    Coverage.peek_result.each_key { |path| census(state, path) }
    compilation = TracePoint.new(:script_compiled) do |event|
      census(state, event.instruction_sequence.absolute_path || event.instruction_sequence.path)
    end
    state[:compilation] = compilation
    compilation.enable
    trace = TracePoint.new(:line) do |event|
      next unless relative(event.path, context)
      census(state, event.path)
      File.write("#{prefix}.active", "ACT source executed\n", mode: "wx")
      state[:active] = true
      trace.disable
    end
    state[:trace] = trace
    @trace = trace
    trace.enable
    nil
  end

  # Persists an independent loaded-source census before execution. Only exact
  # production bytes count; repeated loads of one absolute file are idempotent.
  # The collector must see these records even if a result file/map is deleted.
  def self.census(state, path)
    absolute = File.expand_path(path)
    return if state.fetch(:loaded).key?(absolute)
    source = relative(absolute, state.fetch(:context))
    return unless source

    File.open("#{state.fetch(:prefix)}.census", "ab") do |file|
      file.puts(JSON.generate("path" => absolute, "source" => source))
      file.flush
    end
    state.fetch(:loaded)[absolute] = source
    nil
  end

  # Rebinds only a genuinely forked observer before the owner block executes.
  # Child counters are cleared in the child address space; parent hits cannot be
  # evidence for child execution. The inherited all-file layouts remain intact.
  def self.after_fork
    raise "coverage: no inherited observer" unless @observer
    raise "coverage: fork observer is not inherited" if @observer.fetch(:pid) == Process.pid
    @trace.disable
    @observers.each { |state| state.fetch(:compilation).disable }
    context = @observer.fetch(:context)
    raise "coverage: fork context changed" unless ENV["ACT_COVERAGE_CONTEXT"] &&
      JSON.parse(File.binread(ENV.fetch("ACT_COVERAGE_CONTEXT"))) == context
    raise "coverage: fork source changed" unless sources(context.fetch("root")) == context.fetch("sources")
    Coverage.result(stop: false, clear: true)
    @observers = []
    register(context)
  end

  # Writes durable complete evidence once, including for a permitted exit! owner.
  # Unregistered forks, changed sources and duplicate completion refuse rather
  # than borrowing parent hits or silently dropping an active child.
  def self.finish
    states = @observers || []
    pending = states.reject { |state| state.fetch(:finished) }
    return if pending.empty?
    pending.each do |state|
      state.fetch(:trace).disable
      state.fetch(:compilation).disable
    end
    results = Coverage.peek_result
    pending.each { |state| finish_state(state, results) }
    Coverage.result
    nil
  end

  # Writes one observer's complete sparse maps from the native coverage result.
  # Multiple synthetic controls never replace or clear the inherited real context.
  def self.finish_state(state, results)
    begun = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise "coverage: forked interpreter lacks fresh coverage context" unless Process.pid == state.fetch(:pid)
    context = state.fetch(:context)
    raise "coverage: source changed during execution" unless sources(context.fetch("root")) == context.fetch("sources")
    hashed = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    identity = denominator_identity(context)
    observed_files = {}
    observed_paths = {}
    results.each do |path, result|
      next if @compiled_fixtures&.key?(path) && @compiled_fixtures.fetch(path) == nodes(result)
      relative_path = relative(path, context)
      next unless relative_path
      observed = nodes(result)
      observed_paths[File.expand_path(path)] = true
      previous = observed_files[relative_path]
      raise "coverage: contradictory executable layout" if previous && previous.keys.sort != observed.keys.sort
      raise "coverage: denominator differs from independently compiled source" unless observed.keys.sort == context.fetch("layout").fetch(relative_path).keys.sort
      # nodes already owns a fresh map. Most files have one observed path;
      # avoid rebuilding every node entry during TERM.
      # Identical cold copies still contribute the maximum for every node.
      if previous
        observed.each { |node, hits| previous[node] = hits if hits > previous.fetch(node) }
      else
        observed_files[relative_path] = observed
      end
    end
    raise "coverage: missing loaded source result" unless (state.fetch(:loaded).keys - observed_paths.keys).empty?
    raise "coverage: executed source missing from census" unless observed_files.all? { |path, values|
      values.values.none?(&:positive?) || state.fetch(:loaded).value?(path) }
    result = { "invocation" => context.fetch("invocation"), "selection" => context.fetch("selection"),
      "stage" => context.fetch("stage"), "sources" => context.fetch("sources"),
      "schema" => "act-coverage-census/v1", "complete" => true,
      "denominator_sha256" => identity, "loaded" => state.fetch(:loaded),
      "pid" => Process.pid, "active" => state.fetch(:active), "files" => observed_files,
      "timing" => (state[:timing] || {}).merge("finish_source_hash_seconds" => hashed - begun,
        "finish_prepare_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - begun) }
    publish_result("#{state.fetch(:prefix)}.json", result)
    state[:finished] = true
    nil
  end

  # Publishes complete JSON at path only after writing and syncing a private
  # sibling. An interrupted writer leaves no partial final result. Hard linking
  # preserves exclusive creation; duplicate paths and I/O errors propagate.
  def self.publish_result(path, result)
    pending = "#{path}.pending"
    owned = false
    File.open(pending, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      owned = true
      file.write(JSON.generate(result))
      file.flush
      file.fsync
    end
    File.link(pending, path)
    nil
  ensure
    File.unlink(pending) if owned
  end

  # Merges fresh child evidence by union of executed source nodes. Returns an
  # all-file map, or raises on missing, stale, duplicate or contradictory data.
  # Every ACT-executing interpreter must finish, including cold children.
  # Deliberately killed fixture-only interpreters cannot contribute coverage.
  def self.collect(context)
    identity = denominator_identity(context)
    raise "coverage: source changed before collection" unless sources(context.fetch("root")) == context.fetch("sources")
    directory = context.fetch("directory")
    starts = Dir.glob(File.join(directory, "*.started")).sort
    raise "coverage: no instrumented interpreter" if starts.empty?
    markers = Dir.glob(File.join(directory, "*.{active,census}"))
    expected_markers = starts.flat_map { |path| %w[active census].map { |suffix| path.delete_suffix(".started") + ".#{suffix}" } }
    raise "coverage: unregistered child markers" unless (markers - expected_markers).empty?

    records = starts.filter_map do |path|
      result_path = path.delete_suffix(".started") + ".json"
      active = File.file?(path.delete_suffix(".started") + ".active")
      unless File.file?(result_path)
        raise "coverage: incomplete ACT-executing child evidence #{path}" if active
        census_path = path.delete_suffix(".started") + ".census"
        loaded = File.readlines(census_path).map { |line| JSON.parse(line) }
        raise "coverage: incomplete production-loaded child evidence #{path}" unless loaded.empty?
        next
      end

      result = JSON.parse(File.binread(result_path))
      raise "coverage: incomplete census result" unless result["schema"] == "act-coverage-census/v1" && result["complete"] == true
      %w[invocation selection stage sources].each do |key|
        raise "coverage: stale or contradictory #{key}" unless result.fetch(key) == context.fetch(key)
      end
      raise "coverage: contradictory child identity" unless result.fetch("pid") == JSON.parse(File.binread(path)).fetch("pid")
      raise "coverage: contradictory production execution marker" unless result.fetch("active") == active
      raise "coverage: denominator identity changed" unless result.fetch("denominator_sha256") == identity &&
        JSON.parse(File.binread(path)).fetch("denominator_sha256") == identity
      census_path = path.delete_suffix(".started") + ".census"
      loaded = File.readlines(census_path).map { |line| JSON.parse(line).values_at("path", "source") }
      raise "coverage: contradictory loaded source census" unless loaded.to_h == result.fetch("loaded") &&
        loaded.map(&:first).uniq.length == loaded.length && loaded.all? { |absolute, source|
          context.fetch("sources").key?(source) && relative(absolute, context) == source }
      raise "coverage: missing loaded source result" unless (loaded.map(&:last) - result.fetch("files").keys).empty?
      result
    end
    extras = Dir.glob(File.join(directory, "*.json")) - starts.map { |path| path.delete_suffix(".started") + ".json" }
    raise "coverage: unregistered child evidence" unless extras.empty?
    raise "coverage: no production execution observed" unless records.any? { |record| record.fetch("active") }
    raise "coverage: duplicate child evidence" unless records.map { |record| record.fetch("pid") }.uniq.length == records.length

    # Only the invocation's independent layout can supply unloaded zero nodes.
    # Each sparse record has already proved every census load is present.
    merged = context.fetch("layout").transform_values(&:dup)
    records.each do |record|
      raise "coverage: unregistered production source" unless (record.fetch("files").keys - context.fetch("sources").keys).empty?

      record.fetch("files").each do |path, values|
        raise "coverage: malformed hits" unless values.is_a?(Hash) && values.values.all? { |hits| hits.is_a?(Integer) && hits >= 0 }
        raise "coverage: executed source missing from census" unless values.values.none?(&:positive?) ||
          (record.fetch("active") && record.fetch("loaded").value?(path))
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
