---
ID: TKT-028
Title: Globally Writable External Directories for Multi-Repository and Shared Workspace Mutations
Status: Resolved
Priority: Med
---

## 1. User Need
Following the introduction of globally readable directories (TKT-027), operators frequently need the ability to permit controlled, approved mutations in specific external directories outside the primary working directory (CWD).

For instance, an agent operating within one project repository might need to write or update shared skill definitions in a central repository, emit shared test fixtures to a common corpus, or generate cross-repository patches without having to switch its primary workspace root.

Currently, all write and edit operations (`write_file`, `replace_in_file`, `append_to_file`) are strictly confined to the workspace root (`@env.root`). Any write targeting an external path—even an allowed readable directory—triggers a `SecurityError: Path traversal violation`. Operators need a dedicated configuration option to explicitly designate external directories as writable, following the exact same configuration hierarchy (global, workspace, repo, env, CLI) while maintaining strict human-in-the-loop diff approvals and protected path defenses.

---

## 2. Specification

### 2.1 Configuration Schema & Hierarchy
1. **Settings Extension (`Nightmare::Settings`):**
   - Add property:
     ```crystal
     property writable_directories : Array(String) = [] of String
     ```
   - In JSON deserialization and parsing, accept both `writable_directories` and `writeable_directories` to prevent spelling frustration.
   - Configurable at three levels:
     - **Global Config** (`~/.config/nightmare/config.json`): Base machine settings.
     - **Workspace Central Config** (`~/.config/nightmare/workspaces/<id>/config.json`): Scoped to workspace.
     - **Repo Config** (`.nightmare/settings.json` or `.nightmare/config.json`): Scoped to repository.

2. **CLI & Environment Variable Overrides:**
   - **CLI Flags**: `-W PATH`, `--write-dir=PATH`, `--writable-dir=PATH`, `--writeable-dir=PATH` (repeatable).
   - **Environment Variables**: `NIGHTMARE_WRITABLE_DIRS` (and `NIGHTMARE_WRITEABLE_DIRS`), colon-delimited.

3. **Normalization & Read Invariant:**
   - All paths are expanded and canonicalized via `File.realpath` at initialization.
   - **Invariant**: Any directory marked as writable is automatically added to `readable_directories` if not already present, ensuring tools can inspect existing content and construct unified diffs prior to mutation.

### 2.2 Security Model & Guard Enforcement (`Nightmare::Tools::Guard`)
1. **Write Path Resolution (`Guard#resolve_write`):**
   - A target path is allowed for mutation if:
     a) It resolves within `@env.root` (standard workspace containment), OR
     b) It resolves within any directory specified in `@env.writable_directories` (canonical subtree containment check via realpath).
   - Any path outside both is rejected with `SecurityError: Path traversal violation`.
   - Read-only external directories (from `readable_directories` but not `writable_directories`) strictly reject writes.
2. **Protected Path Defenses:**
   - Protected paths (`.git`, `.nightmare`, etc.) are unconditionally rejected inside external writable directories just as in the workspace root.
3. **Diff Approvals & Auditing:**
   - All mutations in external writable directories pass through interactive diff approval (`approve_diff` / `approve_mutation`).
   - Mutations are displayed with their clean paths and recorded in turn side effects.

### 2.3 Tool Updates (`Nightmare::Tools::Mutation` & `Registry`)
1. **`Mutation` (`src/nightmare/tools/mutation.cr`):**
   - `write_file`, `replace_in_file`, and `append_to_file` resolve target paths via `Guard#resolve_write`.
   - Display paths in diffs and return messages use clean paths without `../../` artifacts.
2. **`Registry` (`src/nightmare/tools/registry.cr`):**
   - Update descriptions for `write_file`, `replace_in_file`, and `append_to_file` to indicate support for allowed writable directories.
3. **Banner & Observability:**
   - `Environment#startup_banner` displays `Write Dirs: <paths>` when configured.

---

## 3. Verification & Validation (V&V)

### 3.1 Verification Plan
1. **Settings & Environment Specs (`spec/settings_spec.cr`, `spec/workspace_spec.cr`):**
   - Verify `writable_directories` parsing and bootstrap serialization.
   - Verify environment variable `NIGHTMARE_WRITABLE_DIRS` resolution and CLI `-W` override.
   - Verify automatic inclusion of writable directories in `readable_directories`.
   - Verify `sanitize_write_path` permits paths in `writable_directories` while rejecting unauthorized paths.
2. **Guard Security Specs (`spec/guard_spec.cr`):**
   - Verify `resolve_write` succeeds for targets in external writable directories.
   - Verify `resolve_write` raises `SecurityError` for targets in external readable-only directories.
   - Verify `resolve_write` rejects protected paths (`.git`) inside external writable directories.
3. **Mutation Tool Specs (`spec/tools_spec.cr`):**
   - Test `write_file` creating new files in external writable directory.
   - Test `replace_in_file` with line numbers and diff approval in external writable directory.
   - Test `append_to_file` in external writable directory.
4. **Full Test Suite:**
   - Run `crystal spec` to ensure zero regressions across the codebase.

### 3.2 Verification Evidence
- `spec/settings_spec.cr`: Verified default empty array and loading of `writable_directories` and `writeable_directories` aliases.
- `spec/workspace_spec.cr`: Verified resolution via environment variables (`NIGHTMARE_WRITABLE_DIRS`, `NIGHTMARE_WRITEABLE_DIRS`), CLI flags (`cli_writable_directories`), automatic inclusion of writable directories in `readable_directories`, path containment checks (`sanitize_write_path`, `inside_writable?`), and startup notification banner `Write Dirs:`.
- `spec/guard_spec.cr`: Verified `resolve_write` allows writes to configured writable directories, blocks unauthorized external directories, and unconditionally refuses writes to protected paths (`.git`, `.nightmare`).
- `spec/tools_spec.cr`: Verified `write_file`, `replace_in_file`, and `append_to_file` in external writable directories with side effect tracking, and confirmed rejection of unconfigured external paths.
- `crystal spec`: Full test suite passed with 313 examples, 0 failures, 0 errors.

### 3.3 Validation Plan
1. Configure an external directory `/tmp/shared_skills_repo` in `~/.config/nightmare/config.json` under `writable_directories`.
2. Launch `nightmare` in an arbitrary project workspace.
3. Prompt the agent to add a new skill file `kubernetes_debugging.md` to `/tmp/shared_skills_repo`.
4. Verify the diff approval modal appears with the external target path.
5. Approve and verify the file is created on disk.

### 3.4 Validation Evidence
- Automated integration specs in `spec/tools_spec.cr` verified end-to-end mutation lifecycle (`write_file`, `append_to_file`, `replace_in_file`) on an external directory, diff generation, and side effect registration.

---

## 4. Open Questions & Concurrency Concerns
1. **Spelling Compatibility**: Support both `writable_directories` and `writeable_directories` in configuration and CLI flags to avoid user error (Resolved: Supported in Settings, Environment, and CLI Parser).
2. **Read Implication**: Writing without reading breaks diff generation; ensure `writable_directories` always implies readability (Resolved: Guaranteed by initialization invariant in Environment).

---

## 5. Revision History
* 2026-10-03: Created ticket and detailed specification (TKT-028).
* 2026-10-03: Implemented across Settings, Environment, Guard, Mutation, Registry, and CLI. All 313 specs passing. Status set to Resolved.
---
