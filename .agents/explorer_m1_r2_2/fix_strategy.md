# Milestone 1 Iteration 2 Fix Strategy: Process Signals & Exit Handling

**Author**: `explorer_m1_r2_2` (Teamwork Explorer)  
**Date**: 2026-09-11  
**Scope**: Milestone 1 Iteration 2 (F1.6, F1.8, F1.7) & Subprocess Exit Handling Standard  
**Target Files**:
- `src/nightmare/directives/resolver.cr`
- `spec/empirical_directives_spec.cr`
- `spec/directives_spec.cr`

---

## 1. Executive Summary

During Milestone 1 Iteration 1 verification, `challenger_m1_2` rejected the release gate due to a reproducible crash bug in `DirectiveBuffer#edit` (`src/nightmare/directives/resolver.cr:219`). When an external editor process terminates abnormally via an unhandled signal (such as `SIGKILL`, `SIGTERM`, `SIGINT`, or crashing via `SIGSEGV`), invoking `status.exit_code` unconditionally raises `RuntimeError: Abnormal exit has no exit code` from the Crystal standard library (`/usr/lib/crystal/process/status.cr:313`). This unhandled exception escapes `DirectiveBuffer#edit` and crashes the entire NIGHTMARE process, destroying interactive session state and violating the zero-crash REPL resiliency requirement.

A comprehensive audit of `src/nightmare/` confirms that `src/nightmare/directives/resolver.cr:219` is currently the only occurrence of `status.exit_code` in the repository. However, the same anti-pattern was discovered in local framework dependencies (`mantle/src/mantle/tools/builtin_tools.cr:450, 452, 547`), and planned future milestones—specifically Milestone 3 (`run_command` subprocess runner with process group timeouts) and Milestone 5 (`Ctrl+C` signal interception and rollback)—are at high risk of reintroducing this defect if an architectural standard is not established.

This document presents:
1. A rigorous root-cause analysis of the failure mode.
2. The codebase audit results across existing files, test suites, and planned modules.
3. A robust, idiomatic Crystal process status handling standard.
4. The exact fix implementation for `DirectiveBuffer#edit`.
5. A comprehensive regression test suite covering SIGKILL, SIGTERM, SIGINT, and normal exit codes.

---

## 2. Detailed Root-Cause Analysis

### 2.1 POSIX Process Termination Semantics
In POSIX/Unix operating systems, a child process terminates in one of two distinct ways:
1. **Normal Exit**: The process invoked `exit(n)`, `_exit(n)`, or returned from `main()`. The kernel records `WIFEXITED(status) == true` and the lower 8 bits of the status represent the exit code (`WEXITSTATUS(status)`).
2. **Abnormal Termination (Signal Exit)**: The process received a terminating signal that it did not catch or ignore (e.g. `SIGKILL`, `SIGTERM`, `SIGINT`, `SIGSEGV`, `SIGABRT`). The kernel records `WIFSIGNALED(status) == true` and the signal number is obtained via `WTERMSIG(status)`. **In this state, POSIX defines no exit code**.

### 2.2 Crystal Standard Library Implementation
Crystal models process termination via `Process::Status` (`/usr/lib/crystal/process/status.cr`). The relevant stdlib implementation is:

```crystal
# /usr/lib/crystal/process/status.cr:312-334
def exit_code : Int32
  exit_code? || raise RuntimeError.new("Abnormal exit has no exit code")
end

def exit_code? : Int32?
  return unless normal_exit?
  (@system_exit_status & 0xff00) >> 8
end

def normal_exit? : Bool
  exit_reason.normal?
end

def signal_exit? : Bool
  !!exit_signal?
end

def exit_signal? : Signal?
  # Returns Signal if terminated by signal, nil otherwise
end
```

Key observations from stdlib:
- `status.success?` is defined as `exit_code? == 0`. It safely returns `false` on abnormal exits without raising.
- `status.normal_exit?` safely returns `false` on signal termination.
- `status.exit_code?` safely returns `nil` on signal termination without raising.
- `status.exit_signal?` safely returns the `Signal` enum (or `nil` if not terminated by signal).
- **`status.exit_code` unconditionally raises `RuntimeError`** when `normal_exit?` is `false`.

### 2.3 The Defect in `DirectiveBuffer#edit`
In `src/nightmare/directives/resolver.cr:208-221`:
```crystal
208: 
209:         if status.success?
210:           edited_content = File.read(temp_path).strip
211:           if edited_content.empty?
212:             io_err.puts "Warning: Edited directive was empty. Retaining previous directive."
213:             return false
214:           end
215: 
216:           @current_text = edited_content
217:           true
218:         else
219:           io_err.puts "Notice: Editor exited with non-zero status (#{status.exit_code}). In-memory directive unchanged."
220:           false
221:         end
```

When an editor process is terminated by a signal (e.g. killed via `kill -9`, killed by an OS OOM killer, or crashed by a segmentation fault):
1. `status.success?` evaluates to `false`.
2. Execution branches into `else` (line 218).
3. Line 219 interpolates `status.exit_code`.
4. Because `status.normal_exit?` is `false`, stdlib raises `RuntimeError: Abnormal exit has no exit code`.
5. The `ensure` block executes (deleting the temporary file), but the exception escapes `edit(...)`.
6. Any caller invoking `edit` or `edit!` (such as `/prompt edit` in the REPL) crashes.

---

## 3. Codebase-Wide Audit

### 3.1 Current Codebase (`src/nightmare/`)
An exhaustive scan was conducted across all files in `src/nightmare/`:
- `src/nightmare/directives/resolver.cr`: Contains line 219 (`status.exit_code`). **Defect confirmed**.
- `src/nightmare/workspace/environment.cr`: Zero subprocess invocations.
- `src/nightmare/workspace/manifest.cr`: Zero subprocess invocations.
- `src/nightmare/exceptions.cr`: Zero subprocess invocations.
- `src/nightmare.cr`: CLI parsing and initialization; invokes standard Crystal `exit 0` / `exit 1` for CLI execution. Zero subprocess invocations.

**Conclusion**: Line 219 of `src/nightmare/directives/resolver.cr` is the single active site of this defect in `src/`.

### 3.2 Existing Test Suites (`spec/`)
- `spec/empirical_directives_spec.cr:322-327`:
  ```crystal
  # When editor process is killed by signal, Process::Status#exit_code raises RuntimeError.
  # This causes buffer.edit to crash with an unhandled exception rather than returning false!
  expect_raises(RuntimeError, /Abnormal exit has no exit code/) do
    buffer.edit(editor_override: "sh -c 'kill -9 $$' --", io_err: err_io)
  end
  ```
  This test was written by `challenger_m1_2` specifically to demonstrate the failure mode. Once the defect is resolved, this test must be updated to assert the correct resilient behavior (`return false`, unchanged directive, notice logged to `io_err`).
- `spec/e2e/test_runner.cr` & E2E specs:
  `test_runner.cr:406` defines `ProcessSession#wait_exit`. In tests where the test runner itself terminates processes via `terminate!` (`signal(Signal::KILL)`), calling `.exit_code` on the returned status would raise. Downstream E2E tests currently avoid calling `.exit_code` on terminated processes, but test assertions should adopt safe conventions.

### 3.3 External Dependencies & Downstream Architecture Risks
- **`mantle/src/mantle/tools/builtin_tools.cr:450, 452, 547`**:
  ```crystal
  if !status.success? && status.exit_code > 1
    err_msg = "Command failed with exit code #{status.exit_code}" if err_msg.empty?
  ...
  error: "Error sending notification. Exit code: #{status.exit_code}"
  ```
  This demonstrates that calling `status.exit_code` without a `normal_exit?` check is a widespread anti-pattern in the local Crystal ecosystem.
- **Milestone 3 (`src/nightmare/tools/shell.cr`)**:
  `run_command` executes shell commands inside process groups with hard timeouts (up to 600s). On timeout or cancellation, it executes `Process.kill(Signal::KILL, -pgid)`. When the command child terminates from `SIGKILL`, `status.normal_exit?` is `false`. If `run_command` calls `status.exit_code`, timeout handling will crash.
- **Milestone 5 (`src/nightmare/ui/signals.cr`)**:
  Interactive `Ctrl+C` handling kills active child processes and rolls back conversational turns. Interrupted processes will exit abnormally via signals.

---

## 4. Robust Process Status Handling Pattern

### 4.1 Core Invariants
1. **Never call `status.exit_code` unconditionally**: Only invoke `status.exit_code` if `status.normal_exit?` is known to be `true`.
2. **Prefer `status.exit_code?` and `status.exit_signal?`**: Use the nilable variants that never raise exceptions.
3. **Use `status.to_s` for general logging**: In Crystal, `status.to_s` safely stringifies normal exit codes (`"0"`, `"1"`, `"127"`) and signal terminations (`"KILL"`, `"TERM"`, `"INT"`).
4. **Avoid deprecated methods**: Do NOT use `status.exit_signal` (deprecated in Crystal stdlib and raises if not signaled). Use `status.exit_signal?`.

### 4.2 Standard Status Description Pattern
When generating human-facing or LLM-facing diagnostic strings from a `Process::Status`, use this canonical pattern:

```crystal
status_desc = if status.normal_exit?
  status.exit_code.to_s
elsif sig = status.exit_signal?
  "signal #{sig}"
else
  "abnormal exit"
end
```

Behavior matrix:
| Process Outcome | `status.normal_exit?` | `status.exit_code?` | `status.exit_signal?` | `status_desc` |
|---|---|---|---|---|
| `exit 0` | `true` | `0` | `nil` | `"0"` |
| `exit 1` | `true` | `1` | `nil` | `"1"` |
| `exit 127` | `true` | `127` | `nil` | `"127"` |
| `kill -9 $$` (`SIGKILL`) | `false` | `nil` | `Signal::KILL` | `"signal KILL"` |
| `kill -15 $$` (`SIGTERM`) | `false` | `nil` | `Signal::TERM` | `"signal TERM"` |
| `kill -2 $$` (`SIGINT`) | `false` | `nil` | `Signal::INT` | `"signal INT"` |

---

## 5. Milestone 1 Iteration 2 Fix Proposal

### 5.1 Target File
`src/nightmare/directives/resolver.cr` (Lines 218–221)

### 5.2 Proposed Code Change
```diff
--- a/src/nightmare/directives/resolver.cr
+++ b/src/nightmare/directives/resolver.cr
@@ -216,7 +216,14 @@ module Nightmare::Directives
           @current_text = edited_content
           true
         else
-          io_err.puts "Notice: Editor exited with non-zero status (#{status.exit_code}). In-memory directive unchanged."
+          status_desc = if status.normal_exit?
+            status.exit_code.to_s
+          elsif sig = status.exit_signal?
+            "signal #{sig}"
+          else
+            "abnormal exit"
+          end
+          io_err.puts "Notice: Editor exited with non-zero status (#{status_desc}). In-memory directive unchanged."
           false
         end
       ensure
```

### 5.3 Rationale
1. **Preserves Contract Compatibility**: For all normal exit codes (`1`, `2`, `127`), `status_desc` evaluates to `"1"`, `"2"`, `"127"`, exactly matching all existing test assertions in `spec/directives_spec.cr` and `spec/empirical_directives_spec.cr`.
2. **Eliminates Abnormal Exit Crash**: For signal terminations (`SIGKILL`, `SIGTERM`, `SIGINT`), `status.exit_code` is never called. It outputs `Notice: Editor exited with non-zero status (signal KILL). In-memory directive unchanged.` and safely returns `false`.
3. **Zero Deprecation Warnings**: Uses `status.exit_signal?` rather than the deprecated `status.exit_signal`, ensuring compliance with AC1 (`0 compiler warnings`).
4. **Minimal Blast Radius**: Confined to 8 lines within `DirectiveBuffer#edit`, requiring zero interface or signature changes.

---

## 6. Regression Test Suite Specification

### 6.1 Update `spec/empirical_directives_spec.cr`
Replace the demonstration failure test (lines 314–327) with comprehensive regression tests asserting non-crashing behavior across multiple signal terminations:

```crystal
    it "handles editor terminated abnormally by SIGKILL gracefully without raising RuntimeError" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Clean Initial System Prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      res = buffer.edit(editor_override: "sh -c 'kill -9 $$' --", io_err: err_io)

      res.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Clean Initial System Prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status (signal KILL). In-memory directive unchanged.")
    end

    it "handles editor terminated abnormally by SIGTERM gracefully" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Clean Initial System Prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      res = buffer.edit(editor_override: "sh -c 'kill -15 $$' --", io_err: err_io)

      res.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Clean Initial System Prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status (signal TERM). In-memory directive unchanged.")
    end

    it "handles editor terminated abnormally by SIGINT gracefully" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Clean Initial System Prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      res = buffer.edit(editor_override: "sh -c 'kill -2 $$' --", io_err: err_io)

      res.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Clean Initial System Prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status (signal INT). In-memory directive unchanged.")
    end
```

### 6.2 Addition to Unit Suite `spec/directives_spec.cr`
Add a dedicated signal termination spec to `spec/directives_spec.cr` within `describe Nightmare::Directives::DirectiveBuffer`:

```crystal
    it "handles abnormal process exit (signal termination) without crashing or mutating prompt" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Preserved Prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      mock_killed_editor = "sh -c 'kill -9 $$' --"
      success = buffer.edit(editor_override: mock_killed_editor, io_err: err_io)

      success.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Preserved Prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status (signal KILL)")
    end
```

---

## 7. Downstream Implementation Guidelines (M3 & M5)

When implementing subsequent milestones, developers must adhere to the following rules:

1. **Milestone 3 (`Nightmare::Tools::Shell` / `run_command`)**:
   - Subprocesses must be executed with `Process.new(..., chdir: @root)`.
   - On timeout, send `Process.kill(Signal::KILL, -pgid)` and collect output.
   - When constructing the tool execution result:
     ```crystal
     if timed_out?
       ToolResult.failure("[Execution timed out after #{timeout_seconds} seconds]")
     elsif status.success?
       ToolResult.success(output)
     elsif status.normal_exit?
       ToolResult.failure("Command failed with exit code #{status.exit_code}\n#{stderr}")
     elsif sig = status.exit_signal?
       ToolResult.failure("Command terminated by signal #{sig}\n#{stderr}")
     else
       ToolResult.failure("Command terminated abnormally\n#{stderr}")
     end
     ```
   - Never call `status.exit_code` directly on a timed-out or signal-terminated command.

2. **Milestone 5 (`Nightmare::UI::Signals`)**:
   - Signal trapping (`Signal::INT.trap`) must signal child process groups with `Signal::KILL` or `Signal::TERM` and immediately clean up in-flight pipelines.
   - Process waiting routines must use `rescue ex : Exception` or nilable exit queries to ensure no signal-related status inspection leaks exceptions into the REPL turn loop.
