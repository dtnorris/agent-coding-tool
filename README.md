# agent-coding-tool

A deliberately small, local-first coordinator for a human directing multiple coding agents.

The source repository is designed to remain safe to publish as open source. Operational task definitions, project details, generated prompts, and runtime state live in a separate data directory and are never required to be committed here.

The tool does not launch agents, plan architecture, parse chat prose, merge code, commit, push, or mutate GitHub. Its first job is to make the existing human-directed workflow cheaper and safer.

## V1 contract

- Pushed `main` is authoritative.
- Local HEAD and dirtiness are observations only.
- Tasks may reference arbitrary Git repositories under the configured repo root.
- Each repository is explicitly `write` or `read_only` for each task.
- Task dependencies must be explicitly complete before a dependent task can be prepared.
- Preparing a task snapshots exact pushed heads and emits a worker prompt.
- Any pushed-head movement after preparation makes the task stale.
- Worker outcomes are recorded explicitly; no prose interpretation is attempted.
- `needs_judgment` and `blocked` are normal outcomes, not failures to be auto-retried.
- The tool never commits, pushes, opens PRs, or otherwise mutates GitHub.

## Source/data separation

The public source checkout contains implementation, tests, documentation, and examples only. Runtime data belongs in an external data directory.

By default, a checkout named `agent-coding-tool` uses a sibling directory named `agent-coding-tool-data`. For example:

- `/path/to/code/agent-coding-tool` — public source checkout
- `/path/to/code/agent-coding-tool-data` — private/local task and state data
- `/path/to/code/other-repository` — a repository referenced by tasks

The default data directory can be overridden with `AGENT_CODING_TOOL_DATA_DIR=/path/to/data`.

The data directory may itself be a private Git repository. Its expected contents are:

- `config.yml` — optional overrides for repository root and default remote/branch.
- `tasks/*.yml` — durable human-authored task definitions.
- `state/*.yml` — explicit runtime/result state.
- `state/prompts/*.txt` — generated worker prompts.

When `config.yml` is absent, `repo_root` defaults to the parent of the data directory, `default_remote` to `origin`, and `default_branch` to `main`. Relative `repo_root` values are resolved from the data directory. See `examples/config.yml`.

The public repository also ignores legacy/local `config.yml`, `tasks/`, `state/`, and `data/` paths as a fail-safe against accidentally committing operational data.

## Task shape

Copy `examples/tasks/EXAMPLE.yml` into the external data directory's `tasks/` directory and replace its contents. Repository keys default to directory names under `repo_root`; an individual repository may additionally set `path`, `remote`, or `branch` when it differs from the defaults.

Required task fields are `id`, `title`, and a non-empty `repositories` mapping. `depends_on`, `constraints`, and `acceptance` are arrays. `goal` is free text.

## Typical workflow

1. Create a task YAML file in the external data directory.
2. Run `bin/agent-coding-tool status` to see ready/blocked work.
3. Run `bin/agent-coding-tool prepare TASK` immediately before launching a coding agent.
4. Paste the generated prompt into the worker.
5. Explicitly record the result with `record`.
6. Apply/review the worker artifact yourself. Once the task has actually landed on authoritative pushed state, record `complete`.
7. Dependent tasks become ready only after that explicit completion.

A worker that discovers a bad task breakout should be recorded as `blocked` or `needs_judgment`, not encouraged to broaden scope.

## Commands

`bin/agent-coding-tool status [TASK]`

Shows effective task state. Prepared and candidate tasks are compared against current pushed heads; head movement produces `STALE` or `STALE_CANDIDATE`.

`bin/agent-coding-tool prepare TASK`

Checks dependencies, resolves exact pushed heads with `git ls-remote`, records local HEAD/dirtiness separately, and writes/prints a worker prompt into the external data directory.

`bin/agent-coding-tool prepare TASK --retry`

Explicitly clears a recorded non-complete outcome and prepares another attempt. Completed tasks cannot be retried without resetting their state.

`bin/agent-coding-tool record TASK OUTCOME --summary "..." --artifact "..." --test "rake=pass"`

Valid outcomes: `candidate_complete`, `complete`, `blocked`, `needs_judgment`, `failed`.

`complete` means the human is asserting that the task is complete on authoritative pushed state; the tool captures a fresh completion snapshot at that moment.

`bin/agent-coding-tool reset TASK`

Clears runtime state for a task. The task definition is untouched.

## Development

Run `rake` for the full test suite. Tests use explicit temporary data directories and do not depend on personal task data.

V1 intentionally has no database, daemon, web UI, agent API, autonomous planner, agent-to-agent messaging, or GitHub write path. Add those only when repeated real workflow friction demonstrates a need.
