# frozen_string_literal: true

require_relative "test/feedback"
require "yaml"
require_relative "lib/agent_coding_tool"
require_relative "test/suite_runner"

desc "Covered, dependency-isolated ordinary feedback; insufficient for final acceptance"
task :test do
  TestFeedback.run(:ordinary, root: __dir__)
end

namespace :test do
  desc "Run the fixed ordinary behavior scope with external execution prohibited"
  task ordinary: "test"

  desc "Run required Git contracts; fail when their inventory or evidence is missing"
  task :git_contract do
    TestFeedback.run(:git_contract, root: __dir__)
  end

  desc "Run all required offline native Git suites in separate Ruby processes"
  task :native_integration do
    TestFeedback.run(:native_integration, root: __dir__)
  end

  task :native_default do
    TestFeedback.run(:native_default, root: __dir__)
  end

  task verified_default: ["test", :native_default]

  desc "Mandatory complete offline acceptance: ordinary first, each native layer once"
  task all: ["test", :git_contract, :native_default, :native_integration] do
    TestFeedback.complete!
  end

  desc "Alias for the same mandatory complete offline gate as test:all"
  task integration: :all
end

namespace :actd do
  desc "Validate YAML syntax in the configured agent-coding-tool-data directory"
  task :validate_yaml do
    data_root = AgentCodingTool::CLI.default_data_root(__dir__)

    unless Dir.exist?(data_root)
      puts "Skipping ACTD YAML validation; data directory does not exist: #{data_root}"
      next
    end

    paths = [
      File.join(data_root, "config.yml"),
      *Dir.glob(File.join(data_root, "tasks", "*.yml")),
      *Dir.glob(File.join(data_root, "state", "*.yml"))
    ].select { |path| File.file?(path) }.uniq.sort

    paths.each { |path| Psych.parse_file(path) }
    puts "Validated #{paths.length} ACTD YAML file#{"s" unless paths.length == 1} in #{data_root}"
  end
end

task default: ["actd:validate_yaml", "test"]
