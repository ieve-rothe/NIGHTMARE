# Fix Strategy: Abnormal Process Exit in `DirectiveBuffer#edit`

**Target Milestone**: Milestone 1 Iteration 2  
**Target File**: `src/nightmare/directives/resolver.cr`  
**Test Files**: `spec/directives_spec.cr` and `spec/empirical_directives_spec.cr`  
**Status**: Ready for Worker Implementation  

---

## 1. Executive Summary & Defect Statement

In Milestone 1 Iteration 1, Challenger `challenger_m1_2` rejected the milestone gate due to a reproducible crash in `Nightmare::Directives::DirectiveBuffer#edit`:

When an external editor process terminates abnormally (e.g. killed by an unhandled signal such as `SIGKILL`, `SIGTERM`, `SIGINT`, or crashing from `SIGSEGV`), invoking `/prompt edit` crashes the NIGHTMARE process with:
```
RuntimeError: Abnormal exit has no exit code
  from /usr/lib/crystal/process/status.cr:313:19 in 'exit_code'
  from src/nightmare/directives/resolver.cr:219:70 in 'edit:editor_override:io_err'
```

### Root Cause
At line 219 of `src/nightmare/directives/resolver.cr`:
```crystal
218:         else
219:           io_err.puts "Notice: Editor exited with non-zero status (#{status.exit_code}). In-memory directive unchanged."
220:           false
221:         end
```
When `status.success?` is false, the code assumes `status` was a normal exit and unconditionally calls `status.exit_code`. Under Crystal's standard library (`/usr/lib/crystal/process/status.cr:312-314`), `Process::Status#exit_code` raises `RuntimeError` if `normal_exit?` is false:
```crystal
  def exit_code : Int32
    exit_code? || raise RuntimeError.new("Abnormal exit has no exit code")
  end
```

### Additional Latent Defects Discovered During Exploration
1. **Deprecated API Risk**: `challenger_m1_2` suggested using `status.exit_signal`. In Crystal stdlib (`/usr/lib/crystal/process/status.cr:280`), `Process::Status#exit_signal` is explicitly marked `@[Deprecated("Use '#exit_signal?' instead.")]` and raises `NotImplementedError` on Windows. Using it risks compiler warnings or cross-platform runtime exceptions.
2. **Missing Tempfile Crash**: If an editor deletes or moves the temporary file before exiting with status 0 (e.g. `rm "$1"`), `File.read(temp_path)` at line 210 raises an uncaught `File::NotFoundError`, crashing the REPL session.
3. **Unprotected Process Spawning**: If process spawning fails (e.g. resource exhaustion, OS limits, missing shell), no `rescue` block guards `edit`, allowing unhandled exceptions to crash the REPL.

---

## 2. Crystal `Process::Status` API Mechanics

Crystal's `Process::Status` (`/usr/lib/crystal/process/status.cr`) encodes process termination state:

| Method | Return Type | Behavior on Normal Exit (`exit(n)`) | Behavior on Abnormal Exit (`kill -9`) | Deprecated / Safe? |
|---|---|---|---|---|
| `normal_exit?` | `Bool` | `true` | `false` | Safe |
| `abnormal_exit?` | `Bool` | `false` | `true` | Safe |
| `exit_code` | `Int32` | Returns integer exit code | **Raises `RuntimeError`** | **UNSAFE if abnormal** |
| `exit_code?` | `Int32?` | Returns integer exit code | Returns `nil` | Safe |
| `exit_signal?` | `Signal?` | Returns `nil` | Returns `Signal::KILL`, etc. | **Safe (Preferred)** |
| `exit_signal` | `Signal` | Raises exception | Returns `Signal::KILL` | **DEPRECATED** (`exit_signal?` preferred) |
| `exit_reason` | `Process::ExitReason` | `ExitReason::Normal` | `ExitReason::Aborted`, `Interrupted`, etc. | Safe |
| `to_s` | `String` | e.g. `"1"` | Signal name e.g. `"KILL"` | Safe |
| `description` | `String` | `"Process exited normally"` | Description of termination | Safe |

---

## 3. Recommended Fix Strategy for `DirectiveBuffer#edit`

### 3.1 Defensive Architecture
To ensure the REPL never crashes during `/prompt edit`, `DirectiveBuffer#edit` must enforce three layers of defense:
1. **Abnormal Exit Formatting**: Check `status.normal_exit?`. If true, format `status.exit_code`. If false, format `status.exit_signal?` (or fallback to `"abnormal exit"` if signal is nil).
2. **Tempfile Existence Verification**: Guard `File.read(temp_path)` with `File.exists?(temp_path)` to protect against deleted/moved tempfiles.
3. **General Exception Boundary**: Wrap the execution in `rescue ex : Exception` to catch unexpected OS/IO errors, emit a diagnostic to `io_err`, retain the prior directive, and return `false`.

### 3.2 Concrete Code Patch for `src/nightmare/directives/resolver.cr`

Lines 195–225 in `src/nightmare/directives/resolver.cr` should be updated as follows:

```crystal
      begin
        tempfile.puts(@current_text)
        tempfile.flush
        tempfile.close

        cmd = "#{editor} #{Process.quote(temp_path)}"
        status = Process.run(
          command: "/bin/sh",
          args: ["-c", cmd],
          input: io_in,
          output: io_out,
          error: io_err
        )

        if status.success?
          unless File.exists?(temp_path)
            io_err.puts "Warning: Edited temporary file was removed. Retaining previous directive."
            return false
          end

          edited_content = File.read(temp_path).strip
          if edited_content.empty?
            io_err.puts "Warning: Edited directive was empty. Retaining previous directive."
            return false
          end

          @current_text = edited_content
          true
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
      rescue ex : Exception
        io_err.puts "Error during editor execution: #{ex.message}. In-memory directive unchanged."
        false
      ensure
        File.delete(temp_path) if File.exists?(temp_path)
      end
```

### 3.3 Rationale for Notice Phrasing
Existing tests in `spec/empirical_directives_spec.cr` (lines 303 & 311) assert:
- `err_io.to_s.should contain("Editor exited with non-zero status (2)")`
- `err_io.to_s.should contain("Editor exited with non-zero status (127)")`

By setting:
- Normal exit 2: `status_desc = "2"` -> `Notice: Editor exited with non-zero status (2). In-memory directive unchanged.`
- Abnormal exit SIGKILL: `status_desc = "signal KILL"` -> `Notice: Editor exited with non-zero status (signal KILL). In-memory directive unchanged.`
- Abnormal exit SIGTERM: `status_desc = "signal TERM"` -> `Notice: Editor exited with non-zero status (signal TERM). In-memory directive unchanged.`

All existing assertions in `spec/empirical_directives_spec.cr` continue to pass without regression.

---

## 4. Test Specifications

### 4.1 Required Updates in `spec/empirical_directives_spec.cr`
In `spec/empirical_directives_spec.cr` (lines 314–327), Challenger `challenger_m1_2` wrote a test that asserted `expect_raises(RuntimeError)`. Once the fix is applied, `buffer.edit` no longer raises an exception. That test must be updated to verify successful graceful handling:

```crystal
    it "gracefully handles editor terminated abnormally by signal without crashing" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Clean Initial System Prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new

      res = buffer.edit(editor_override: "sh -c 'kill -9 $$' --", io_err: err_io)
      res.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Clean Initial System Prompt")
      err_io.to_s.should contain("Editor exited with non-zero status (signal KILL)")
    end
```

### 4.2 New Regression Specifications to Add to `spec/directives_spec.cr`
In `spec/directives_spec.cr`, inside `describe Nightmare::Directives::DirectiveBuffer`, immediately following line 245, add the following test cases:

```crystal
    it "safely handles abnormal editor exit caused by unhandled signals without raising exceptions" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Initial uncorrupted prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      mock_killed_editor = "sh -c 'kill -9 $$' --"
      success = buffer.edit(editor_override: mock_killed_editor, io_err: err_io)

      success.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Initial uncorrupted prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status (signal KILL)")
    end

    it "safely handles abnormal editor exit caused by SIGTERM without raising exceptions" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Initial uncorrupted prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      mock_term_editor = "sh -c 'kill -15 $$' --"
      success = buffer.edit(editor_override: mock_term_editor, io_err: err_io)

      success.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Initial uncorrupted prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status (signal TERM)")
    end

    it "safely handles missing temporary file if deleted by editor" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Initial uncorrupted prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      mock_deleting_editor = "sh -c 'rm -f \"$1\"' --"
      success = buffer.edit(editor_override: mock_deleting_editor, io_err: err_io)

      success.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Initial uncorrupted prompt")
      err_io.to_s.should contain("Warning: Edited temporary file was removed")
    end
```

---

## 5. Implementation & Verification Plan for Worker

1. **Modify `src/nightmare/directives/resolver.cr`**: Apply the patch in section 3.2.
2. **Update `spec/empirical_directives_spec.cr`**: Update the abnormal exit test per section 4.1.
3. **Add regression specs to `spec/directives_spec.cr`**: Add the 3 test cases per section 4.2.
4. **Compile & Spec Verification**:
   - `shards build` (must compile with 0 warnings and 0 errors)
   - `crystal spec spec/directives_spec.cr spec/empirical_directives_spec.cr`
   - Full Milestone 1 suite: `crystal spec spec/nightmare_spec.cr spec/workspace_spec.cr spec/directives_spec.cr spec/empirical_directives_spec.cr spec/e2e/test_runner_spec.cr` (expected: 63 examples, 0 failures, 0 errors).
