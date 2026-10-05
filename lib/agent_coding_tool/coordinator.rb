# frozen_string_literal: true

require "fileutils"
require "time"

module AgentCodingTool
  class Coordinator
    OUTCOMES = %w[candidate_complete complete blocked needs_judgment failed].freeze
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
      @state_store.write(id, new_state)

      { "task" => task, "state" => new_state, "prompt" => prompt }
    end

    def start(id)
      @task_store.load(id)
      state = @state_store.load(id)
      outcome = state.dig("result", "outcome")
      raise InvalidState, "#{id}: already complete" if outcome == "complete"
      if outcome
        raise InvalidState, "#{id}: has recorded outcome #{outcome}; use prepare --retry to prepare a new attempt"
      end
      raise InvalidState, "#{id}: prepare the task before starting" unless state["snapshot"]
      raise InvalidState, "#{id}: already in flight" if state["started_at"]

      state["started_at"] = Time.now.utc.iso8601
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
