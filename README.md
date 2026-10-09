# agent-coding-tool

A deliberately small, local-first coordinator for a human directing multiple
coding agents.

The source repository is designed to remain safe to publish as open source.
Operational task definitions, project details, generated prompts, and runtime
state live in a separate data directory and are never required to be committed
here.

The tool does not launch agents, plan architecture, parse chat prose, or merge
code. Lifecycle commands remain local. The explicit `publish` command commits
and pushes selected changes in the configured private data checkout only.

## V1 contract

- Pushed `main` is authoritative.
- Local HEAD and dirtiness are observations only.
- Tasks may reference arbitrary Git repositories under the configured repo
  root.
- Each repository is explicitly `write` or `read_only` for each task.
- Task dependencies must be explicitly complete before a dependent task can be
  prepared.
- Preparing a task snapshots exact pushed heads and emits a worker prompt.
- Generated worker prompts direct GitHub repository reads through the connected
  integration and prohibit unnecessary cloud-browser or website-permission
  fallback.
- Preparing remains allowed when another prepared, in-flight, or candidate task
  has the same writable authority, but prints a collision warning.
- Writable pushed-head movement after preparation makes the task stale;
  read-only movement requires refresh/reconciliation.
- Starting a prepared task explicitly marks it in flight and rejects fresh
  write/write collisions with in-flight or candidate work unless the operator
  explicitly overrides; no agent liveness is detected.
- Worker outcomes are recorded explicitly; no prose interpretation is
  attempted.
- `needs_judgment` and `blocked` are normal outcomes, not failures to be
  auto-retried.
- Lifecycle commands never commit or push. `publish` is a separate operator
  action limited to the verified data checkout; it never opens PRs.

## Source/data separation

The public source checkout contains implementation, tests, documentation, and
examples only. Runtime data belongs in an external data directory.

By default, a checkout named `agent-coding-tool` uses a sibling directory named
`agent-coding-tool-data`. For example:

- `/path/to/code/agent-coding-tool` — public source checkout
- `/path/to/code/agent-coding-tool-data` — private/local task and state data
- `/path/to/code/other-repository` — a repository referenced by tasks

The default data directory can be overridden with
`AGENT_CODING_TOOL_DATA_DIR=/path/to/data`.

The data directory may itself be a private Git repository. Its expected
contents are:

- `config.yml` — optional overrides for repository root and default
  remote/branch and optional `publish_repository` identity.
- `tasks/*.yml` — durable human-authored task definitions.
- `state/*.yml` — explicit runtime/result state.
- `state/prompts/*.txt` — generated worker prompts.

When `config.yml` is absent, `repo_root` defaults to the parent of the data
directory, `default_remote` to `origin`, and `default_branch` to `main`.
Relative `repo_root` values are resolved from the data directory. See
`examples/config.yml`.
Publication expects `dtnorris/agent-coding-tool-data` by default. The
`publish_repository` setting can explicitly name another `owner/repository`
or an absolute local bare-repository path for offline fixtures. GitHub SSH
and HTTPS remote forms are normalized for identity verification.

The public repository also ignores legacy/local `config.yml`, `tasks/`,
`state/`, and `data/` paths as a fail-safe against accidentally committing
operational data.

## Task shape

Copy `examples/tasks/EXAMPLE.yml` into the external data directory's `tasks/`
directory and replace its contents. Repository keys default to directory names
under `repo_root`; an individual repository may additionally set `path`,
`remote`, or `branch` when it differs from the defaults.

Required task fields are `id`, `title`, and a non-empty `repositories` mapping.
`depends_on`, `constraints`, and `acceptance` are arrays. `goal` is free text.
An optional `worker_recommendation` mapping supplies non-empty `model` and
`thinking` strings as human-authored launch guidance.

## Typical workflow

1. Create a task YAML file in the external data directory.
2. Run `bin/agent-coding-tool status` to see active work, blockers, and recent
   progress.
3. Run `bin/agent-coding-tool prepare TASK` immediately before the work.
4. Run `bin/agent-coding-tool start TASK` to reserve the writable lane. Only
   after start succeeds, hand the generated prompt to the worker. Start is a
   human assertion; it does not launch a worker process.
5. Run `bin/agent-coding-tool received TASK` when the worker result is ready
   for review/application.
6. Apply/review the worker artifact yourself. Once the task has actually landed
   on authoritative pushed state, run `bin/agent-coding-tool finish TASK`.
7. Dependent tasks become ready only after that explicit completion.
8. Run `bin/agent-coding-tool publish` when ready to commit and push pending
   lifecycle state. Publication is never implicit in steps 3–6.

A worker that discovers a bad task breakout should be recorded as `blocked` or
`needs_judgment`, not encouraged to broaden scope.

## Commands

`bin/agent-coding-tool next`

Read-only advisory for work that can be started now. It uses the same effective
status/freshness snapshot, READY priority ranking, dependency-unlock metrics,
and remote URL plus branch writable authorities as `status` and `start`.
Fresh IN_FLIGHT and CANDIDATE writers occupy lanes; PREPARED work is available
but does not reserve one. The compatible start set is selected in priority
order, not rearranged to maximize the number of workers. READY rows show
`act prepare TASK` followed by `act start TASK`; fresh PREPARED rows show only
`act start TASK`. Both lifecycle commands recheck their own gates before a
prompt can be handed to a worker. The output also separates capacity waits,
running lanes, candidates awaiting human review/application, dependency waits,
and recorded interventions. Expected unlock counts are conditional consequences
of verified completion, not claims that downstream work is already eligible.
No state, prompt, Git ref, or agent is changed by `next`.

`bin/agent-coding-tool next --json` exports that same plan as one JSON
document on stdout. Its binding `agent-coding-tool-next/v0.1` contract has
`schema_version`, `advisory: true`, `snapshot`, `facts`, and
`recommendations`. `facts.tasks` records effective statuses, reasons,
dependencies, one-based priority ranks, and prepared pushed-head bindings
with an explicit checked/not-checked freshness state; `facts.reservations` records
current IN_FLIGHT/CANDIDATE writable remote URL and branch pairs.
`recommendations` contains ordered `starts`, `waiting_capacity`,
`candidate_review`, `interventions`, and `waiting_dependencies` arrays.
Start rows include the same grounded lifecycle commands as the text view,
optional configured model/thinking advice, and conditional downstream counts.
Capacity rows identify selected or occupied conflicting authorities. Empty
sections remain empty arrays. Array ordering follows the existing ranked
planner and stable task-store order; no clock-generated plan ID is introduced.
The snapshot states which freshness was observed and that prepare/start must
revalidate. It does not grant authority, launch a worker, or resolve a stale
candidate or human judgment. Malformed or unavailable pushed-head evidence
produces no partial JSON, an error on stderr, and a nonzero exit.

`bin/agent-coding-tool status [TASK] [--all | --active]`

Shows effective task state. The default dashboard includes every non-blocked
active task, the three easiest blocked tasks, and the five most recently
completed tasks ranked by their recorded completion timestamps. Retained
timestamped completions display oldest-to-newest, with the newest at the
bottom. Completed tasks without a usable recorded timestamp remain visible
before the chronological rows in stable task-store order. `--all` shows every
task with the same COMPLETE ordering, and `--active` excludes every completed
task while retaining the three-blocker dashboard limit. The two options are
mutually exclusive. Explicit `status TASK` lookup always shows the named task.

Broad dashboards are ordered for scanability: `COMPLETE`, `CANDIDATE`,
`NEEDS_JUDGMENT`, `IN_FLIGHT`, `READY`, then other active or exceptional
states, with `BLOCKED` last. READY tasks are ranked by immediate
collision-aware parallel unlock width, immediate unlock count, longest
downstream dependency path, then
distinct downstream task count. READY and fresh CANDIDATE rows show downstream
depth/count and `unlocks: N tasks / M parallel`: `N` is the number of
dependency-blocked tasks that would become READY if the row's task completed,
while `M` is the exact maximum subset that could start together without
conflicting with each other or other fresh IN_FLIGHT/CANDIDATE writers under
normal repository-authority rules. For a CANDIDATE, this models the state after
the candidate is finished, so its own current write reservation is excluded.
This is deterministic advisory prioritization only; it does not launch work or
reserve repositories. Default and `--active` dashboards show only the three
easiest dependency blockers, ranked by fewest incomplete dependencies; explicit
`blocked` outcomes without measurable dependency counts rank after
dependency-derived blockers. `--all` remains exhaustive. Major groups are
separated by a blank line. Every broad-dashboard task headline remains on one
line; embedded title whitespace is normalized, and long headlines truncate to
the terminal width with ASCII `...`. Subordinate details retain their own
wrapping or truncation behavior. Explicit `status TASK` lookup shows the full
original title and details. Dependency blockers use the compact `waiting on:`
label. When output is a TTY, status labels are colored; set `NO_COLOR` to
disable ANSI color.

Recorded `NEEDS_JUDGMENT` rows provide a compact operator handoff: a `reason:`,
an optional explicitly recorded `next:`, and the mechanical `resume: act
prepare TASK --retry` command. Each handoff field is normalized to one line and
dynamically truncated to the terminal width with ASCII `...`; the stored values
are unchanged. Use explicit `status TASK` to see the complete, untruncated
summary and next action.

Prepared, in-flight, and candidate tasks are compared against current pushed
heads; writable head movement produces `STALE` or `STALE_CANDIDATE`. Read-only
movement preserves the state with a refresh/reconciliation warning.
Presentation filtering does not alter task state or dependency resolution.
Fresh `PREPARED` rows also show live reasons when normal `start` is currently
blocked by a fresh `IN_FLIGHT` or `CANDIDATE` writer with the same authoritative
repository and branch. These terminal-width-aware diagnostics are recalculated
on every status query and disappear with the collision; they do not change the
task's `PREPARED` state. `PREPARED`/`PREPARED` overlap remains advisory, and
explicit `status TASK` shows every blocker without dashboard truncation.

Normal lifecycle: `READY` → `prepare` → `PREPARED` → `start` → `IN_FLIGHT` →
`received` → `CANDIDATE` → `finish` → `COMPLETE`. `received` is shorthand for
the `candidate_complete` outcome, and `finish` is shorthand for the `complete`
outcome. Recorded outcomes, incomplete dependencies, and hard staleness take
precedence over `IN_FLIGHT`.

`bin/agent-coding-tool prepare TASK`

Checks dependencies, resolves exact pushed heads with `git ls-remote`, records
local HEAD/dirtiness separately, and writes/prints a worker prompt into the
external data directory. Preparation warns about writable-authority overlap
with fresh `PREPARED`, `IN_FLIGHT`, or `CANDIDATE` tasks, but remains legal so
the operator can stage later work and choose which prepared task starts first.
When task metadata includes `worker_recommendation`, the terminal output prints
the advisory model and thinking level after the complete generated prompt. The
recommendation is not copied into the prompt file, runtime state, or snapshots,
and the tool does not launch or configure a worker. A fresh preparation clears
any in-flight marker and prior collision override record, including when
re-preparing a task without a recorded outcome.

`bin/agent-coding-tool prepare TASK --retry`

Explicitly clears a recorded non-complete outcome and any in-flight marker,
then prepares another attempt in `PREPARED` state. Completed tasks cannot be
retried without resetting their state.

`bin/agent-coding-tool start TASK [--allow-write-collision]`

Human assertion that a prepared prompt has been handed to a worker. Records a
UTC `started_at` without changing the snapshot or prompt. Requires an existing
task and preparation with no recorded outcome; a second start fails with
`already in flight`.

By default, start fails closed when another fresh `IN_FLIGHT` or `CANDIDATE`
task writes the same authoritative repository and branch. `PREPARED` work does
not block: the first explicitly started task wins. `COMPLETE`, `FAILED`,
`BLOCKED`, `NEEDS_JUDGMENT`, `STALE`, and `STALE_CANDIDATE` do not block.
Read/write and read/read overlap remain legal. Repository identity is the
prepared snapshot's existing `[remote_url, branch]` authority, so different
logical task repository keys that resolve to the same remote and branch still
collide.

Use `--allow-write-collision` only to intentionally run conflicting write work.
When it bypasses an actual collision, the runtime state records the override
time and conflicting tasks/repositories. The flag is per start invocation;
there is no global disable switch.

Collision checks are advisory scheduling safety for a human-operated workflow,
not a process lock or autonomous scheduler. The tool still does not launch,
inspect, or control agents or check liveness. Existing pushed-head freshness
semantics remain authoritative.

`bin/agent-coding-tool received TASK --summary "..." --artifact "..." --test
"rake=pass"`

Records that the worker result is ready for human review/application. This is
the preferred human-facing shorthand for `record TASK candidate_complete`; the
stored outcome remains `candidate_complete` and the effective status remains
`CANDIDATE` (or `STALE_CANDIDATE` when freshness requires it).

`bin/agent-coding-tool finish TASK --summary "..." --artifact "..." --test
"rake=pass"`

Records that the landed task is complete on authoritative pushed state. This is
the preferred human-facing shorthand for `record TASK complete`; the stored
outcome remains `complete`, the fresh completion snapshot is captured, and the
effective status remains `COMPLETE`.

`bin/agent-coding-tool record TASK OUTCOME --summary "..." --next "..."
--artifact "..." --test "rake=pass"`

Generic/manual outcome primitive. Valid outcomes: `candidate_complete`,
`complete`, `blocked`, `needs_judgment`, `failed`. The existing `record TASK
candidate_complete` and `record TASK complete` forms remain supported alongside
the preferred shorthands. `--next` stores an optional explicit operator action
for `blocked`, `needs_judgment`, or `failed`; it is rejected for successful
outcomes and is never inferred from the summary.

Every recorded result clears the in-flight marker. `IN_FLIGHT` is not an
outcome, and recording results without first calling `start` remains supported.

`complete` means the human is asserting that the task is complete on
authoritative pushed state; the tool captures a fresh completion snapshot at
that moment.

`bin/agent-coding-tool reset TASK`

Clears runtime state for a task, including the in-flight marker. The task
definition is untouched.

`bin/agent-coding-tool publish [TASK | --all] [--dry-run]`

Publication is an explicit operator action against the configured data
checkout. Without arguments it commits pending `state/*.yml` and
`state/prompts/*.txt` changes across tasks. With a task ID it selects only
that task's state and timestamped generated prompts. `--all` commits all
ordinary tracked and nonignored untracked ACTD changes, including task
definitions and documentation. Each mode accepts `--dry-run`, which previews
the selected files, existing staged paths, commit/push need, and blockers
without staging or updating refs.

The command verifies the checkout root, expected remote identity, configured
branch, and exact remote head. Narrow modes use a path-specific commit, so
unrelated staged work is preserved; a selected file with conflicting staged
and working versions blocks publication. A previously unpublished local
commit blocks new publication unless it is exactly one commit created by the
same `publish` mode over the unchanged remote base. In that case the command
retries the normal push. No force push, merge, reset, or rebase occurs. A
failed push retains the local commit and reports its SHA; retry the same
`publish` invocation after resolving the blocker. The command reports
`PUBLISHED` only after reading back the remote ref.

## Development

Run `rake` for the full test suite. Tests use explicit temporary data
directories and do not depend on personal task data. The publisher tests in
the normal suite use a deterministic Git runner fake, so they do not launch
Git subprocesses. Run the slower disposable-repository smoke tests explicitly
when changing Git staging or push behavior:

```sh
ruby -Ilib:test test/integration/publisher_git_integration.rb
```

V1 intentionally has no database, daemon, web UI, agent API, autonomous
planner, or agent-to-agent messaging. Add those only when
repeated real workflow friction demonstrates a need.
