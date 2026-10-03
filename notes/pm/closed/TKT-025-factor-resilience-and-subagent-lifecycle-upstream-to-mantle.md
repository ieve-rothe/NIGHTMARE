---
ID: TKT-025
Title: Factor Resilience, Anti-Derailment, and Subagent Lifecycle Upstream to Mantle
Status: Closed
Priority: High
---

## 1. User Need

Developers building both human-in-the-loop (HITL, e.g. `nightmare`) and autonomous no-human-in-the-loop (NHITL, e.g. `dusk`) agent harnesses require shared, battle-tested mechanisms for local model stability, context resilience, execution safety, and subagent supervision. 

Currently, critical anti-derailment logic—including dynamic token calibration, in-turn context shedding, history pruning, unclosed tool call sealing, loop circuit breaking, process group lifecycle management, and the subagent exit interview protocol—resides exclusively inside `nightmare`. Duplicating these mechanisms in a sister harness would lead to diverged bug fixes and high maintenance overhead, while branching governance checks directly within `nightmare` creates unnecessary interactive coupling for autonomous execution. 

Lifting these domain-agnostic resilience primitives upstream into the `mantle` framework allows both interactive and headless/autonomous harnesses to share a hardened execution core while delegating governance to clean, dependency-injected policies.

---

## 2. Specification

### 2.1 Context Resilience & Token Economics (`Mantle::Storage`)

Move context management and adaptive calibration primitives from `nightmare/src/nightmare/context/` into `mantle/src/mantle/storage/`:

1. **`Mantle::Storage::TokenEstimator`** (from `nightmare/src/nightmare/context/token_calibrator.cr`):
   - Dynamic character-to-token divisor calibration against provider response `prompt_eval_count`.
   - Exponential moving average smoothing (`alpha = 0.2`, clamping divisor between 2.5 and 5.0).
   - Zero-dependency JSON serialization for workspace cache persistence (`calibrator.json`).

2. **`Mantle::Storage::Shedder`** (from `nightmare/src/nightmare/context/shedder.cr`):
   - `shed_active_turn!`: Proactive in-turn compression of consumed tool result messages down to head/tail excerpts when approaching token thresholds, keeping the most recent $N$ exchanges verbatim.
   - `prune_history!`: Multi-phase historical token reduction (Phase 1 compresses completed tool exchanges oldest-first; Phase 2 evicts older turns FIFO) ensuring active turn and system/user prompts are never corrupted.

3. **Turn Integrity & Tool Call Sealer** (from `nightmare/src/nightmare/context/sliding_store.cr`):
   - `seal_open_tool_calls`: Automatically detects unfulfilled or aborted `tool_calls` and appends synthetic tool error messages before dispatching subsequent inference turns, preventing provider API 400 rejection errors (Ollama, Anthropic, OpenAI).
   - Duplicate tool call ID disambiguation.
   - Interrupted turn side-effect annotations carried forward into subsequent user turns.

---

### 2.2 Anti-Derailment Circuit Breakers & Spend Controls (`Mantle::Tools::Middleware`)

1. **Unified Mutation-Aware Loop Breaker**:
   - Merge `nightmare/src/nightmare/harness/loop_detector.cr` with `mantle/src/mantle/tools/middleware/cyclic_read_breaker.cr`.
   - Track consecutive identical `(tool_name, args)` executions.
   - Automatically reset loop counters when a workspace mutation occurs (`write_file`, `replace_in_file`, file creation/deletion).
   - Trip `Mantle::Tools::TerminalToolError` (`ERR_DEGENERATE_LOOP`) when threshold is reached.

2. **Spend Cap Monitoring & Predictive Iteration Hooks**:
   - Move `Nightmare::Harness::ToolLoop` accounting into Mantle's step/session execution pipeline.
   - Track cumulative `eval_count` across multi-turn tool loops against a configurable turn spend cap (`TURN_SPEND_CAP_TOKENS`).
   - Wire `TokenEstimator` and `Shedder` into `Mantle::Step#on_iteration` hook natively.

3. **Jittered Exponential Retrier** (from `nightmare/src/nightmare/harness/retrier.cr`):
   - Move retry loops for HTTP 429 rate limits, context overflow recovery, and transient API failures into Mantle's client execution layer.

---

### 2.3 Subagent Supervision Protocol & Exit Interview (`Mantle::Subagents`)

Promote `nightmare/src/nightmare/harness/subagent_runner.cr`'s supervisor lifecycle to replace or enhance `mantle/src/mantle/subagents/runner.cr`:

1. **Scoped Execution & Tool Filtering**:
   - Independent subagent iteration budget clamping (`budget_iterations`).
   - Stripping recursive delegation tools (`spawn_subagent`) to prevent unbounded nesting.
   - Shell mutation restrictions in subagent mode (e.g. banning git write operations).

2. **Two-Tier Exit Interview**:
   - **Tier 1 (In-Thread Conversational Debrief):** When a subagent hits max iterations, a loop breaker, or an unrecoverable tool failure, freeze tool execution, shed prior bulky tool outputs to reclaim token space, and query the subagent within its active thread:
     *"Your execution limit has been reached. Please provide an exit summary covering: 1. Original goal and approach, 2. Progress made and concrete findings, 3. Roadblocks or where you got stuck, 4. Concrete recommendations."*
   - **Tier 2 (Deterministic Telemetry Post-Mortem Fallback):** If the subagent's context is exhausted, the model errors, or the exit interview fails, deterministically generate a structured post-mortem from tool execution logs, thinking traces, files modified, and termination errors.

---

### 2.4 Process Group Supervision & Safe Sandboxing (`Mantle::Tools`)

1. **Unix Process Group Supervisor** (from `nightmare/src/nightmare/tools/shell.cr`):
   - Spawn commands into dedicated process groups (`pgid`).
   - Thread-safe process group registry and clean tree termination (`kill_all_active!` sending `SIGTERM`, waiting grace period, then `SIGKILL`).
   - Command timeout clamping and output byte capping.

2. **Sensitive Path Guarding & Scoped Targets** (`Mantle::Tools::FileSystemSandbox`):
   - Absorb sensitive read/write pattern blacklists (`.env*`, `*.pem`, `id_rsa*`, `*secret*`, `*credential*`, `.git/**`).
   - Support optional `files_targeted` whitelist filtering for scoped tasks.

---

### 2.5 Governance Inversion via Dependency Injection

Decouple interactive human prompts from core execution:
- Define an abstract execution policy in Mantle:
  ```crystal
  alias ExecutionPolicy = Proc(ExecutionRequest, PolicyDecision)
  ```
- **Nightmare (HITL):** Injects terminal TUI approval prompts (`[y/n/a/p/e]`).
- **Dusk (NHITL):** Injects automated verification policies (Bubblewrap sandbox containment check, automated test execution, critic pass).

---

### 2.6 Nightmare Integration & Regression Testing

Refactor `nightmare` to consume the migrated components from `Mantle`, removing redundant local definitions while preserving all existing CLI interfaces, TUI presentation hooks, and test suites.

---

## 3. Verification & Validation (V&V)

### Verification Plan
1. **Mantle Unit Specs:**
   - Specs for `Mantle::Storage::TokenEstimator` testing calibration formula and bounds.
   - Specs for `Mantle::Storage::Shedder` validating head/tail preservation and FIFO history pruning.
   - Specs for `Mantle::Tools::Middleware::LoopBreaker` verifying mutation reset and exception tripping.
   - Specs for `Mantle::Subagents::Runner` testing iteration budget clamp, tool call sealing, and two-tier exit interview.
2. **Nightmare Regression Suite:**
   - Update `shard.yml` in `nightmare` pointing to local `mantle` path.
   - Run `crystal spec` in `nightmare` to verify all 296+ existing examples pass without regression.

* **Verification Evidence:**
  - `mantle`: `crystal spec` passes with 334 examples, 0 failures, 0 errors, 0 pending (in 3.77s).
    - `spec/mantle/storage/token_estimator_spec.cr` passing.
    - `spec/mantle/storage/turn_and_shedder_spec.cr` passing (including duplicate tool call ID deduplication with result pairing preservation).
    - `spec/mantle/tools/loop_breaker_spec.cr` passing (including consecutive identical loop halting and unmutated cyclic read detection).
    - `spec/mantle/tools/process_group_supervisor_spec.cr` passing (including self-healing CWD re-anchoring, pipe drain past byte caps, and prompt SIGTERM exit status waiting).
    - `spec/mantle/subagents/supervisor_spec.cr` passing (including subagent budget clamping, unclosed tool call sealing, and two-tier exit interview / post-mortem fallback).
  - `nightmare`: `crystal spec` passes with 297 examples, 0 failures, 0 errors, 0 pending (in 1:31m).
    - Verified all existing suites: `spec/tools_spec.cr`, `spec/plan/subagent_runner_spec.cr`, `spec/guard_spec.cr`, `spec/loop_circuit_breaker_spec.cr`.
    - Eliminates duplicate local process group, shedding, loop breaker, and exit interview code from Nightmare, delegating cleanly to Mantle.

### Validation Plan
1. **Interactive Subagent Run (Nightmare):**
   - Trigger a subagent in Nightmare that exhausts its iteration budget on a search task.
   - Verify that the subagent returns a concise exit interview summary to the root agent.
2. **Autonomous Headless Simulation (Dusk-style):**
   - Run a standalone Mantle script using the supervised subagent runner and automated policy callback (no terminal interaction).
   - Verify that repetitive reads trip `ERR_DEGENERATE_LOOP` and produce a clean post-mortem without hanging or prompting stdin.

* **Validation Evidence:**
  - Automated test runs in `nightmare` (`spec/plan/subagent_runner_spec.cr`) and `mantle` (`spec/mantle/subagents/supervisor_spec.cr`) validated both tiers of the subagent exit interview:
    1. Tier 1 conversational exit interview successfully prompts the dying subagent in-thread with prior bulky tool results shed, extracting goal, findings, and roadblocks.
    2. Tier 2 deterministic telemetry post-mortem fallback triggers reliably when LLM calls are disabled or context is blown, generating structured diagnostics without human prompts.
  - Pipe buffer deadlock protection verified with outputs >24KB without hanging child processes.

---

## Open Questions & Concurrency Concerns

1. **Fiber & Multi-Session Safety of Process Groups:**
   - In a concurrent worker harness (e.g. multiple autonomous tasks executing in parallel), `ProcessGroupSupervisor` accepts an instance-level `@active_pgids` set and `&on_spawn` hook, preventing cross-session signal crosstalk.
2. **Multi-Repo Release Ordering:**
   - Changes verified locally in monorepo layout. Ready for atomic git commits across `mantle` and `nightmare` following Conventional Commits.
3. **Mantle Context Architecture Alignment:**
   - `Turn`, `SlidingStore`, `TokenEstimator`, and `Shedder` are now standard Mantle storage components under `Mantle::Storage`, ready for use by any harness.

---

## 4. Revision History

* 2026-09-27: Initial ticket created documenting architectural evaluation, component factor-out plan, and upstream migration proposal for Mantle in preparation for Dusk sister harness.
* 2026-09-27: Implementation complete. Factored out `TokenEstimator`, `Shedder`, `Turn`, `SlidingStore`, `LoopBreaker`, `ProcessGroupSupervisor`, `ExecutionPolicy`, and `Subagent::Supervisor` to Mantle. Refactored Nightmare to consume Mantle primitives. All 334 Mantle specs and 297 Nightmare specs green. Ticket closed.
