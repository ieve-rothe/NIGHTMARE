---
ID: TKT-027
Title: Globally Readable External Directories for Shared Repositories and Skills
Status: Resolved
Priority: Med
---

## 1. User Need
Operators and developers frequently maintain centralized resources on their workstations that span across repositories—such as a central repository of agent `SKILL` definitions, shared corporate coding standards, shared architecture guidelines, or common documentation.

Currently, NIGHTMARE enforces a strict, single-root isolation model: all file inspection tools (`read_file`, `list_files`, `search`, `file_info`) and context pinning (`/add`) delegate through `Tools::Guard#resolve_read`, which calls `Workspace::Environment#sanitize_path`. If any requested path resolves outside the active workspace root (`Dir.current` / `@root`), NIGHTMARE halts execution with a fatal `SecurityError: Path traversal violation`.

As a result, agents cannot autonomously discover, search, or read skills and reference files located outside the current working directory, and operators cannot pin external reference files into context. Operators need a secure, configurable way to designate specific directories (and their recursive subtrees) as globally or per-workspace readable, allowing autonomous inspection and context pinning while preserving strict write protection and sensitive pattern defenses.

*(Current Codebase Assessment: Nightmare does not currently have this capability; all read operations are hard-isolated to `@root`.)*

---

## 2. Specification

### 2.1 Configuration Schema & Hierarchy
1. **Settings Extension (`Nightmare::Settings`):**
   - Add property:
     ```crystal
     property readable_directories : Array(String) = [] of String
     ```
   - Configurable at three levels with inherited aggregation:
     - **Global Config** (`~/.config/nightmare/config.json`): Applies to all workspaces on the machine (e.g., `["/home/cam/repos/skills", "/home/cam/docs/standards"]`).
     - **Workspace Central Config** (`~/.config/nightmare/workspaces/<id>/config.json`): Adds workspace-specific external readable paths.
     - **Repo Config** (`.nightmare/settings.json` or `.nightmare/config.json`): Adds repo-specific external readable paths.
   - When merging settings, paths from all configured levels are combined and deduplicated.

2. **CLI & Environment Variable Overrides:**
   - **CLI Flags**: Add `-R PATH` / `--read-dir=PATH` (can be specified multiple times) in `Nightmare::CLI::Parser`.
   - **Environment Variable**: `NIGHTMARE_READABLE_DIRS` (colon-delimited list of paths, e.g., `/path/a:/path/b`).

3. **Path Normalization:**
   - At initialization time, `Environment` normalizes all paths via `File.expand_path`, expands `~`, resolves symlinks via `File.realpath` (if the directory exists on disk), and retains existing directories.
   - Non-existent directories produce a graceful warning at startup rather than an unhandled crash.

### 2.2 Security Model & Guard Enforcement (`Nightmare::Tools::Guard`)
1. **Read Path Resolution (`Guard#resolve_read`):**
   - A target path is allowed for read access if:
     a) It resolves within `@env.root` (standard workspace containment), OR
     b) It resolves within any directory specified in `@env.settings.readable_directories` (canonical subtree containment check via realpath).
   - If neither condition is met, raise `SecurityError.new("Path traversal violation: target '#{path}' is outside root and not in allowed readable directories")`.
2. **Sensitive File Protection Remains Universal:**
   - All paths resolved within external readable directories remain subject to `Guard#sensitive_read?` checks.
   - Block any files matching `DEFAULT_SENSITIVE_PATTERNS` (`.env*`, `*.pem`, `id_rsa*`, `*secret*`, `*credential*`, `.git`, `.git/**`).
3. **Strict Mutation Isolation (Zero External Writes):**
   - `Guard#resolve_write` remains strictly bounded to `@env.root`.
   - External readable directories are strictly READ-ONLY. Any attempt by `write_file`, `replace_in_file`, or `append_to_file` to target an external readable directory must be unconditionally rejected with `SecurityError`.
4. **Symlink Traversal Containment:**
   - Symlinks inside external readable directories that point outside both `@env.root` and configured readable directories are blocked using symlink-safe resolution (`safe_realpath`).

### 2.3 Tool Ergonomics & File Discovery (`Nightmare::Tools::ReadOnly`)
1. **`list_files(path : String?, glob : String?)`:**
   - When `path` is omitted, lists files in the workspace root as before.
   - When `path` is provided and points to a configured readable directory outside the workspace root (e.g., `list_files(path: "/home/cam/repos/skills", glob: "**/*.md")`):
     - Validates directory existence and permission via `Guard#resolve_read`.
     - Recursively scans matching files, excluding protected and sensitive files.
     - Returns paths prefixed by the target path or clean relative paths that can be passed directly to `read_file`.
2. **`search(pattern : String, path : String?, glob : String?)`:**
   - Supports passing an external readable path as `path`.
   - Formats matched lines with clear path prefixes for direct consumption by the agent.
3. **`read_file(path : String, offset : Int32?, limit : Int32?)`:**
   - Accepts external paths validated by `Guard#resolve_read`.
   - Preserves pagination (`offset`, `limit`), token estimation, and per-file token ceilings.
4. **`file_info(path : String)`:**
   - Returns metadata for files located in external readable directories.

### 2.4 Context Pinning Ergonomics (`Nightmare::Commands::Router` & `PinnedFiles`)
1. **`/add <path>`:**
   - Supports pinning external files from allowed readable directories into active context.
   - `PinnedFiles#add` delegates through `guard.resolve_read(path)`.
   - `PinnedFiles#render_pinned_block` formats the header cleanly: `=== PINNED FILE: <path> ===`.

### 2.5 Agent Awareness & Observability
1. **System Prompt & Discovery:**
   - When external readable directories are configured, include a brief system note in context assembly or tool descriptions:
     `Allowed external readable directories: <list>` so the LLM agent is aware that external repositories or skill directories are available for inspection.
2. **Startup Banner:**
   - Display configured readable directories in `Environment#startup_banner` when running in standard interactive mode:
     ```
     ┌── NIGHTMARE ────────────────────────────────────────────────────────────┐
     │ Workspace : /home/cam/repos/adjutant/nightmare                          │
     │ Config    : ~/.config/nightmare/workspaces/nightmare-abc/               │
     │ State/Logs: ~/.local/state/nightmare/workspaces/nightmare-abc/          │
     │ Read Dirs : /home/cam/repos/skills                                      │
     └─────────────────────────────────────────────────────────────────────────┘
     ```

---

## 3. Verification & Validation (V&V)

### 3.1 Verification Plan (Automated Unit & Integration Specs)
1. **Settings & Environment Specs (`spec/workspace/environment_spec.cr`, `spec/settings_spec.cr`):**
   - Verify `readable_directories` parses from global `config.json`, workspace `config.json`, and repo `settings.json`.
   - Verify CLI option `--read-dir` and environment variable `NIGHTMARE_READABLE_DIRS` populate `readable_directories`.
   - Verify path normalization and expansion (`~`, relative paths, realpaths).
2. **Guard Security Specs (`spec/tools/guard_spec.cr`):**
   - Verify `resolve_read` succeeds for paths within workspace root.
   - Verify `resolve_read` succeeds for files inside configured readable directories (root and nested subdirectories).
   - Verify `resolve_read` raises `SecurityError` for paths outside workspace root that are not in readable directories.
   - Verify `resolve_read` raises `SecurityError` for sensitive files (`.env`, `id_rsa`, `.git/config`) located inside readable directories.
   - Verify `resolve_write` raises `SecurityError` when targeting files inside external readable directories.
3. **Read-Only Tools Specs (`spec/tools/read_only_spec.cr`):**
   - Test `list_files` with `path` pointing to an external readable directory.
   - Test `search` with `path` pointing to an external readable directory.
   - Test `read_file` with offset/limit on external readable files.
   - Test `file_info` on external readable files.
4. **Slash Command Specs (`spec/commands/router_spec.cr`):**
   - Test `/add <external_file_path>` successfully pins external file.
   - Test `/drop <external_file_path>` unpins it.
   - Test `/review` correctly includes external pinned file tokens and content.
5. **Regression Verification:**
   - Run full spec suite: `crystal spec`.

### 3.2 Verification Evidence
- `spec/settings_spec.cr`: Verified default empty array and bootstrap serialization of `readable_directories`.
- `spec/workspace_spec.cr`: Verified resolution of `readable_directories` from environment variables (`NIGHTMARE_READABLE_DIRS`), CLI overrides, and configuration; verified `sanitize_read_path` allows external paths while `sanitize_path` rejects writes; verified `startup_banner` renders configured directories.
- `spec/tools/guard_spec.cr`: Verified `resolve_read` grants access to external readable subtrees, `resolve_write` strictly blocks mutations, and sensitive read patterns (`.env`, `id_rsa`, `.git/config`) remain blocked.
- `spec/tools_spec.cr`: Verified `list_files`, `search`, `read_file`, and `file_info` on external readable directories.
- `spec/pinned_files_spec.cr`: Verified pinning and prompt block rendering for external files.
- `spec/commands/router_spec.cr`: Verified `/add`, `/review`, and `/drop` slash commands with external file paths.
- Full test suite: `crystal spec` passing 307 examples, 0 failures, 0 errors, 0 pending (1:36m).

### 3.3 Validation Plan
1. Configure `~/.config/nightmare/config.json` with an external directory containing markdown skill files (`/tmp/shared_skills`).
2. Launch `nightmare` in an arbitrary workspace directory.
3. Verify startup banner displays `Read Dirs: /tmp/shared_skills`.
4. Ask the agent: *"Find the skill file for database migrations in my shared skills directory and tell me what guidelines it defines."*
5. Confirm the agent successfully calls `list_files(path: "/tmp/shared_skills")`, identifies the file, calls `read_file`, and incorporates it into context.
6. Attempt to mutate the external file (e.g. agent attempting `write_file` or `/add` then editing) and verify mutation is firmly rejected.

### 3.4 Validation Evidence
- Verified via unit and end-to-end tool harness specs that external skills directories can be listed, searched, read, and pinned into context while mutating them is strictly prevented.

---

## 4. Open Questions & Concurrency Concerns
1. **Tool Description Prompting**: Addressed; tool schemas (`list_files`, `search`, `read_file`, `file_info`) updated to clarify that external allowed readable directories are supported, and the active allowed readable directories are appended to the system prompt in `REPL`.
2. **Glob Pattern Matching**: Addressed; `ReadOnly#list_files` and `ReadOnly#search` preserve the caller-provided directory prefix so paths returned can be directly consumed by `read_file`.
3. **Mantle FileSystemSandbox Alignment**: Addressed; `Guard#initialize` supplies `allowed_paths = [@env.root] + @env.readable_directories` to `Mantle::Tools::FileSystemSandbox`.

---

## 5. Revision History
* 2026-10-03: Created ticket and detailed technical implementation plan (TKT-027).
* 2026-10-03: Implemented `readable_directories` across `Settings`, `Environment`, `Guard`, `ReadOnly`, `Registry`, `CLI`, and `Router`. Added 9 test cases covering security boundaries, tool ergonomics, and context pinning. All 307 specs passing. Status updated to Resolved.
---
