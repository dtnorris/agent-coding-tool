# TST-08 profile and coverage handoff

Measured on the operator Mac, 2026-10-16 local time. This baseline-bound artifact supplies TST-13 and operator review with costs, test boundaries, recovery evidence and remaining acceptance work. [Rakefile](../../../Rakefile), [README Development](../../../README.md#development) and [AGENTS.md](../../../AGENTS.md) retain authority over execution and selection. Expected direct runtime saving from TST-08 is zero. No existing test, threshold, production file or shared helper changed.

## Result and provenance

| Gate/sample | Wall seconds | CPU user/system seconds | Outcome |
| --- | ---: | ---: | --- |
| Complete `bundle exec rake TESTOPTS=--seed=808` | 146.98 | 61.73 / 52.46 | 283 runs, 3,584 assertions, 0 failures, 2 errors, 0 skips; exit 1 |
| Its Minitest elapsed | 146.510784 | Included above | Same complete discovery |
| Instrumented Minitest, same 24 files and seed | 155.26 | 72.53 / 52.55 | Same 283/3,584/0/2/0; exit 1 |
| Its Minitest elapsed | 154.959827 | Included above | Sum of inclusive test durations: 154.932821 |
| Separate warm `actd:validate_yaml` invocation | 0.23 | 0.17 / 0.05 | PASS, 250 copied files; actual task action 0.031602 seconds |
| Refreshed read-only ACTD YAML-only validation | 0.22 | 0.16 / 0.05 | PASS, 252 copied files at `0ebe7eb`; no additional Minitest baseline |
| Qualified early cold public CLI journey and refusals | 37.446669 Minitest | See command record | PASS, 2 tests, 222 assertions |
| Targeted refusal matrix with child tracing | 15.84 | See command record | PASS, 1 test, 88 assertions; Minitest 15.527059 seconds |
| Final observer smoke | 0.250857 Minitest | See command record | PASS, 3 tests, 21 assertions |

The two complete samples exhaust this task's complete-baseline budget. The instrumented sample runs Minitest only. There was no second instrumented default run. An earlier default command attempt validated YAML but aborted **before discovery** because Rake 13.4.2 treats the separate value in `TESTOPTS=--seed 808` as a filename. Use `--seed=808` with this Rake loader. That aborted attempt is retained and excluded from runtime comparisons.

Both complete samples have these pre-existing environmental errors, at `Launcher#verify_running_process!`:

- `ParallelDeliveryTest#test_automatic_delivery_while_verified_sibling_remains_running`
- `ParallelLaunchTest#test_explicit_parallel_launch_owns_distinct_roots_and_preserves_stale_checkpoint`

Both report `launch: T worker liveness is unknown; inspect before retrying`. A separate finite fixture probe reproduces `Errno::EPERM` from spawning `ps`; signal and process-group probes succeed. `kern.bootsessionuuid` is also denied, separately. Native checks and host identity were left unchanged. Full-suite green acceptance remains **BLOCKED** on host execution of these two cases. Their later assertions and later successful-delivery operations were not reached; their measured costs cannot stand in for successful host paths.

The measured source is ACT `4013979f9c603a5b8d94d0817f4329e445f478e7`, with ACTD `db299a4d11f8d97512a2bf4a9cf1628c95d09339` and skills `e4e92e678b567ceaabe9c9d9c94215f6729099ba`. Connected GitHub reads matched all three prepared heads at entry. ACT and skills still match at final refresh; read-only ACTD movement is reconciled below and in [freshness.json](freshness.json). Local HEAD, remote, ancestors, index and tracked/untracked state were inspected. The implementation workspace began clean; all additions belong to this handoff. A separate local clone at the exact ACT commit executed the tests. Its only source additions were the two optional diagnostic files; all baseline implementation/tests stayed byte-identical.

Final ACTD `main` is `0ebe7eba35e2d14fda8baf8957550bfa8585c161`, three commits ahead. Connector comparison lists eight changed paths: FO-25 state, TST-08 state/task, four generated prompts, and new FO-26 task. TST-08's only task change is the runtime qualification clarification already present in this assignment; its new state matches this attempt's supplied preparation. FO-25 completion and FO-26 registration do not affect ACT source or the optimization decisions. Prompt text is excluded from the YAML selection. Exact-ref reads of the four changed/added selected YAML blobs were verified against their Git blob IDs and overlaid on a separate copied corpus; all 252 files parsed successfully. Read-only worktrees were left untouched. The two complete suite measurements remain bound to the original 250-file corpus; **no complete default measurement against the refreshed 252-file corpus is claimed**. This unrelated read-only movement requires no writable-source abort or task re-preparation.

Ruby 4.0.6 arm64, Bundler 4.0.17, Minitest 5.27.0 and Rake 13.4.2 were installed and `bundle check` passed. Lock SHA-256: `f641fb8cf6da99b0d3893de535b475da839390f33003e68467108d4d04634adb`. Host: macOS 26.6.2 (25G83), Darwin 25.6.0, arm64, 14 logical CPUs, local APFS. CPU product identity is unavailable through the sandbox. [environment.json](environment.json) records the observations and limits. Coding guidance was read at revision `e4e92e6`; planning guidance at `358f7f2`. Their local SHA-256 values match the complete supplied skills (`5337876c…98982` and `8a726b39…009`).

One test process ran at a time, with no Minitest parallelization, coverage instrumentation, gem changes or cache flush. Early qualification warmed code/filesystem caches; fixtures were fresh per process. Host-wide contention and thermal state were unmeasured. Small inspection/smoke commands overlapped the first complete run. Sample counts are one per mode, so no median or exact observer-overhead estimate is justified. Instrumented Minitest elapsed exceeds uninstrumented elapsed by 8.449043 seconds (5.77%); tracing, verbose output, warm effects and noise are confounded. This is no measurement of deployed test growth or optimization savings.

Historical 148.391673 seconds / 288 runs / 3,734 assertions / 244 YAML files has no verified source/environment binding. Registration's 23 files / 274 literal methods became 24 / 283 through the nine methods in `manual_parallel_launch_test.rb` added by `194369b`. Current executed discovery equals all 283 literal methods. The historical extra five runs and assertion difference cannot be reconciled further without its source/discovery evidence; no cases were skipped or filtered to match it. The new native sandbox file similarly changes six integration files to seven. The measured YAML selection is exactly 250 files, hashed in [corpus.json](corpus.json); the later refreshed selection has 252.

## Ranked costs

These are **inclusive per-test durations from the instrumented whole selection**, including fixture work inside test bodies. They are not isolated per-file wall measurements. The targeted matrix wall above is an isolated *method* measurement with additional child instrumentation; no isolated full-file walls were collected.

| Rank | Test (class#method) | Seconds | Actual work and reason |
| --- | --- | ---: | --- |
| 1 | `ParallelDeliveryTest#test_both_delivery_orders_preserve_independent_candidates_and_recover` | 24.414 | Both delivery orders; two native launches per fixture, checkpoint record/verify, validated commits, lost-push recovery, candidate/staleness checks. Production ownership and Git verification repeat at each boundary. |
| 2 | `ManualParallelLaunchTest#test_public_cli_manual_overlap_preserves_candidates_with_active_and_historical_variants` | 22.987 | Four active/historical combinations; cold prepare/start/launch/checkpoint/status, native Git and candidate byte preservation. Two finite external writers are joined, not arbitrarily skipped. |
| 3 | `ManualParallelLaunchTest#test_refusal_matrix_preserves_manual_candidate` | 14.061 | Eleven independently built refusal scenarios; 55 cold CLI invocations in the targeted follow-up. |
| 4 | `ManualParallelLaunchTest#test_each_forbidden_sandbox_write_refuses` | 11.774 | Five protected-boundary leak controls; real prepare, native writer/reader worktrees and preflight; fake external sandbox results. |
| 5 | `ParallelDeliveryTest#test_automatic_then_explicit_cli_delivery_keep_separate_task_candidates` | 7.488 | Multiple native launches and complete auto/explicit delivery, commits and candidate checks with fake remote publication. |
| 6 | `ManualParallelLaunchTest#test_preflight_races_refuse_before_reservation` | 6.800 | Four independent identity/prompt/authority/manual-state race fixtures through native preflight. |
| 7 | `ParallelDeliveryTest#test_tampered_advanced_sibling_validation_blocks_delivery` | 4.700 | Two native runs, first delivery and validated commit, then tampered-log refusal. |
| 8 | `ParallelDeliveryTest#test_reservation_race_and_held_lock_refuse_before_publication` | 3.505 | Two native runs plus lock and reservation-race controls; production validation remains active. |
| 9 | `ManualParallelLaunchTest#test_manual_candidate_refuses_and_terminal_non_candidate_remains_nonblocking` | 3.498 | Separate candidate and blocked-outcome fixtures, with repeated cold prepare/start and launch. |
| 10 | `ParallelDeliveryTest#test_overlap_refusal_matrix_preserves_sibling_and_unpublished_candidate` | 3.308 | Two native initial runs followed by five evidence mutations and unknown-liveness refusal. |

All ten above passed. Their sum is 102.535 seconds, with overlapping operation categories inside each test. All 283 test measurements are retained in [main-process.json.gz](main-process.json.gz); [summary.json](summary.json) supplies aggregates.

| Observed main-process operation | Calls | Inclusive seconds | Interpretation |
| --- | ---: | ---: | --- |
| Actual Open3 Git, all subcommands | 4,645 | 73.226 | Main process only; excludes Git inside cold CLI children. |
| Git `rev-parse` | 1,464 | 20.564 | Parent/worktree HEAD, Git administration and provenance probes. |
| Git `remote` | 603 | 8.397 | Repeated authority/get-url checks. |
| Git `worktree` | 427 | 7.671 | Native add/list/ownership/removal paths. |
| Git `ls-remote` | 290 | 7.602 | Local bare fixture refs; no network protocols allowed. |
| Coding skill blob reads | 428 | 6.752 | Real immutable-object validation on repeated render/regeneration. |
| Planning skill blob reads | 29 | 0.430 | Opted-in planning material. |
| Other Git `cat-file` | 403 | 5.609 | Commit/object/ownership validation; distinct from skill blobs. |
| Ruby subprocess capture | 175 | 47.775 | 158 calls / 44.591 seconds are in the manual-parallel class. Includes child internals and boot/exit; do not add child times again. |
| Fixture `codex` capture | 234 | 8.092 | Real processes running fake version/help/auth/sandbox executables. No real Codex. |
| OS spawn attempts | 5,132 | 9.353 | Nested inside captures where applicable; two raised events. Excludes child internal spawns. |
| Stubbed Open3 call layers | 584 | 6.481 | Some forward to real capture; nested totals overlap actual Git. Injected runner/inspector/provider calls outside Open3 are not counted. |
| Ruby IO `fsync`, native implementation | 1,851 | 0.087407 | Real sync calls, including file/directory persistence. Git's internal syscalls are unobserved. No no-op substitution. |
| Ruby IO `fsync` fault stubs | 6 | 0.000059 | Synthetic exceptions, separately classified. |
| File rename layers | 1,166 | 0.325 | Native plus test-stub layers; same-thread self time 0.094 seconds. Includes cold-reader controls nested in rename. |
| Recursive copy / removal | 103 / 372 | 0.751 / 1.153 | Main-process `cp_r` / `remove_entry`; other observed file operations remain in raw data. |
| Sleep / waitpid / thread join | 400 / 31 / 5,390 | 5.515 / 6.792 / 6.191 | Main-process polls and waits; thread/child/nested intervals overlap. A 30-second fake-worker ceiling is not a measured 30-second cost. |
| Minitest `setup` / `teardown` hooks | 283 / 283 | 0.035432 / 0.010326 | Hook methods only. Most expensive fixtures execute in test bodies, so these do not measure all setup work. All six hook phases are retained. |

Main observer CPU after installation: user 12.581504 / system 9.698900; reaped-child user 59.843089 / system 42.819767 seconds. Parent reaped-child CPU includes descendants; never sum CPU recursively across the child follow-up. Instrumentation consumes CPU inside the measured process. The per-operation `same_thread_self_seconds` subtracts directly observed nesting on the same thread only; it is not an exclusive wall decomposition across threads or subprocesses. `raises_within` counts raised events, including internally rescued errors, rather than escaped exceptions or failed tests. Git subcommand `other` retains 183 calls / 2.633 seconds that the fixed whitelist does not identify more narrowly.

The child follow-up captures one parent and 55 CLI processes: 33 prepare, 11 start, 11 launch. Children contain 263 Git calls / 4.724149 inclusive seconds, 94 native syncs / 0.004376 seconds; the parent adds 59 Git calls / 1.210337 seconds. Prepare children alone spend 3.872077 seconds in 220 Git calls. There are 40 coding blob reads / 0.645236 seconds across parent and children. Parent Ruby capture totals 14.025370 seconds; child observed lifetimes total 9.415521 seconds **inside that interval**. The residual includes interpreter/require startup before observer installation, observer serialization/exit and other overhead; it is not an isolated startup benchmark. Fake-worker internals remain uninstrumented because the production worker environment excludes RUBYOPT. See [child-followup.json.gz](child-followup.json.gz).

Limits: no all-descendant operation profile for the whole suite; injected runner/provider counts, Git internal syscalls, YAML serialization/parsing beyond the separate outer YAML action, ordinary file writes, GC, exact interpreter startup, child sleep and child sync totals are not separately measured for the whole selection. Parent Ruby capture bounds those child costs inclusively. The targeted child slice is not extrapolated to all children. Status/error preservation was qualified with actual text and binary stdout/stderr, exit 7, original fake return/exception identity, nested real/stub calls and native missing-executable failure. Forwarding wrappers were rejected during smoke qualification; the delivered observer uses passive TracePoint and replaces no methods. No child output enters labels.

## Coverage and retention inventory

[source-inventory.json](source-inventory.json) lists every current default/integration method, line, file hash and relevant boundary source line. The following totals are summed inclusive durations, **not standalone file wall time**. Two erroring tests are included in their groups. Existing selection stays `test/**/*_test.rb`; both new observer files are excluded by name.

| Default file / class | Tests | Inclusive seconds | Behavior / external boundary | Retention owner |
| --- | ---: | ---: | --- | --- |
| [manual_parallel_launch_test.rb](../../manual_parallel_launch_test.rb) | 9 | 66.291 | Cold CLI/native Git/process; manual/external candidate preservation, leak/race/refusal matrices | David: ownership decision |
| [parallel_delivery_test.rb](../../parallel_delivery_test.rb) | 7 | 46.880 | Native ownership/validation/commits; fake GitHub/guard; both-order recovery and live sibling; 1 native-ps ERROR included | TST-10 |
| [preflight_recovery_test.rb](../../preflight_recovery_test.rb) | 4 | 10.653 | Native failed preflight, abandonment, removal interruption and foreign/dirty refusal | TST-12 |
| [launcher_test.rb](../../launcher_test.rb) | 34 | 8.257 | Decision fakes by default, explicit native Git/process; prompt, nonzero, binary final, Ctrl-C and spawn failure | TST-10 |
| [parallel_launch_test.rb](../../parallel_launch_test.rb) | 5 | 6.107 | Native separate workers/worktrees, locks, stale-main and collision ownership; 1 native-ps ERROR included | TST-10 |
| [planning_guidance_test.rb](../../planning_guidance_test.rb) | 10 | 4.181 | Real synthetic skill objects, metadata/pin/UTF-8/refusal, cold public handoff | TST-09 |
| [worktree_manager_test.rb](../../worktree_manager_test.rb) | 7 | 2.131 | Native exact base/branch/readers, registry/backpointer, dirty and symlink preservation | TST-12 |
| [coordinator_test.rb](../../coordinator_test.rb) | 34 | 1.838 | Fake repository observations; actual YAML/state/prompt persistence and lifecycle/freshness | TST-11 |
| [write_collision_test.rb](../../write_collision_test.rb) | 15 | 1.368 | Fake inspector with actual persistence; manual advisory overlap and authority/refusal | TST-11 |
| [cli_test.rb](../../cli_test.rb) | 49 | 1.359 | Public CLI output/exit/status/prepare/result; fake observations, real state and prompt files | TST-11 |
| [live_write_collision_status_test.rb](../../live_write_collision_status_test.rb) | 10 | 1.205 | Fake observations, persisted states; alias/candidate/stale/reader diagnostics, batched read-only status | TST-11 |
| [coding_skill_test.rb](../../coding_skill_test.rb) | 7 | 0.901 | Native synthetic object integrity, immutable pin despite dirty/newer source, no partial writes | TST-09 |
| [next_test.rb](../../next_test.rb) | 13 | 0.853 | Scheduling/JSON/read-only/freshness decisions with fake inspector and actual state fixtures | TST-11 |
| [rakefile_test.rb](../../rakefile_test.rb) | 4 | 0.745 | Real child Rake/parser on copied tiny YAML fixtures; malformed/missing/ignored data | TST-13 |
| [ready_unlock_metrics_test.rb](../../ready_unlock_metrics_test.rb) | 8 | 0.554 | Exact dependency/parallel width decisions with fake observations and real state fixtures | TST-11 |
| [state_store_test.rb](../../state_store_test.rb) | 14 | 0.513 | Real files, sync/rename/permissions/symlinks/cold readers; injected operation faults | Retain safety oracle |
| [family_status_test.rb](../../family_status_test.rb) | 15 | 0.379 | In-memory task/state/inspector observations; public ranking/formatting/read-only views | TST-11 |
| [status_next_summary_test.rb](../../status_next_summary_test.rb) | 6 | 0.329 | Fake inspector with actual state fixtures; public consistent actions/status/width | TST-11 |
| [prompt_renderer_test.rb](../../prompt_renderer_test.rb) | 5 | 0.268 | Real rendering and synthetic pinned blob reads; scope/documentation/performance contracts | TST-09 |
| [publisher_test.rb](../../publisher_test.rb) | 15 | 0.065 | Deterministic fail-loud Git protocol fake; selection/index/identity/failures/public output | Retain default |
| [task_store_test.rb](../../task_store_test.rb) | 3 | 0.039 | Real temporary task YAML; checkpoint and worker metadata validation | Retain default |
| [retry_liveness_test.rb](../../retry_liveness_test.rb) | 1 | 0.010 | Deterministic OS/identity/tool error matrix; no real lsof/signals | Retain default |
| [config_test.rb](../../config_test.rb) | 2 | 0.002 | Real temporary config/path defaults | Retain default |
| [repo_inspector_test.rb](../../repo_inspector_test.rb) | 6 | 0.002 | Injected runners, exact Git argv/ref parsing, deduplication and real thread barriers | Retain default |

Boundary obligations for subsequent changes:

| Invariant / real boundary | Existing representatives to retain | Responsible follow-up |
| --- | --- | --- |
| Authoritative remote identity/head, writable staleness and read-only reconciliation | RepoInspectorTest, CoordinatorTest, LauncherTest stale/authority/read-only cases, manual refusal matrix | TST-09/10/11 retain decisions; TST-12 retains native ownership; TST-13 inventories composed proof |
| Dirty index/tracked/untracked and preserved foreign candidates | LauncherTest dirty-divergent parent; WorktreeManagerTest visible writer/backpointer; manual `older_bytes`; checkpoint and publisher integrations | TST-10/12 and existing integration owners |
| Worktree branch/base, detached readers, isolation/collisions and paths | WorktreeManagerTest writer/reader/symlink/backpointer; ParallelLaunchTest; manual nested-checkout/leak/race controls | TST-10/12; manual file ownership needs David's assignment |
| Manual/external versus ACT-managed execution | WriteCollisionTest, LiveWriteCollisionStatusTest, NextTest, ManualParallelLaunchTest, parallel delivery refusal | TST-10/11; preserve active real fixture worker and cold CLI journey |
| Atomic persistence, corruption, permissions, symlinks and restart | StateStoreTest unchanged: short-write/flush/fsync/close/rename faults, post-rename truth, real cold readers; Coordinator/CLI persistence | TST-11 keeps StateStoreTest as read-only safety oracle; no global fsync replacement |
| Checkpoint completeness/applicability/provenance/recovery | `checkpoint_git_integration.rb`, parallel delivery checkpoints, manual CLI record/verify, retry historical checkpoint | Existing integration owners; TST-13 must enforce retained gate before any move |
| Nonzero/invalid binary final, exceptions, cancellation/timeouts and process groups | LauncherTest process/invalid-final/spawn-failure/Ctrl-C/nonzero CLI cases; ParallelLaunchTest live sibling; observer binary controls | TST-10 retains actual finite fixture executables and native process assertions |
| Publication denial, validation evidence/coverage/lease and lost-response recovery | PublisherTest fake protocol; ParallelDeliveryTest; publisher/delivery/multi-delivery Git integrations | TST-10 decisions, existing integrations and TST-13 gate ownership |
| Public output, exit statuses, JSON, selection and prompt bytes | CLITest, FamilyStatusTest, NextTest, StatusNextSummaryTest, RakefileTest, CodingSkillTest, PlanningGuidanceTest | TST-09/11; TST-13 owns Rakefile, its tests and README |

Early continuous acceptance used the existing `ManualParallelLaunchTest` public cold CLI positive journey and `test_refusal_matrix_preserves_manual_candidate`: prepare saves prompt/state; another CLI process launches the fixture executable against the exact prepared base; native worktrees, checkpoint round trips, prompt bytes and older candidates are checked. Stale authoritative heads and changed prompt bytes refuse with exit 2 before worker PID/reservation. Those two tests passed before the complete baselines. `PlanningGuidanceTest#test_public_prepare_to_cold_regeneration_and_fake_worker_handoff` also passed in both complete selections; it deletes required planning handoff bytes, proves the assertion and launch refusal fail before handoff, restores bytes and checks exact fake-worker stdin. External GitHub publication and sandbox/Codex behavior are declared fakes; native Git/filesystem/process handoffs remain real where these tests select them.

The seven integration files are excluded by the default glob. Each is classified explicitly:

| File under `test/integration/` | Literal tests | Supported role / retention |
| --- | ---: | --- |
| `publisher_git_integration.rb` | 20 | README Git staging, index preservation, native commit/push, identity, races and retry smoke; retain for publisher/Git changes |
| `delivery_manager_git_integration.rb` | 10 | README exact validation/commit/recovery/log/privacy/coverage/guard smoke; fake remote provider, local Git push adapter case |
| `multi_delivery_git_integration.rb` | 7 | README multi-writer/cross-check/partial-delivery/recovery/cleanup smoke; fake remote provider/guard |
| `checkpoint_git_integration.rb` | 7 | README complete patch, wrong baseline, symlink, gate, cold reconstruction and launch-binding smoke |
| `attempt_retry_git_integration.rb` | 14 | README cold public retry/closeout, old-layout classification, partial creation, retained bytes/checkpoints, races and nonzero/spawn failures; declared fixture boot/lsof/sandbox boundaries |
| `manual_parallel_native_sandbox.rb` | 1 | Separate native macOS sandbox acceptance documented above README's five Git smoke commands. Requires real installed Codex; **NOT RUN / outside this task's real-Codex authority** |
| `terminal_attempt_reproduction.rb` | 2 | Historical opt-in characterization of defects at `b0101cf4`; assertions expect fixed-path collision and missing host identity. Current retry behavior has changed. Preserve as historical evidence, not a current mandatory green regression gate. **NOT RUN** |

The five README Git suites were inspected, not executed in TST-08; no production or native-test behavior changed. Their supported commands remain:

```sh
bundle exec ruby -Ilib:test test/integration/publisher_git_integration.rb
bundle exec ruby -Ilib:test test/integration/delivery_manager_git_integration.rb
bundle exec ruby -Ilib:test test/integration/multi_delivery_git_integration.rb
bundle exec ruby -Ilib:test test/integration/checkpoint_git_integration.rb
bundle exec ruby -Ilib:test test/integration/attempt_retry_git_integration.rb
```

Run each in its own process with the qualified fixture environment below. `PublisherTest` is defined in both the default and integration files; their current test names are distinct, but helpers/setup share a class and can overwrite contracts when loaded together. A future aggregate must use isolated invocations and verify complete summaries. No supported mandatory aggregate exists yet; TST-13 owns that change. No case may disappear from required coverage while waiting for that gate.

## Cost/risk decisions for David and TST-13

Reaching 30 seconds from the measured default requires over 116.98 seconds of wall reduction; reaching 15 requires over 131.98. No removal or saving was measured. Neither target is established, and successful native host paths have additional unmeasured work after the two current refusals.

- **TST-10: measured priority, bounded review.** ParallelDeliveryTest spends 38.880 seconds in 2,520 main-process Git calls out of 46.880 inclusive seconds. The both-orders test alone is 24.414 seconds. The smallest useful experiment is one decision-only forged-evidence/lock/refusal slice through the existing injected boundaries, comparing actual calls and keeping the native end-to-end positive, both-order recovery, live sibling, cancellation, stale-head and no-publication controls. Checkpoint/ownership semantics still need real Git. Avoid a new fake Git/OS framework. Maximum possible group removal is not an admissible savings claim.
- **Manual parallel family: NEEDS_JUDGMENT on ownership/boundary.** Its 66.291 seconds dominates and exceeds 30 by itself. It was added after registration and is outside the explicit TST-09..12 file lists. Its 158 cold CLI calls / 44.591 seconds plus 591 direct Git calls / 11.089 seconds identify real cost. The refusal follow-up confirms repeated native prepare/Git work, not fsync, as a concrete contributor. David must assign any change or supported integration classification; no task YAML, ownership or preparation was changed here. This cannot silently become TST-10 scope.
- **TST-09: secondary conditional opportunity.** Main-process skill blob reads total 457 calls / 7.182 seconds; dedicated integrity/cold paths are included and must stay native. That is an inclusive upper bound for removing *all* main-process skill reads, not achievable savings. The targeted CLI slice adds measured child reads but cannot be extrapolated. If still needed after the native-boundary decision, start with one ordinary Coordinator decision group and an exact-argv test-only blob response; retain real immutable-object, dirty-branch, wrong-pin, digest/UTF-8 and public cold-handoff controls. Do not re-seed or cache production skills.
- **TST-11: defer / no code recommended from this evidence.** Main-process sync is 0.087 seconds overall; CoordinatorTest has 330 syncs / 0.005299 seconds. The targeted cold CLI children also have only 0.004376 seconds of sync. YAML/write components were not isolated, so this artifact grants no premise that they dominate. Preserve the real filesystem safety oracle; do not build a memory store to pursue an unmeasured cause.
- **TST-12: defer unless a smaller decision slice proves worthwhile.** WorktreeManagerTest is 2.131 seconds (149 Git calls / 2.004 seconds); PreflightRecoveryTest is 10.653 seconds (607 Git calls / 8.633 seconds). Registry/backpointer, interrupted removal, dirty/foreign/active paths and ownership are these cases' subjects. Copy/removal costs are small in the main profile. Existing early `git:false` decisions are already cheap. Retain native semantics; no broad replacement is justified by this profile alone.
- **TST-13/operator next gate:** first qualify the two native process cases on the unsandboxed host with fixture tools. Then decide whether expensive native families belong in a supported, fail-closed, mandatory integration gate, with this behavior manifest. That one boundary decision could make several speculative fixture rewrites unnecessary. The two largest families total 113.171 inclusive instrumented seconds; moving selection would redistribute validation cost, not accelerate required aggregate validation. A sub-30 default is plausible only after a deliberate boundary/removable-work decision and fresh comparable measurement; a sub-15 default and sub-30 total validation have no demonstrated path here. Defer unnecessary TST-09..12 work rather than automatically implementing four abstractions. Any substantial scope/dependency change requires David's explicit revision and safe re-preparation, with retry where applicable.

ACT-18 remains registered without pushed state in the inspected ACTD snapshot. TST-02 and TST-07 have complete records and implement different outcomes. No launcher/coordinator/CLI/state/helper contract was edited, so this task has no shared-file writer seam with those efforts. Future owners must recheck unpublished candidates/current writers and refresh after integration. TST-13 alone owns Rakefile, `test/rakefile_test.rb` and README test-contract edits; all recommendations here are handoff material.

## Reproduction, recovery and application

[commands.json](commands.json) contains exact argv, roots, environment overrides, outcomes, raw stdout/stderr/time bytes encoded as base64, hashes, file timestamp bounds and the temporary child hook source. It retains the first enclosing-Git fixture failure and corrected journey, aborted Rake option attempt, failed relative-path child hook load and qualified binary child control. Those are fixture/instrumentation qualifications, not product failures. Full-suite logs and all complete outcomes are retained. Use Ruby `JSON.parse`, `Base64.decode64` and `Zlib::GzipReader` to inspect exact bytes; gzip uncompressed hashes are in summary.json. No child output or secrets are used in measurement labels.

Execution used a new exact-commit local clone and an ACTD `git archive` copy. Fixture TMPDIR was a sibling of the execution source, inside the verified writable disposable root. Initially Git discovered the enclosing ACT worktree above fixtures and correctly refused nested worktrees; setting `GIT_CEILING_DIRECTORIES` to the disposable container corrected that environment without altering checks. Synthetic coding/planning Git fixtures come from existing CodingSkillSupport. LauncherSupport and the native tests select fixture executables/providers. PATH guards for `gh`, `codex`, `curl`, `wget`, `ssh`, `scp`, `nc` fail with status 97; native fixture paths take precedence. Git permits only the local `file` protocol, disables global/system configuration, lazy fetching and prompts. Shell network restrictions remain independent. No live service, real Codex, paid resource, operator checkout mutation or real ACT lifecycle operation occurred.

Reconstruct this environment in a **disposable container**, copying the pinned ACTD snapshot rather than pointing at personal task data:

```sh
# Set these to existing qualified disposable paths; keep fixture roots outside source.
export TST08_ROOT=/absolute/disposable/container
export TST08_SOURCE="$TST08_ROOT/source"
export TMPDIR="$TST08_ROOT/fixtures"
export AGENT_CODING_TOOL_DATA_DIR="$TST08_ROOT/data"
export GIT_CEILING_DIRECTORIES="$TST08_ROOT"
export GIT_ALLOW_PROTOCOL=file GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0
# Create data via: git -C READ_ONLY_ACTD archive db299a4... | tar -x -C "$TST08_ROOT/data"
# Use the complete SHA recorded above. Install the fail-loud PATH guards described above.
export PATH="$TST08_ROOT/guards:$PATH"
cd "$TST08_SOURCE"
```

The exact complete commands below are retained for future authorized reproduction; **do not run a third complete TST-08 baseline**. New expensive gates need operator checkpoint preservation and an appropriate fresh task/budget. Existing task-specific ceilings remain controlling.

```sh
/usr/bin/time -p bundle exec rake TESTOPTS=--seed=808
/usr/bin/time -p bundle exec ruby -Ilib:test test/profile_suite.rb \
  --output /absolute/new-evidence.json -- --seed 808 --verbose
```

The observer creates its output exclusively and refuses to overwrite evidence. Its main process alone is observed; child tracing in this handoff was a separately qualified temporary targeted hook.

Application commands (David controls application; require a clean, exact prepared baseline and refreshed pushed identity):

```sh
shasum -a 256 -c TST-08.patch.sha256
test "$(git -C "$TST08_SOURCE" rev-parse HEAD)" = 4013979f9c603a5b8d94d0817f4329e445f478e7
test -z "$(git -C "$TST08_SOURCE" status --porcelain)"
git -C "$TST08_SOURCE" apply --check /absolute/TST-08.patch
git -C "$TST08_SOURCE" apply /absolute/TST-08.patch
git -C "$TST08_SOURCE" diff --check
```

Post-application focused validation, using the qualified fixture environment above:

```sh
bundle exec ruby test/profile_observer_smoke.rb --seed 808
bundle exec ruby -Ilib:test test/manual_parallel_launch_test.rb --seed 808 \
  --name '/test_public_cli_manual_overlap_preserves_candidates_with_active_and_historical_variants|test_refusal_matrix_preserves_manual_candidate/'
# On the operator host: recover native acceptance without faking process observations.
bundle exec ruby -Ilib:test test/parallel_launch_test.rb --seed 808 \
  --name test_explicit_parallel_launch_owns_distinct_roots_and_preserves_stale_checkpoint
bundle exec ruby -Ilib:test test/parallel_delivery_test.rb --seed 808 \
  --name test_automatic_delivery_while_verified_sibling_remains_running
```

The complete implementation was preserved before expensive validation as baseline-bound local patches, including untracked additions. Pre-profile patch SHA-256: `b8a26ab3ae10490b6acdef285c9f511cdb61534198031e71678e7ff2aaabe28d`; it remains at `tmp/tst08/implementation-before-profile.patch`. The original pre-read-only-refresh candidate also survives at `tmp/tst08/before-readonly-refresh-TST-08.patch`, SHA-256 `2a41aa211598d13694db1c2373828b8e42335f9d5deaaa2af419d753e3bd0fba`. The final root-relative `tmp/tst08/TST-08.patch` includes all diagnostics and reconciled handoff artifacts, with a separate SHA-256 file. Clean exact-baseline applicability, whitespace and reconstructed bytes are checked separately. Private ACT checkpoint registration was **NOT RUN** under the no-lifecycle-mutation restriction. David may preserve the implementation through host-controlled `act checkpoint record TST-08 --workspace PATH`, then use `act checkpoint gate ... -- COMMAND` and `act checkpoint verify ...` for later authorized gates. These local artifacts have no host/disk-loss guarantee.

Implementation proof: **PASS** for observer controls, same complete selection/outcomes under tracing, early CLI positive/negative handoff and targeted child profile. Integrated green host acceptance: **BLOCKED** on the two native liveness cases. Five Git integrations: **NOT RUN**, commands and coverage retained. Real Codex sandbox acceptance: **NOT RUN / unauthorized here**. Current-source eligibility: writable ACT and skills heads match preparation; read-only ACTD movement was reconciled without rewriting baseline evidence. Future movement requires the applicable reconciliation/re-preparation. Publication: **NOT RUN / no authority**. No real ACT outcome was recorded.

Suggested commit message, only if David chooses to apply and commit: `test: profile ACT suite costs and document test boundaries`.

This is the only new Markdown file. Its lasting purpose is the baseline-bound profiling/coverage/operator contract handoff requested by TST-08; TST-13 should use it when establishing the authoritative aggregate test contract rather than copying temporary progress into README.
