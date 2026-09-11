# Handoff Report: Milestone 1 Iteration 2 Fix Strategy for Process Signals & Exit Handling

**Agent**: `explorer_m1_r2_2` (Teamwork Explorer)  
**Parent**: `orchestrator_1` (Conv ID: `3ad3ad0f-7c04-4b8b-8435-1ed5dba552db`)  
**Type**: Hard Handoff  
**Target Milestone**: Milestone 1 Iteration 2  
**Detailed Strategy Reference**: `/home/cam/repos/adjutant/nightmare/.agents/explorer_m1_r2_2/fix_strategy.md`

---

## 1. Observation

### 1.1 Direct Observation of Reported Defect
`challenger_m1_2` rejected Milestone 1 Iteration 1 based on an abnormal editor exit crash in `DirectiveBuffer#edit`:
- Command executed:
  ```crystal
  mock_editor = "sh -c 'kill -9 $$' --"
  buffer.edit(editor_override: mock_editor, io_err: err_io)
  ```
- Verbatim exception:
  ```
  CRASHED WITH EXCEPTION: RuntimeError: Abnormal exit has no exit code
  /usr/lib/crystal/process/status.cr:313:19 in 'exit_code'
  src/nightmare/directives/resolver.cr:219:70 in 'edit:editor_override:io_err'
  ```

### 1.2 Inspection of Implementation Code
In `src/nightmare/directives/resolver.cr:218-221`:
```crystal
218:         else
219:           io_err.puts "Notice: Editor exited with non-zero status (#{status.exit_code}). In-memory directive unchanged."
220:           false
221:         end
```

### 1.3 Inspection of Crystal Standard Library
In `/usr/lib/crystal/process/status.cr`:
- Lines 312–314:
  ```crystal
  def exit_code : Int32
    exit_code? || raise RuntimeError.new("Abnormal exit has no exit code")
  end
  ```
- Lines 325–334:
  ```crystal
  def exit_code? : Int32?
    return unless normal_exit?
    (@system_exit_status & 0xff00) >> 8
  end
  ```
- Lines 280–287:
  ```crystal
  @[Deprecated("Use `#exit_signal?` instead.")]
  def exit_signal : Signal
  ```
- Lines 289–300:
  ```crystal
  def exit_signal? : Signal?
    # Returns Signal? or nil if not terminated by signal
  end
  ```

### 1.4 Codebase Scan for `exit_code`, `Process.run`, and `Signal`
1. `src/nightmare/`:
   - `src/nightmare/directives/resolver.cr:219` is the **only** call to `status.exit_code` across the entire `src/` directory.
   - `workspace/environment.cr`, `workspace/manifest.cr`, `exceptions.cr`, and `nightmare.cr` make zero process calls.
2. `spec/`:
   - `spec/empirical_directives_spec.cr:324-326` currently asserts `expect_raises(RuntimeError, /Abnormal exit has no exit code/)` as an empirical demonstration of the defect.
   - `spec/e2e/tier1_feature_spec.cr:633`, `tier2_boundary_spec.cr:430, 631, 648`, and `test_runner_spec.cr:115, 132` call `.exit_code` on `ProcessSession#wait_exit` in normal clean-exit scenarios.
3. External dependencies:
   - `mantle/src/mantle/tools/builtin_tools.cr:450, 452, 547` contains the exact same anti-pattern (`if !status.success? && status.exit_code > 1`).

---

## 2. Logic Chain

1. **Failure Mechanism**:
   - In Unix semantics, process termination is partitioned into normal exits (`exit(n)`) and abnormal signal terminations (`WIFSIGNALED`).
   - When an editor process is terminated by a signal (`SIGKILL`, `SIGTERM`, `SIGINT`, `SIGSEGV`), `status.normal_exit?` is `false`.
   - In `src/nightmare/directives/resolver.cr:219`, `status.exit_code` is invoked unconditionally within the `else` branch of `if status.success?`.
   - `Process::Status#exit_code` raises `RuntimeError("Abnormal exit has no exit code")` when `status.normal_exit?` is `false`.
   - The exception escapes `DirectiveBuffer#edit`, crashing the process and destroying conversational context in an interactive REPL session.

2. **Resolution Mechanism**:
   - `status.normal_exit?` must be checked before calling `status.exit_code`.
   - If `status.normal_exit?` is `true`, `status.exit_code` provides the numeric exit code (`1`, `2`, `127`).
   - If `status.normal_exit?` is `false`, `status.exit_signal?` provides the `Signal` enum (`Signal::KILL`, `Signal::TERM`, etc.).
   - `status.exit_signal?` must be used instead of `status.exit_signal` to prevent Crystal compiler deprecation warnings (AC1 requirement: 0 warnings).
   - Formatting the notice as `Notice: Editor exited with non-zero status (#{status_desc}). In-memory directive unchanged.` preserves exact message parity for normal non-zero exits while cleanly handling abnormal terminations without throwing.

3. **Regression Test Alignment**:
   - `spec/empirical_directives_spec.cr:314-327` must be updated from expecting a `RuntimeError` crash to asserting `res.should be_false`, directive unchanged, and error message matching `Notice: Editor exited with non-zero status (signal KILL)`.
   - Additional test cases covering `SIGTERM` and `SIGINT` termination must be added to `spec/empirical_directives_spec.cr`.
   - A unit spec covering abnormal signal exit must be added to `spec/directives_spec.cr`.

---

## 3. Caveats

1. **Downstream Unimplemented Modules**: Milestone 3 (`Nightmare::Tools::Shell` / `run_command`) and Milestone 5 (`Nightmare::UI::Signals`) are planned but not yet implemented in `src/nightmare/`. They cannot be directly modified in this milestone. However, explicit guidelines have been documented in `fix_strategy.md` to prevent workers from repeating this anti-pattern.
2. **Local Frameworks**: `mantle/src/mantle/tools/builtin_tools.cr` exhibits a similar pattern, but per R6, framework refactoring is out of scope for Milestone 1.
3. No other caveats.

---

## 4. Conclusion

1. **Single Source Defect**: The abnormal exit failure is strictly isolated to `src/nightmare/directives/resolver.cr:219`.
2. **Proposed Fix for `worker_m1_r2`**:
   Replace lines 218–221 of `src/nightmare/directives/resolver.cr` with:
   ```crystal
           else
             status_desc = if status.normal_exit?
               status.exit_code.to_s
             elsif sig = status.exit_signal?
               "signal #{sig}"
             else
               "abnormal exit"
             end
             io_err.puts "Notice: Editor exited with non-zero status (#{status_desc}). In-memory directive unchanged."
             false
           end
   ```
3. **Proposed Test Updates**:
   - Update `spec/empirical_directives_spec.cr:314-327` to assert non-crashing behavior on `SIGKILL`.
   - Add `SIGTERM` and `SIGINT` empirical test cases.
   - Add unit test to `spec/directives_spec.cr`.

---

## 5. Verification Method

### 5.1 Pre-Fix Failure Reproduction
Run the adversarial one-liner against current code:
```bash
crystal eval '
require "./src/nightmare/workspace/environment"
require "./src/nightmare/directives/resolver"

buffer = Nightmare::Directives::DirectiveBuffer.new(
  current_text: "Initial directive",
  source: Nightmare::Directives::Source::DefaultPersona
)
buffer.edit(editor_override: "sh -c '\''kill -9 $$'\'' --", io_err: IO::Memory.new)
'
```
Observed behavior: Crashes with `RuntimeError: Abnormal exit has no exit code`.  
Expected behavior after fix: Returns `false`, directive remains `"Initial directive"`, zero exceptions.

### 5.2 Milestone 1 Test Suite Verification
Run all Milestone 1 specs:
```bash
crystal spec spec/nightmare_spec.cr spec/workspace_spec.cr spec/directives_spec.cr spec/empirical_directives_spec.cr spec/e2e/test_runner_spec.cr
```
Expected result: 60+ examples, 0 failures, 0 errors.

### 5.3 Zero Warning Build Verification
Verify clean build without deprecation warnings:
```bash
crystal build src/nightmare.cr --warnings all -o bin/nightmare
```
Expected result: Exit code 0 with zero warnings.
