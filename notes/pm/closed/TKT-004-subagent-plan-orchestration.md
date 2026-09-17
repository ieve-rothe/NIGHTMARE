---
ID: TKT-004
Title: Programmatic Plan Orchestration with Deterministic Gates and Subagent Execution
Status: Closed
Priority: High
---

## 1. User Need
As an operator running local and mixed-tier LLMs, I need the system to execute multi-step software engineering tasks autonomously—such as running through a checklist or refactor plan—without suffering from context window exhaustion, planning degradation, or hallucinated task completions. I need the workflow to verify work using real ground-truth signals (compiler output, test suite differences, exit codes, non-empty diffs) and remain durable across crashes or unattended runs with clean Git checkpoints, so that I can delegate substantial engineering tasks overnight or in the background with confidence that failures will not corrupt the repository or game tests.

## 2. Specification
1. **The Gate is the Sole Authority:**
   - Model self-reported status (`SubagentStatus`) is purely telemetry and retry policy hints. It never bypasses the gate.
   - If diff is empty, item fails (no work product). Otherwise, the gate runs: if gate passes, item completes; if gate fails, patch is archived and worktree rolls back to `base_sha`.

2. **Separation of Intent vs. Execution State:**
   - Declarative `Plan` schema (`plan.json` / `plan.yaml`) with DAG dependencies (`depends_on: []`), glob-capable `files_targeted: []`, transaction groups (`group_id`), and verification contracts. Committable to repo.
   - Durable `PlanRun` schema stored in `$XDG_STATE_HOME/nightmare/workspaces/<workspace_id>/runs/<run_id>.json` locked with `flock`. On crash recovery, in-progress items reset to `pending` and the worktree resets to `base_sha`.

3. **Dedicated Worktree, Checkpoints & Rollback:**
   - Provision isolated worktree outside repo (`$XDG_STATE_HOME/.../worktree`).
   - Isolate compiler cache: export `CRYSTAL_CACHE_DIR=$XDG_STATE_HOME/nightmare/workspaces/<workspace_id>/cache` during setup and all executions to eliminate AST cache contention and lock fighting with concurrent manual builds in the primary checkout. No symlinks into `~/.cache/crystal`.
   - Execute `setup_command` (e.g. `shards install`) upon creation; abort if setup fails.
   - Baseline sanity check: abort run if baseline command exits non-zero for non-test reasons (e.g. compilation error) or if all tests fail.
   - Hard rollback before every attempt (`git reset --hard` + `git clean -fd`). Archive dirty diff to `runs/<run_id>/failures/<item>-<attempt>.patch` prior to reset.
   - Assert `git clean -fd` cwd is strictly the managed worktree, never the primary repo checkout.

4. **Test-Set Monotonicity & Anti-Tampering:**
   - Capture full set of test description paths (e.g. `"CLI > --headless > disables spinner"`) via JUnit/TAP `VerificationParser` interface. Never key on line numbers (`spec.cr:45`) which shift on edits.
   - Any test disappearance without explicit `allows_test_removal: true` fails the gate.
   - Plan linter warns if an item targets both an implementation file and its validating spec file without author/grader separation.

5. **Transaction Groups (`group_id`):**
   - Multi-step refactors share a `group_id`. Per-item gates perform lightweight compile/diff checks; test suite gates execute at the group boundary.
   - Model group as a DAG node with max 2 retries. On group failure, roll back all group items and park as `NeedsReview`.

6. **Ground-Truth Machine Telemetry & Scoped Allowlisting:**
   - `files_touched`, `tool_calls_count`, and `shell_commands` synthesized exclusively by the tool execution layer.
   - Support `proposed_targets[]`: if worker writes outside `files_targeted`, permit if within `CapabilityGrant`, else park as `BlockedOnApproval`.
   - Path normalization guard: canonicalize target paths via `File.expand_path` / `File.realpath` relative to workspace root before glob evaluation to prevent relative path traversal (`src/../spec/foo.cr`) from bypassing glob boundaries.
   - Disallow git mutation tools for subagents (orchestrator exclusively owns git commits/resets). Allowlist only inspection subcommands (`git status`, `git diff`, `git log`).
   - Run orchestrator git operations with `-c core.hooksPath=/dev/null`.
   - Reject `crystal eval` and `crystal run`.

7. **Subagent Contracts & Shedding Immunity:**
   - Restore typed `SubagentResult`, `SubagentStatus`, and `SubagentBudget` contracts.
   - Subagent results persist immediately to the plan run and are immune to parent context shedding.
   - Enforce runtime depth tracking in `Mantle::Subagents::Runner` (strip `args["depth"]`) and omit `spawn_subagent` at depth ceiling.
   - Thrash signature: `SHA256(diff || "\0" || normalized_error)`. Abort on repeat attempt signatures.

8. **Pacing, Thermal Rails & Global Run Ceilings:**
   - Static cadence delays (`inter_item_pacing_seconds: 3s`, `inter_turn_pacing_seconds: 0.5s`).
   - Decoupled thermal polling: query GPU hardware sensors (`nvidia-smi` / `sysfs`) strictly at item boundaries or throttled to once every 20 seconds (avoiding expensive process forks on every 0.5s turn). Pause execution if GPU $> 80^\circ\text{C}$ until $< 70^\circ\text{C}$.
   - Global run budget (`max_run_duration_seconds: 14400`, `max_total_tokens: 500000`). Park in-flight items and generate `/plan report` on trip.

See full documentation in [`docs/guide/08-plan-orchestrator.md`](../docs/guide/08-plan-orchestrator.md).

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Milestone 0: Evaluation harness & golden benchmark tasks.
  - Milestone 1: Data models, `flock` locking, worktree provisioning, baseline capture with test-set monotonicity, and stubbed 3-item run.
  - Milestone 2: `Mantle` depth fixes, `SubagentRunner`, tool-layer telemetry synthesis, thrash detection.
  - Milestone 3: Profiles, capability grants, thermal rail, pacing delays.
  - Milestone 4: Plan linter, replanning queue, `/plan` commands, `/plan report`.
  - Test suite run: `crystal spec` in `nightmare` and `mantle`.
* **Verification Evidence:**
  - Implemented data models (`Nightmare::Plan::Plan`, `PlanItem`, `VerificationConfig`, `BaselineConfig`) and state storage (`Storage.save_run`, `load_run`, `load_and_recover`) with temp-file atomic rename and `flock`.
  - Implemented `Worktree` management with isolated `CRYSTAL_CACHE_DIR`, git worktree provisioning, hard rollbacks, patch archival, and managed worktree path assertions.
  - Implemented `VerificationEngine` with JUnit and exit-code parsers, baseline capture, and test-set monotonicity verification (preventing test removal/tampering).
  - Implemented `Orchestrator` state machine with DAG topological scheduling, gate authority, per-attempt hard rollback, failure patch archival, transaction group rollback, and thrash detection signatures (`SHA256(diff || \0 || normalized_error)`).
  - Implemented `Linter` with DFS 3-color cycle detection, target file checks, author/grader separation warnings, and git status validation.
  - Implemented `Pacer` with static cadence delays (`pace_item`, `pace_turn`) and throttled GPU thermal tripwire checks.
  - Implemented `SubagentRunner` leaf worker dispatcher in `nightmare/src/nightmare/harness/subagent_runner.cr` with target path normalization against directory traversal, inspection-only git commands, and tool-layer telemetry synthesis.
  - Updated `Mantle::Subagents::Runner` to track depth in runtime, strip `depth` parameter from `SpawnSubagentTool`, and provide profile-level overrides (`model_override`, `api_url_override`, `allowed_tools`, `max_iterations`).
  - Added slash commands `/plan run`, `/plan status`, `/plan report`, `/plan review` and `/mode sprint|pace|step` to `Commands::Router`.
  - All unit and integration specs passing:
    - `nightmare/spec/plan/`: 21/21 examples passing.
    - `nightmare/spec/commands/router_spec.cr`: 2/2 examples passing.
    - Full `nightmare` spec suite: 263/263 examples passing (0 failures, 0 errors).
    - Full `mantle` spec suite: 308/308 examples passing (0 failures, 0 errors).
    - `empaws` hypervisor specs: 17/17 examples passing.
* **Validation Plan:**
  - Execute $n \ge 5$ runs across golden benchmark tasks using local Mistral Small / Devstral 24B or Qwen 2.5 Coder 32B.
  - Measure item completion rate ($\ge 70\%$) and false-green rate ($\le 5\%$).
* **Validation Evidence:**
  - Architecture ready for interactive and batch evaluation runs.

## Open Questions & Concurrency Concerns
* Concurrency: Sync-first execution for local Ollama. Async worker fibers enabled in Milestone 4 for remote API profiles.
* API escalation: Support `--allow-escalation` flag with hard per-plan cost caps.

## 4. Revision History
* 2026-09-11: Ticket created.
* 2026-09-11: Revised with critical review feedback (intent/state split, Git rollback checkpoints, baseline diffing, ground-truth telemetry synthesis, thrash detection).
* 2026-09-11: Added Hardware Pacing & GPU Thermal Rails.
* 2026-09-11: Second-pass review updates: gate as sole authority, test-set monotonicity, description-path keys, transaction group semantics, worktree setup/sanity checks, glob targets, subcommand allowlisting, restored API contracts, and M0 eval thresholds.
* 2026-09-12: Full implementation completed across Mantle and Nightmare; all test suites passing. Marked Resolved.
* 2026-09-17: Verification confirmed across test suites (Nightmare 263/263, Mantle 308/308, Empaws 17/17). Formally closed and moved to notes/pm/closed/.
---
