# frozen_string_literal: true

require_relative "test_helper"

class TaskStoreTest < Minitest::Test
  include TestHelpers

  def test_checkpoint_defaults_to_required_and_exemptions_are_explicit
    with_workspace do |dir|
      write_task(dir, id: "T1")
      path = File.join(dir, "tasks", "T1.yml")
      store = AgentCodingTool::TaskStore.new(File.join(dir, "tasks"))
      assert AgentCodingTool::CheckpointPolicy.required?(store.load("T1"))
      task = YAML.safe_load_file(path)
      task["checkpoint"] = { "mode" => "exempt", "category" => "planning", "reason" => "No executable deliverable." }
      File.write(path, YAML.dump(task))
      refute AgentCodingTool::CheckpointPolicy.required?(store.load("T1"))
      [nil, { "mode" => "exempt" }, { "mode" => "exempt", "category" => "coding", "reason" => "No" },
       { "mode" => "required", "reason" => "silent bypass" }].each do |invalid|
        task["checkpoint"] = invalid
        File.write(path, YAML.dump(task))
        assert_raises(AgentCodingTool::InvalidTask) { store.load("T1") }
      end
    end
  end

  def test_worker_recommendation_accepts_generic_nonempty_strings
    with_workspace do |dir|
      write_task(dir, id: "T1", worker_recommendation: {
                   "model" => "Any human-authored model", "thinking" => "Custom effort"
                 })

      task = AgentCodingTool::TaskStore.new(File.join(dir, "tasks")).load("T1")

      assert_equal "Any human-authored model", task.dig("worker_recommendation", "model")
      assert_equal "Custom effort", task.dig("worker_recommendation", "thinking")
    end
  end

  def test_worker_recommendation_validation
    invalid = {
      "non-mapping metadata" => [],
      "missing model" => {"thinking" => "High"},
      "missing thinking" => {"model" => "GPT-5.6 Sol"},
      "empty model" => {"model" => "", "thinking" => "High"},
      "empty thinking" => {"model" => "GPT-5.6 Sol", "thinking" => ""}
    }

    invalid.each do |description, recommendation|
      with_workspace do |dir|
        write_task(dir, id: "T1")
        path = File.join(dir, "tasks", "T1.yml")
        task = YAML.safe_load_file(path, aliases: false)
        task["worker_recommendation"] = recommendation
        File.write(path, YAML.dump(task))

        error = assert_raises(AgentCodingTool::InvalidTask, description) do
          AgentCodingTool::TaskStore.new(File.join(dir, "tasks")).load("T1")
        end
        assert_includes error.message, "worker_recommendation", description
      end
    end
  end
end
