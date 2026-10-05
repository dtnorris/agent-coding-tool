# frozen_string_literal: true

require "rake/testtask"
require "yaml"
require_relative "lib/agent_coding_tool"

Rake::TestTask.new do |task|
  task.libs << "lib"
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
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

task default: ["actd:validate_yaml", :test]
