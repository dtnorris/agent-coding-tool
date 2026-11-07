# frozen_string_literal: true

require "yaml"
require "fileutils"
require "digest"
require "json"
require "time"

# Sanitized, deterministic dashboard corpus. No operator task/evidence is copied.
module StatusScale
  SEED = 41_202_611
  SHA = "a" * 40

  # Writes count tasks under a new root, with seven fixed authorities by default.
  # Scales task text, states, families and converging dependency paths together.
  # Returns content hashes; existing destinations refuse with ArgumentError.
  def self.generate(root, count:, refs: 7)
    raise ArgumentError, "destination already exists" if File.exist?(root)
    FileUtils.mkdir_p([File.join(root, "tasks"), File.join(root, "state")])
    File.write(File.join(root, "config.yml"), YAML.dump("repo_root" => File.join(root, "repos")))
    random = Random.new(SEED)
    count.times do |index|
      group, slot = index.divmod(100)
      id = identity(index)
      # Approximate the pinned registry's 244/292 COMPLETE and 3/292 prepared/
      # running population. Retain READY work, fan-in and converging paths.
      dependencies = case slot
                     when 84..93, 98..99 then [identity(group * 100 + 82), identity(group * 100 + 83)]
                     when 94 then [identity(group * 100 + 84)]
                     when 95 then [identity(group * 100 + 84), identity(group * 100 + 85)]
                     when 96 then [identity(group * 100 + 94), identity(group * 100 + 95)]
                     when 97 then [identity(group * 100 + 86)]
                     else []
                     end
      name = "repo#{index % refs}"
      repositories = { name => { "access" => "write" },
        "repo#{(index + 1) % refs}" => { "access" => "read_only" } }
      if slot >= 98
        repositories = refs.times.to_h do |number|
          ["repo#{number}", { "access" => number == index % refs ? "write" : "read_only" }]
        end
      end
      task = { "id" => id, "title" => "Synthetic dashboard task #{index}",
        "repositories" => repositories, "depends_on" => dependencies,
        "goal" => "Bounded synthetic work. " * (20 + random.rand(20)),
        "constraints" => ["No external execution. " * 12],
        "acceptance" => ["Retain lifecycle and freshness. " * 12] }
      File.write(File.join(root, "tasks", "#{id}.yml"), YAML.dump(task))
      state = { "id" => id, "history" => Array.new(3) { { "summary" => "Synthetic prior observation. " * 8 } } }
      if slot < 84
        state["result"] = { "outcome" => "complete", "recorded_at" => (Time.utc(2026, 1, 1) + index).iso8601 }
      elsif slot >= 98
        state["snapshot"] = repositories.to_h do |repo, _spec|
          [repo, { "path" => File.join(root, "repos", repo), "remote" => "origin",
            "remote_url" => "https://github.com/example/#{repo}.git", "branch" => "main", "pushed_sha" => SHA }]
        end
        state["prepared_at"] = "2026-01-01T00:00:00Z"
        state["started_at"] = "2026-01-01T00:01:00Z" if group.even?
        state["result"] = { "outcome" => "candidate_complete", "artifact" => "synthetic.patch" } if group % 3 == 1
      elsif slot == 97
        state["icebox"] = { "at" => "2026-01-01T00:00:00Z", "reason" => "Synthetic deferral" }
      end
      # Approximately the observed state proportion, without empty-only scaling.
      File.write(File.join(root, "state", "#{id}.yml"), YAML.dump(state)) unless (84..93).cover?(slot)
    end
    Dir.glob(File.join(root, "**", "*.yml")).sort.to_h do |path|
      [path.delete_prefix(root + "/"), Digest::SHA256.file(path).hexdigest]
    end
  end

  # Returns a stable family/task ID for a nonnegative fixture index.
  def self.identity(index)
    "F#{index / 100}-#{format('%05d', index)}"
  end
end

if $PROGRAM_NAME == __FILE__
  require "time"
  root, count, refs = ARGV
  puts JSON.generate(StatusScale.generate(root, count: Integer(count), refs: Integer(refs || 7)))
end
