---
ID: TKT-022
Title: Degenerate Loop History Salvage and /recover Session Restoration
Status: Closed
Priority: High
---

## 1. User Need
When an autonomous agent runs into a degenerate loop (such as repeatedly invoking the same inspection tool without progress), the harness's circuit breaker trips (`ERR_DEGENERATE_LOOP`) and halts turn execution. Currently, the active turn remains uncommitted in `SlidingStore`. When the user enters their next input (e.g. asking "Do you know what you were working on?"), `SlidingStore#start_turn` unconditionally replaces the active turn, completely discarding all intermediate progress, subagent investigations, and error diagnostics from the LLM-visible context. Furthermore, Ollama's KV cache is completely wiped due to the abrupt drop in prompt length.

The user needs:
1. **Automated Turn Salvage**: When a degenerate loop or unrecoverable error occurs, the harness must seal the in-flight turn, record open tool failure reasons and a terminal assistant explanation in `transcript.md`, and commit the turn to history so the bot retains full contextual memory of what it attempted and why it failed.
2. **Interactive `/recover` Slash Command**: A user-facing command to inspect recent failure dumps in `.nightmare/failures/` and restore context into an active session on demand (e.g., following a crash, session restart, or `/clear`).

## 2. Root Cause Analysis
1. `StepRunner#process_step_result` only commits turns and records transcript entries on `result.ok?`. When `handle_loop_circuit_breaker` is executed, it dumps a failure JSON to `.nightmare/failures/` and returns `TurnOutcome.failure(...)` without calling `store.commit_turn` or recording to transcript.
2. Unpaired tool calls: If the loop detector trips in middleware, the assistant message contains a `tool_call` that was never given a corresponding `tool` result. Calling `store.commit_turn` naively would fail `active.well_formed?`.
3. `SlidingStore#start_turn` replaces `@active_turn = Turn.new(msg)` unconditionally. Any uncommitted turn is discarded into garbage collection.

## 3. Specification & Implementation Plan

### 3.1 Harness Degenerate Loop Salvage (`StepRunner`)
1. In `StepRunner#handle_loop_circuit_breaker`, implement `salvage_circuit_breaker_turn`:
   - Inspect `store.active_turn`.
   - Identify any open tool calls (declared in assistant messages without a subsequent matching tool message).
   - Append synthetic tool messages for each open call:
     `{"error": "ERR_DEGENERATE_LOOP: execution halted due to repeated calls", "refused": true}`
   - Append a terminal assistant message explaining the execution halt:
     `"Execution halted by loop circuit breaker: #{msg}. Repeated call to '#{tool_name}' aborted to prevent context exhaustion."`
   - Record newly appended messages to `@transcript` if active.
   - Run `Context::Shedder.shed_active_turn!` if tokens exceed the shed trigger threshold.
   - Call `store.commit_turn` to store the well-formed turn in `@store.history`.

### 3.2 SlidingStore Resilience (`SlidingStore`)
1. Add `push_turn(turn : Turn) : Nil` ensuring turns are well-formed and applying soft-cap eviction.
2. In `start_turn`, if `@active_turn` exists, has more than 1 message (i.e. contains work), and was not committed, automatically seal and push it before initializing the new turn.

### 3.3 Slash Command (`Router#handle_recover`)
1. Implement `/recover [list|view|restore] [target]`:
   - `/recover` or `/recover list`: Lists recent failure dumps from `.nightmare/failures/` with index, date/time, tool, iterations, and tokens.
   - `/recover view <index|filename>`: Displays user prompt, key actions, and error info.
   - `/recover restore <index|filename>`: Parses the dump JSON, reconstructs a well-formed `Turn`, applies shedding, and calls `store.push_turn(turn)`.

## 4. Verification & Validation (V&V)

* **Verification Plan:**
  - Add unit specs in `spec/loop_circuit_breaker_spec.cr` verifying:
    - On degenerate loop tripping, `store.history.size` increases by 1.
    - The committed turn is `well_formed?`.
    - Terminal assistant message contains loop explanation.
    - Subsequent turn via `store.start_turn` retains prior turn in assembled messages.
  - Add unit specs in `spec/commands/router_spec.cr` verifying:
    - `/recover` lists failure dumps.
    - `/recover restore` restores a dump into `store.history` and `/review` reflects the restored turn.
  - Run `crystal spec spec/loop_circuit_breaker_spec.cr spec/commands/router_spec.cr`.

* **Verification Evidence:**
  - `spec/loop_circuit_breaker_spec.cr`: Passed 4 examples in 2.07ms (all assertions passed, verified history retention and well-formedness).
  - `spec/commands/router_spec.cr`: Passed 15 examples in 19.54ms (verified `/recover`, `/recover list`, `/recover view`, and `/recover restore`).
  - Full test suite `crystal spec`: 282 examples, 0 failures, 0 errors, 0 pending in 10.81s.

## 5. Revision History
* 2026-09-25: Created ticket following user request for in-context failure logging and `/recover` command.
* 2026-09-25: Implemented in-harness history salvage, `SlidingStore#push_turn`, `start_turn` uncommitted salvage, and `/recover` command suite. Verified with full test suite and closed ticket.
---
