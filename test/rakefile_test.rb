# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "test_helper"

class RakefileTest < Minitest::Test
  PROJECT_ROOT = File.expand_path("..", __dir__)
  VALID_YAML = {
    "config.yml" => "---\nrepo_root: ..\n",
    "tasks/T1.yml" => "---\nid: T1\ntitle: Task\n",
    "state/T1.yml" => "---\nstatus: PREPARED\n"
  }.freeze

  def test_validation_accepts_managed_yaml_ignores_other_files_and_is_read_only
    with_data_directory do |data_root|
      managed_paths = write_valid_yaml(data_root)
      ignored_paths = {
        "state/prompts/T1.txt" => "not: [valid YAML",
        "notes.yml" => "also: [not valid",
        "tasks/README.txt" => "neither: [is this"
      }.map do |relative_path, content|
        write_file(data_root, relative_path, content)
      end
      paths = managed_paths + ignored_paths
      old_time = Time.at(1_600_000_000)
      paths.each { |path| File.utime(old_time, old_time, path) }
      before = paths.to_h { |path| [path, [File.binread(path), File.stat(path).mtime]] }

      stdout, stderr, status = run_validation(data_root)

      assert_predicate status, :success?, stderr
      assert_includes stdout, "Validated 3 ACTD YAML files"
      assert_empty stderr
      assert_equal before, paths.to_h { |path| [path, [File.binread(path), File.stat(path).mtime]] }
    end
  end

  def test_validation_reports_each_malformed_managed_surface
    %w[config.yml tasks/T1.yml state/T1.yml].each do |relative_path|
      with_data_directory do |data_root|
        write_valid_yaml(data_root)
        malformed_path = File.join(data_root, relative_path)
        File.write(malformed_path, "broken: [\n")

        _stdout, stderr, status = run_validation(data_root)

        refute_predicate status, :success?
        assert_includes stderr, malformed_path
        assert_match(/line \d+ column \d+/, stderr)
      end
    end
  end

  def test_validation_is_a_clean_skip_when_selected_data_directory_is_absent
    Dir.mktmpdir do |dir|
      missing = File.join(dir, "missing-data")

      stdout, stderr, status = run_validation(missing)

      assert_predicate status, :success?, stderr
      assert_includes stdout, "Skipping ACTD YAML validation"
      assert_includes stdout, missing
      assert_empty stderr
    end
  end

  def test_environment_override_selects_the_alternate_data_directory
    with_data_directory do |data_root|
      malformed_path = write_file(data_root, "config.yml", "broken: [\n")

      _stdout, stderr, status = run_validation(data_root)

      refute_predicate status, :success?
      assert_includes stderr, malformed_path
    end
  end

  private

  def with_data_directory
    Dir.mktmpdir do |dir|
      data_root = File.join(dir, "actd")
      FileUtils.mkdir_p(data_root)
      yield data_root
    end
  end

  def write_valid_yaml(data_root)
    VALID_YAML.map do |relative_path, content|
      write_file(data_root, relative_path, content)
    end
  end

  def write_file(data_root, relative_path, content)
    path = File.join(data_root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def run_validation(data_root)
    Open3.capture3(
      { "AGENT_CODING_TOOL_DATA_DIR" => data_root },
      RbConfig.ruby,
      Gem.bin_path("rake", "rake"),
      "actd:validate_yaml",
      chdir: PROJECT_ROOT
    )
  end
end
