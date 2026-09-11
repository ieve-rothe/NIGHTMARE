# Empirical Challenge & Stress Test Report: Directives Resolution & In-Memory Mutation (F1.6, F1.8, F1.7)

**Agent**: `challenger_m1_2` (critic, specialist)  
**Parent**: `orchestrator_1` (Conv ID: `3ad3ad0f-7c04-4b8b-8435-1ed5dba552db`)  
**Target Milestone**: M1 — Workspace Anchoring & Central XDG Mapping  
**Verdict**: **REJECT**  

---

## 1. Observation

### 1.1 Scope & Verification Target
The implementation under empirical challenge comprises:
- Directives Resolution Hierarchy (F1.6): `src/nightmare/directives/resolver.cr`
- In-Memory Directive Mutation & Rollback (F1.8): `src/nightmare/directives/resolver.cr` (`DirectiveBuffer`)
- Startup Notification Banner Formatting & Integrity (F1.7): `src/nightmare/workspace/environment.cr` (`Environment#startup_banner`)

### 1.2 Empirical Stress-Test Execution
An adversarial test suite with 14 empirical test cases (`spec/empirical_directives_spec.cr`) was authored and executed with `crystal spec spec/empirical_directives_spec.cr`.

### 1.3 Confirmed Failure Mode: Editor Abnormal Exit Crash
During stress-testing of `/prompt edit` non-zero exit handling, an editor process terminating abnormally (such as being terminated by a signal `SIGKILL`, `SIGTERM`, `SIGINT`, or crashing with a segmentation fault) was executed:
```crystal
mock_editor = "sh -c 'kill -9 $$' --"
buffer.edit(editor_override: mock_editor, io_err: err_io)
```

**Verbatim Exception Output**:
```
CRASHED WITH EXCEPTION: RuntimeError: Abnormal exit has no exit code
/usr/lib/crystal/process/status.cr:313:19 in 'exit_code'
src/nightmare/directives/resolver.cr:219:70 in 'edit:editor_override:io_err'
```

**Direct Code Inspection** (`src/nightmare/directives/resolver.cr:218-221`):
```crystal
218:         else
219:           io_err.puts "Notice: Editor exited with non-zero status (#{status.exit_code}). In-memory directive unchanged."
220:           false
221:         end
```

In Crystal's standard library (`/usr/lib/crystal/process/status.cr:310-316`):
```crystal
  def exit_code : Int32
    if normal_exit?
      exit_status
    else
      raise "Abnormal exit has no exit code"
    end
  end
```
When `status.normal_exit?` is false (process terminated by a signal), calling `status.exit_code` unconditionally raises `RuntimeError("Abnormal exit has no exit code")`. Because line 219 lacks a signal check or exception handler, this unhandled exception escapes `DirectiveBuffer#edit` and crashes the calling process.

### 1.4 Passed Empirical Assertions
All other test domains passed empirical verification:
1. **Directives Precedence (F1.6)**:
   - Evaluated 5 tiers sequentially: CLI Flag > Repo Committed (`.nightmare/prompt.md`) > Workspace Central (`$XDG_CONFIG_HOME/.../prompt.md`) > Global Central (`$XDG_CONFIG_HOME/prompt.md`) > Default General Persona (`DEFAULT_PERSONA`).
   - Missing files fall through gracefully without creating repository litter.
   - 0-byte empty files fall through gracefully to lower tiers.
   - Whitespace-only files (`" \t\r\n "`) fall through gracefully to lower tiers.
   - Passing an empty/whitespace file to CLI flag (`-s`) falls back to `DEFAULT_PERSONA` under `Source::CliFlag`.
   - Missing CLI target raises `ArgumentError`.
   - Relative CLI paths expand against `env.root`.
   - External CLI paths and symlinks resolve properly; dangling symlinks raise `ArgumentError`.
   - Anomalous repository layouts (e.g. `.nightmare` created as a regular file, or `.nightmare/prompt.md` created as a directory) handle gracefully without exceptions.
2. **Disk File Immutability (F1.8)**:
   - Evaluated `/prompt edit` with mock editor mutating tempfile content.
   - Checked all 4 on-disk tiers (CLI file, repo file, workspace file, global file) before and after mutation.
   - SHA-256 digests, file sizes, and modification times (`mtime`) were 100% byte-for-byte identical before and after in-memory edit.
   - Temporary file in `Dir.tempdir` confirmed cleanly deleted in both success and error paths.
   - `reset!` cleanly restores original in-memory directive.
3. **Editor Normal Non-Zero Exit Handling (F1.8)**:
   - Editor exiting with code 1 (`exit 1`): rolls back, returns `false`, leaves directive unchanged.
   - Editor exiting with code 2 (`exit 2`): rolls back, returns `false`, leaves directive unchanged.
   - Editor exiting with code 127 (`exit 127`): rolls back, returns `false`, leaves directive unchanged.
   - Editor clearing tempfile to empty or whitespace: emits warning, rolls back, returns `false`, leaves directive unchanged.
4. **Startup Notification Banner (F1.7)**:
   - Exact 76 columns width verified across all 5 lines for `/home/cam/repos/adjutant/nightmare` and standard paths.
   - Line 0: `┌── NIGHTMARE ─────────────────────────────────────────────────────────────┐` (76 chars)
   - Line 1: `│ Workspace : ...                                                          │` (76 chars)
   - Line 2: `│ Config    : ...                                                          │` (76 chars)
   - Line 3: `│ State/Logs: ...                                                          │` (76 chars)
   - Line 4: `└──────────────────────────────────────────────────────────────────────────┘` (76 chars)
   - Unicode single-line box characters intact (`┌`, `─`, `┐`, `│`, `└`, `┘`).
   - Dynamic width expansion verified for long directory paths (> 72 chars), retaining uniform column width across all 5 lines.
   - Config and state paths contain trailing slashes and replace `$HOME` prefix with `~`.

---

## 2. Logic Chain

1. **Contract Invariant**:
   - `ORIGINAL_REQUEST.md` R1 and `docs/DESIGN.md` §3 specify that `/prompt edit` must launch an editor and gracefully revert to the prior prompt if the editor exits with an error without crashing the REPL session.
   - `src/nightmare/directives/resolver.cr:180` defines `def edit(...) : Bool`. Callers expect a boolean return value indicating success or failure.
2. **Defect Mechanism**:
   - At line 219 of `src/nightmare/directives/resolver.cr`, if `status.success?` is false, the code logs:
     `io_err.puts "Notice: Editor exited with non-zero status (#{status.exit_code}). In-memory directive unchanged."`
   - In Unix process semantics, a process may exit non-zero via `exit(code)` (`normal_exit? == true`) OR via an unhandled signal (`normal_exit? == false`).
   - When a signal kills the editor process (e.g. user sends `SIGTERM`, OS kernel OOM killer fires `SIGKILL`, or editor segfaults), `normal_exit?` is false.
   - Crystal stdlib `Process::Status#exit_code` raises `RuntimeError("Abnormal exit has no exit code")` when `normal_exit?` is false.
3. **Blast Radius**:
   - When the user runs `/prompt edit` in the interactive REPL and the editor crashes or is killed by a signal, this unhandled exception crashes NIGHTMARE, immediately killing the developer's REPL session and losing all in-memory context.
4. **Remediation**:
   - Line 219 should check `status.normal_exit?` before invoking `status.exit_code`:
     ```crystal
     status_desc = status.normal_exit? ? status.exit_code.to_s : "signal #{status.exit_signal}"
     io_err.puts "Notice: Editor exited with non-zero status (#{status_desc}). In-memory directive unchanged."
     false
     ```

---

## 3. Caveats

No caveats. All required domains (precedence with missing/empty/whitespace files, CLI override precedence, disk immutability via checksums, editor exit handling, and banner formatting) were tested empirically with live process execution.

---

## 4. Conclusion

**Verdict: REJECT**

Milestone 1 is rejected solely due to the crash bug in `DirectiveBuffer#edit` (`src/nightmare/directives/resolver.cr:219`). While the directives precedence hierarchy, CLI override precedence, on-disk immutability, and startup banner formatting are fully compliant and robust, the failure of `DirectiveBuffer#edit` to safely handle abnormal editor process termination violates the zero-crash REPL resiliency requirement.

Once `worker_m1_1` applies the one-line fix to handle `!status.normal_exit?` in `src/nightmare/directives/resolver.cr:219`, this milestone can be immediately approved.

---

## 5. Verification Method

### 5.1 Reproduce Abnormal Exit Crash Bug
Execute the following one-liner to observe the crash:
```bash
cd /home/cam/repos/adjutant/nightmare
crystal eval '
require "./src/nightmare/workspace/environment"
require "./src/nightmare/directives/resolver"

buffer = Nightmare::Directives::DirectiveBuffer.new(
  current_text: "Initial directive",
  source: Nightmare::Directives::Source::DefaultPersona
)

# Simulate editor killed by SIGKILL
buffer.edit(editor_override: "sh -c '\''kill -9 $$'\'' --", io_err: IO::Memory.new)
'
```
**Observed result**: Crashes with `RuntimeError: Abnormal exit has no exit code`.  
**Expected result after fix**: Returns `false` and does not raise an exception.

### 5.2 Run Full Empirical Test Suite
Run the 14 adversarial tests verifying directives precedence, immutability checksums, editor exit codes, and banner formatting:
```bash
cd /home/cam/repos/adjutant/nightmare
crystal spec spec/empirical_directives_spec.cr
```
Expected result: 14 examples, 0 failures, 0 errors.

### 5.3 Run Full Milestone 1 Test Suite
```bash
cd /home/cam/repos/adjutant/nightmare
crystal spec spec/nightmare_spec.cr spec/workspace_spec.cr spec/directives_spec.cr spec/empirical_directives_spec.cr spec/e2e/test_runner_spec.cr
```
Expected result: 60 examples, 0 failures, 0 errors.
