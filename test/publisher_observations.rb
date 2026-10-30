# frozen_string_literal: true

require "digest"
require_relative "git_contract/observations"

# Finite Publisher command transcripts, consumed by B's strict observation seam.
# These describe external responses; production selects paths, verifies identity,
# constructs commit trailers, handles failures and decides whether to publish.
module PublisherObservations
  BASE = "a" * 40
  COMMIT = "b" * 40
  REMOTE = "git@github.com:dtnorris/agent-coding-tool-data.git"
  REPOSITORY = "dtnorris/agent-coding-tool-data"
  OPERATIONS = %w[MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply].freeze

  # Returns one exact argv/cwd/raw response expectation; no commands execute.
  # B validates the tuple and raises ArgumentError for an invalid observation.
  def git_observation(arguments, stdout = "", stderr: "", success: true)
    GitContract::Observation.new(argv: ["git", *arguments], cwd: @root,
      result: [stdout.b, stderr.b, success])
  end

  # Returns checkout identity observations for the fixture's top-level path.
  # Production still resolves real paths and checks the on-disk lock directory.
  def checkout_observations
    [git_observation(["rev-parse", "--show-toplevel"], "#{@root}\n"),
     git_observation(["rev-parse", "--absolute-git-dir"], "#{@root}/.git\n")]
  end

  # Returns explicit fetch/push destination observations, without normalizing
  # identities. The caller supplies refusal variants; production interprets them.
  def destination_observations(remote: REMOTE, push_urls: [REMOTE])
    [*checkout_observations,
     git_observation(["remote", "get-url", "origin"], "#{remote}\n"),
     git_observation(["remote", "get-url", "--push", "--all", "origin"], push_urls.join("\n") + "\n")]
  end

  # Returns authoritative remote-ref bytes for a caller-declared SHA.
  # Does not derive remote state from a preceding commit or push response.
  def remote_observation(sha = BASE)
    git_observation(["ls-remote", "--exit-code", "origin", "refs/heads/main"], "#{sha}\trefs/heads/main\n")
  end

  # Returns read observations for one inspection. Status bytes and scope-path
  # requests are independent test inputs, not a simulated Git index or selector.
  # Operation/path lists permit explicit early-refusal transcripts.
  def inspection_observations(status:, scope_paths:, head: BASE, remote_head: BASE, operations: OPERATIONS)
    [*destination_observations,
     git_observation(["symbolic-ref", "--quiet", "--short", "HEAD"], "main\n"),
     git_observation(["rev-parse", "HEAD"], "#{head}\n"), remote_observation(remote_head),
     git_observation(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"], status),
     *operations.map { |name| git_observation(["rev-parse", "--git-path", name], "#{@root}/.git/#{name}\n") },
     *scope_paths.map { |path| git_observation(["ls-files", "--stage", "--", path]) }]
  end

  # Returns preview, lock-location and locked-inspection observations for an
  # actual publication. Both inspections execute the production decision logic.
  def publication_observations(**inspection)
    [*inspection_observations(**inspection), *checkout_observations, *inspection_observations(**inspection)]
  end

  # Returns exact expected commit argv for independently specified files/mode.
  # The digest binds that expected set; production must produce the same trailer.
  def commit_arguments(files, mode: :default, task_id: nil)
    message = task_id ? "ACTD: publish #{task_id}" :
      (mode == :all ? "ACTD: publish working-tree changes" : "ACTD: publish lifecycle state")
    trailer = "ACT-Publish: v1\nACT-Publish-Mode: #{task_id ? "task:#{task_id}" : mode}\n" \
      "ACT-Publish-Repository: #{REPOSITORY}\nACT-Publish-Branch: main\n" \
      "ACT-Publish-Base: #{BASE}\nACT-Publish-Selection: #{Digest::SHA256.hexdigest(files.join("\0"))}"
    mode == :all ? ["commit", "-m", message, "-m", trailer] :
      ["commit", "--only", "-m", message, "-m", trailer, "--", *files]
  end

  # Returns pre-commit authority and staging observations. No fixture state
  # changes implicitly; real commit/index/ref effects stay in the native gate.
  def before_commit_observations(mode: :default, untracked: [], files: [], staging_files: files)
    observations = [remote_observation, git_observation(["rev-parse", "HEAD"], "#{BASE}\n")]
    observations << git_observation(["--literal-pathspecs", "add", "-A", "--", *staging_files]) if mode == :all && !staging_files.empty?
    observations << git_observation(["add", "-N", "--", *untracked]) unless untracked.empty?
    observations
  end

  # Returns an explicit successful local commit response sequence. Exact argv
  # and selected paths must match; publication responses are declared separately.
  def commit_observations(files, mode: :default, task_id: nil, untracked: [], staging_files: files)
    [*before_commit_observations(mode: mode, untracked: untracked, files: files, staging_files: staging_files),
     git_observation(commit_arguments(files, mode: mode, task_id: task_id)),
     git_observation(["rev-parse", "HEAD"], "#{COMMIT}\n"), paths_observation(files)]
  end

  # Returns a successful push followed by an independent authoritative ref read.
  # Missing or extra requests fail through Replay; no local state is inferred.
  def push_observations
    [git_observation(["push", "origin", "HEAD:refs/heads/main"]), remote_observation(COMMIT)]
  end

  # Returns one independently declared NUL-delimited committed-path response.
  def paths_observation(files)
    git_observation(["diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "HEAD"], files.join("\0") + "\0")
  end

  # Installs finite observations through Publisher's existing runner input.
  # Returns the runner; teardown verifies consumption even after expected refusal.
  # Unexpected commands raise GitContract::UnexpectedObservation immediately.
  def expect_git(observations)
    runner = GitContract::Replay.new(observations)
    @replays << runner
    @publisher = publisher(runner: runner)
    runner
  end
end
