---
ID: TKT-032
Title: Prevent Spec Suite XDG Workspace Pollution in State and Cache Directories
Status: Closed
Priority: High
---

## 1. User Need
Developers and operators running the `nightmare` test suite require automated tests to run cleanly in complete isolation without mutating or polluting host user directories. Specifically, test executions must not leak ephemeral workspace directories into `~/.local/state/nightmare/workspaces/` or `~/.cache/nightmare/workspaces/`. Orphaned test directories clutter the operator's workspace list and consume filesystem resources.

## 2. Specification

### 2.1 Incident Investigation & Root Cause Analysis
1. **Symptom**:
   - Operator discovered 44+ directories matching the pattern `*nightmare_spec_dir-<hash>` in `/home/cam/.local/state/nightmare/workspaces/` and 183+ in `/home/cam/.cache/nightmare/workspaces/`.
   - Inspection of the leaked directories showed they were empty workspace directory skeletons.

2. **Mechanism**:
   - In `spec/spec_helper.cr`, `with_temp_dir` creates an isolated directory in `/tmp/` named `*nightmare_spec_dir` and yields its canonical path.
   - When `Nightmare::Workspace::Environment.new(root, ...)` or `Environment.resolve(root, ...)` is initialized with this path, the slug is derived from `File.basename(root)` (e.g. `0gxixtpdnightmare_spec_dir`), producing workspace ID `<slug>-<hash>`.
   - When `ensure_dirs: true` is passed (or left at default `true`), `Environment#initialize` executes:
     ```crystal
     Dir.mkdir_p(@config_dir) unless Dir.exists?(@config_dir)
     Dir.mkdir_p(@state_dir) unless Dir.exists?(@state_dir)
     Dir.mkdir_p(@cache_dir) unless Dir.exists?(@cache_dir)
     ```
   - When `xdg_state_home` or `xdg_cache_home` are not explicitly specified, `Environment` falls back to `resolve_xdg`, which evaluates to `~/.local/state` and `~/.cache`.
   - While `with_temp_dir` cleans up the temporary root directory in `/tmp/` via `FileUtils.rm_rf(dir)`, the directories created under `~/.local/state/nightmare/workspaces/<workspace_id>` and `~/.cache/nightmare/workspaces/<workspace_id>` reside outside the temporary root and remain orphaned.

3. **Culprit Isolation**:
   - Automated empirical leak detection across every file in `spec/` isolated the leak directly to `spec/keys_spec.cr`:
     - `spec/keys_spec.cr:41`: `env = Nightmare::Workspace::Environment.new(root, xdg_config_home: File.join(root, ".config"), ensure_dirs: true)`
     - `spec/keys_spec.cr:59`: `env = Nightmare::Workspace::Environment.new(root, xdg_config_home: File.join(root, ".config"), ensure_dirs: true)`
     - `spec/keys_spec.cr:77`: `env = Nightmare::Workspace::Environment.new(root, xdg_config_home: File.join(root, ".config"), ensure_dirs: true)`
   - In each of these three tests, `xdg_config_home` was overridden into `root/.config` (which was cleaned up when `root` was removed), but `xdg_state_home` and `xdg_cache_home` were omitted.
   - Consequently, each invocation of `spec/keys_spec.cr` created exactly 3 orphaned directories in `~/.local/state/nightmare/workspaces/` and 3 orphaned directories in `~/.cache/nightmare/workspaces/`.

### 2.2 Functional Requirements
1. **Component-Level Remediation (`spec/keys_spec.cr`)**:
   - Updated `spec/keys_spec.cr` test cases to explicitly isolate `xdg_state_home` and `xdg_cache_home` into `root` subdirectories.
2. **Global Suite-Level Isolation (`spec/spec_helper.cr`)**:
   - Added defense-in-depth cleanup in `with_temp_dir`'s `ensure` block to automatically wipe any host XDG directories matching the temporary workspace ID (`<slug>-<hash>`).
3. **Artifact Cleanup**:
   - Removed all existing orphaned spec directories (`*nightmare_spec_dir*`) from `~/.local/state/nightmare/workspaces/` and `~/.cache/nightmare/workspaces/`.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Run `crystal spec spec/keys_spec.cr` and verify that the count of directories in `~/.local/state/nightmare/workspaces` and `~/.cache/nightmare/workspaces` does not increase.
  - Run the entire spec suite (`crystal spec`) and verify zero new directories are created under the real host user's XDG state, config, or cache directories.
  - Verify all unit specs in `spec/keys_spec.cr` pass without failure.
* **Verification Evidence:**
  - `spec/keys_spec.cr`: 6 examples, 0 failures, 0 errors, 0 pending (State delta: 0, Cache delta: 0).
  - Full test suite run (`crystal spec`): 326 examples, 0 failures, 0 errors, 0 pending (4.48s).
  - Verified post-suite run: 0 directories matching `*spec*` in `~/.local/state/nightmare/workspaces/`, `~/.cache/nightmare/workspaces/`, or `~/.config/nightmare/workspaces/`.
* **Validation Plan:**
  - Verify that running `crystal spec` in `nightmare` leaves `~/.local/state/nightmare/workspaces` and `~/.cache/nightmare/workspaces` with only legitimate non-spec workspaces.
* **Validation Evidence:**
  - Cleaned all 48 orphaned directories in state and 189 in cache. Inspected directory contents via `ls -la ~/.local/state/nightmare/workspaces/`: only legitimate workspace (`kasten-beed8f62`) remains. Re-ran spec suite and confirmed zero pollution.

## Open Questions & Concurrency Concerns
* **Global Isolation vs Per-Spec Parameters**: Resolved by combining explicit per-spec isolation on tests calling `Environment.new` with an automated safety net in `with_temp_dir` ensuring any temporary workspace ID created during a test is pruned on completion.

## 4. Revision History
* 2026-10-06: Initial bug report and ticket creation. Completed root cause investigation isolating leak to `spec/keys_spec.cr`.
* 2026-10-06: Implemented per-spec XDG isolation in `spec/keys_spec.cr` and safety net in `spec/spec_helper.cr`. Purged all orphaned directories. Verified full test suite. Closed.
---
