# frozen_string_literal: true

require "fileutils"
require "time"

module AgentCodingTool
  class Coordinator
    OUTCOMES = %w[candidate_complete complete blocked needs_judgment failed].freeze

    def initialize(task_store:, state_store:, repo_inspector:, prompt_renderer:, prompt_root:)
      @task_store = task_store
      @state_store = state_store
      @repo_inspector = repo_inspector
      @prompt_renderer = prompt_renderer
      @prompt_root = prompt_root
      FileUtils.mkdir_p(@prompt_root)
    end

    def tasks = @task_store.all

    def status(id)
      task = @task_store.load(id)
      state = @state_store.load(id)
      result = state["result"] || {}
      outcome = result["outcome"]

      return status_hash("COMPLETE", task, state) if outcome == "complete"
      return status_hash("NEEDS_JUDGMENT", task, state, result["summary"]) if outcome == "needs_judgment"
      return status_hash("FAILED", task, state, result["summary"]) if outcome == "failed"
      return status_hash("BLOCKED", task, state, result["summary"]) if outcome == "blocked"

      incomplete = incomplete_dependencies(task)
      unless incomplete.empty?
        return status_hash("BLOCKED", task, state, "dependencies incomplete: #{incomplete.join(', ')}")
      end

      snapshot = state["snapshot"]
      return status_hash("READY", task, state) unless snapshot

      stale = stale_repositories(task, snapshot)
      unless stale.empty?
        label = outcome == "candidate_complete" ? "STALE_CANDIDATE" : "STALE"
        return status_hash(label, task, state, "pushed main changed: #{stale.join(', ')}")
      end

      label = outcome == "candidate_complete" ? "CANDIDATE" : "PREPARED"
      status_hash(label, task, state)
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
      @state_store.write(id, new_state)

      { "task" => task, "state" => new_state, "prompt" => prompt }
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
      @state_store.write(id, state)
      state
    end

    def reset(id)
      @task_store.load(id)
      @state_store.write(id, { "id" => id })
    end

    private

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

    def stale_repositories(task, snapshot)
      task.fetch("repositories").filter_map do |name, spec|
        previous = snapshot[name]
        next name unless previous

        current = @repo_inspector.snapshot(name, spec)
        name if current.fetch("pushed_sha") != previous.fetch("pushed_sha")
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
