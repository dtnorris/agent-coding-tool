# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module AgentCodingTool
  # Explicit task-scoped disposal, distinct from retry closeout and soft reset.
  # Immutable originals and candidate recovery precede native removal. A small
  # phase receipt fences admission and permits a cold repeat after interruption.
  class TaskReset
    SCHEMA = "agent-coding-tool-hard-reset/v1"
    PHASES = %w[preserving archived retiring publishing complete].freeze
    RUNTIME_FIELDS = %w[status snapshot prepared_at prompt_path coding_skill planning_guidance planning_skill
      started_at result completion_snapshot completion_observations checkpoint write_overlap write_collision_override
      icebox administrative_override].freeze

    # Binds private data and optional deterministic interruption/liveness seams.
    # Construction reads no evidence and creates nothing.
    def initialize(data_root:, transport: NativeCommandTransport.new, liveness: RetryLiveness.new, fault: nil, task_store: nil, state_store: nil)
      @data = WorktreeManager.canonical_system_path(data_root)
      @runs, @archives = "#{@data}-runs", "#{@data}-resets"
      @tasks = task_store || TaskStore.new(File.join(@data, "tasks"))
      @states = state_store || StateStore.new(File.join(@data, "state"))
      @transport, @liveness, @fault = transport, liveness, fault
      @archive = ResetArchive.new(transport: transport)
    end

    # Lists validated phase receipts outside active discovery. Originals keep
    # their statuses; a reset receipt establishes no tests, acceptance or delivery.
    # Malformed/foreign receipts refuse rather than becoming absent history.
    def history(id)
      task_identity!(id)
      root = File.join(@archives, id)
      return [] unless present?(@archives)
      private_directory!(@archives)
      return [] unless present?(root)
      private_directory!(root)
      IncidentalMetadata.children(root).sort.map do |name|
        raise InvalidState, "hard reset: foreign archive entry" unless name.match?(ExternalActivity::UUID)
        directory = File.join(root, name)
        private_directory!(directory)
        receipt = read_receipt(directory)
        unless receipt.values_at("schema", "task_id", "archive") == [SCHEMA, id, directory] &&
               PHASES.include?(receipt["phase"]) && receipt["last_attempt"].is_a?(Integer) && receipt["last_attempt"] >= 0 &&
               receipt["intent_sha256"] == Digest::SHA256.file(plain_file!(File.join(directory, "intent.json"))).hexdigest
          raise InvalidState, "hard reset: malformed reset identity/phase"
        end
        receipt
      end
    end

    # Refuses new task writers during an unfinished operation. This is read-only
    # and must also be called inside each writer's physical reservation boundary.
    def assert_admission!(id)
      unfinished = history(id).find { |receipt| receipt["phase"] != "complete" }
      raise InvalidState, "#{id}: unfinished hard reset (#{unfinished.fetch('phase')}); repeat act reset #{id} --hard; archive: #{unfinished.fetch('archive')}" if unfinished
      retired_paths(id)
      nil
    end

    # Explains only empty retired containers to legacy filesystem scans. A
    # reoccupied resource remains foreign and refuses; old ordinary checkouts
    # need not remain configured or available after verified retirement.
    def retired_paths(id)
      history(id).select { |receipt| receipt["phase"] == "complete" }.flat_map do |receipt|
        load_intent(receipt).fetch("resources").map do |resource|
          path = resource.fetch("entry").fetch("path")
          safe_path!(path)
          raise InvalidState, "hard reset: retired resource reoccupied #{path}" if present?(path)
          path
        end
      end
    end

    # Prevents publication of lifecycle files while any task reset is unfinished.
    # Absent archives require no task scan; malformed private entries refuse.
    def assert_publication!
      return unless present?(@archives)
      private_directory!(@archives)
      IncidentalMetadata.children(@archives).each { |id| assert_admission!(id) }
    end

    # Returns the monotonic retired-attempt floor; archived attempts never inflate
    # active counts or permit retained branch/path reuse by a new invocation.
    def attempt_floor(id)
      history(id).map { |receipt| receipt.fetch("last_attempt") }.max || 0
    end

    # Reports current dependency/configuration blockers without preparation,
    # remote reads or writes. Source freshness/objects remain prepare/launch
    # gates; a successful reset cannot manufacture a valid missing repository.
    def readiness(id)
      task = task_identity!(id)
      blockers = task.fetch("depends_on", []).filter_map do |dependency|
        "dependencies incomplete: #{dependency}" unless @states.load(dependency).dig("result", "outcome") == "complete"
      end
      inspector = RepoInspector.new(Config.load(File.join(@data, "config.yml")), transport: @transport)
      task.fetch("repositories").each do |name, spec|
        begin
          inspector.repository_authority(name, spec)
        rescue RepositoryError => error
          blockers << "configuration: #{error.message}"
        end
      end
      blockers
    end

    # Builds a read-only preview from original evidence and native ownership.
    # Returns exact source/archive mappings, candidate summaries and blockers.
    # Unsafe paths, missing proof or unavailable liveness raise without writes.
    def preview(id)
      task = task_identity!(id)
      records = history(id)
      pending = records.reject { |receipt| receipt["phase"] == "complete" }
      raise InvalidState, "hard reset: conflicting unfinished operations" if pending.length > 1
      if pending.first
        receipt = pending.first
        intent = load_intent(receipt)
        recheck!(id, intent, receipt)
        return presentation(intent, receipt)
      end
      state_path = @states.state_path(id)
      state = load_state(id)
      runs = attempt_directories(id)
      attempts = runs.map { |directory| original_attempt!(id, directory) }
      entries = attempts.flat_map { |attempt| attempt.fetch("entries") }
      verify_scope!(id, attempts)
      verify_manual_state!(state, attempts)
      verify_override_reservations!(id, attempts)
      blockers = liveness_blockers(task, state, attempts)
      sources = []
      add_source(sources, @tasks.task_path(id), "original/task")
      add_source(sources, state_path, "original/state") if present?(state_path)
      add_source(sources, File.join(@runs, id), "original/runs", retire: true) unless runs.empty?
      checkpoint_root = File.join(@runs, "checkpoints", id)
      add_source(sources, checkpoint_root, "original/checkpoints", retire: true) if present?(checkpoint_root)
      override_root = File.join(@runs, LifecycleOverride::NAMESPACE, id)
      add_source(sources, override_root, "original/overrides", retire: true) if present?(override_root)
      prompt_paths(id, state).each_with_index { |path, index| add_source(sources, path, "original/prompts/#{index}", retire: true) }
      check_progress!(id, sources)
      resources = entries.uniq { |entry| entry.fetch("path") }.map.with_index do |entry, index|
        path = entry.fetch("path")
        exists = present?(path)
        { "entry" => entry, "archive" => "candidates/#{index}",
          "content" => exists ? @archive.inventory(path, worktree: true) : nil,
          "identity" => exists ? identity(path) : nil,
          "head" => exists ? git(path, "rev-parse", "HEAD").strip : nil,
          "git_state" => exists ? git_state(path) : nil,
          "git_status" => exists ? git(path, "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored").split("\0") : [] }
      end
      last = [attempt_floor(id), *attempts.map { |attempt| attempt.fetch("report").fetch("attempt") }].max
      replacement = (state || {}).reject { |key, _value| RUNTIME_FIELDS.include?(key) }.merge("id" => id)
      noop = !!(state && (state.empty? || state == replacement) && attempts.empty? && sources.none? { |source| source["retire"] })
      directory = File.join(@archives, id, SecureRandom.uuid)
      intent = { "schema" => SCHEMA, "task_id" => id, "archive" => directory, "last_attempt" => last,
        "sources" => sources, "attempts" => attempts, "resources" => resources,
        "replacement" => replacement,
        "configuration" => configuration_identity,
        "preparation_blockers" => readiness(id),
        "state_verification" => state ? "parsed; ownership/liveness checked separately" : "unverified raw bytes",
        "evidence_verification" => "original prompt and resource ownership corroborated; other progress/validation bytes preserved raw, not revalidated",
        "prior_outcome" => state&.dig("result", "outcome"), "icebox" => state && state.key?("icebox"),
        "downstream" => @tasks.all.filter_map { |other| other.fetch("id") if other.fetch("depends_on", []).include?(id) },
        "external_data_retained" => attempts.filter_map { |attempt| attempt.fetch("report").dig("fixture", "path") },
        "blockers" => blockers, "noop" => noop }
      presentation(intent, nil)
    rescue SystemCallError, IOError, JSON::ParserError, Psych::Exception, KeyError, TypeError => error
      raise InvalidState, "hard reset preview: #{error.class}: #{error.message}"
    end

    # Executes precisely a confirmed preview under the shared reservation lock.
    # No confirmation is inferred here: the public CLI owns terminal consent.
    # Returns the completed receipt; errors retain phase/artifacts and never
    # report lifecycle success before verified archival and retirement finish.
    def execute(id, preview:)
      return preview if preview.fetch("noop")
      ReservationLock.synchronize(@data) do
        current = self.preview(id)
        receipt = current["receipt"]
        intent = current.fetch("intent")
        unless receipt || comparable(current.fetch("intent")) == comparable(preview.fetch("intent"))
          raise InvalidState, "hard reset: source changed after preview; inspect a fresh preview"
        end
        raise InvalidState, "hard reset: #{intent.fetch('blockers').join('; ')}" unless intent.fetch("blockers").empty?
        unless receipt
          # Use the destination actually shown to the operator, not the fresh
          # UUID allocated by reinspection. Every source identity was rechecked.
          intent["archive"] = preview.fetch("intent").fetch("archive")
          receipt = begin_operation(intent)
        end
        @intent, @receipt = intent, receipt
        directory = receipt.fetch("archive")
        if receipt["phase"] == "preserving"
          preserve!(intent, receipt)
          transition!(receipt, "archived")
          @fault&.call("after_archive", receipt)
        end
        verify_archive!(intent, receipt)
        recheck!(id, intent, receipt)
        if %w[archived retiring].include?(receipt["phase"])
          transition!(receipt, "retiring")
          intent.fetch("resources").each_with_index { |resource, index| retire_resource!(resource, index, receipt) }
          retire_evidence!(intent, receipt)
          verify_retirement!(intent, receipt)
          transition!(receipt, "publishing")
        end
        recheck!(id, intent, receipt)
        if receipt["phase"] == "publishing"
          verify_retirement!(intent, receipt)
          @fault&.call("before_state", receipt)
          @states.write(id, intent.fetch("replacement")) unless reset_state?(id, intent)
          @fault&.call("after_state", receipt)
          transition!(receipt, "complete")
        end
        receipt
      end
    rescue Error, SystemCallError, IOError, NotImplementedError, JSON::ParserError, Psych::Exception, KeyError, TypeError => error
      location = @receipt && "; phase #{@receipt['phase']}; archive #{@receipt['archive']}; completed resources #{@receipt['retired'].inspect}; repeat the same command after resolving the failure"
      raise InvalidState, "hard reset: #{error.class}: #{error.message}#{location}"
    end

    private

    # Validates the actual root/task filename and matching registered identity.
    # Returns the current definition; paths and malformed tasks refuse unchanged.
    def task_identity!(id)
      raise InvalidTask, "hard reset: unsafe task ID" unless id.is_a?(String) && id.match?(ExternalActivity::ID)
      safe_path!(@data)
      plain_file!(@tasks.task_path(id))
      task = @tasks.load(id)
      raise InvalidTask, "hard reset: task identity mismatch" unless task["id"] == id
      task
    end

    # Returns parsed lifecycle or nil for independently recoverable damaged raw
    # bytes. A conflicting parsed identity always refuses; it is never repaired.
    def load_state(id)
      path = @states.state_path(id)
      plain_file!(path) if present?(path)
      state = @states.load(id)
      raise InvalidState, "hard reset: foreign task state" if state.key?("id") && state["id"] != id
      return nil unless state["result"].nil? || state["result"].is_a?(Hash)
      state
    rescue InvalidState => error
      raise if error.message.include?("foreign task state") || error.message.include?("unsafe")
      nil
    end

    # Returns safe active run directories, never archive directories. Unknown
    # children are evidence failures, independently of lifecycle/task scope.
    def attempt_directories(id)
      return [] unless present?(@runs)
      private_directory!(@runs)
      root = File.join(@runs, id)
      return [] unless present?(root)
      private_directory!(root)
      IncidentalMetadata.children(root).sort.map do |name|
        directory = File.join(root, name)
        private_directory!(directory)
        directory
      end
    end

    # Corroborates the original prompt, preparation, inventory and native Git.
    # Historical membership/access never comes from today's task. Malformed
    # progress/checkpoint bytes are preserved separately and confer no proof.
    def original_attempt!(id, directory)
      report = JSON.parse(File.binread(plain_file!(File.join(directory, "handoff.json"))))
      record_path = File.join(directory, "worktrees.json")
      unless report.values_at("schema_version", "task_id", "worktrees_path") == [Launcher::SCHEMA, id, record_path] &&
             report["attempt"].is_a?(Integer) && report["attempt"].positive? &&
             report["preparation"].is_a?(Hash) && !report["preparation"].empty?
        raise InvalidState, "hard reset: missing/corrupt original ownership #{directory}"
      end
      recovery = AttemptRecovery.new(data_root: @data, transport: @transport)
      if present?(record_path)
        raw = JSON.parse(File.binread(plain_file!(record_path)))
        manager = WorktreeManager.new(root: raw.fetch("root"), record_path: record_path, transport: @transport)
        heads = raw.fetch("entries").filter_map do |entry|
          [entry.fetch("name"), git(entry.fetch("path"), "rev-parse", "HEAD").strip] if present?(entry.fetch("path"))
        end.to_h
        inventory = manager.inspect!(head_overrides: heads, allow_partial: true)
        unless inventory.values_at("task_id", "attempt") == report.values_at("task_id", "attempt") &&
               (!inventory["invocation_id"] || inventory["invocation_id"] == report["invocation_id"]) &&
               inventory.fetch("entries").map { |entry| entry.fetch("name") }.sort == report.fetch("preparation").keys.sort &&
               (!report["worktrees"] || recovery.send(:immutable, report.fetch("worktrees")) == recovery.send(:immutable, inventory))
          raise InvalidState, "hard reset: conflicting original ownership #{directory}"
        end
        inventory.fetch("entries").each do |entry|
          prepared = report.fetch("preparation").fetch(entry.fetch("name"))
          unless prepared.values_at("path", "remote", "remote_url", "branch", "pushed_sha") ==
                 entry.values_at("parent", "remote", "remote_url", "source_branch", "base_sha")
            raise InvalidState, "hard reset: original source identity mismatch"
          end
          protected_roots!(inventory.fetch("root"), entry.fetch("parent"))
        end
        # Only the original prompt is authority for historical access. Damaged
        # logs/progress remain exact unverified raw bytes in the archive; no old
        # validation is inferred or relabeled. Process facts still pass liveness.
        prompt_report = report.merge("child_pid" => nil,
          "artifacts" => report.fetch("artifacts", []).select { |artifact| artifact["path"] == File.join(directory, "prompt.txt") })
        recovery.send(:verify_artifacts!, prompt_report, directory)
        recovery.send(:verify_original_contract!, report, directory, inventory)
      else
        recovery.send(:verify_no_creation!, id, report)
        inventory = { "entries" => [] }
      end
      { "run_dir" => directory, "report" => report, "inventory" => inventory, "entries" => inventory.fetch("entries") }
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError => error
      raise InvalidState, "hard reset: missing/corrupt ownership #{directory} (#{error.class})"
    end

    # Requires unique attempt numbers and exact owned children at every original
    # root, including legacy layouts. Foreign/overlapping paths always refuse.
    def verify_scope!(id, attempts)
      numbers = attempts.map { |attempt| attempt.fetch("report").fetch("attempt") }
      raise InvalidState, "hard reset: duplicate attempt identity" unless numbers.uniq == numbers
      entries = attempts.flat_map { |attempt| attempt.fetch("entries") }
      paths = entries.map { |entry| entry.fetch("path") }
      raise InvalidState, "hard reset: overlapping ownership" unless paths.uniq == paths
      roots = attempts.filter_map { |attempt| attempt.fetch("inventory")["root"] }
      # Retained empty attempt containers (including Finder metadata) are still
      # explained by original archived ownership, without counting active runs.
      history(id).select { |receipt| receipt["phase"] == "complete" }.each do |receipt|
        original = load_intent(receipt)
        paths.concat(original.fetch("resources").map { |resource| resource.fetch("entry").fetch("path") })
        roots.concat(original.fetch("attempts").filter_map { |attempt| attempt.fetch("inventory")["root"] })
      end
      roots << WorktreeManager.canonical_system_path(Config.load(File.join(@data, "config.yml")).worktree_root)
      roots.uniq.each do |root|
        safe_path!(root)
        foreign = WorktreeManager.foreign_task_paths(root: root, task_id: id, paths: paths)
        raise InvalidState, "hard reset: foreign task resources #{foreign.join(', ')}" unless foreign.empty?
      end
      paths.combination(2) do |first, second|
        next if first == second
        raise InvalidState, "hard reset: overlapping resource roots" if overlap?(first, second)
      end
    end

    # A manual start or damaged lifecycle without independent managed proof is
    # unknown process use. A terminal status alone cannot release a reservation.
    def verify_manual_state!(state, attempts)
      if state.nil? && attempts.empty?
        raise InvalidState, "hard reset: damaged state without independent managed ownership; process use unknown"
      end
      if state && (state["result"] || state["checkpoint"] || state["status"]) && attempts.none? { |attempt|
        attempt.fetch("report").values_at("prepared_at", "preparation") == state.values_at("prepared_at", "snapshot") }
        raise InvalidState, "hard reset: manual/unknown outcome or checkpoint; inactive managed execution proof required"
      end
      return unless state && state["started_at"]
      matches = attempts.select do |attempt|
        execution = attempt.fetch("report")["execution_state"]
        execution.is_a?(Hash) && execution.values_at("prepared_at", "started_at", "snapshot") == state.values_at("prepared_at", "started_at", "snapshot")
      end
      raise InvalidState, "hard reset: manual/unknown worker reservation" unless matches.length == 1
    end

    # An audited declaration cannot erase an earlier manual/unknown reservation.
    # Qualifies preserved original states independently of the current label;
    # damaged bytes require the same independent managed proof as current state.
    def verify_override_reservations!(id, attempts)
      root = File.join(@runs, LifecycleOverride::NAMESPACE, id)
      return unless present?(root)
      safe_path!(root)
      Dir.glob(File.join(root, "*", "original.yml")).each do |path|
        bytes = File.binread(plain_file!(path))
        original = begin
          value = YAML.safe_load(bytes, aliases: false)
          value if value.is_a?(Hash)
        rescue Psych::Exception
          nil
        end
        raise InvalidState, "hard reset: foreign override state identity" if original && original["id"] && original["id"] != id
        verify_manual_state!(original, attempts)
      end
    end

    # Returns exact process/external blockers, with retained old authorities in
    # the conflict floor. Dependencies are scheduler facts, never reset authority.
    def liveness_blockers(task, state, attempts)
      inspector = RepoInspector.new(Config.load(File.join(@data, "config.yml")), transport: @transport)
      external = ExternalActivity.new(data_root: @data, task_store: @tasks, state_store: @states, repo_inspector: inspector)
      historical_task = task.merge("repositories" => task.fetch("repositories").transform_values { |spec| spec.merge("access" => "write") })
      # Logical names can point at different authorities across attempts. Check
      # each original snapshot so a later name cannot erase an older conflict.
      activity = external.active_snapshot
      floors = [state || {}] + attempts.map { |attempt| { "snapshot" => attempt.fetch("report").fetch("preparation") } }
      conflicts = floors.flat_map { |floor| external.conflicts(historical_task, floor, snapshot: activity) }
        .uniq { |row| row.values_at("task_id", "observation_id") }
      blockers = conflicts.map { |row| "external activity #{row.fetch('task_id')}/#{row.fetch('observation_id')}: explicit end required" }
      attempts.each do |attempt|
        result = @liveness.check(attempt.fetch("report"), attempt.fetch("inventory"))
        report = attempt.fetch("report")
        blockers << "attempt #{report.fetch('attempt')}: host PID #{report['host_pid']}, worker PID/group #{report['child_pid']}, worktrees #{attempt.fetch('entries').map { |entry| entry.fetch('path') }.join(', ')}: use #{result}" unless result == :clear
      end
      blockers
    end

    # Preserves only ACT-managed prompts under the safe prompt root. Caller
    # supplied paths outside it remain a refusal, not recursive collection.
    def prompt_paths(id, state)
      root = File.join(@data, "state", "prompts")
      safe_path!(root)
      paths = Dir.glob(File.join(root, "#{id}-*.txt"))
      paths << File.join(root, "#{id}.txt") if present?(File.join(root, "#{id}.txt"))
      if state && state["prompt_path"]
        path = state.fetch("prompt_path")
        raise InvalidState, "hard reset: foreign prepared prompt" unless paths.include?(path)
      end
      paths.sort.each { |path| plain_file!(path) }
    end

    # Adds exact source identity/content/mapping. No symlinked root is followed.
    def add_source(sources, path, destination, retire: false)
      safe_path!(path)
      sources << { "path" => path, "archive" => destination, "content" => @archive.inventory(path),
        "identity" => identity(path), "retire" => retire }
    end

    # Refuses unfinished gates/publication rather than hiding them in an archive.
    # Complete records remain original bytes and never qualify future execution.
    def check_progress!(id, sources)
      sources.each do |source|
        source.fetch("content").each_key do |relative|
          next unless relative.match?(/(?:\A|\/)gate-[0-9a-f-]+\.started\.json\z/)
          finished = File.join(source.fetch("path"), relative.sub(".started.json", ".finished.json"))
          raise InvalidState, "hard reset: unresolved active gate #{finished}" unless File.file?(finished) && !File.symlink?(finished)
          document = JSON.parse(File.binread(finished))
          raise InvalidState, "hard reset: unresolved active gate #{finished}" unless
            document["schema_version"] == Checkpoint::GATE_SCHEMA && document["task_id"] == id &&
            document["receipt_phase"] == "finished" && document["finished_at"].is_a?(String) &&
            %w[exited signal failed_to_start not_run].include?(document.dig("command_outcome", "status"))
          Time.iso8601(document.fetch("finished_at"))
        end
        source.fetch("content").each_key do |relative|
          next unless File.basename(relative) == "delivery.json"
          path = File.join(source.fetch("path"), relative)
          document = JSON.parse(File.binread(plain_file!(path)))
          complete = document["schema"] == DeliveryManager::SCHEMA && document["task_id"] == id &&
            %w[draft_pr unchanged].include?(document["stage"])
          if document["stage"] == "draft_pr"
            complete &&= document["commit_sha"].to_s.match?(/\A[0-9a-f]{40}\z/) && document["pr"].is_a?(Hash) &&
              document.dig("pr", "head") == document["commit_sha"] && document.dig("pr", "url").is_a?(String)
          end
          raise InvalidState, "hard reset: unresolved publication #{path}" unless complete
        end
      end
    rescue JSON::ParserError, ArgumentError
      raise InvalidState, "hard reset: corrupt gate/publication progress; inactivity unverified"
    end

    # Creates durable intent and the initial small phase receipt before copying.
    # Existing archives are never overwritten, adopted or manually relocated.
    def begin_operation(intent)
      directory = intent.fetch("archive")
      [@archives, File.dirname(directory)].each do |path|
        safe_path!(path)
        Dir.mkdir(path, 0o700) unless present?(path)
        private_directory!(path)
      end
      raise InvalidState, "hard reset: archive destination occupied" if present?(directory)
      Dir.mkdir(directory, 0o700)
      bytes = JSON.pretty_generate(intent) + "\n"
      write_once(File.join(directory, "intent.json"), bytes)
      receipt = { "schema" => SCHEMA, "task_id" => intent.fetch("task_id"), "archive" => directory,
        "last_attempt" => intent.fetch("last_attempt"), "intent_sha256" => Digest::SHA256.hexdigest(bytes),
        "phase" => "preserving", "retired" => {}, "moved" => [], "created_at" => Time.now.utc.iso8601(6) }
      save_receipt(receipt)
      @intent, @receipt = intent, receipt
      @fault&.call("before_archive", receipt)
      receipt
    end

    # Copies original evidence/candidates and independent Git objects, verifies
    # hashes/modes, then publishes the content manifest. Errors retain all bytes.
    def preserve!(intent, receipt)
      directory = receipt.fetch("archive")
      intent.fetch("sources").each do |source|
        @archive.preserve(source.fetch("path"), File.join(directory, source.fetch("archive")), source.fetch("content"))
      end
      recovery = {}
      intent.fetch("resources").each do |resource|
        next unless resource["content"]
        target = File.join(directory, resource.fetch("archive"))
        @archive.preserve(resource.fetch("entry").fetch("path"), File.join(target, "worktree"), resource.fetch("content"), worktree: true)
        recovery[resource.fetch("archive")] = @archive.preserve_git(resource.fetch("entry"), File.join(target, "repository.git"))
      end
      path = File.join(directory, "content.json")
      bytes = JSON.pretty_generate(recovery) + "\n"
      if present?(path)
        raise InvalidState, "hard reset: archive manifest changed" unless File.binread(plain_file!(path)) == bytes
      else
        write_once(path, bytes)
      end
      receipt["content_sha256"] = Digest::SHA256.hexdigest(bytes)
      verify_archive!(intent, receipt)
      @fault&.call("before_archive_verified", receipt)
    end

    # Rehashes every preserved original, worktree and independent Git store.
    # A phase/receipt alone never authorizes retirement or lifecycle publication.
    def verify_archive!(intent, receipt)
      directory = receipt.fetch("archive")
      content = File.binread(plain_file!(File.join(directory, "content.json")))
      raise InvalidState, "hard reset: archive manifest checksum mismatch" unless Digest::SHA256.hexdigest(content) == receipt.fetch("content_sha256")
      manifests = JSON.parse(content)
      intent.fetch("sources").each do |source|
        raise InvalidState, "hard reset: original archive changed #{source.fetch('path')}" unless
          @archive.inventory(File.join(directory, source.fetch("archive"))) == source.fetch("content")
      end
      intent.fetch("resources").each do |resource|
        next unless resource["content"]
        target = File.join(directory, resource.fetch("archive"))
        raise InvalidState, "hard reset: candidate archive changed" unless
          @archive.inventory(File.join(target, "worktree")) == resource.fetch("content") &&
          @archive.inventory(File.join(target, "repository.git")) == manifests.fetch(resource.fetch("archive"))
      end
    end

    # Rechecks original identities, task definition, liveness and native ownership
    # under the physical lock. Resume accepts absent paths only after its own
    # recorded removal intent and corroborating original archive/native registry.
    def recheck!(id, intent, receipt)
      task = task_identity!(id)
      directory = receipt.fetch("archive")
      raise InvalidState, "hard reset: configuration changed after preview" unless configuration_identity == intent.fetch("configuration")
      verify_archive!(intent, receipt) unless receipt["phase"] == "preserving"
      verify_discovery!(id, intent, receipt)
      intent.fetch("sources").each do |source|
        path = source.fetch("path")
        next if receipt.fetch("moved").include?(path) && verify_moved!(source, receipt)
        if receipt["phase"] == "publishing" && path == @states.state_path(id) && reset_state?(id, intent)
          next
        end
        unless present?(path) && identity(path) == source.fetch("identity") && @archive.inventory(path) == source.fetch("content")
          # Rename may have finished before the receipt replacement. The exact
          # source identity must survive at its predetermined retired location.
          next if source["retire"] && verify_moved!(source, receipt)
          raise InvalidState, "hard reset: source changed #{path}"
        end
      end
      resources = intent.fetch("resources")
      resources.each_with_index do |resource, index|
        entry = resource.fetch("entry")
        manager = manager_for(intent, entry)
        retired = receipt.fetch("retired")[index.to_s]
        if retired && !present?(entry.fetch("path"))
          manager.send(:verify_absent_entry!, entry)
        elsif resource["content"]
          manager.send(:verify_entry!, entry, expected_head: resource.fetch("head"))
          unless identity(entry.fetch("path")) == resource.fetch("identity") && git_state(entry.fetch("path")) == resource.fetch("git_state") &&
                 @archive.inventory(entry.fetch("path"), worktree: true) == resource.fetch("content")
            raise InvalidState, "hard reset: candidate changed #{entry.fetch('path')}"
          end
        else
          manager.send(:verify_absent_entry!, entry)
        end
      end
      live = liveness_blockers(task, load_state(id), intent.fetch("attempts"))
      raise InvalidState, "hard reset: #{live.join('; ')}" unless live.empty?
      # A newer resource is never inherited by a resumed operation.
      verify_scope!(id, intent.fetch("attempts"))
    end

    # Detects new lifecycle/prompt/run/checkpoint material during cold recovery.
    # A recorded operation never acquires authority over a newer execution.
    def verify_discovery!(id, intent, receipt)
      paths = intent.fetch("sources").map { |source| source.fetch("path") }
      state_path = @states.state_path(id)
      if !paths.include?(state_path) && present?(state_path) && !(receipt["phase"] == "publishing" && reset_state?(id, intent))
        raise InvalidState, "hard reset: new lifecycle evidence during reset"
      end
      [File.join(@runs, id), File.join(@runs, "checkpoints", id)].each do |path|
        raise InvalidState, "hard reset: new managed evidence during reset #{path}" if present?(path) && !paths.include?(path)
      end
      expected = intent.fetch("sources").select { |source| source.fetch("archive").start_with?("original/prompts/") }
        .reject { |source| verify_moved!(source, receipt) }.map { |source| source.fetch("path") }
      raise InvalidState, "hard reset: prepared prompts changed during reset" unless prompt_paths(id, nil) == expected.sort
    end

    # Binds raw index bytes/modes and all stage entries as well as HEAD. Optional
    # index refresh is disabled, so preview cannot rewrite native staging state.
    def git_state(path)
      index = git(path, "rev-parse", "--path-format=absolute", "--git-path", "index").strip
      shared = git(path, "rev-parse", "--shared-index-path").strip
      shared = File.expand_path(shared, path) unless shared.empty?
      { "head" => git(path, "rev-parse", "HEAD").strip,
        "stages_base64" => [git(path, "ls-files", "--stage", "-z")].pack("m0"),
        "index" => present?(index) ? @archive.inventory(plain_file!(index)) : nil,
        "shared_index" => shared.empty? ? nil : @archive.inventory(plain_file!(shared)) }
    end

    # Removes one exact corroborated disposable worktree via native Git. Force
    # is local to this proved boundary after full archival, including dirty and
    # unmerged index content. Branches/refs and original inventories survive.
    def retire_resource!(resource, index, receipt)
      entry = resource.fetch("entry")
      key = index.to_s
      manager = manager_for(@intent, entry)
      if receipt.fetch("retired")[key] && !present?(entry.fetch("path"))
        manager.send(:verify_absent_entry!, entry)
        receipt.fetch("retired")[key] = "removed"
        save_receipt(receipt)
        return
      end
      recheck!(@intent.fetch("task_id"), @intent, receipt)
      receipt.fetch("retired")[key] = "removing"
      save_receipt(receipt)
      @fault&.call("before_remove:#{index}", receipt)
      if resource["content"]
        manager.send(:verify_entry!, entry, expected_head: resource.fetch("head"))
        git(entry.fetch("parent"), "worktree", "remove", "--force", "--", entry.fetch("path"))
      end
      manager.send(:verify_absent_entry!, entry)
      @fault&.call("after_remove:#{index}", receipt)
      receipt.fetch("retired")[key] = "removed"
      save_receipt(receipt)
    end

    # Moves only inventoried active task evidence/prompts after native retirement.
    # Native rename preserves original bytes/statuses and source inode identities.
    # Cross-filesystem failure retains both the copy and active original.
    def retire_evidence!(intent, receipt)
      intent.fetch("sources").select { |source| source["retire"] }.each do |source|
        path = source.fetch("path")
        if verify_moved!(source, receipt)
          receipt.fetch("moved") << path unless receipt.fetch("moved").include?(path)
          save_receipt(receipt)
          next
        end
        recheck!(intent.fetch("task_id"), intent, receipt)
        destination = retired_path(source, receipt)
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        File.rename(path, destination)
        File.open(File.dirname(path)) { |parent| parent.fsync }
        File.open(File.dirname(destination)) { |parent| parent.fsync }
        @fault&.call("after_move:#{source.fetch('archive')}", receipt)
        receipt.fetch("moved") << path
        save_receipt(receipt)
      end
    end

    # Checks a predetermined moved original, including identity, bytes and modes;
    # reoccupied source paths refuse instead of being removed on resume.
    def verify_moved!(source, receipt)
      destination = retired_path(source, receipt)
      return false unless present?(destination)
      safe_path!(destination)
      raise InvalidState, "hard reset: retired source reoccupied #{source.fetch('path')}" if present?(source.fetch("path"))
      raise InvalidState, "hard reset: moved original identity changed" unless
        identity(destination) == source.fetch("identity") && @archive.inventory(destination) == source.fetch("content")
      true
    end

    # Returns the fixed destination for original active evidence after retirement.
    def retired_path(source, receipt)
      File.join(receipt.fetch("archive"), "retired", source.fetch("archive"))
    end

    # Requires both preservation handoffs before lifecycle publication. Missing
    # retirement cannot be masked by a successful individual Git removal.
    def verify_retirement!(intent, receipt)
      intent.fetch("resources").each_with_index do |resource, index|
        raise InvalidState, "hard reset: retirement incomplete #{resource.fetch('entry').fetch('path')}" unless receipt.fetch("retired")[index.to_s] == "removed"
        manager_for(intent, resource.fetch("entry")).send(:verify_absent_entry!, resource.fetch("entry"))
      end
      intent.fetch("sources").select { |source| source["retire"] }.each do |source|
        raise InvalidState, "hard reset: evidence retirement incomplete #{source.fetch('path')}" unless verify_moved!(source, receipt)
      end
    end

    # Resolves the manager from its original root; current configuration cannot
    # enlarge or replace historical ownership after a task-definition change.
    def manager_for(intent, entry)
      attempt = intent.fetch("attempts").find { |row| row.fetch("entries").include?(entry) }
      WorktreeManager.new(root: attempt.fetch("inventory").fetch("root"),
        record_path: File.join(attempt.fetch("run_dir"), "worktrees.json"), transport: @transport)
    end

    # Returns an inert preview/public summary with full exact scope available in
    # intent. The CLI prints it before its one default-no terminal confirmation.
    def presentation(intent, receipt)
      { "task_id" => intent.fetch("task_id"), "archive" => intent.fetch("archive"),
        "noop" => intent.fetch("noop", false), "intent" => intent, "receipt" => receipt,
        "prior_outcome" => intent["prior_outcome"], "downstream" => intent.fetch("downstream"),
        "resources" => intent.fetch("resources").map { |resource| resource.fetch("entry").slice("path", "parent", "branch", "access", "attempt")
          .merge("changes" => resource.fetch("git_status")) },
        "blockers" => intent.fetch("blockers"), "external_data_retained" => intent.fetch("external_data_retained") }
        .merge("preparation_blockers" => intent.fetch("preparation_blockers"))
    end

    # Removes only the fresh preview's nondeterministic destination for comparison.
    def comparable(intent)
      intent.reject { |key, _value| key == "archive" }
    end

    # Reads and hash-checks the immutable operation intent before cold resume.
    def load_intent(receipt)
      path = plain_file!(File.join(receipt.fetch("archive"), "intent.json"))
      raise InvalidState, "hard reset: intent checksum mismatch" unless Digest::SHA256.file(path).hexdigest == receipt.fetch("intent_sha256")
      intent = JSON.parse(File.binread(path))
      raise InvalidState, "hard reset: intent identity mismatch" unless
        intent.values_at("schema", "task_id", "archive", "last_attempt") == receipt.values_at("schema", "task_id", "archive", "last_attempt")
      intent
    end

    # Reads the small phase record without accepting a caller-supplied locator.
    def read_receipt(directory)
      plain_file!(File.join(directory, "operation.yml"))
      StateStore.new(directory).load("operation")
    end

    # Persists one phase/action before proceeding. Atomic replacement/sync is
    # individual-file durability, never a multi-filesystem transaction claim.
    def save_receipt(receipt)
      StateStore.new(receipt.fetch("archive")).write("operation", receipt)
    end

    # Publishes the next persisted phase; injected failures retain prior facts.
    def transition!(receipt, phase)
      receipt["phase"] = phase
      save_receipt(receipt)
      @fault&.call("phase:#{phase}", receipt)
    end

    # Recognizes only the exact requested publication during cold recovery.
    def reset_state?(id, intent)
      path = @states.state_path(id)
      plain_file!(path) if present?(path)
      present?(path) && File.binread(path) == YAML.dump(intent.fetch("replacement"))
    end

    # Writes new durable immutable bytes, refusing occupied or symlinked targets.
    def write_once(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.open(File.dirname(path)) { |directory| directory.fsync }
    end

    # Checks disposal/archive roots against ordinary checkouts and private data.
    def protected_roots!(root, parent)
      protected = [parent, @data, @runs, @archives, File.expand_path("../..", __dir__)]
      raise InvalidState, "hard reset: unsafe overlapping worktree root" if protected.any? { |path| overlap?(root, path) }
      raise InvalidState, "hard reset: archive overlaps ordinary checkout" if overlap?(@archives, parent)
    end

    # Returns whether two absolute directories overlap in either direction.
    def overlap?(first, second)
      first == second || first.start_with?(second + "/") || second.start_with?(first + "/")
    end

    # Returns stable source identity, separate from content hashes and modes.
    def identity(path)
      stat = File.lstat(path)
      { "device" => stat.dev, "inode" => stat.ino, "uid" => stat.uid, "mode" => stat.mode }
    end

    # Binds global ACT configuration by identity/hash without copying unrelated
    # configuration into task archives. Absent optional configuration is valid.
    def configuration_identity
      path = File.join(@data, "config.yml")
      return nil unless present?(path)
      identity(plain_file!(path)).merge("sha256" => Digest::SHA256.file(path).hexdigest)
    end

    # Checks canonical ancestors without creating or following arbitrary links.
    def safe_path!(path)
      raise InvalidState, "hard reset: unsafe/noncanonical path #{path}" unless File.expand_path(path) == path
      cursor = path
      loop do
        raise InvalidState, "hard reset: unsafe symlinked root #{cursor}" if File.symlink?(cursor)
        break if cursor == File.dirname(cursor)
        cursor = File.dirname(cursor)
      end
    end

    # Enforces operator ownership/privacy for protected records and containers.
    def private_directory!(path)
      safe_path!(path)
      stat = File.lstat(path)
      raise InvalidState, "hard reset: unsafe/nonprivate directory #{path}" unless
        stat.directory? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
      path
    end

    # Qualifies direct regular files before reads; contents may be malformed raw
    # state but a symlink/path location never supplies ownership authority.
    def plain_file!(path)
      safe_path!(path)
      raise InvalidState, "hard reset: unsafe/missing file #{path}" unless File.file?(path) && File.stat(path).uid == Process.uid
      path
    end

    # Includes dangling links when deciding whether a path is occupied.
    def present?(path)
      File.exist?(path) || File.symlink?(path)
    end

    # Executes only byte-safe offline Git with optional index writes disabled.
    def git(path, *args)
      result = @transport.call(["git", *args], cwd: path, binmode: true,
        env: { "GIT_OPTIONAL_LOCKS" => "0", "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0" })
      raise InvalidState, "hard reset: Git #{args.first} failed: #{result.stderr.strip}" unless result.success?
      result.stdout
    end
  end
end
