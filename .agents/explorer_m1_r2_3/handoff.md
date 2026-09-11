# Milestone 1 Iteration 2: Worker Implementation & Re-Verification Plan Handoff

**Agent**: `explorer_m1_r2_3` (investigator, synthesizer)  
**Parent**: `orchestrator_1` (Conv ID: `3ad3ad0f-7c04-4b8b-8435-1ed5dba552db`)  
**Milestone**: Milestone 1 Iteration 2 (Workspace Anchoring & Central XDG Mapping)  
**Target Worker**: `worker_m1_2`  
**Status**: COMPLETE  

---

## 1. Observation

### 1.1 Root Cause & Verbatim Error
Challenger `challenger_m1_2` rejected Milestone 1 (`/home/cam/repos/adjutant/nightmare/.agents/challenger_m1_2/handoff.md`) due to an abnormal editor process exit crash in `Nightmare::Directives::DirectiveBuffer#edit`:
- Target file: `src/nightmare/directives/resolver.cr`, lines 218–221:
  ```crystal
  218:         else
  219:           io_err.puts "Notice: Editor exited with non-zero status (#{status.exit_code}). In-memory directive unchanged."
  220:           false
  221:         end
  ```
- When an editor terminates abnormally via signal (`SIGKILL`, `SIGTERM`, `SIGINT`, segfault), `status.normal_exit?` is `false`.
- In Crystal's standard library (`/usr/lib/crystal/process/status.cr:312-314`):
  ```crystal
  def exit_code : Int32
    exit_code? || raise RuntimeError.new("Abnormal exit has no exit code")
  end
  ```
- Calling `status.exit_code` unconditionally raises:
  ```
  RuntimeError: Abnormal exit has no exit code
    /usr/lib/crystal/process/status.cr:313:19 in 'exit_code'
    src/nightmare/directives/resolver.cr:219:70 in 'edit:editor_override:io_err'
  ```

### 1.2 Codebase Search for Other Process Status Calls
Using `grep_search` across `src/`:
- `src/nightmare/directives/resolver.cr:219` is the only location calling `status.exit_code`.
- No other files in `src/nightmare/` invoke `Process.run` or inspect `Process::Status` (subprocesses in tools and signal trapping belong to Milestones 3 and 5).

### 1.3 Crystal `Process::Status` Mechanics
Verified via Crystal stdlib `/usr/lib/crystal/process/status.cr`:
- `status.normal_exit?`: Returns `true` on normal exit (`exit 0`, `exit 1`), `false` on signal termination.
- `status.exit_code`: Returns `Int32` on normal exit, raises `RuntimeError` on abnormal exit.
- `status.exit_code?`: Returns `Int32?` on normal exit, `nil` on abnormal exit (safe).
- `status.exit_signal?`: Returns `Signal?` (`Signal::KILL`, `Signal::TERM`) on signal exit, `nil` on normal exit (safe).
- `status.exit_signal`: Deprecated (`@[Deprecated("Use '#exit_signal?' instead.")]`) and raises `NotImplementedError` on Windows.

### 1.4 Test Suite State
- Current Milestone 1 test run:
  `crystal spec spec/nightmare_spec.cr spec/workspace_spec.cr spec/directives_spec.cr spec/empirical_directives_spec.cr spec/e2e/test_runner_spec.cr`
  Result: 60 examples, 0 failures, 0 errors.
- In `spec/empirical_directives_spec.cr:314-327`, the test passes because it explicitly expects the crash:
  `expect_raises(RuntimeError, /Abnormal exit has no exit code/)`.
  Once the bug is resolved, this test must be updated to verify that `buffer.edit` returns `false` and does NOT raise an exception.

---

## 2. Logic Chain

1. **Defect**: When an external editor is terminated by an OS signal or crashes during `/prompt edit`, `status.normal_exit?` evaluates to `false`. Calling `status.exit_code` invokes an exception in Crystal's stdlib that escapes `DirectiveBuffer#edit`, crashing the REPL session and losing all in-memory turns.
2. **Defensive Status Formatting**:
   - `status.normal_exit?` must be checked first.
   - If `true`, use `status.exit_code.to_s`.
   - If `false`, inspect `status.exit_signal?`. If present, format as `"signal #{sig}"` (e.g. `"signal KILL"`, `"signal TERM"`).
   - If neither, format as `"abnormal exit"`.
   - The notice output `io_err.puts "Notice: Editor exited with non-zero status (#{status_desc}). In-memory directive unchanged."` satisfies both normal exit tests expecting `status (1)` and signal exit tests expecting `status (signal KILL)`.
3. **Defensive File Handling**:
   - If an editor deletes the temporary file before exiting cleanly (`rm -f "$1"` and exit 0), `File.read(temp_path)` would raise `File::NotFoundError`. Checking `unless File.exists?(temp_path)` before reading prevents this failure.
4. **Defensive Exception Boundary**:
   - Wrapping execution in `rescue ex : Exception` ensures unexpected process spawning errors or IO errors log a message to `io_err`, retain the prior directive, and return `false` without crashing.
5. **Specification Consolidation**:
   - Integrating the 14 empirical test cases from `spec/empirical_directives_spec.cr` into `spec/directives_spec.cr` brings the test suite into alignment with `PROJECT.md`'s canonical layout and prevents regressions.
   - Updating `spec/empirical_directives_spec.cr` to assert graceful handling (`res.should be_false`, `err_io.to_s.should contain("signal KILL")`) guarantees that both test suites pass 100% cleanly.

---

## 3. Caveats

- **External Editor Signal Propagation**: Interactive editors (`vim`, `nano`) handle `SIGINT` (Ctrl+C) internally and typically do not terminate unless forced (`kill -9`). The automated test suite simulates abnormal process termination via shell invocation (`sh -c 'kill -9 $$' --`), which accurately triggers `normal_exit? == false` and `exit_signal? == Signal::KILL`.
- **E2E Test Suites**: Running `crystal spec` without arguments executes `spec/e2e/tier*.cr` tests designed for Milestones 2 through 6. For Milestone 1, the valid test target is `spec/nightmare_spec.cr spec/workspace_spec.cr spec/directives_spec.cr spec/empirical_directives_spec.cr spec/e2e/test_runner_spec.cr`.

---

## 4. Conclusion

The plan formulated in `/home/cam/repos/adjutant/nightmare/.agents/explorer_m1_r2_3/plan.md` provides `worker_m1_2` with the exact, copy-paste-ready implementation, diff, test specifications, and verification commands required to resolve Challenger `challenger_m1_2`'s rejection.

Key deliverables formulated for `worker_m1_2`:
1. Exact replacement for `DirectiveBuffer#edit` in `src/nightmare/directives/resolver.cr` with `status.normal_exit?`, `status.exit_signal?`, tempfile check, and exception rescue.
2. Complete test block integration into `spec/directives_spec.cr` (integrating all 14 empirical tests).
3. Regression fix update for `spec/empirical_directives_spec.cr`.
4. Exact passing criteria guaranteeing 0 compiler warnings, 0 errors, and 100% spec pass rate across 60+ tests.

---

## 5. Verification Method

To independently verify the proposed fix and specifications:

1. **Verify Isolation via Crystal Eval**:
   ```bash
   cd /home/cam/repos/adjutant/nightmare
   crystal eval '
   require "./src/nightmare/workspace/environment"
   require "./src/nightmare/directives/resolver"

   # Verify proposed logic handles SIGKILL gracefully
   tempfile = File.tempfile("test", ".md")
   status = Process.run("sh", ["-c", "kill -9 $$"])
   status_desc = if status.normal_exit?
                   status.exit_code.to_s
                 elsif sig = status.exit_signal?
                   "signal #{sig}"
                 else
                   "abnormal exit"
                 end
   puts "Status description: #{status_desc}"
   raise "Failed" unless status_desc == "signal KILL"
   puts "VERIFIED"
   '
   ```
   Expected output: `Status description: signal KILL` and `VERIFIED`.

2. **Verify Full Plan Document**:
   Inspect `/home/cam/repos/adjutant/nightmare/.agents/explorer_m1_r2_3/plan.md` for verbatim Crystal code and integration instructions.
