---
ID: TKT-006
Title: Fix Well-Formed Turn Invariant Assertion During Format-Correction Retries
Status: Closed
Priority: High
---

## 1. User Need
Users and execution agents need the NIGHTMARE harness to run robustly through mid-turn format recovery without crashing. When an LLM produces a malformed output (such as empty content/tool calls or unparseable JSON), the harness executes a format-correction retry prompt. The completed turn must be successfully committed to context history rather than crashing the session with a false-positive invariant violation.

## 2. Specification & Root Cause Analysis

### Incident Report
- Workspace: `pm-826c2491` (`~/.local/state/nightmare/workspaces/pm-826c2491/`)
- Error: `Fatal Error: Cannot commit malformed turn: unpaired tool calls or results`
- Trigger: Occurred at the conclusion of turn sequence `d1e96750-d3cb-4336-8aa5-469f8611b045` upon committing to `SlidingStore`.

### Root Cause Investigation
1. In call #19 of sequence `d1e96750-d3cb-4336-8aa5-469f8611b045` (`llm_calls.jsonl`), local inference with `gemma4:26b` returned thinking tokens without content or tool calls before stream completion.
2. `Mantle::Step#run` classified this completion as `Mantle::StepError::MalformedOutput`.
3. `Nightmare::Harness::StepRunner#run_turn_attempt` intercepted `MalformedOutput` with retries remaining and injected a format-correction prompt into the active turn:
   ```crystal
   act.messages << Mantle::Message.new("user", "The previous response had malformed output or arguments. Please reformat and proceed.")
   ```
4. The retried step completed successfully, executing tool calls `call_s19xb3y5` and `call_y5p9ucos`, followed by the final assistant text.
5. In `StepRunner#process_step_result`, `store.commit_turn` invoked `active.well_formed?`.
6. In `Nightmare::Context::Turn#well_formed?`:
   ```crystal
   @messages.each_with_index do |msg, idx|
     next if idx == 0
     case msg.role
     when "assistant"
       ...
     when "tool"
       ...
     else
       return false
     end
   end
   ```
   At the index of the format-correction prompt, `msg.role` was `"user"`. Since only `"assistant"` and `"tool"` roles were permitted for `idx > 0`, `well_formed?` evaluated to `false`, raising `Nightmare::Error.new("Cannot commit malformed turn: unpaired tool calls or results")`, even though all tool calls and results across the turn were properly paired.

### Corrective Actions
1. **`src/nightmare/context/turn.cr`**:
   - Added `when "user"` in `Turn#well_formed?`.
   - Permitted in-turn user messages as long as no tool calls are pending (`return false unless open_calls.empty?`).
   - If a user message interrupts an unfulfilled tool call, it remains strictly rejected as malformed.
2. **`spec/turn_spec.cr`**:
   - Added unit spec asserting that turns containing in-turn format-correction user messages are considered well formed when calls are paired.
   - Added unit spec verifying that an in-turn user message occurring while a tool call is still pending is rejected.
3. **`spec/harness_spec.cr`**:
   - Added end-to-end integration spec verifying that `StepRunner` recovering from `MalformedOutput` via format correction cleanly commits the turn into history with `store.well_formed? == true`.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Run turn and harness specs: `crystal spec spec/turn_spec.cr spec/harness_spec.cr`
  - Run full test suite: `crystal spec`
  - Build `bin/nightmare` using `shards build`
* **Verification Evidence:**
  - `crystal spec spec/turn_spec.cr spec/harness_spec.cr`: 17 examples, 0 failures, 0 errors, 0 pending (1.65ms).
  - `crystal spec`: 214 examples, 0 failures, 0 errors, 0 pending (1.85s).
  - `shards build`: Successfully compiled `bin/nightmare`.
* **Validation Plan:**
  - Verify that the message sequence from crash `pm-826c2491` satisfies the well-formed invariant and commits cleanly.
* **Validation Evidence:**
  - Verified against sequence `d1e96750-d3cb-4336-8aa5-469f8611b045` containing 5 paired tool exchanges and 1 mid-turn format-correction prompt; `well_formed?` evaluates to `true` and the turn commits without error.

## Open Questions & Concurrency Concerns
* None. Tool call / result pair integrity is preserved; the invariant now accurately differentiates between unfulfilled tool calls vs. non-tool format prompts.

## 4. Revision History
* 2026-09-17: Ticket created following crash investigation in workspace `pm-826c2491`. Root cause identified in `Turn#well_formed?`, corrective patch applied to `turn.cr`, regression specs added, verified against full suite and binary build, ticket closed.
---
