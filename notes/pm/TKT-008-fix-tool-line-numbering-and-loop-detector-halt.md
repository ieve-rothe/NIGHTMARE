---
ID: TKT-008
Title: Hard Circuit Breaker for Loop Detection, Line-Anchored Mutation Interface, and Tool-Conditioned Shedding
Status: In-Progress
Priority: High
---

## 1. User Needs

* **UN-1: Deterministic Fault Handling ("Lights-Off" Automation)**
  Autonomous agents operating in unattended, lights-off pipelines need system fault conditions (such as infinite tool-call loops) to behave as hard circuit breakers. The harness must immediately terminate the active agent thread, log a deterministic failure code (`ERR_DEGENERATE_LOOP`), persist full postmortem telemetry for asynchronous human review, and allow batch job execution to proceed without hanging or prompting an absent human operator.

* **UN-2: Read/Write Interface Compatibility & Determinism**
  An agent's write tools must be compatible with the output of its read tools. Because `read_file` displays line-numbered output (`   28 | `), the mutation interface must accept deterministic line coordinates (`start_line`, `end_line`) rather than requiring brittle substring matching that leads agents to mistake display formatting for literal file content.

* **UN-3: Unblinded Sensor Telemetry (Tool-Conditioned State Retention)**
  The agent's perceptual state must not be arbitrarily blinded during text inspection or error diagnosis. When context shedding occurs:
  1. Structured file inspection tools (`read_file`) must retain sufficient content (3,000 characters) for the agent to inspect the lines it is modifying.
  2. Command outputs (`run_command`) must retain at least 1,500 characters and specifically preserve the **tail** (the bottom where stack traces, build failures, and assertion errors reside) rather than the head.

* **UN-4: Closed-Loop Diagnostic Control**
  Autonomous agents require an operating policy that supports closed-loop diagnosis. When an edit or tool execution fails, the agent must be permitted and directed to perform diagnostic reads to inspect the discrepancy, rather than being forced into blind speculative mutations by an open-loop execution mandate.

---

## 2. Problem Description & Investigation Findings

### Reference Workspace
* Workspace trace: `/home/cam/.local/state/nightmare/workspaces/pm-826c2491/` (`transcript.md` and `llm_calls.jsonl`).

### Symptoms
* An agent tasked with editing `pm_skill.md` fired identical calls repeatedly until reaching `max_iterations = 25`, looping on `read_file` calls that were repeatedly refused by `LoopDetector`.

### Engineering Analysis of Failure Modes

* **PD-1: LoopDetector Treated Critical Faults as Conversational Data**
  * In `src/nightmare/tools/middleware.cr`, when an identical call occurred 3 times, `LoopDetector` returned `[Refused: identical call repeated 3 times. Change approach or ask the user.]` as in-band tool output.
  * In local models (`gemma4:26b`), feeding a meta-error back into the active context window provoked a degenerate 20-token completion that re-invoked the identical tool call.
  * In lights-off environments, prompting the user or continuing inference during a catastrophic fault violates fail-fast architecture.

* **PD-2: Read/Write Interface Incompatibility**
  * In `src/nightmare/tools/read_only.cr`, `read_file` prepended line numbers: `#{line_num.to_s.rjust(5)} | #{line}`.
  * In `src/nightmare/tools/mutation.cr`, `replace_in_file` required an exact raw substring match (`original.scan(target)`).
  * The agent logically assumed `   28 | ` was part of the file's literal content, causing repeated `{"error":"Target string not found in pm_skill.md"}` errors.

* **PD-3: Blinded Sensor Telemetry via Indiscriminate Context Shedding**
  * `Config::SHED_KEEP_CHARS = 200` unconditionally truncated tool output down to ~4 lines from the head (`[... output truncated: was 1936 bytes]`).
  * In file reads, the agent could not see lines 20–35 of `pm_skill.md`, forcing it to blindly guess markdown syntax, indentation, and backticks.
  * In shell execution, keeping only 200–300 chars from the head cuts off the bottom stack trace and compiler diagnostics where critical error causes are output.

* **PD-4: System Prompt Enforcing Open-Loop Speculative Guessing**
  * `DEFAULT_PERSONA` in `src/nightmare/system_prompt/resolver.cr` mandated: *"Every turn must produce a mutation... A turn that only reads is a failed turn"* and *"replace_in_file fails loudly on a non-matching search string. That is your safety net. Do not spend a read call confirming what the tool will confirm for you."*
  * This prohibited diagnostic reads when mutations failed and pressured the model into rapid speculative guesses, directly triggering the loop detector.

---

## 3. Root Cause Summary
1. **Absence of a Hard Circuit Breaker:** In-band advisory strings were used in place of immediate process termination and deterministic error logging (`ERR_DEGENERATE_LOOP`).
2. **Interface Disconnect:** Write tools lacked line-anchored coordinates (`start_line`, `end_line`), conflicting directly with the line-numbered presentation of `read_file`.
3. **Uniform Context Truncation:** A static 200-char shedding clamp blinded the agent's inspection sensors and severed compiler stack traces.
4. **Open-Loop Prompt Constraints:** Strict "must mutate every turn" rules penalized closed-loop diagnostic recovery.

---

## 4. Proposed Changes & Requirements Traceability

### Change 1: LoopDetector Hard Circuit Breaker & Deterministic Error
* **Mapped Needs & Problems:** `UN-1` | `PD-1`
* **Technical Specification:**
  * In `src/nightmare/tools/middleware.cr`, when repetition threshold (3) is reached, raise `Nightmare::Harness::LoopCircuitBreakerException.new(msg)`.
  * Add `StepErrorKind::DegenerateLoopCircuitBreaker` (`ERR_DEGENERATE_LOOP`) to `src/nightmare/harness/types.cr`.
  * In `src/nightmare/harness/step_runner.cr`, catch `LoopCircuitBreakerException` and return `TurnOutcome.failure` with `ERR_DEGENERATE_LOOP` (non-retryable).
  * Immediately terminate the turn; do not reinvoke inference or prompt the user.

### Change 2: Automated Failure State Dump (CAPA Log)
* **Mapped Needs & Problems:** `UN-1` | `PD-1`
* **Change Reason / Justification:** In unattended lights-off environments, terminating without persisting state destroys the evidence needed for asynchronous debugging. A structured failure dump provides a permanent audit record of the degenerate state.
* **Technical Specification:**
  * When `LoopCircuitBreakerException` is caught, `StepRunner` writes an incident report to `.nightmare/failures/failure_<timestamp>_<sequence_id>.json` containing: timestamp, offending tool name, serialized arguments, full message exchange history, and token metrics.

### Change 3: Line-Anchored Mutation Interface (`start_line`, `end_line`)
* **Mapped Needs & Problems:** `UN-2` | `PD-2`
* **Technical Specification:**
  * Update `replace_in_file` in `src/nightmare/tools/mutation.cr` to accept optional `start_line: Int32?` and `end_line: Int32?`.
  * When `start_line` and `end_line` are provided:
    * Validate `1 <= start_line <= end_line <= total_lines`.
    * Deterministically replace lines `(start_line - 1)...end_line` with `replacement`.
    * Completely bypass substring scanning and regex matching.
  * Update `src/nightmare/tools/registry.cr` parameter schemas to expose `start_line` and `end_line`.

### Change 4: Display-Prefix Stripping Fallback in Substring Matching
* **Mapped Needs & Problems:** `UN-2` | `PD-2`
* **Change Reason / Justification:** Agents or legacy workflows may still invoke `replace_in_file` using pure `target` strings. If an agent copies lines containing `   28 | ` into `target` without specifying `start_line`/`end_line`, an automated fallback match that strips `^\s*\d+\s*\|\s?` prevents an avoidable edit failure while line-anchored adoption propagates.
* **Technical Specification:**
  * In `replace_in_file`, if raw `original.scan(target).size == 0`, check if lines in `target` match `^\s*\d+\s*\|\s?`. If so, strip the prefix from `target` (and `replacement` if present) and retry the scan against `original`.

### Change 5: Tool Schema Display Decoration Clarification
* **Mapped Needs & Problems:** `UN-2` | `PD-2`
* **Change Reason / Justification:** The model's perceptual boundary is defined by tool descriptions. Explicitly documenting that `read_file` output contains visual line numbers prevents models from assuming line numbers are file content.
* **Technical Specification:**
  * Update `read_file` description in `src/nightmare/tools/registry.cr` to state: *"Returns file contents with '<line> | ' prefixes for line referencing. Use these line numbers with replace_in_file's 'start_line' and 'end_line'."*
  * Update `replace_in_file` description to highlight line-anchored replacement.

### Change 6: Tool-Conditioned Context Shedding (`read_file` head vs `run_command` tail)
* **Mapped Needs & Problems:** `UN-3` | `PD-3`
* **Change Reason / Justification:** 300 characters is only a few lines of text; in build or test suite failures, truncating to 300 characters or taking the head eliminates the stack trace, leaving only the header and blinding the agent to the actual error cause. We set `SHED_SHELL_KEEP_CHARS = 1_500` and retain the **tail** (bottom) of shell output, while `read_file` retains 3,000 characters from the head.
* **Technical Specification:**
  * In `src/nightmare/config.cr`:
    * `SHED_SHELL_KEEP_CHARS = 1_500`
    * `SHED_FILE_KEEP_CHARS = 3_000`
  * In `src/nightmare/context/turn.cr` (`ToolExchange#shed!`):
    * If tool is `run_command`: retain the last `1_500` characters (tail):
      `"[... earlier output shed: was #{raw_bytes} bytes]\n#{content[content.size - keep_chars..]}"`.
    * If tool is `read_file`: retain up to `3_000` characters (head):
      `"#{content[0, keep_chars]}\n[... remaining output shed: was #{raw_bytes} bytes]"`.

### Change 7: Closed-Loop System Prompt Alignment
* **Mapped Needs & Problems:** `UN-4` | `PD-4`
* **Technical Specification:**
  * In `src/nightmare/system_prompt/resolver.cr` (`DEFAULT_PERSONA`):
    * Remove *"Every turn must produce a mutation: an edit, a new file, or a command that changes state. A turn that only reads is a failed turn."*
    * Remove *"replace_in_file fails loudly on a non-matching search string. That is your safety net. Do not spend a read call confirming what the tool will confirm for you."*
    * Add closed-loop instructions:
      * *"When modifying files, use line-anchored replacement (`start_line`, `end_line`) referencing line numbers from `read_file`."*
      * *"When an operation fails or produces an unexpected error, execute a diagnostic read to inspect the file state before attempting subsequent edits."*

---

## 5. Requirements Traceability Matrix (RTM)

| Component / Proposed Change | User Need | Problem Description | Change Reason / Technical Justification |
| :--- | :--- | :--- | :--- |
| **Change 1: Hard Circuit Breaker (`ERR_DEGENERATE_LOOP`)** | `UN-1` | `PD-1` | Halts execution immediately on 3rd identical call; stops degenerate token loops in lights-off automation. |
| **Change 2: Failure State Dump (CAPA Report)** | `UN-1` | `PD-1` | Preserves full diagnostic telemetry (call history, arguments, memory snapshot) for asynchronous root cause analysis. |
| **Change 3: Line-Anchored Mutation (`start_line`, `end_line`)** | `UN-2` | `PD-2` | Directly aligns write tool inputs with `read_file`'s line-numbered display, providing deterministic edits. |
| **Change 4: Fallback Prefix Stripping in `replace_in_file`** | `UN-2` | `PD-2` | Backward-compatibility safeguard: strips `   28 \| ` if an agent passes raw decorated text into pure substring replacement. |
| **Change 5: Tool Schema Descriptions** | `UN-2` | `PD-2` | Clarifies perceptual boundaries in tool definitions so LLMs recognize line numbers as coordinates. |
| **Change 6: Tool-Conditioned Context Shedding (Shell Tail / File Head)** | `UN-3` | `PD-3` | Unblinds sensor telemetry: retains 3,000 chars for file reads and 1,500 chars from the **tail** (bottom) for shell commands to preserve stack traces. |
| **Change 7: Closed-Loop System Prompt** | `UN-4` | `PD-4` | Removes conflicting "must mutate" mandate; enables diagnostic reading upon operation failure. |

---

## 6. Verification & Validation (V&V)

* **Verification Results:**
  * `spec/line_anchored_mutation_spec.cr` (9 examples passing):
    * Single-line replacement via `start_line` / `end_line`.
    * Default `end_line = start_line` when only `start_line` provided.
    * Multi-line range replacement.
    * Display-prefix stripping (`   28 | `) in replacement for line-anchored mode.
    * Line coordinate out-of-bounds rejection (`0..1`, `2..1`, `1..5` on 2-line file).
    * Substring fallback prefix stripping for decorated target and replacement.
    * Tool schema exposure of `start_line` / `end_line` in `replace_in_file`.
    * Tool schema documentation of line number gutter in `read_file`.
  * `spec/loop_circuit_breaker_spec.cr` (2 examples passing):
    * `ToolMiddleware::LoopDetector` raises `LoopCircuitBreakerException` on 3rd identical call and sets `tripped?` with recorded tool and arguments.
    * `StepRunner` intercepts circuit breaker, returns non-retryable `StepOutcome.failure` with `ERR_DEGENERATE_LOOP`, and creates full diagnostic JSON dump in `.nightmare/failures/` with serialized arguments, message history, and token metrics.
  * `spec/tool_conditioned_shedding_spec.cr` (3 examples passing):
    * `run_command` retains last 1,500 chars (tail), preserving fatal compiler errors and stack traces.
    * `read_file` retains first 3,000 chars (head).
    * Default/generic tools retain 200 chars (head) with `[... output truncated: was ...]`.
  * Full Nightmare test suite: 228 examples, 0 failures, 0 errors.
  * Full Mantle test suite: 308 examples, 0 failures, 0 errors.

---

## 7. Revision History
* 2026-09-17: Created initial ticket based on workspace `pm-826c2491` investigation.
* 2026-09-17: Updated with lights-off engineering directives (circuit breaker, line-anchored editing, tool-conditioned shedding, prompt alignment).
* 2026-09-17: Added comprehensive Requirements Traceability Matrix (RTM) linking all 7 proposed changes to User Needs (UN-1..4) and Problem Descriptions (PD-1..4) with explicit change justifications.
* 2026-09-17: Updated Change 6: bumped `SHED_SHELL_KEEP_CHARS` to 1,500 characters and specified retaining the **tail** (bottom) of shell output to preserve stack traces. Set status to `In-Progress`.
* 2026-09-17: Completed implementation and automated test verification across `nightmare` and `mantle`. All 228 + 308 tests pass. Status marked `Resolved`.
---
