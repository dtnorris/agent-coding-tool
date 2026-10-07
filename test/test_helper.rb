# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "agent_coding_tool"

module TestHelpers
  FakeInspector = Struct.new(:heads, :local_dirty, :remote_urls, keyword_init: true) do
    def snapshot(name, _spec)
      sha = heads.fetch(name)
      {
        "path" => "/repos/#{name}",
        "remote" => "origin",
        "remote_url" => remote_urls&.fetch(name, nil) || "git@github.com:example/#{name}.git",
        "branch" => "main",
        "pushed_sha" => sha,
        "local_head" => sha,
        "local_dirty" => !!local_dirty
      }
    end

    def pushed_heads(references)
      references.each_with_object({}) do |reference, resolved|
        repository = reference.fetch("name").split("/", 2).last
        key = [reference.fetch("remote_url"), reference.fetch("branch")]
        resolved[key] = heads.fetch(repository)
      end
    end
  end

  def with_workspace
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tasks"))
      FileUtils.mkdir_p(File.join(dir, "state", "prompts"))
      yield dir
    end
  end

  def write_task(dir, id:, depends_on: [], repositories: { "alpha" => { "access" => "write" } },
                 title: "Task", worker_recommendation: nil)
    data = {
      "id" => id,
      "title" => title,
      "depends_on" => depends_on,
      "repositories" => repositories,
      "goal" => "Do the bounded thing.",
      "constraints" => ["Do not broaden scope."],
      "acceptance" => ["Focused tests pass."]
    }
    data["worker_recommendation"] = worker_recommendation if worker_recommendation
    File.write(File.join(dir, "tasks", "#{id}.yml"), YAML.dump(data))
  end

  def coordinator_for(dir, heads)
    AgentCodingTool::Coordinator.new(
      task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
      state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
      repo_inspector: FakeInspector.new(heads: heads),
      prompt_renderer: AgentCodingTool::PromptRenderer.new,
      prompt_root: File.join(dir, "state", "prompts")
    )
  end
end
