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
- Writable pushed-head movement after preparation makes the task stale; read-only movement requires refresh/reconciliation.
- Starting a prepared task explicitly marks it in flight; no agent liveness is detected.
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

Required task fields are `id`, `title`, and a non-empty `repositories` mapping. `depends_on`, `constraints`, and `acceptance` are arrays. `goal` is free text. An optional `worker_recommendation` mapping supplies non-empty `model` and `thinking` strings as human-authored launch guidance.

## Typical workflow

1. Create a task YAML file in the external data directory.
2. Run `bin/agent-coding-tool status` to see active work, blockers, and recent progress.
3. Run `bin/agent-coding-tool prepare TASK` immediately before launching a coding agent.
4. Paste the generated prompt into the worker and run `bin/agent-coding-tool start TASK`.
5. Run `bin/agent-coding-tool received TASK` when the worker result is ready for review/application.
6. Apply/review the worker artifact yourself. Once the task has actually landed on authoritative pushed state, run `bin/agent-coding-tool finish TASK`.
7. Dependent tasks become ready only after that explicit completion.

A worker that discovers a bad task breakout should be recorded as `blocked` or `needs_judgment`, not encouraged to broaden scope.

## Commands

`bin/agent-coding-tool status [TASK] [--all | --active]`

Shows effective task state. The default dashboard includes every non-blocked active task, the three easiest blocked tasks, and the five most recently completed tasks ranked by their recorded completion timestamps. Completed tasks without a usable recorded timestamp remain visible. `--all` shows every task, and `--active` excludes every completed task while retaining the three-blocker dashboard limit. The two options are mutually exclusive. Explicit `status TASK` lookup always shows the named task.

Broad dashboards are ordered for scanability: `COMPLETE`, `CANDIDATE`, `IN_FLIGHT`, `READY`, then other active or exceptional states, with `BLOCKED` last. READY tasks are ranked by longest downstream dependency path, then by distinct downstream task count, and display both structural metrics. Default and `--active` dashboards show only the three easiest dependency blockers, ranked by fewest incomplete dependencies; explicit `blocked` outcomes without measurable dependency counts rank after dependency-derived blockers. `--all` remains exhaustive. Major groups are separated by a blank line. Long broad-dashboard titles and diagnostics wrap to the terminal width with subordinate or hanging indentation, except IN_FLIGHT task rows, which remain on one line and truncate their title with an ellipsis when necessary. Reasons render on an indented second line, and dependency blockers use the compact `waiting on:` label. When output is a TTY, status labels are colored; set `NO_COLOR` to disable ANSI color.

Prepared, in-flight, and candidate tasks are compared against current pushed heads; writable head movement produces `STALE` or `STALE_CANDIDATE`. Read-only movement preserves the state with a refresh/reconciliation warning. Presentation filtering does not alter task state or dependency resolution.

Normal lifecycle: `READY` → `prepare` → `PREPARED` → `start` → `IN_FLIGHT` → `received` → `CANDIDATE` → `finish` → `COMPLETE`. `received` is shorthand for the `candidate_complete` outcome, and `finish` is shorthand for the `complete` outcome. Recorded outcomes, incomplete dependencies, and hard staleness take precedence over `IN_FLIGHT`.

`bin/agent-coding-tool prepare TASK`

Checks dependencies, resolves exact pushed heads with `git ls-remote`, records local HEAD/dirtiness separately, and writes/prints a worker prompt into the external data directory. When task metadata includes `worker_recommendation`, the terminal output prints the advisory model and thinking level after the complete generated prompt. The recommendation is not copied into the prompt file, runtime state, or snapshots, and the tool does not launch or configure a worker. A fresh preparation clears any in-flight marker, including when re-preparing a task without a recorded outcome.

`bin/agent-coding-tool prepare TASK --retry`

Explicitly clears a recorded non-complete outcome and any in-flight marker, then prepares another attempt in `PREPARED` state. Completed tasks cannot be retried without resetting their state.

`bin/agent-coding-tool start TASK`

Human assertion that a prepared prompt has been handed to a worker. Records a UTC `started_at` without changing the snapshot or prompt. Requires an existing task and preparation with no recorded outcome; a second start fails with `already in flight`. This does not launch, inspect, or control agents, check liveness, or refresh repository heads. Use `status` to check dependencies and staleness.

`bin/agent-coding-tool received TASK --summary "..." --artifact "..." --test "rake=pass"`

Records that the worker result is ready for human review/application. This is the preferred human-facing shorthand for `record TASK candidate_complete`; the stored outcome remains `candidate_complete` and the effective status remains `CANDIDATE` (or `STALE_CANDIDATE` when freshness requires it).

`bin/agent-coding-tool finish TASK --summary "..." --artifact "..." --test "rake=pass"`

Records that the landed task is complete on authoritative pushed state. This is the preferred human-facing shorthand for `record TASK complete`; the stored outcome remains `complete`, the fresh completion snapshot is captured, and the effective status remains `COMPLETE`.

`bin/agent-coding-tool record TASK OUTCOME --summary "..." --artifact "..." --test "rake=pass"`

Generic/manual outcome primitive. Valid outcomes: `candidate_complete`, `complete`, `blocked`, `needs_judgment`, `failed`. The existing `record TASK candidate_complete` and `record TASK complete` forms remain supported alongside the preferred shorthands.

Every recorded result clears the in-flight marker. `IN_FLIGHT` is not an outcome, and recording results without first calling `start` remains supported.

`complete` means the human is asserting that the task is complete on authoritative pushed state; the tool captures a fresh completion snapshot at that moment.

`bin/agent-coding-tool reset TASK`

Clears runtime state for a task, including the in-flight marker. The task definition is untouched.

## Development

Run `rake` for the full test suite. Tests use explicit temporary data directories and do not depend on personal task data.

V1 intentionally has no database, daemon, web UI, agent API, autonomous planner, agent-to-agent messaging, or GitHub write path. Add those only when repeated real workflow friction demonstrates a need.
