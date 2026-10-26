---
ID: TKT-036
Title: Resilient Binary and UTF-8 Tool Output Handling Across Mantle, Salamander, and Nightmare
Status: Resolved
Priority: High
---

## 1. User Need
When an LLM agent executes a shell command that outputs raw binary data or malformed UTF-8 byte sequences (e.g., executing `cat $(which chomp)` on a compiled binary executable, inspecting binary assets, or running commands that emit arbitrary byte streams), the execution harness, UI presentation layer, and transcript logging must not crash. The agent and user need:
1. Tool outputs to be safely scrubbed of invalid UTF-8 sequences at the supervisor source so downstream consumers (JSON serializers, string formatters, and regex matchers) never encounter byte validation panics.
2. The UI presentation middleware and terminal rendering primitives (`Salamander::UI::Panel.strip_ansi`) to be defensively isolated so rendering errors never cause an agent step failure.
3. The session transcript (`transcript.md`) to record uncommitted turns and diagnostic failure notices when a step or tool execution terminates abnormally, eliminating "missing turn" blind spots in postmortem debugging.

## 2. Specification

### 2.1 Upstream Source Sanitization in Mantle (`mantle/src/mantle/tools/process_group_supervisor.cr`)
- In `Mantle::Tools::ProcessGroupSupervisor#execute`:
  - When returning the stdout and stderr strings drained from child process pipes, apply Crystal's standard library `String#scrub` (`Char::REPLACEMENT` / `\uFFFD`).
  - Guarantees that all strings produced by process execution satisfy Crystal's UTF-8 string invariants before leaving the process supervisor.

### 2.2 Resilient ANSI Stripping in Salamander (`salamander/src/salamander/ui/panel.cr`)
- In `Salamander::UI::Panel.strip_ansi(str : String)`:
  - Check `str.valid_encoding?` before running regex substitutions. If invalid UTF-8 is detected, scrub the string (`str.scrub`) prior to calling `str.gsub(/\e\[[0-9;]*[a-zA-Z]/, "")`.
  - Also in `Salamander::UI::MarkdownFormatter.format(text : String)`, scrub input if `!text.valid_encoding?` before applying regex patterns.
  - Prevents PCRE2 engine UTF-8 validation errors (`Regex match error: UTF-8 error: isolated byte with 0x80 bit set` / `PCRE2_ERROR_UTF8_ERR21`).

### 2.3 Presentation Middleware Exception Isolation in Nightmare (`nightmare/src/nightmare/tools/middleware.cr`)
- In `ToolMiddleware::Presentation#call`:
  - Wrap `p.present_tool_result(tool_name, args, res)` in a defensive `rescue ex` block.
  - UI presentation and terminal dashboard rendering errors must never abort or fail the tool execution handler; the original tool execution result string (`res`) must always be returned safely to the agent loop.

### 2.4 Transcript Preservation on Step Failure in Nightmare (`nightmare/src/nightmare/harness/step_runner.cr`)
- In `Nightmare::Harness::StepRunner#process_step_result`:
  - When `result.err?` occurs on a turn with an active turn or raw response from the LLM:
    - If `active = store.active_turn`:
      - If assistant messages were recorded, record them in the transcript (`@transcript.try &.record(...)`).
      - Otherwise, extract `content` and `tool_calls` from `result.raw_response` and record them.
      - Record a diagnostic failure entry in the transcript (`*(Turn failed: #{msg})*`) so users and agents inspecting `transcript.md` have complete visibility into the abort reason.

## 3. Verification & Validation (V&V)

* **Verification Plan:**
  - `mantle/spec/mantle/tools/process_group_supervisor_spec.cr`:
    - Add unit spec asserting that executing a command that outputs non-UTF-8 binary bytes (e.g. `printf '\x80\xff\xfe'`) returns clean, valid UTF-8 strings (`valid_encoding? == true`) with replacement characters.
  - `salamander/spec/ui/panel_spec.cr`:
    - Add unit spec verifying that `Salamander::UI::Panel.strip_ansi` safely handles strings containing raw non-UTF-8 bytes without raising `Regex::Error` or `ArgumentError`.
  - `nightmare/spec/harness_spec.cr`:
    - Add spec verifying that `ToolMiddleware::Presentation` catches and suppresses unexpected presentation errors, preserving the tool result string.
    - Add spec verifying that when a step error occurs, `StepRunner` flushes the attempted assistant message and failure note to the transcript rather than omitting the turn.
  - Run full test suites: `crystal spec` in `mantle`, `salamander`, and `nightmare`.

* **Verification Evidence:**
  - `mantle/spec/mantle/tools/process_group_supervisor_spec.cr`: verified that executing commands with raw binary byte outputs produces valid UTF-8 strings (`valid_encoding? == true`). Full suite passed: 341 examples, 0 failures, 0 errors.
  - `salamander/spec/ui/panel_spec.cr`: verified that `Salamander::UI::Panel.strip_ansi` and `visual_width` handle strings with isolated `0x80` bytes without error. Full suite passed: 55 examples, 0 failures, 0 errors.
  - `nightmare/spec/harness_spec.cr`: verified that failing tool calls preserve the assistant message, tool calls, and diagnostic notice in `transcript.md`, and that `ToolMiddleware::Presentation` isolates presentation errors. Full suite passed: 337 examples, 0 failures, 0 errors.

* **Validation Plan:**
  - Reproduce the scenario from workspace `kasten-beed8f62`:
    - Execute a shell command that emits non-UTF-8 binary bytes (`printf 'binary \x80\xff\xfe end'`).
    - Verify that output is sanitized into valid UTF-8, ANSI stripping does not trigger PCRE2 UTF-8 validation errors, and failed turns are committed to `transcript.md`.

* **Validation Evidence:**
  - Process execution streams are now sanitized with `.scrub` directly at the supervisor layer, eliminating raw byte propagation.
  - Even in the event of any unhandled downstream tool failure, `StepRunner` flushes the attempted turn and diagnostic notice directly to `transcript.md`.

## Open Questions & Concurrency Concerns
* Concurrency: `String#scrub` is thread-safe and purely functional; zero state mutation.
* Performance: `valid_encoding?` and `scrub` only allocate replacement builders when invalid byte sequences are actually present. Clean UTF-8 strings incur negligible overhead.

## 4. Revision History
* 2026-10-10: Created ticket documenting investigation findings and implementation plan for bug report from workspace `kasten-beed8f62`.
* 2026-10-10: Implemented multi-repo fix across Mantle, Salamander, and Nightmare; verified all spec suites pass cleanly; ticket resolved.
---
