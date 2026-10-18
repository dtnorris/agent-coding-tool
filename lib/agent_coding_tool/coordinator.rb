# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "time"

module AgentCodingTool
  # Coordinates explicit task lifecycle, prepared provenance and prompt handoff.
  class Coordinator
    OUTCOMES = %w[candidate_complete complete blocked needs_judgment failed].freeze
    NEXT_ACTION_OUTCOMES = %w[blocked needs_judgment failed].freeze
    PREPARE_COLLISION_STATES = %w[PREPARED IN_FLIGHT CANDIDATE].freeze
    START_COLLISION_STATES = %w[IN_FLIGHT CANDIDATE].freeze
    RECENT_COMPLETE_LIMIT = 5

    # Binds lifecycle stores and optional observation seam; construction writes
    # nothing. Filesystem-backed callers use the canonical private sibling root.
    def initialize(task_store:, state_store:, repo_inspector:, prompt_renderer:, prompt_root:, external_activity: nil)
      @task_store = task_store
      @state_store = state_store
      @repo_inspector = repo_inspector
      @prompt_renderer = prompt_renderer
      @prompt_root = prompt_root
      @external_activity = external_activity
    end

    def tasks = @task_store.all

    # Returns the private observation seam using the existing task/state stores.
    # No paths are created by initialization or read-only status projection.
    def external_activity
      @external_activity ||= ExternalActivity.new(
        data_root: File.dirname(File.dirname(@state_store.state_path("unused"))),
        task_store: @task_store, state_store: @state_store, repo_inspector: @repo_inspector)
    end

    # Regenerates a prepared task's prompt after validating required skill pins
    # and designation; returns bytes or raises InvalidState before any writes.
    def launch_prompt(id)
      task = @task_store.load(id)
      state = @state_store.load(id)
      validate_skill_identity!(id, state, required: true)
      validate_planning_guidance!(task, state)
      @prompt_renderer.render(task, state.fetch("snapshot"), dependencies: preparation_dependencies(task))
    end

    def launch_heads(id)
      task = @task_store.load(id)
      snapshot = @state_store.load(id).fetch("snapshot")
      context = { "pending" => { "task" => task, "snapshot" => snapshot } }
      validate_prepared_provenance!([context])
      references = freshness_references(task, snapshot)
      heads = @repo_inspector.pushed_heads(references)
      validate_freshness!(references, heads)
      snapshot.to_h do |name, repo|
        [name, repo.slice("remote_url", "branch").merge("pushed_sha" => heads.fetch(repo.values_at("remote_url", "branch")))]
      end
    end

    def status(id) = statuses([id]).first

    # Resolves one lifecycle/freshness snapshot and overlays private observations.
    # Open activity survives completion filtering; no records/timestamps change.
    # Invalid lifecycle or freshness provenance retains its existing refusals.
    def statuses(ids = nil, completion_filter: :all, strict_freshness: false)
      external_snapshot = external_activity.active_snapshot
      selected_tasks = ids ? Array(ids).map { |id| @task_store.load(id) } : tasks
      unless ids
        visible = filter_completed_tasks(selected_tasks, completion_filter)
        selected_tasks = selected_tasks.select { |task| visible.include?(task) ||
          external_snapshot.any? { |activity| activity["task_id"] == task["id"] } }
      end
      selected_contexts = selected_tasks.map { |task| status_context(task) }
      overlaps_by_id = {}
      blocker_ids = selected_contexts.filter_map do |context|
        pending = context["pending"]
        next unless pending && !pending.fetch("outcome") && !pending.fetch("state")["started_at"]

        task = pending.fetch("task")
        overlaps = write_collision_overlaps(task.fetch("id"), task, pending.fetch("snapshot"))
        overlaps_by_id[task.fetch("id")] = overlaps
        overlaps.keys
      end.flatten.uniq
      selected_ids = selected_tasks.to_h { |task| [task.fetch("id"), true] }
      blocker_contexts = blocker_ids.reject { |id| selected_ids.key?(id) }
                                    .map { |id| status_context(@task_store.load(id)) }
      contexts = selected_contexts + blocker_contexts
      validate_prepared_provenance!(contexts) if strict_freshness
      references = contexts.filter_map { |context| context["pending"] }.flat_map do |pending|
        freshness_references(pending.fetch("task"), pending.fetch("snapshot"))
      end
      validate_freshness_references!(references) if strict_freshness
      pushed_heads = references.empty? ? {} : @repo_inspector.pushed_heads(references)
      validate_freshness!(references, pushed_heads) if strict_freshness
      yield pushed_heads if block_given?

      resolved = contexts.to_h do |context|
        status = context["status"] || freshness_status(context.fetch("pending"), pushed_heads)
        [status.fetch("id"), status]
      end

      selected_contexts.map do |context|
        id = (context["status"] || context.fetch("pending").fetch("task")).fetch("id")
        status = resolved.fetch(id)
        unless external_snapshot.empty?
          task = selected_tasks.find { |selected| selected["id"] == id }
          status = status.dup
          activity = external_snapshot.find { |row| row["task_id"] == id }
          status["external_activity"] = activity if activity
          conflicts = external_activity.conflicts(task, status.fetch("state"), snapshot: external_snapshot)
          status["external_conflicts"] = conflicts unless conflicts.empty?
          # Sanitized snapshot shared by planner/unlock metrics and printed once
          # in JSON facts. It never enters lifecycle state or generated prompts.
          status["external_reservations"] = external_snapshot
        end
        next status unless status.fetch("status") == "PREPARED"

        collisions = collision_records(overlaps_by_id.fetch(id, {}), resolved.values,
                                       states: START_COLLISION_STATES)
        collisions.empty? ? status : status.merge("write_collisions" => collisions)
      end
    end

    # Returns conditional dependency unlock counts and startable parallel width
    # for the supplied status snapshot, including its external reservations.
    # Repository resolution failures retain the existing planner error contract.
    def completion_unlock_metrics(statuses)
      all_tasks = tasks
      tasks_by_id = all_tasks.to_h { |task| [task.fetch("id"), task] }
      reservations = statuses.filter_map do |status|
        next unless START_COLLISION_STATES.include?(status.fetch("status"))

        task = tasks_by_id.fetch(status.fetch("id"))
        snapshot = status.fetch("state").fetch("snapshot")
        [status.fetch("id"), writable_authorities(task, snapshot).keys]
      end.to_h
      authority_cache = {}
      external_snapshot = statuses.first&.fetch("external_reservations", []) || []

      statuses.filter_map do |status|
        next unless %w[READY CANDIDATE].include?(status.fetch("status"))

        id = status.fetch("id")
        reserved_authorities = reservations.reject { |task_id, _authorities| task_id == id }
                                            .values
                                            .flatten(1)
                                            .uniq
        unlocked = immediately_unlocked_tasks(id, all_tasks)
        startable_authorities = unlocked.filter_map do |task|
          next unless external_activity.conflicts(task, @state_store.load(task.fetch("id")), snapshot: external_snapshot).empty?
          authorities = task_writable_authorities(task, authority_cache)
          authorities unless (authorities & reserved_authorities).any?
        end
        [
          id,
          {
            "unlock_count" => unlocked.length,
            "parallel_width" => maximum_compatible_count(startable_authorities)
          }
        ]
      end.to_h
    end

    # Advisory selection over one caller-supplied effective-state snapshot.
    # The caller supplies the dashboard's existing priority ordering.
    def next_start_set(statuses, ranked_statuses)
      by_id = tasks.to_h { |task| [task.fetch("id"), task] }
      occupied = statuses.filter_map do |status|
        next unless START_COLLISION_STATES.include?(status.fetch("status"))

        task = by_id.fetch(status.fetch("id"))
        { "id" => status.fetch("id"), "status" => status.fetch("status"),
          "authorities" => checked_authorities!(status.fetch("id"), writable_authorities(task, status.fetch("state").fetch("snapshot")).keys) }
      end
      reservations = occupied.dup
      starts = []
      waiting_capacity = []
      external_waits = []
      authority_cache = {}

      ranked_statuses.each do |status|
        label = status.fetch("status")
        next unless %w[READY PREPARED].include?(label)

        id = status.fetch("id")
        if status["external_conflicts"]
          external_waits << { "id" => id, "status" => label, "conflicts" => status.fetch("external_conflicts") }
          next
        end
        task = by_id.fetch(id)
        authorities = if label == "PREPARED"
                        writable_authorities(task, status.fetch("state").fetch("snapshot")).keys
                      else
                        task_writable_authorities(task, authority_cache)
                      end
        authorities = checked_authorities!(id, authorities)
        conflicts = reservations.filter_map do |reserved|
          shared = authorities & reserved.fetch("authorities")
          next if shared.empty?

          { "task_id" => reserved.fetch("id"), "status" => reserved.fetch("status"), "authorities" => shared }
        end
        row = { "id" => id, "status" => label, "authorities" => authorities }
        if conflicts.empty?
          starts << row
          reservations << row.merge("status" => "SELECTED")
        else
          waiting_capacity << row.merge("conflicts" => conflicts)
        end
      end
      selection = { "starts" => starts, "waiting_capacity" => waiting_capacity, "occupied" => occupied }
      selection["external_waits"] = external_waits unless external_waits.empty?
      selection
    end

    # Snapshots a task and writes its prompt/state, clearing only attempt-local
    # overlap/checkpoint pointers. Invalid prerequisites, skill material, pins or
    # changed planning designation raise before any prompt/state writes.
    def prepare(id, retry_result: false)
      task = @task_store.load(id)
      state = @state_store.load(id)
      dependencies = preparation_dependencies(task)
      incomplete = dependencies.filter_map { |dependency| dependency.fetch("id") unless dependency.fetch("outcome") == "complete" }
      unless incomplete.empty?
        raise InvalidState, "#{id}: dependencies incomplete: #{incomplete.join(', ')}"
      end

      previous_outcome = state.dig("result", "outcome")
      if previous_outcome == "complete"
        raise InvalidState, "#{id}: already complete"
      end
      if previous_outcome && !retry_result
        raise InvalidState, "#{id}: has recorded outcome #{previous_outcome}; use --retry to prepare a new attempt"
      end

      data_root = File.dirname(File.dirname(@state_store.state_path(id)))
      if File.directory?(File.join("#{data_root}-runs", id)) || File.symlink?(File.join("#{data_root}-runs", id))
        AttemptRecovery.new(data_root: data_root).retry_ready!(id)
      end

      validate_skill_identity!(id, state)
      validate_planning_guidance!(task, state)
      snapshot = snapshot_task(task)
      prompt = @prompt_renderer.render(task, snapshot, dependencies: dependencies)
      collisions = write_collisions(id, task, snapshot, states: PREPARE_COLLISION_STATES)
      timestamp = "#{Time.now.utc.strftime('%Y%m%dT%H%M%S%6NZ')}-#{SecureRandom.hex(6)}"
      prompt_path = File.join(@prompt_root, "#{id}-#{timestamp}.txt")
      FileUtils.mkdir_p(@prompt_root)
      File.write(prompt_path, prompt)

      new_state = state.merge(
        "id" => id,
        "prepared_at" => Time.now.utc.iso8601(6),
        "snapshot" => snapshot,
        "prompt_path" => prompt_path,
        "coding_skill" => @prompt_renderer.skill_identity
      )
      if task["planning_guidance"] == "required"
        new_state["planning_guidance"] = "required"
        new_state["planning_skill"] = @prompt_renderer.planning_skill_identity
      end
      new_state.delete("result") if retry_result
      new_state.delete("started_at")
      new_state.delete("write_collision_override")
      new_state.delete("write_overlap")
      new_state.delete("checkpoint")
      @state_store.write(id, new_state)

      { "task" => task, "state" => new_state, "prompt" => prompt, "write_collisions" => collisions }
    end

    # Reserves a prepared task after dependency/freshness checks; returns its state.
    # Manual overlaps are advisory, never verified isolation. Invalid input raises
    # InvalidState/RepositoryError before any state write; CLI owns the shared lock.
    # Opted-in planning verifies full skill material and saved prompt bytes first.
    def start(id, allow_write_collision: false, expected_collisions: nil, launch_authorization: nil)
      task = @task_store.load(id)
      state = @state_store.load(id)
      external_activity.assert_clear!(id)
      raise InvalidTask, "#{id}: task identity mismatch" unless task.fetch("id") == id
      unless state["result"].nil? || state["result"].is_a?(Hash)
        raise InvalidState, "#{id}: malformed result state"
      end
      outcome = state.dig("result", "outcome")
      raise InvalidState, "#{id}: already complete" if outcome == "complete"
      if outcome
        raise InvalidState, "#{id}: has recorded outcome #{outcome}; use prepare --retry to prepare a new attempt"
      end
      raise InvalidState, "#{id}: prepare the task before starting" unless state["snapshot"]
      raise InvalidState, "#{id}: already in flight" if state["started_at"]
      unless state["id"] == id && state["prepared_at"].is_a?(String) &&
             state["snapshot"].is_a?(Hash) && state["snapshot"].keys.sort == task.fetch("repositories").keys.sort &&
             state["prompt_path"].is_a?(String) && File.file?(state["prompt_path"]) && !File.symlink?(state["prompt_path"])
        raise InvalidState, "#{id}: missing/invalid preparation"
      end
      begin
        Time.iso8601(state.fetch("prepared_at"))
      rescue ArgumentError
        raise InvalidState, "#{id}: invalid preparation timestamp"
      end
      validate_skill_identity!(id, state)
      validate_planning_guidance!(task, state)
      if task["planning_guidance"] == "required"
        validate_skill_identity!(id, state, required: true)
        prompt = @prompt_renderer.render(task, state.fetch("snapshot"), dependencies: preparation_dependencies(task))
        unless File.binread(state.fetch("prompt_path")) == prompt.b
          raise InvalidState, "#{id}: generated prompt changed; preserve prior evidence and explicitly reprepare"
        end
      end
      effective = statuses([id], strict_freshness: true).first
      unless effective.fetch("status") == "PREPARED"
        raise InvalidState, "#{id}: start blocked: #{effective['status']} #{effective['reason']}"
      end
      collisions = effective.fetch("write_collisions", [])
      if expected_collisions && collisions != expected_collisions
        raise InvalidState, "#{id}: write reservations changed during launch; inspect and retry"
      end
      manual_conflicts = launch_authorization&.fetch("unverified_manual_conflicts", []) || []
      if launch_authorization && (!allow_write_collision || (collisions.empty? && manual_conflicts.empty?) ||
                                  launch_authorization["task_id"] != id ||
                                  launch_authorization["conflicts"] != collisions)
        raise InvalidState, "#{id}: invalid launch collision authorization"
      end
      collisions = (collisions + manual_conflicts.map { |row|
        row.slice("task_id", "status").merge("repositories" => row.fetch("repositories").dup)
      }).uniq { |row| row.fetch("task_id") }
      started_at = Time.now.utc.iso8601
      state["started_at"] = started_at
      unless collisions.empty?
        state["write_overlap"] = {
          "observed_at" => started_at,
          "basis" => manual_conflicts.any? ? "operator_authorized_manual_overlap" :
            launch_authorization ? "verified_launch_at_start" : "manual_unverified",
          "conflicts" => collisions.map { |row| row.merge("repositories" => row.fetch("repositories").dup) },
          "authorities" => collisions.flat_map { |row| row.fetch("repositories") }.uniq.sort.map { |name|
            state.fetch("snapshot").fetch(name).slice("remote_url", "branch") }
        }
      end
      if allow_write_collision && !collisions.empty?
        state["write_collision_override"] = {
          "allowed_at" => started_at,
          "conflicts" => collisions
        }
        state["write_collision_override"]["launch"] = launch_authorization if launch_authorization
      else
        state.delete("write_collision_override")
      end
      @state_store.write(id, state)
      state
    end

    def record(id, outcome:, summary: nil, next_action: nil, artifact: nil, tests: [])
      raise InvalidState, "invalid outcome: #{outcome}" unless OUTCOMES.include?(outcome)
      if !next_action.nil? && !NEXT_ACTION_OUTCOMES.include?(outcome)
        raise InvalidState, "--next is only supported for blocked, needs_judgment, and failed outcomes"
      end

      task = @task_store.load(id)
      state = @state_store.load(id)
      if outcome != "complete" && !state["snapshot"]
        raise InvalidState, "#{id}: prepare the task before recording #{outcome}"
      end

      result = {
        "outcome" => outcome,
        "recorded_at" => Time.now.utc.iso8601,
        "summary" => summary,
        "next_action" => next_action,
        "artifact" => artifact,
        "tests" => tests
      }.reject { |_key, value| value.nil? || value == [] }

      state["id"] = id
      state["result"] = result
      state["completion_snapshot"] = snapshot_task(task) if outcome == "complete"
      state.delete("started_at")
      @state_store.write(id, state)
      state
    end

    def reset(id)
      @task_store.load(id)
      @state_store.write(id, { "id" => id })
    end

    private

    # Binds explicit planning designation and pin to existing preparation state.
    # Fresh tasks and unopted legacy state remain compatible; missing/drifted
    # requirements raise InvalidState before adoption, reservation or handoff.
    def validate_planning_guidance!(task, state)
      required = task["planning_guidance"] == "required"
      recorded = state.key?("planning_guidance") || state.key?("planning_skill")
      prepared = %w[snapshot prepared_at prompt_path coding_skill].any? { |key| state.key?(key) }
      return unless recorded || (required && prepared)
      return if required && state["planning_guidance"] == "required" &&
                state["planning_skill"] == @prompt_renderer.planning_skill_identity

      raise InvalidState, "#{task.fetch('id')}: planning guidance designation or skill pin missing or changed; preserve prior evidence and explicitly reset/reprepare (use --retry after a recorded non-complete outcome)"
    end

    # Rejects pin drift before preparation writes or launch rendering. Legacy
    # state may be explicitly prepared; launching it requires that preparation.
    # Inputs are task ID/state and whether a pin is required; raises InvalidState.
    def validate_skill_identity!(id, state, required: false)
      return unless required || state.key?("coding_skill")
      return if state["coding_skill"] == @prompt_renderer.skill_identity

      raise InvalidState, "#{id}: coding skill pin missing or changed; preserve prior evidence and explicitly reset/reprepare to adopt this pin"
    end

    def validate_prepared_provenance!(contexts)
      contexts.each do |context|
        pending = context["pending"]
        next unless pending

        task = pending.fetch("task")
        snapshot = pending.fetch("snapshot")
        unless snapshot.is_a?(Hash)
          raise RepositoryError, "#{task.fetch('id')}: prepared freshness provenance is malformed"
        end
        task.fetch("repositories").each_key do |name|
          repository = snapshot[name]
          unless repository.is_a?(Hash) &&
                 %w[remote_url branch].all? { |field| repository[field].is_a?(String) && !repository[field].empty? } &&
                 repository["pushed_sha"].is_a?(String) && repository["pushed_sha"].match?(/\A[0-9a-f]{40}\z/)
            raise RepositoryError, "#{task.fetch('id')}/#{name}: prepared freshness provenance is missing or malformed"
          end
        end
      end
    end

    def validate_freshness_references!(references)
      references.each do |reference|
        unless reference.is_a?(Hash) &&
               %w[name remote_url branch].all? { |field| reference[field].is_a?(String) && !reference[field].empty? }
          raise RepositoryError, "next: remote freshness reference is missing or malformed"
        end
      end
    end

    def validate_freshness!(references, pushed_heads)
      unless pushed_heads.is_a?(Hash)
        raise RepositoryError, "next: pushed-head evidence is unavailable"
      end
      references.each do |reference|
        key = [reference.fetch("remote_url"), reference.fetch("branch")]
        sha = pushed_heads[key]
        unless sha.is_a?(String) && sha.match?(/\A[0-9a-f]{40}\z/)
          raise RepositoryError, "#{reference.fetch('name')}: pushed-head evidence is missing or malformed"
        end
      end
    end

    def checked_authorities!(id, authorities)
      unless authorities.is_a?(Array) && authorities.all? { |remote, branch|
        remote.is_a?(String) && !remote.empty? && branch.is_a?(String) && !branch.empty?
      }
        raise RepositoryError, "#{id}: writable remote/branch authority is missing or malformed"
      end
      authorities.uniq
    end

    def filter_completed_tasks(selected_tasks, completion_filter)
      unless %i[all active recent].include?(completion_filter)
        raise ArgumentError, "invalid completion filter: #{completion_filter.inspect}"
      end
      return selected_tasks if completion_filter == :all

      complete = selected_tasks.each_with_index.filter_map do |task, index|
        state = @state_store.load(task.fetch("id"))
        next unless state.dig("result", "outcome") == "complete"

        [task.fetch("id"), completion_time(state), index]
      end
      return selected_tasks.reject { |task| complete.any? { |id, _time, _index| id == task.fetch("id") } } if completion_filter == :active

      ranked = complete.select { |_id, time, _index| time }
      recent_ids = ranked.sort_by { |_id, time, index| [time, index] }
                         .last(RECENT_COMPLETE_LIMIT)
                         .to_h { |id, _time, _index| [id, true] }
      unranked_ids = complete.filter_map { |id, time, _index| [id, true] unless time }.to_h
      visible_ids = recent_ids.merge(unranked_ids)

      selected_tasks.reject do |task|
        complete.any? { |id, _time, _index| id == task.fetch("id") } &&
          !visible_ids.key?(task.fetch("id"))
      end
    end

    def completion_time(state)
      recorded_at = state.dig("result", "recorded_at")
      Time.iso8601(recorded_at) if recorded_at.is_a?(String) && !recorded_at.empty?
    rescue ArgumentError
      nil
    end

    def status_context(task)
      id = task.fetch("id")
      state = @state_store.load(id)
      result = state["result"] || {}
      outcome = result["outcome"]

      status = status_hash("COMPLETE", task, state) if outcome == "complete"
      status ||= status_hash("NEEDS_JUDGMENT", task, state, result["summary"]) if outcome == "needs_judgment"
      status ||= status_hash("FAILED", task, state, result["summary"]) if outcome == "failed"
      status ||= status_hash("BLOCKED", task, state, result["summary"]) if outcome == "blocked"
      return { "status" => status } if status

      incomplete = incomplete_dependencies(task)
      unless incomplete.empty?
        return {
          "status" => status_hash("BLOCKED", task, state, "dependencies incomplete: #{incomplete.join(', ')}")
        }
      end

      snapshot = state["snapshot"]
      return { "status" => status_hash("READY", task, state) } unless snapshot

      { "pending" => { "task" => task, "state" => state, "outcome" => outcome, "snapshot" => snapshot } }
    end

    # Resolves prepared state against batched observed heads, retaining original
    # candidate provenance. Returns presentation data; malformed references raise.
    def freshness_status(pending, pushed_heads)
      task = pending.fetch("task")
      state = pending.fetch("state")
      outcome = pending.fetch("outcome")
      snapshot = pending.fetch("snapshot")

      refresh, stale = changed_repositories(task, snapshot, pushed_heads).partition do |name|
        snapshot.key?(name) && task.fetch("repositories").fetch(name).fetch("access") == "read_only"
      end
      label = if !stale.empty?
                outcome == "candidate_complete" ? "STALE_CANDIDATE" : "STALE"
              elsif outcome == "candidate_complete"
                "CANDIDATE"
              elsif state["started_at"]
                "IN_FLIGHT"
              else
                "PREPARED"
              end
      reason = "read-only pushed branch changed; refresh and reconcile materially affected findings before finalizing: #{refresh.join(', ')}" unless refresh.empty?
      reason = "pushed branch changed: #{stale.join(', ')}" unless stale.empty?
      status = status_hash(label, task, state, reason)
      if outcome == "candidate_complete"
        delivery = recorded_candidate_delivery(task.fetch("id"), state)
        status["candidate_handoff"] = {
          "task_id" => task.fetch("id"),
          "attempt" => delivery&.fetch("attempt") || state.dig("write_collision_override", "launch", "attempt") || state.dig("checkpoint", "attempt"),
          "artifact" => state.dig("result", "artifact"),
          "checkpoint" => state["checkpoint"],
          "validation" => state.dig("result", "tests"),
          "validation_provenance" => delivery ? "recorded host delivery; inspection does not revalidate bytes or logs" : "recorded result; independent host validation unavailable here",
          "host_delivery" => delivery,
          "overlaps" => state.dig("write_overlap", "conflicts") || state.dig("write_collision_override", "conflicts"),
          "changed_paths" => delivery && delivery.fetch("repositories").transform_values { |record| record["paths"] },
          "source" => task.fetch("repositories").filter_map { |name, spec|
            next unless spec.fetch("access") == "write"
            repo = snapshot.fetch(name)
            { "repository" => name, "prepared_sha" => repo.fetch("pushed_sha"),
              "observed_sha" => pushed_heads.fetch(repo.values_at("remote_url", "branch")) } },
          "integration" => "not approved",
          "reconciliation" => stale.empty? ? "review required" : "source changed; renewed validation required",
          "next_action" => "review candidate against current main; explicitly reconcile and renew validation if source changed; publication, merge and finish need separate authority"
        }
      end
      status
    end

    # Returns recorded candidate metadata for one matching host attempt, or nil
    # when unavailable/ambiguous/malformed. Reads only private records; never hashes
    # worktrees, probes liveness or turns old validation into integration approval.
    def recorded_candidate_delivery(id, state)
      root = "#{File.dirname(File.dirname(@state_store.state_path(id)))}-runs"
      return unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/) && File.directory?(root) && File.realpath(root) == root
      runs = Dir.glob(File.join(root, id, "*", "handoff.json")).filter_map do |path|
        next unless File.realpath(path) == path
        report = JSON.parse(File.binread(path))
        next unless report.values_at("schema_version", "task_id", "prepared_at", "preparation") ==
          [Launcher::SCHEMA, id, state["prepared_at"], state["snapshot"]]
        [File.dirname(path), report]
      end
      return unless runs.length == 1
      run_dir, report = runs.first
      writers = report.fetch("writable_repositories", [report.fetch("writable_repository")])
      return unless writers.is_a?(Array) && writers.all? { |name| name.is_a?(String) && name.match?(/\A[A-Za-z0-9_-]+\z/) }
      records = writers.to_h do |name|
        path = writers.length == 1 ? File.join(run_dir, "delivery.json") : File.join(run_dir, "repositories", name, "delivery.json")
        return unless File.file?(path) && File.realpath(path) == path
        record = JSON.parse(File.binread(path))
        return unless record.values_at("schema", "task_id", "base_sha") ==
          [DeliveryManager::SCHEMA, id, state.fetch("snapshot").fetch(name).fetch("pushed_sha")]
        [name, record.slice("branch", "commit_sha", "base_sha", "stage", "paths", "manifest", "commands", "pr")]
      end
      { "attempt" => report.fetch("attempt"), "invocation_id" => report.fetch("invocation_id"), "repositories" => records }
    rescue SystemCallError, JSON::ParserError, KeyError, TypeError, NoMethodError
      nil
    end

    def incomplete_dependencies(task)
      task.fetch("depends_on", []).reject do |dependency|
        @state_store.load(dependency).dig("result", "outcome") == "complete"
      end
    end

    def preparation_dependencies(task)
      task.fetch("depends_on", []).map do |id|
        state = @state_store.load(id)
        {
          "id" => id,
          "outcome" => state.dig("result", "outcome"),
          "state_path" => @state_store.state_path(id),
          "completion_snapshot" => state["completion_snapshot"]
        }
      end
    end

    def immediately_unlocked_tasks(completed_id, all_tasks)
      all_tasks.select do |task|
        state = @state_store.load(task.fetch("id"))
        next false if state["snapshot"] || state.dig("result", "outcome")

        incomplete = incomplete_dependencies(task)
        !incomplete.empty? && incomplete.all? { |dependency| dependency == completed_id }
      end
    end

    def task_writable_authorities(task, cache)
      cache[task.fetch("id")] ||= task.fetch("repositories").filter_map do |name, spec|
        next unless spec.fetch("access") == "write"

        @repo_inspector.repository_authority(name, spec)
      end.uniq
    end

    def maximum_compatible_count(authority_sets)
      best = 0
      search = lambda do |index, selected, count|
        return if count + authority_sets.length - index <= best

        if index == authority_sets.length
          best = count
          return
        end

        authorities = authority_sets.fetch(index)
        search.call(index + 1, selected + authorities, count + 1) if (selected & authorities).empty?
        search.call(index + 1, selected, count)
      end
      search.call(0, [], 0)
      best
    end

    def snapshot_task(task)
      task.fetch("repositories").to_h do |name, spec|
        [name, @repo_inspector.snapshot(name, spec)]
      end
    end

    def freshness_references(task, snapshot)
      task.fetch("repositories").filter_map do |name, _spec|
        previous = snapshot[name]
        next unless previous

        {
          "name" => "#{task.fetch('id')}/#{name}",
          "remote_url" => previous.fetch("remote_url"),
          "branch" => previous.fetch("branch")
        }
      rescue KeyError
        raise RepositoryError, "#{task.fetch('id')}/#{name}: prepared snapshot lacks remote URL or branch"
      end
    end

    def changed_repositories(task, snapshot, pushed_heads)
      task.fetch("repositories").filter_map do |name, _spec|
        previous = snapshot[name]
        next name unless previous

        key = [previous.fetch("remote_url"), previous.fetch("branch")]
        name if pushed_heads.fetch(key) != previous.fetch("pushed_sha")
      rescue KeyError
        raise RepositoryError, "#{task.fetch('id')}/#{name}: prepared snapshot lacks freshness provenance"
      end
    end

    def write_collisions(id, task, snapshot, states:)
      overlaps = write_collision_overlaps(id, task, snapshot)
      return [] if overlaps.empty?

      collision_records(overlaps, statuses(overlaps.keys), states:)
    end

    def write_collision_overlaps(id, task, snapshot)
      target_authorities = writable_authorities(task, snapshot)
      return {} if target_authorities.empty?

      tasks.each_with_object({}) do |other_task, found|
        other_id = other_task.fetch("id")
        next if other_id == id

        other_snapshot = @state_store.load(other_id)["snapshot"]
        next unless other_snapshot

        shared = target_authorities.keys & writable_authorities(other_task, other_snapshot).keys
        next if shared.empty?

        found[other_id] = shared.flat_map { |authority| target_authorities.fetch(authority) }.uniq.sort
      end
    end

    def collision_records(overlaps, effective_statuses, states:)
      effective_statuses.filter_map do |status|
        next unless states.include?(status.fetch("status"))
        next unless overlaps.key?(status.fetch("id"))

        {
          "task_id" => status.fetch("id"),
          "status" => status.fetch("status"),
          "repositories" => overlaps.fetch(status.fetch("id"))
        }
      end
    end

    def writable_authorities(task, snapshot)
      task.fetch("repositories").each_with_object({}) do |(name, spec), authorities|
        next unless spec.fetch("access") == "write"

        repository = snapshot[name]
        next unless repository

        authority = [repository.fetch("remote_url"), repository.fetch("branch")]
        (authorities[authority] ||= []) << name
      rescue KeyError
        raise RepositoryError, "#{task.fetch('id')}/#{name}: prepared snapshot lacks remote URL or branch"
      end
    end

    # Builds read-only presentation fields from a lifecycle label/task/state.
    # Recorded execution evidence is historical; missing liveness remains unknown.
    def status_hash(label, task, state, reason = nil)
      status = {
        "id" => task.fetch("id"),
        "title" => task.fetch("title"),
        "status" => label,
        "reason" => reason,
        "state" => state
      }
      result = state["result"]
      if state["started_at"] || result&.fetch("outcome", nil) == "candidate_complete"
        status["execution_evidence"] = {
          "isolation" => state.dig("write_collision_override", "launch") ? "last_verified_at_launch" : "unverified",
          "liveness" => "unknown"
        }
      end
      status["next_action"] = result["next_action"] if result&.key?("next_action")
      if %w[PREPARED IN_FLIGHT CANDIDATE].include?(label) && CheckpointPolicy.required?(task)
        status["checkpoint"] = state.dig("checkpoint", "status") || "missing"
      end
      status
    end
  end
end
