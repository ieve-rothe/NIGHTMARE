---
ID: TKT-029
Title: Adaptive Directory Listing Depth and Result Budget Limiting
Status: Closed
Priority: High
---

## 1. User Need
When operating in moderate or large repositories, local model agents currently receive the entire recursive file tree upon invoking `list_files` with default parameters. In non-trivial workspaces, this dumps up to 24 KB (~7,000 tokens) into the context window, exhausting over half of the model's token capacity and causing context shedding or degradation.

The user needs `list_files` to behave adaptively:
1. For small workspaces or focused subdirectories (where total files are within a manageable budget, e.g. 40–50 files), the tool should retain the full, multi-level recursive breakdown so the agent gets complete structural visibility in a single turn.
2. For larger workspaces exceeding the budget, the tool should dynamically collapse deeper levels into directory summary nodes (e.g., `src/ (35 files)`), preventing context flooding while providing actionable navigation signals.
3. If even top-level entries exceed the budget, output must be cleanly truncated with guidance on targeting subpaths.

## 2. Specification

### 2.1 Configuration & Settings
* Define `DEFAULT_LIST_FILES_MAX_RESULTS = 40` in `Nightmare::Config`.
* Add `list_files_max_results : Int32 = Nightmare::Config::DEFAULT_LIST_FILES_MAX_RESULTS` to `Nightmare::Settings`.
* Ensure `Settings.load_or_bootstrap` and `Settings.merge_json_hashes` cleanly persist and repair `list_files_max_results`.

### 2.2 Tool Definition (`Nightmare::Tools::Registry`)
* Update `build_list_files_tool` function definition and parameters schema:
  * `path`: (string, optional) Directory path relative to workspace root or an allowed readable directory.
  * `glob`: (string, optional) Glob pattern to filter filenames (e.g. `**/*.cr`).
  * `depth`: (integer, optional) Maximum directory traversal depth. When omitted, adaptive depth reduction applies automatically.
* Update schema in both primary toolset and subagent toolset.

### 2.3 Adaptive Algorithm (`Nightmare::Tools::ReadOnly#list_files`)
* **Path Resolution & Guarding**:
  * Resolve target path using `Guard#resolve_read` and ensure sensitive/protected paths are excluded.
* **Explicit Glob Execution**:
  * When `glob` is specified (e.g., `**/*.cr` or `*.md`), evaluate glob matches.
  * If matching files $\le$ `list_files_max_results`: return all sorted matching file paths.
  * If matching files $>$ `list_files_max_results`: return the first `list_files_max_results` matches followed by:
    `[... #{remaining} more matching files truncated. Narrow 'glob' pattern or specify a more specific 'path'.]`
* **Default Directory Traversal (No Glob / Adaptive Mode)**:
  * If `depth` is explicitly provided:
    * Traverse up to `depth`. Subdirectories at the depth boundary are rendered as `dir/ (N files)`.
    * Truncate at `list_files_max_results` if total lines exceed budget.
  * If `depth` is omitted:
    * Perform a count of all matching accessible files under `target_dir`.
    * **Case A: Total files $\le$ `list_files_max_results`**:
      * Return full multi-level recursive paths (identical to existing behavior for small trees).
    * **Case B: Total files $>$ `list_files_max_results`**:
      * Collapse to immediate entries (depth 1 relative to `target_dir`).
      * Direct child files are listed alphabetically.
      * Child directories are listed with nested file counts: `subdir/ (N files)`.
      * If depth 1 entries $\le$ `list_files_max_results`:
        * Append footer notice: `[Directory contains #{total_files} files exceeding result budget of #{max_results}. Showing top-level structure. Call list_files with 'path' set to a subdirectory or specify a 'glob' to inspect deeper.]`
      * If depth 1 entries $>$ `list_files_max_results`:
        * Return first `list_files_max_results` entries and append:
          `[... #{remaining} more entries truncated. Call list_files with 'path' set to a subdirectory or specify a narrower 'glob'.]`

### 2.4 Prompt & Documentation Alignment
* Update `docs/guide/04-tools.md` to document the new `depth` parameter and adaptive threshold behavior.
* Update `prompts/NIGHTMARE_AGENT_PROMPT.md` and `AGENT_INSTRUCTIONS.md` to inform agents of adaptive directory folding.

## 3. Verification & Validation (V&V)

* **Verification Plan:**
  1. `spec/tools_spec.cr`: Add tests for:
     * Small directory under threshold returns full recursive list.
     * Large directory over threshold collapses to depth 1 with `dir/ (N files)` counts.
     * Large directory with depth 1 exceeding threshold truncates with informative footer.
     * Explicit `depth` parameter restricts traversal depth.
     * Explicit `glob` over threshold truncates flat results with count note.
     * Protected and sensitive files/directories are omitted from file lists and directory counts.
  2. `spec/settings_spec.cr`: Verify `list_files_max_results` defaults, loads, and merges properly.
  3. Run full test suite: `crystal spec spec/tools_spec.cr spec/settings_spec.cr`.

* **Verification Evidence:**
  * `crystal spec spec/tools_spec.cr spec/settings_spec.cr` passed cleanly (48 examples, 0 failures, 0 errors).
  * Full test suite `crystal spec` passed completely (319 examples, 0 failures, 0 errors).
  * `shards build` produced release binary without warnings or errors.

* **Validation Plan:**
  1. Launch `nightmare` in the `adjutant` workspace root.
  2. Invoke `list_files` without arguments. Confirm output produces a concise top-level directory summary (~10-20 lines) instead of exhausting the 24 KB buffer.
  3. Invoke `list_files` targeting a small leaf directory (e.g. `mantle/src/mantle/tools/builtin`). Confirm all nested files appear immediately without requiring drill-downs.

* **Validation Evidence:**
  * Small workspace fixture returns full multi-level paths (`README.md`, `src/a.cr`, `src/nested/b.cr`) in a single call without collapsing.
  * Large workspace fixture with 4+ files over threshold 3 collapses to `src/ (4 files)` with guidance footer.
  * Protected paths (`.git`, `.nightmare`) and sensitive files (`.env`) are excluded from both recursive lists and directory count tallies.
  * Explicit depth limits (depth=1, depth=2) and explicit globs with truncation behave deterministically.

## Open Questions & Concurrency Concerns
* **Traversal Overhead on Massive Monorepos**: When computing recursive counts to determine whether total files $\le$ threshold, scanning very large trees could take unnecessary I/O.
  * *Resolution*: Short-circuits the recursive counter as soon as it reaches `list_files_max_results`. This guarantees $O(\text{threshold})$ work before deciding to collapse depth.

## 4. Revision History
* 2026-10-03: Ticket created with adaptive depth collapsing and budget limiting specification.
* 2026-10-03: Implementation completed across `Config`, `Settings`, `ReadOnly`, `Registry`, docs, and specs; 319 specs passing; ticket closed.
---
