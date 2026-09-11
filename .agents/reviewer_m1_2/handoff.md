# Milestone 1 Independent Review Report: Workspace Anchoring & Central XDG Mapping

**Reviewer**: `reviewer_m1_2` (Roles: reviewer, critic)  
**Parent**: `orchestrator_1` (Conv ID: `3ad3ad0f-7c04-4b8b-8435-1ed5dba552db`)  
**Target Milestone**: Milestone 1 (F1.1 - F1.8, F6.1)  
**Verdict**: **APPROVE**  

---

## 1. Observation

### 1.1 Dependency Resolution & Framework Linkage (F6.1)
- `shard.yml` specifies path dependencies linking local sibling frameworks:
  ```yaml
  dependencies:
    mantle:
      path: ../mantle
    salamander:
      path: ../salamander
    tts_kokoro:
      path: ../tts_kokoro
  ```
- Command execution `shards check` directly observed:
  ```
  I: Dependencies are satisfied
  ```
  Exited with code 0.

### 1.2 Clean Compilation with Zero Warnings
- Executed `shards build` in `/home/cam/repos/adjutant/nightmare`:
  ```
  I: Dependencies are satisfied
  I: Building: nightmare
  ```
  Exited with code 0.
- Executed `crystal build src/nightmare.cr --warnings all --no-codegen`:
  Zero warnings and zero errors produced on stdout and stderr. Exited with code 0.
- Binary verification:
  - `./bin/nightmare --version` returned `NIGHTMARE 0.1.0` (exit code 0).
  - `./bin/nightmare --help` returned option flags `-s`, `--system`, `--no-log`, `-m`, `--model`, `-v`, `--version`, `-h`, `--help` (exit code 0).
  - `./bin/nightmare` (default) rendered the exact Unicode box banner:
    ```text
    ┌── NIGHTMARE ─────────────────────────────────────────────────────────────┐
    │ Workspace : /home/cam/repos/adjutant/nightmare                           │
    │ Config    : ~/.config/nightmare/workspaces/nightmare-b97495a0/           │
    │ State/Logs: ~/.local/state/nightmare/workspaces/nightmare-b97495a0/      │
    └──────────────────────────────────────────────────────────────────────────┘
    ```
    Exited with code 0.

### 1.3 Full Test Suite Execution
- Executed `crystal spec spec/workspace_spec.cr spec/directives_spec.cr spec/nightmare_spec.cr spec/e2e/test_runner_spec.cr`:
  ```
  .............................Notice: Editor exited with non-zero status (1). In-memory directive unchanged.
  .................

  Finished in 5.07 seconds
  46 examples, 0 failures, 0 errors, 0 pending
  ```
  Exited with code 0.

### 1.4 Code Inspection & Integrity Check
1. `src/nightmare/exceptions.cr`:
   - Top-level `SecurityError < Exception` defined.
   - Namespaced alias `Nightmare::SecurityError = ::SecurityError` provided.
   - `Nightmare::Error < Exception` and `Nightmare::ConfigurationError < Error` defined.
2. `src/nightmare/workspace/environment.cr`:
   - Line 33: `@root = File.realpath(root_path)` immutably canonicalizes the anchor root.
   - Lines 35-40: Deterministic workspace ID generated as `#{slug}-#{hash}` using `File.basename(@root).gsub(/[^a-zA-Z0-9_-]/, "_")` and `Digest::SHA256.hexdigest(@root)[0..7]`.
   - Lines 42-58: XDG paths mapped cleanly to central XDG homes (`$XDG_CONFIG_HOME`, `$XDG_STATE_HOME`, `$XDG_CACHE_HOME`).
   - Lines 137-164 (`resolve_contained_path`): Recursively inspects existing ancestors via `File.realpath` and `File.symlink?`, rejoining non-existent path segments.
   - Lines 166-169 (`path_inside_root?`): Appends trailing slash to `@root` when verifying prefix, preventing sibling collision attacks (`path == @root || path.starts_with?("#{@root}/")`).
   - Lines 96-102 (`sanitize_path`): Raises `SecurityError` on any escape attempt.
   - Lines 104-110 (`git_path?`): Correctly identifies paths inside `.git/` vs regular files.
3. `src/nightmare/workspace/manifest.cr`:
   - `Manifest`: Implements JSON serialization for `workspace.json`.
   - `AuditLog`: Enforces 20 MB size threshold (`MAX_SIZE = 20_971_520_i64`), rotates up to 3 historical generations (`.1`, `.2`, `.3`), and respects `@enabled` (disabling logging when `--no-log` is active).
4. `src/nightmare/directives/resolver.cr`:
   - Enforces 5-tier resolution in exact precedence:
     1. CLI flag (`-s` / `--system <path>`)
     2. Repo committed override (`.nightmare/prompt.md`)
     3. Workspace central config (`$XDG_CONFIG_HOME/nightmare/workspaces/<id>/prompt.md`)
     4. Global central config (`$XDG_CONFIG_HOME/nightmare/prompt.md`)
     5. Default general persona fallback (`DEFAULT_PERSONA`)
   - Blank / whitespace file fallthrough: files containing only whitespace fall through to the next tier.
   - `DirectiveBuffer` executes in-memory editing on `/tmp` tempfile, deletes tempfile in `ensure`, reverts on non-zero editor exit, and never mutates repository or XDG files on disk.
5. `src/nightmare.cr`:
   - Guarded via `{% if !@top_level.has_constant?("Spec") %}`, ensuring CLI execution only occurs in standalone binary mode and never interferes with the spec runner.

### 1.5 Adversarial Stress Test Results
- Out-of-tree symlinks: Dereferenced target outside `@root` strictly raises `Nightmare::SecurityError`.
- Broken symlinks: Target does not exist; `File.realpath` raises `File::Error` which is caught and re-raised as `Nightmare::SecurityError: Unresolvable path`.
- Ancestor broken symlinks: `sanitize_path("broken_link/nested/new.cr")` raises `Nightmare::SecurityError: Unresolvable path`.
- Circular symlink loops (`link_a -> link_b`, `link_b -> link_a`): Resolves ancestor error and raises `Nightmare::SecurityError: Unresolvable path`.
- Sibling directory prefix collisions (`/tmp/repo` vs `/tmp/repo_evil`): Strictly rejected because prefix matching checks `/tmp/repo/`.
- Null byte injection (`"src/\0foo.cr"`): Caught by Crystal standard library (`ArgumentError: String contains null byte`).
- Zero repo litter: Repeated launches, directory sanitizations, and directive edits leave zero files created or modified inside the target repository. `git status` confirms working tree cleanliness.
- Integrity verification: No hardcoded test responses, no facade classes, no dummy implementations.

---

## 2. Logic Chain

1. **Root Containment and Path Safety**:
   - `File.realpath(root_path)` canonicalizes the root at startup.
   - `resolve_contained_path` handles both existing files, symlinks, and non-existent targets (needed for upcoming file creation tools in M3) by walking up to the nearest existing ancestor.
   - Testing against `#{@root}/` ensures that sibling directories sharing a prefix cannot bypass containment.
   - Dereferencing symlinks before prefix checking ensures that in-repo symlinks pointing outside the repository are blocked with `SecurityError`.
   - All tests and adversarial probes verify that containment cannot be bypassed.

2. **Zero Repository Litter Invariant**:
   - Manifests, command allowlists, logs, and caches are routed strictly through `$XDG_*` directories partitioned by `<slug>-<hash>`.
   - `.nightmare/prompt.md` in `@root` is only read if present, never created.
   - DirectiveBuffer edits use `/tmp` and clean up immediately.
   - Verification with `git status` confirms that no untracked files or metadata exist in the project directory.

3. **Directive Resolution Precedence**:
   - Resolution order follows CLI > repo > workspace > global > default persona.
   - Non-existent CLI paths trigger `ArgumentError`.
   - Empty or whitespace files safely fall through.
   - Tested across all 5 tiers individually and in combined precedence tests.

4. **Code Quality and Compilation**:
   - Compiles cleanly with zero warnings under `--warnings all`.
   - All 46 specs pass with zero failures or errors.
   - Macro guard properly decouples binary invocation from spec runner.

---

## 3. Caveats

No caveats. All Milestone 1 functional requirements and security invariants (F1.1 - F1.8, F6.1) are fully implemented and verified. Downstream REPL loops and tool executions are deferred to subsequent milestones (M2 - M5) as planned.

---

## 4. Conclusion

**Verdict: APPROVE**

The Milestone 1 implementation is clean, robust, adheres strictly to specifications, and successfully passes all verification and adversarial tests. The codebase is ready for Milestone 2.

---

## 5. Verification Method

To independently reproduce this verification:

```bash
cd /home/cam/repos/adjutant/nightmare

# 1. Verify shard dependencies
shards check

# 2. Build binary cleanly
shards build

# 3. Check compilation warnings
crystal build src/nightmare.cr --warnings all --no-codegen

# 4. Verify CLI banner and flags
./bin/nightmare --version
./bin/nightmare --help
./bin/nightmare

# 5. Run full M1 test suite
crystal spec spec/workspace_spec.cr spec/directives_spec.cr spec/nightmare_spec.cr spec/e2e/test_runner_spec.cr
```

Expected result: 46 examples, 0 failures, 0 errors, 0 pending. Zero warnings.
