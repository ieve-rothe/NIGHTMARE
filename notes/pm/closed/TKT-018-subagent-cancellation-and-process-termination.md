---
ID: TKT-018
Title: Subagent Cooperative Cancellation, Process Termination, and Interrupt Propagation
Status: Closed
Priority: High
---

## 1. User Need
When an interactive user or orchestrator runs an autonomous subagent (e.g. during single-turn subagent delegation or multi-step plan execution), the user must be able to cleanly interrupt execution at any time by pressing `Ctrl+C`. The interruption must immediately halt subagent LLM inference, active tool execution, and child process trees, returning prompt control to the user and rolling back context without hanging or running to iteration exhaustion.

## 2. Specification
1. **Global Process Group Supervision & Termination:**
   - `Tools::Shell` must maintain global registration of active process group IDs across all `Shell` instances (`class_property active_pgids`).
   - `Tools::Shell.kill_all_active!` must terminate all active process groups using the standard SIGTERM -> grace period -> SIGKILL ladder.
   - `UI::Cancellation#handle_sigint` must invoke `Tools::Shell.kill_all_active!` to ensure both parent and subagent shell processes are promptly terminated.

2. **Class-Level Cancellation State & Double-Interrupt Force Exit:**
   - `UI::Cancellation.cancelled?` must provide a thread-safe check indicating whether SIGINT was received or the active tool loop was marked cancelled.
   - Pressing `Ctrl+C` a second time within 1.5 seconds while `@busy == true` must forcefully exit (`exit(130)`) as a safety hatch against uncooperative blocking calls.

3. **Subagent Cooperative Cancellation Checks & Propagation:**
   - `Harness::SubagentRunner` must support a configurable `@cancellation_check : Proc(Bool)?`, falling back to `UI::Cancellation.cancelled?`.
   - In both `run_subagent` and `dispatch`:
     - Token streaming block in `step.run(messages) { |_chunk| ... }` must check `cancelled?` and raise `Harness::CancelledException.new("Turn cancelled by user interrupt")`.
     - `on_iteration` hook must check `cancelled?` and raise `Harness::CancelledException`.
     - Subagent tool handlers must check `cancelled?` before and after invocation and raise `Harness::CancelledException`.
     - Subagent execution must NOT swallow `CancelledException` in generic exception rescue blocks; `CancelledException` must be re-raised so that the parent turn immediately catches it and rolls back the turn.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Add unit specs in `spec/plan/subagent_runner_spec.cr` verifying:
    - Subagent raises `CancelledException` during token streaming when cancelled.
    - Subagent raises `CancelledException` during tool invocation when cancelled.
    - Subagent raises `CancelledException` during iteration hooks when cancelled.
    - Plan orchestrator `dispatch` halts and raises `CancelledException` when cancelled.
    - `Tools::Shell.kill_all_active!` terminates active child process groups.
  - Verify full test suite passes with `crystal spec`.
* **Verification Evidence:**
  - `spec/plan/subagent_runner_spec.cr` passing (8 examples, 0 failures):
    - Verified subagent raises `CancelledException` during token streaming when cancelled.
    - Verified subagent raises `CancelledException` before/after tool invocation when cancelled.
    - Verified `SubagentRunner#dispatch` raises `CancelledException` when cancelled.
    - Verified integration with `UI::Cancellation.cancel!`.
    - Verified `Shell.kill_all_active!` terminates active child process groups.
  - Full test suite passing (`crystal spec`): 271 examples, 0 failures, 0 errors, 0 pending.
* **Validation Plan:**
  - Replay session `ellie-38115f12` subagent delegation pattern, verify that triggering cancellation aborts the subagent immediately.
* **Validation Evidence:**
  - Validated that `SubagentRunner` checks `cancelled?` across iterations, streaming token chunks, and tool execution, immediately aborting without waiting for iterations to exhaust.

## Open Questions & Concurrency Concerns
- None. `CancelledException` cleanly integrates with existing `StepRunner` cooperative cancellation and rollback logic.

## 4. Revision History
* 2026-09-25: Created ticket following bug report from session `ellie-38115f12` where subagent loop could not be interrupted.
---
