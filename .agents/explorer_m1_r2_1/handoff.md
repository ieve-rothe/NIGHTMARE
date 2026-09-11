# Handoff Report: Milestone 1 Iteration 2 Fix Strategy for Abnormal Process Exit in `DirectiveBuffer#edit`

**Agent**: `explorer_m1_r2_1` (explorer)  
**Parent**: `orchestrator_1` (Conv ID: `3ad3ad0f-7c04-4b8b-8435-1ed5dba552db`)  
**Target Milestone**: Milestone 1 Iteration 2  
**Handoff Type**: Hard  

---

## 1. Observation

### 1.1 Verbatim Defect & Stack Trace
When simulating an editor killed by an unhandled signal (`kill -9 $$` / SIGKILL), `DirectiveBuffer#edit` crashes with:
```
Unhandled exception: Abnormal exit has no exit code (RuntimeError)
  from /usr/lib/crystal/process/status.cr:313:19 in 'exit_code'
  from src/nightmare/directives/resolver.cr:219:70 in 'edit:editor_override:io_err'
```

Direct code inspection of `src/nightmare/directives/resolver.cr:209-221`:
```crystal
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

### 1.2 Crystal Standard Library Implementation
In `/usr/lib/crystal/process/status.cr:312-334`:
```crystal
  def exit_code : Int32
    exit_code? || raise RuntimeError.new("Abnormal exit has no exit code")
  end

  def exit_code? : Int32?
    return unless normal_exit?
    ...
  end
```
Additionally, `/usr/lib/crystal/process/status.cr:280-287` marks `exit_signal` as deprecated:
```crystal
  @[Deprecated("Use `#exit_signal?` instead.")]
  def exit_signal : Signal
```
Calling `status.exit_signal` risks compiler warnings on strict builds and raises `NotImplementedError` on Windows. The safe, non-deprecated method is `status.exit_signal? : Signal?`.

### 1.3 Latent Edge Case Observations
1. **Removed Tempfile**: If an editor deletes the temporary file (e.g. `rm "$1"`), `File.read(temp_path)` at line 210 raises `File::NotFoundError: Error opening file with mode 'r': ... No such file or directory`.
2. **Missing Exception Boundary**: `DirectiveBuffer#edit` lacked a `rescue ex : Exception` clause around process execution and file reading.
3. **Challenger Spec Assertion**: In `spec/empirical_directives_spec.cr:324-326`, `challenger_m1_2` wrote `expect_raises(RuntimeError, /Abnormal exit has no exit code/)`. If `DirectiveBuffer#edit` is fixed without updating this test, `spec/empirical_directives_spec.cr` will fail because no exception is raised.

---

## 2. Logic Chain

1. **Contract Invariant**: R1 (`ORIGINAL_REQUEST.md`) and F1.8 (`PROJECT.md`) require `/prompt edit` to edit system directives in-memory and gracefully revert to the prior directive upon any editor failure, without crashing the REPL session.
2. **Failure Mechanism**: At `src/nightmare/directives/resolver.cr:219`, `status.exit_code` is invoked inside `else` when `status.success?` is false. Because abnormal termination (signals, crashes) results in `status.normal_exit? == false`, calling `status.exit_code` unconditionally triggers Crystal's stdlib check (`/usr/lib/crystal/process/status.cr:313`) and raises `RuntimeError("Abnormal exit has no exit code")`.
3. **REPL Session Impact**: Because the exception is unhandled, an abnormal editor exit terminates the entire NIGHTMARE process, causing catastrophic loss of in-memory conversation turns.
4. **Resolution Strategy**:
   - Guard against abnormal exit by checking `status.normal_exit?` before accessing `exit_code`.
   - Use `status.exit_signal?` (non-deprecated) to report the terminating signal name (e.g. `signal KILL`, `signal TERM`).
   - Guard `File.read(temp_path)` with `File.exists?(temp_path)`.
   - Wrap the execution block in `rescue ex : Exception` to catch any uncaught OS or IO errors, log cleanly to `io_err`, and return `false`.
   - Update `spec/empirical_directives_spec.cr` to assert graceful handling (`res.should be_false`) rather than expecting `RuntimeError`.
   - Add 3 regression specs to `spec/directives_spec.cr` covering `SIGKILL`, `SIGTERM`, and deleted tempfile scenarios.

---

## 3. Caveats

No caveats. All execution branches (normal non-zero exit, `SIGKILL`, `SIGTERM`, `SIGINT`, `SIGSEGV`, deleted tempfile, empty content, and clean exit 0) have been empirically verified with Crystal eval scripts on this machine.

---

## 4. Conclusion

The defect reported by `challenger_m1_2` is confirmed and fully diagnosed. A comprehensive fix strategy and defensive design have been documented in `/home/cam/repos/adjutant/nightmare/.agents/explorer_m1_r2_1/fix_strategy.md`.

Worker `worker_m1_1` (or successor worker) should apply the proposed changes to `src/nightmare/directives/resolver.cr`, update `spec/empirical_directives_spec.cr:314-327`, and add the 3 regression specifications to `spec/directives_spec.cr`.

---

## 5. Verification Method

### 5.1 Direct Code Inspection
Verify `src/nightmare/directives/resolver.cr:218-225` uses `status.normal_exit?` and `status.exit_signal?`:
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

### 5.2 Build Verification
From `/home/cam/repos/adjutant/nightmare`:
```bash
shards build
```
Expected output: clean build, zero compiler warnings or errors.

### 5.3 Test Suite Execution
From `/home/cam/repos/adjutant/nightmare`:
```bash
crystal spec spec/directives_spec.cr spec/empirical_directives_spec.cr
```
Expected output: 38 examples, 0 failures, 0 errors, 0 pending.

### 5.4 Full Milestone 1 Regression Suite
From `/home/cam/repos/adjutant/nightmare`:
```bash
crystal spec spec/nightmare_spec.cr spec/workspace_spec.cr spec/directives_spec.cr spec/empirical_directives_spec.cr spec/e2e/test_runner_spec.cr
```
Expected output: 63 examples, 0 failures, 0 errors, 0 pending.
