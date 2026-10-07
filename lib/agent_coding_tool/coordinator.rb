# frozen_string_literal: true

require "fileutils"
require "time"

module AgentCodingTool
  class Coordinator
    OUTCOMES = %w[candidate_complete complete blocked needs_judgment failed].freeze
    PREPARE_COLLISION_STATES = %w[PREPARED IN_FLIGHT CANDIDATE].freeze
    START_COLLISION_STATES = %w[IN_FLIGHT CANDIDATE].freeze
    RECENT_COMPLETE_LIMIT = 5

    def initialize(task_store:, state_store:, repo_inspector:, prompt_renderer:, prompt_root:)
      @task_store = task_store
      @state_store = state_store
      @repo_inspector = repo_inspector
      @prompt_renderer = prompt_renderer
      @prompt_root = prompt_root
      FileUtils.mkdir_p(@prompt_root)
    end

    def tasks = @task_store.all

    def status(id) = statuses([id]).first

    def statuses(ids = nil, completion_filter: :all)
      selected_tasks = ids ? Array(ids).map { |id| @task_store.load(id) } : tasks
      selected_tasks = filter_completed_tasks(selected_tasks, completion_filter) unless ids
      contexts = selected_tasks.map { |task| status_context(task) }
      references = contexts.filter_map { |context| context["pending"] }.flat_map do |pending|
        freshness_references(pending.fetch("task"), pending.fetch("snapshot"))
      end
      pushed_heads = references.empty? ? {} : @repo_inspector.pushed_heads(references)

      contexts.map do |context|
        context["status"] || freshness_status(context.fetch("pending"), pushed_heads)
      end
    end

    def ready_unlock_metrics(statuses)
      all_tasks = tasks
      tasks_by_id = all_tasks.to_h { |task| [task.fetch("id"), task] }
      reserved_authorities = statuses.filter_map do |status|
        next unless START_COLLISION_STATES.include?(status.fetch("status"))

        task = tasks_by_id.fetch(status.fetch("id"))
        snapshot = status.fetch("state").fetch("snapshot")
        writable_authorities(task, snapshot).keys
      end.flatten(1).uniq
      authority_cache = {}

      statuses.filter_map do |status|
        next unless status.fetch("status") == "READY"

        id = status.fetch("id")
        unlocked = immediately_unlocked_tasks(id, all_tasks)
        startable_authorities = unlocked.filter_map do |task|
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

    def prepare(id, retry_result: false)
      task = @task_store.load(id)
      state = @state_store.load(id)
      incomplete = incomplete_dependencies(task)
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

      snapshot = snapshot_task(task)
      prompt = @prompt_renderer.render(task, snapshot)
      collisions = write_collisions(id, task, snapshot, states: PREPARE_COLLISION_STATES)
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      prompt_path = File.join(@prompt_root, "#{id}-#{timestamp}.txt")
      File.write(prompt_path, prompt)

      new_state = state.merge(
        "id" => id,
        "prepared_at" => Time.now.utc.iso8601,
        "snapshot" => snapshot,
        "prompt_path" => prompt_path
      )
      new_state.delete("result") if retry_result
      new_state.delete("started_at")
      new_state.delete("write_collision_override")
      @state_store.write(id, new_state)

      { "task" => task, "state" => new_state, "prompt" => prompt, "write_collisions" => collisions }
    end

    def start(id, allow_write_collision: false)
      task = @task_store.load(id)
      state = @state_store.load(id)
      outcome = state.dig("result", "outcome")
      raise InvalidState, "#{id}: already complete" if outcome == "complete"
      if outcome
        raise InvalidState, "#{id}: has recorded outcome #{outcome}; use prepare --retry to prepare a new attempt"
      end
      raise InvalidState, "#{id}: prepare the task before starting" unless state["snapshot"]
      raise InvalidState, "#{id}: already in flight" if state["started_at"]

      collisions = write_collisions(id, task, state.fetch("snapshot"), states: START_COLLISION_STATES)
      unless collisions.empty? || allow_write_collision
        raise InvalidState, write_collision_error(id, collisions)
      end

      started_at = Time.now.utc.iso8601
      state["started_at"] = started_at
      if allow_write_collision && !collisions.empty?
        state["write_collision_override"] = {
          "allowed_at" => started_at,
          "conflicts" => collisions
        }
      else
        state.delete("write_collision_override")
      end
      @state_store.write(id, state)
      state
    end

    def record(id, outcome:, summary: nil, artifact: nil, tests: [])
      raise InvalidState, "invalid outcome: #{outcome}" unless OUTCOMES.include?(outcome)

      task = @task_store.load(id)
      state = @state_store.load(id)
      if outcome != "complete" && !state["snapshot"]
        raise InvalidState, "#{id}: prepare the task before recording #{outcome}"
      end

      result = {
        "outcome" => outcome,
        "recorded_at" => Time.now.utc.iso8601,
        "summary" => summary,
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

    def freshness_status(pending, pushed_heads)
      task = pending.fetch("task")
      state = pending.fetch("state")
      outcome = pending.fetch("outcome")
      snapshot = pending.fetch("snapshot")

      refresh, stale = changed_repositories(task, snapshot, pushed_heads).partition do |name|
        snapshot.key?(name) && task.fetch("repositories").fetch(name).fetch("access") == "read_only"
      end
      unless stale.empty?
        label = outcome == "candidate_complete" ? "STALE_CANDIDATE" : "STALE"
        return status_hash(label, task, state, "pushed branch changed: #{stale.join(', ')}")
      end

      label = if outcome == "candidate_complete"
                "CANDIDATE"
              elsif state["started_at"]
                "IN_FLIGHT"
              else
                "PREPARED"
              end
      reason = "read-only pushed branch changed; refresh and reconcile materially affected findings before finalizing: #{refresh.join(', ')}" unless refresh.empty?
      status_hash(label, task, state, reason)
    end

    def incomplete_dependencies(task)
      task.fetch("depends_on", []).reject do |dependency|
        @state_store.load(dependency).dig("result", "outcome") == "complete"
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
      target_authorities = writable_authorities(task, snapshot)
      return [] if target_authorities.empty?

      overlaps = tasks.each_with_object({}) do |other_task, found|
        other_id = other_task.fetch("id")
        next if other_id == id

        other_snapshot = @state_store.load(other_id)["snapshot"]
        next unless other_snapshot

        shared = target_authorities.keys & writable_authorities(other_task, other_snapshot).keys
        next if shared.empty?

        found[other_id] = shared.flat_map { |authority| target_authorities.fetch(authority) }.uniq.sort
      end
      return [] if overlaps.empty?

      statuses(overlaps.keys).filter_map do |status|
        next unless states.include?(status.fetch("status"))

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

    def write_collision_error(id, collisions)
      conflicts = collisions.map { |collision| "#{collision.fetch('task_id')} (#{collision.fetch('status')})" }.join(", ")
      repositories = collisions.flat_map { |collision| collision.fetch("repositories") }.uniq.sort.join(", ")
      "#{id}: conflicts with active task#{'s' if collisions.length > 1} #{conflicts}\n" \
        "shared writable repositories: #{repositories}\n" \
        "finish or reprepare the conflicting work first, or rerun start with --allow-write-collision"
    end

    def status_hash(label, task, state, reason = nil)
      {
        "id" => task.fetch("id"),
        "title" => task.fetch("title"),
        "status" => label,
        "reason" => reason,
        "state" => state
      }
    end
  end
end
