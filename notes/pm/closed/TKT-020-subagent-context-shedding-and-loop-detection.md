---
ID: TKT-020
Title: Subagent Context Resilience — In-Turn Shedding, Loop Detection, and Context Protection
Status: Closed
Priority: High
---

## 1. User Need
Currently, subagents dispatched via `spawn_subagent` or via the Plan Orchestrator (`SubagentRunner#dispatch`) execute on a bare `Mantle::Step` with an unmanaged `Array(Mantle::Message)`. They lack in-turn token shedding, dynamic token estimation, tool loop circuit breaking, and context overflow recovery.

When a subagent performs intensive inspection across multiple files or shell commands, the unmanaged working buffer accumulates tokens indefinitely. Because context does not automatically slide or shed, subagents inevitably exceed provider context windows (or local model token budgets, e.g. 12k/16k/32k), crashing with an unhandled `StepError::ClientFailure` (HTTP 400 Context Length Exceeded). Subagents should be full peers to root agents in operational resilience—depth-limited, but equipped with in-turn context shedding, loop detection, and token protection.

## 2. Specification
1. **Isolated Subagent Context Store (`SlidingStore` + `ToolLoop`)**:
   - In `Nightmare::Harness::SubagentRunner` (`dispatch` and `run_subagent`), create an isolated single-turn `Context::SlidingStore` and `Context::TokenEstimator`.
   - Initialize `active_turn` in the subagent store with the initial user prompt so that intermediate tool calls and responses form a valid `Turn` with `ToolExchange` objects.
2. **In-Turn Shedding Integration**:
   - Integrate `Nightmare::Harness::ToolLoop` into the subagent's `on_iteration` hook.
   - As tool results are appended, invoke `ToolLoop#handle_iteration` to synchronize `working_messages` with `active_turn`, calibrate token estimates, and trigger `Context::Shedder.shed_active_turn!` when token count exceeds `trigger_ratio * hardmax`.
   - Ensure older consumed tool outputs (like `read_file` and `run_command`) are compressed according to `Config::SHED_FILE_KEEP_CHARS` and `Config::SHED_SHELL_KEEP_CHARS` while preserving recent verbatim calls (`Config::SHED_KEEP_VERBATIM = 2`).
3. **Loop Detection & Circuit Breaker**:
   - Equip subagent registries with `ToolMiddleware::LoopDetector` backed by an instance of `Nightmare::Harness::LoopDetector`.
   - Catch `LoopCircuitBreakerException` inside subagent step execution to cleanly terminate degenerate repetitive loops rather than burning iterations or tokens.
4. **Context Overflow & Exception Handling**:
   - Catch provider context overflow errors (`context_length_exceeded` / `Mantle::Clients::APIError` with `context_overflow?`) in subagent execution, performing emergency shedding and retrying up to `Config::CONTEXT_OVERFLOW_RETRIES` turns.
   - Enforce `Config::TURN_SPEND_CAP_TOKENS` within the subagent turn loop.
5. **Telemetry & Cancellation Preservation**:
   - Preserve existing UI telemetry updates (`SubagentTelemetry`), pacing (`Pacer#pace_turn`), and cooperative cancellation checks (`CancelledException`) across all iteration and tool execution hooks.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Add unit specs in `spec/plan/subagent_runner_spec.cr` verifying:
    - Subagent triggers in-turn shedding when accumulating large tool results (e.g. repeated `read_file` calls exceeding threshold).
    - Subagent trips loop circuit breaker when calling identical tools consecutively.
    - Subagent recovers or gracefully handles context overflow.
    - Subagent enforces turn spend cap.
    - Subagent results and side-effects remain consistent and correctly reported to caller.
  - Run full test suite `crystal spec` in `nightmare`.
* **Verification Evidence:**
  - `crystal spec spec/plan/subagent_runner_spec.cr`: 13 examples, 0 failures, 0 errors, 0 pending.
  - `crystal spec spec/shedder_and_store_spec.cr spec/tool_conditioned_shedding_spec.cr spec/loop_circuit_breaker_spec.cr`: 14 examples, 0 failures, 0 errors, 0 pending.
  - Full suite `crystal spec`: 276 examples, 0 failures, 0 errors, 0 pending.
* **Validation Plan:**
  - Simulate a subagent reading multiple large files totaling >15,000 tokens (surpassing `TOKEN_HARDMAX = 12_000`) and verify that in-turn shedding keeps the subagent operating without hitting context limit rejections.
* **Validation Evidence:**
  - Verified via `spec/plan/subagent_runner_spec.cr` that sequential file reads automatically compress earlier consumed tool exchanges (keeping the head and appending truncation notices) while preserving recent verbatim exchanges, successfully completing the turn without hitting context limit rejections.

## 4. Revision History
* 2026-09-25: Created ticket following evaluation of subagent context behavior and alignment with peer-agent con-ops. Implemented isolated SlidingStore + ToolLoop, LoopDetector middleware, spend cap enforcement, and emergency context overflow recovery in SubagentRunner. Verified with unit specs and full test suite; closed ticket.
---
