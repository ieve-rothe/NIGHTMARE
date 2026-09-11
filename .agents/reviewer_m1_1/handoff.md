# Milestone 1 Review & Adversarial Challenge Report

**Reviewer**: `reviewer_m1_1`  
**Parent**: `orchestrator_1` (Conv ID: `3ad3ad0f-7c04-4b8b-8435-1ed5dba552db`)  
**Scope**: Milestone 1 Implementation (`exceptions.cr`, `environment.cr`, `manifest.cr`, `resolver.cr`, `nightmare.cr`, spec suite)  
**Verdict**: **APPROVE**  
**Integrity Audit**: **CLEAN (Zero Violations)**  

---

## 1. Observation

### 1.1 Command Execution & Independent Verification
All verification commands were executed within `/home/cam/repos/adjutant/nightmare` with `BypassSandbox: true`:

1. **Dependency Verification**:
   ```bash
   shards check
   ```
   *Output*:
   ```text
   I: Dependencies are satisfied
   ```
   *Result*: Code 0.

2. **Clean Build Verification**:
   ```bash
   shards build
   ```
   *Output*:
   ```text
   I: Dependencies are satisfied
   I: Building: nightmare
   ```
   *Result*: Code 0. Zero warnings, zero errors. Built `bin/nightmare`.

3. **Test Suite Verification**:
   ```bash
   crystal spec spec/workspace_spec.cr spec/directives_spec.cr spec/nightmare_spec.cr spec/e2e/test_runner_spec.cr
   ```
   *Output*:
   ```text
   .............................Notice: Editor exited with non-zero status (1). In-memory directive unchanged.
   .................

   Finished in 5.07 seconds
   46 examples, 0 failures, 0 errors, 0 pending
   ```
   *Result*: Code 0. All 46 examples passed with zero failures or errors.

4. **CLI Binary Execution**:
   - `./bin/nightmare --version` -> `NIGHTMARE 0.1.0` (Exit code 0)
   - `./bin/nightmare --help` -> Formatted usage and flag description (Exit code 0)
   - `./bin/nightmare /nonexistent/dir` -> `Fatal Initialization Error: Workspace directory does not exist: /nonexistent/dir` (Exit code 1)
   - `./bin/nightmare -s /nonexistent/prompt.md` -> Startup banner followed by `Directive Error: System directive file not found: ...` (Exit code 1)
   - `./bin/nightmare` -> Emits structured Unicode box banner matching exact specification (Exit code 0):
     ```text
     ┌── NIGHTMARE ─────────────────────────────────────────────────────────────┐
     │ Workspace : /home/cam/repos/adjutant/nightmare                           │
     │ Config    : ~/.config/nightmare/workspaces/nightmare-b97495a0/           │
     │ State/Logs: ~/.local/state/nightmare/workspaces/nightmare-b97495a0/      │
     └──────────────────────────────────────────────────────────────────────────┘
     ```

### 1.2 Code Inspection
1. `src/nightmare/exceptions.cr`:
   - Line 1: `class SecurityError < Exception; end`
   - Line 5: `module Nightmare; alias SecurityError = ::SecurityError; ... end`
   - Defines `Nightmare::Error` and `Nightmare::ConfigurationError`.
2. `src/nightmare/workspace/environment.cr`:
   - Line 33: `@root = File.realpath(root_path)` immutably locks canonical path.
   - Lines 35-40: Deterministic slug generation with character filtering and 8-character SHA-256 hash calculation: `workspace_id = "#{slug}-#{hash}"`.
   - Lines 42-57: Central XDG paths resolved outside `@root`.
   - Lines 96-102: `sanitize_path` validates that canonical ancestor targets reside within `@root`.
   - Lines 104-110: `git_path?` helper identifies paths pointing to `.git`.
   - Lines 112-135: `startup_banner` builds box banner with minimum 72 content width and aligned borders.
3. `src/nightmare/workspace/manifest.cr`:
   - Lines 5-56: `Manifest` struct with JSON serialization, `touch`, `load_or_create`, and `bootstrap`. Timestamps normalized with `at_beginning_of_second`.
   - Lines 58-117: `AuditLog` class with 20MB limit (`MAX_SIZE = 20_971_520_i64`), 3 rotated files retention (`MAX_ROTATED = 3`), atomic rotation, and `--no-log` disabled toggle.
4. `src/nightmare/directives/resolver.cr`:
   - Lines 4-20: `Source` enum covering 5 tiers.
   - Lines 22-28: `DEFAULT_PERSONA` verbatim match to specification.
   - Lines 58-118: 5-tier resolution hierarchy (CLI > repo > workspace > global > default persona).
   - Lines 146-250: `DirectiveBuffer` managing in-memory active directives; `edit` forks editor on an ephemeral tempfile without touching disk files.
5. `src/nightmare.cr`:
   - Lines 23-79: `Nightmare::CLI::Parser` parsing flags and workspace paths.
   - Lines 100-117: Resolves environment and directive manager.
   - Lines 123-125: Macro guard `{% if !@top_level.has_constant?("Spec") %}` isolating CLI execution during test runs.

---

## 2. Logic Chain

1. **Integrity Audit**:
   - Verification inspected every line of source code in `src/nightmare/`.
   - No mock responses, hardcoded return values, facade implementations, or task bypasses exist.
   - Implementations interact with the live Linux filesystem and Crystal standard library.
   - Conclusion: Zero integrity violations.

2. **Workspace Anchoring & Path Safety (F1.1, F1.2, F1.5)**:
   - Observation: `sanitize_path` uses `resolve_contained_path` to resolve non-existent targets by walking to the nearest existing ancestor, resolving `File.realpath`, and checking `path == @root || path.starts_with?("#{@root}/")`.
   - Result: Escaping traversals (`../`, `/etc/passwd`), out-of-tree symlinks, dangling symlinks, and sibling prefix collision attacks (`/repo_fake` vs `/repo`) are deterministically blocked with `Nightmare::SecurityError`.
   - Central XDG directories are placed in `$HOME/.config`, `$HOME/.local/state`, `$HOME/.cache` (or custom XDG paths), leaving the target repository with zero litter (`Dir.children(dir).should be_empty`).

3. **Deterministic Partitioning & Logging (F1.3, F1.4)**:
   - Observation: Basename is sanitized to `[a-zA-Z0-9_-]` and combined with the first 8 hex characters of `SHA256(@root)`.
   - Result: Stable, idempotent workspace identifier across invocations.
   - Audit logging handles JSON and text payloads and rotates up to 3 generations when size exceeds 20MB.

4. **Directives Precedence & In-Memory Mutation (F1.6, F1.8)**:
   - Observation: Tier resolution cascades CLI -> repo `.nightmare/prompt.md` -> workspace config -> global config -> default general persona.
   - Result: Missing files or whitespace-only files correctly fall through.
   - `DirectiveBuffer#edit` writes to a `/tmp` tempfile, executes `$EDITOR` or `$VISUAL`, updates in-memory prompt only on exit status 0, and cleanly deletes the tempfile in `ensure`. Disk configuration files remain untouched.

---

## 3. Caveats

1. The interactive Salamander REPL loop and tool execution harness are planned for downstream milestones (M2 through M5). At M1, `Nightmare::CLI.run` handles option parsing, banner printing, workspace bootstrapping, and directive loading.
2. In `git_path?`, checking `rel == ".git" || rel.starts_with?(".git/")` catches target repository root git operations. For git submodule operations in M3, checking all path segments for `.git` is recommended.

---

## 4. Conclusion

**Verdict: APPROVE**

The Milestone 1 work product meets all architectural and functional specifications (F1.1 - F1.8, F6.1):
- Dependency resolution and compilation succeed cleanly with zero warnings or errors.
- The 46-example unit and integration test suite passes 100%.
- Path security, zero repository litter, deterministic workspace identification, audit logging, directive hierarchy, in-memory directive buffering, and CLI entry point are fully implemented.

---

## 5. Verification Method

To independently reproduce verification:

```bash
cd /home/cam/repos/adjutant/nightmare

# 1. Verify dependencies
shards check

# 2. Build binary
shards build

# 3. Test CLI
./bin/nightmare --version
./bin/nightmare --help
./bin/nightmare

# 4. Run test suite
crystal spec spec/workspace_spec.cr spec/directives_spec.cr spec/nightmare_spec.cr spec/e2e/test_runner_spec.cr
```

---

## 6. Quality Review

### Review Summary
**Verdict**: **APPROVE**

### Findings

#### [Minor] Suggestion 1: Submodule `.git` Path Protection in M3
- **What**: `git_path?` checks whether relative path starts with `.git` or `.git/`.
- **Where**: `src/nightmare/workspace/environment.cr:107`
- **Why**: Protects the root repository's `.git/` directory. However, git repositories containing submodules may have paths like `vendor/module/.git`.
- **Suggestion**: When implementing mutation tools in M3 (F3.4), ensure `.git` protection checks `Path.new(sanitized).parts.includes?(".git")` so nested submodule git directories are also defended.

### Verified Claims
- `shards check` dependencies satisfied -> verified via run_command -> **PASS**
- `shards build` produces `bin/nightmare` with zero warnings -> verified via run_command -> **PASS**
- 46 spec examples pass -> verified via `crystal spec` -> **PASS**
- Path traversal and symlink escape blocked with `SecurityError` -> verified via specs and adversarial eval -> **PASS**
- Deterministic `<slug>-<hash>` workspace ID -> verified via specs and eval -> **PASS**
- 5-tier directive precedence -> verified via specs -> **PASS**
- In-memory directive edit without disk mutation -> verified via specs and eval -> **PASS**

### Coverage Gaps
- None for Milestone 1 scope.

### Unverified Items
- None.

---

## 7. Adversarial Challenge Report

### Challenge Summary
**Overall Risk Assessment**: **LOW**

### Challenges

#### Challenge 1: Symlink Cycles within Root
- **Assumption Challenged**: Can an attacker create a recursive symlink cycle inside the workspace root to cause an infinite loop or stack overflow in `sanitize_path`?
- **Attack Scenario**: Create `loop1 -> loop2` and `loop2 -> loop1` inside the workspace root, then call `sanitize_path("loop1")`.
- **Actual Behavior**: `resolve_contained_path` executes `File.realpath(curr)`. Crystal's runtime detects the symlink cycle and raises `File::Error: Error resolving realpath: Too many levels of symbolic links`. The rescue block catches this and safely raises `SecurityError.new("Unresolvable path: loop1")`.
- **Result**: **DEFENDED (PASS)**.

#### Challenge 2: Sibling Prefix Collision Attacks
- **Assumption Challenged**: Does path containment naively use string prefix checking (e.g. `/tmp/repo_fake` matching `/tmp/repo`)?
- **Attack Scenario**: Workspace root `/tmp/repo`, sibling path `/tmp/repo_attacker/secret.txt`.
- **Actual Behavior**: `path_inside_root?` verifies `path == @root || path.starts_with?("#{@root}/")`. Since `/tmp/repo_attacker` neither equals `/tmp/repo` nor starts with `/tmp/repo/`, it raises `Nightmare::SecurityError`.
- **Result**: **DEFENDED (PASS)**.

#### Challenge 3: Dangling Out-of-Tree Symlink
- **Assumption Challenged**: If a symlink inside the workspace points to a non-existent path outside the workspace, does the non-existent file creation logic bypass the check?
- **Attack Scenario**: `link_out -> /nonexistent/outside/path`. Calling `sanitize_path("link_out/new_file.txt")`.
- **Actual Behavior**: Loop stops on `link_out` because `File.symlink?(curr)` is true even though `File.exists?(curr)` is false. It then calls `File.realpath(link_out)`, which detects that the destination is outside `@root` (or non-existent) and raises `SecurityError`.
- **Result**: **DEFENDED (PASS)**.

#### Challenge 4: In-Memory Directive Edit with Empty Output or Failure
- **Assumption Challenged**: What happens if the user clears all text in `$EDITOR` or the editor crashes?
- **Attack Scenario**: Editor writes 0 bytes or exits with status 127 / 1.
- **Actual Behavior**: `DirectiveBuffer#edit` inspects exit status and trimmed content. On empty content or non-zero exit code, it emits a notice/warning to STDERR, leaves `@current_text` intact with its original value, and returns `false`.
- **Result**: **DEFENDED (PASS)**.

### Stress Test Results
- Symlink loop -> raises `SecurityError` -> **PASS**
- Out-of-tree symlink -> raises `SecurityError` -> **PASS**
- Path traversal (`../`, `../../`, `/etc/passwd`) -> raises `SecurityError` -> **PASS**
- Sibling directory prefix collision -> raises `SecurityError` -> **PASS**
- Non-existent file in valid directory -> returns sanitized canonical path -> **PASS**
- Null byte in path string -> raises `ArgumentError` -> **PASS**
- Audit log rotation over 20MB -> rotates `.1`, `.2`, `.3` -> **PASS**
- Missing system prompt file flag -> prints banner and exits 1 -> **PASS**
- Missing workspace directory argument -> exits 1 with initialization error -> **PASS**
