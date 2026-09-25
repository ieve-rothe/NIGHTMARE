---
ID: TKT-015
Title: Refine LoopDetector to Track Consecutive Repetition and Invalidate on Workspace Mutation
Status: Closed
Priority: High
---

## 1. User Need
Autonomous agents iterating on software tasks need to perform cyclic edit-test workflows (e.g., compiling code, reviewing errors, editing source files, and re-compiling) without the harness falsely aborting execution. When an agent is actively modifying files and reacting to changing tool outputs, the execution harness must not mistake legitimate repeated test/read invocations for an infinite degenerate loop.

## 2. Specification
1. **Consecutive Repetition Tracking:**
   - Change `LoopDetector` from tracking a cumulative per-turn count of `(tool_name, args_json)` across the entire turn to tracking **consecutive** identical invocations.
   - If an invocation differs in `tool_name` or `args_json`, or if an intervening tool call occurs, the consecutive repetition counter for the previous call must reset (or only consecutive identical calls should count towards `threshold`).
2. **Workspace Mutation Invalidation / Reset:**
   - When any workspace-modifying tool (e.g., `write_file`, `replace_in_file`, `append_to_file`) or a mutation-producing shell command successfully executes, reset or invalidate the repetition counters for inspection/verification tools (`run_command`, `read_file`, `search`, etc.).
   - An identical verification command (e.g., `crystal test_compile.cr`, `crystal spec`, `shards build`) executed after an intervening workspace mutation is part of a valid edit-verify feedback loop and must not count toward a degenerate loop threshold.
3. **Output Divergence / Progress Detection (Optional / Diagnostic):**
   - If consecutive calls to `run_command` produce differing outputs (e.g., compiler moving to a new line or different error diagnostic), evaluate whether divergence indicates forward progress.
4. **Preserve True Loop Circuit Breaker:**
   - Retain the hard circuit breaker (`ERR_DEGENERATE_LOOP`) and CAPA telemetry dump in `.nightmare/failures/` when a tool is genuinely called identically and consecutively `threshold` times without progress or workspace changes.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  * Add unit specs in `spec/loop_circuit_breaker_spec.cr` verifying:
    * Consecutive identical tool calls still trip the circuit breaker at `threshold` (e.g., 3 identical `read_file` calls back-to-back).
    * Non-consecutive identical calls interleaved with mutations (e.g., `run_command` -> `replace_in_file` -> `run_command` -> `replace_in_file` -> `run_command`) do not trip `ERR_DEGENERATE_LOOP`.
    * Interleaved distinct tool calls do not trigger false-positive loop halting.
  * Verify existing specs (`spec/harness_spec.cr`, `spec/integration/workflows_spec.cr`) continue to pass.
* **Verification Evidence:**
  * `spec/loop_circuit_breaker_spec.cr` passing (4 examples, 0 failures):
    * Verified consecutive repetition halts at threshold.
    * Verified edit-test cycles (5 consecutive runs of `crystal test_compile.cr` interleaved with `replace_in_file`) execute cleanly without tripping.
    * Verified tool argument changes reset the consecutive counter.
  * Full test suite passing (`crystal spec`): 250 examples, 0 failures, 0 errors, 0 pending.
* **Validation Plan:**
  * Replay the message sequence from `bug_report_files/nightmare-966dd3b5/failures/failure_20260925_041857_894_d9f680a4.json` through the harness and ensure the agent successfully completes the compilation/fix cycle without premature abort.
* **Validation Evidence:**
  * Validated that the sequence of 5 `crystal test_compile.cr` executions separated by `replace_in_file` edits no longer triggers `ERR_DEGENERATE_LOOP`.
  * Verified that back-to-back repeating calls (such as in failure 1 where `replace_in_file` was repeated 5 times consecutively) still reliably trip `ERR_DEGENERATE_LOOP` and halt execution.

## Open Questions & Concurrency Concerns
* None remaining; consecutive repetition tracking addresses both edit-test loops and multi-step diagnostic reads without compromising degenerate loop circuit breaking.

## 4. Revision History
* 2026-09-24: Created ticket following investigation of false-positive loop aborts in session `nightmare-966dd3b5`.
* 2026-09-24: Implemented consecutive tracking in `Nightmare::Harness::LoopDetector`, added specs in `spec/loop_circuit_breaker_spec.cr`, verified full suite passing, and closed ticket.
---
