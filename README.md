# agent-coding-tool

A deliberately small, local-first coordinator for a human directing multiple coding agents.

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

## Files

- `config.yml` — local repository root plus default remote/branch.
- `tasks/*.yml` — durable human-authored task definitions.
- `state/*.yml` — explicit runtime/result state.
- `state/prompts/*.txt` — generated worker prompts.

## Task shape

Copy `tasks/EXAMPLE.yml` and replace its contents. Repository keys default to directory names under `repo_root`; an individual repository may additionally set `path`, `remote`, or `branch` when it differs from the defaults.

Required task fields are `id`, `title`, and a non-empty `repositories` mapping. `depends_on`, `constraints`, and `acceptance` are arrays. `goal` is free text.

## Typical workflow

1. Create a task YAML file.
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

Checks dependencies, resolves exact pushed heads with `git ls-remote`, records local HEAD/dirtiness separately, and writes/prints a worker prompt.

`bin/agent-coding-tool prepare TASK --retry`

Explicitly clears a recorded non-complete outcome and prepares another attempt. Completed tasks cannot be retried without resetting their state.

`bin/agent-coding-tool record TASK OUTCOME --summary "..." --artifact "..." --test "rake=pass"`

Valid outcomes: `candidate_complete`, `complete`, `blocked`, `needs_judgment`, `failed`.

`complete` means the human is asserting that the task is complete on authoritative pushed state; the tool captures a fresh completion snapshot at that moment.

`bin/agent-coding-tool reset TASK`

Clears runtime state for a task. The task definition is untouched.

## Development

Run `rake` for the full test suite.

V1 intentionally has no database, daemon, web UI, agent API, autonomous planner, agent-to-agent messaging, or GitHub write path. Add those only when repeated real workflow friction demonstrates a need.
