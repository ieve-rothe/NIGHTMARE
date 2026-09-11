# Milestone 1 Handoff Report: Workspace Anchoring & Central XDG Mapping (F1.1 - F1.8, F6.1)

**Agent**: `worker_m1_1`  
**Parent**: `orchestrator_1` (Conv ID: `3ad3ad0f-7c04-4b8b-8435-1ed5dba552db`)  
**Status**: Milestone 1 Complete & Verified (100% Passing Tests, Clean Build)  

---

## 1. Observation

### 1.1 Dependency Resolution & Framework Linkage (F6.1)
`shard.yml` was configured with local path dependencies:
```yaml
dependencies:
  mantle:
    path: ../mantle
  salamander:
    path: ../salamander
  tts_kokoro:
    path: ../tts_kokoro
```
Command execution:
```
shards install
I: Resolving dependencies
I: Installing mantle (1.1.0 at ../mantle)
I: Installing tts_kokoro (0.1.0 at ../tts_kokoro)
I: Installing salamander (0.2.0 at ../salamander)
I: Writing shard.lock
```
Verification with `shards check`:
```
shards check
I: Dependencies are satisfied
```

### 1.2 Implemented Core Modules
The following source files were authored and verified:
1. `src/nightmare/exceptions.cr`:
   - Defines top-level `SecurityError < Exception` and `Nightmare::SecurityError = ::SecurityError` alias.
   - Defines `Nightmare::Error` and `Nightmare::ConfigurationError`.
2. `src/nightmare/workspace/manifest.cr`:
   - `struct Nightmare::Workspace::Manifest` with `JSON::Serializable`, `load`, `save`, `touch`, `bootstrap`, `load_or_create`.
   - Timestamps initialized with `Time.utc.at_beginning_of_second` to ensure exact second-precision ISO-8601 equality across serialization rounds.
   - `class Nightmare::Workspace::AuditLog` implementing atomic size-based rotation at 20MB (`MAX_SIZE = 20_971_520_i64`), retaining up to 3 historical generations (`.1`, `.2`, `.3`), disabled if `--no-log` is passed.
3. `src/nightmare/workspace/environment.cr`:
   - Canonical root resolution: immutable `@root = File.realpath(root_path)`.
   - Deterministic workspace ID: `slug = File.basename(@root).gsub(/[^a-zA-Z0-9_-]/, "_")`, `hash = Digest::SHA256.hexdigest(@root)[0..7]`, `workspace_id = "#{slug}-#{hash}"`.
   - Central XDG base directory mapping (`$XDG_CONFIG_HOME`, `$XDG_STATE_HOME`, `$XDG_CACHE_HOME`) mapped to `.../nightmare/workspaces/<workspace_id>/`.
   - Defensive path sanitization: `sanitize_path(path)` resolves ancestors to allow non-existent file creation while blocking traversal (`../`) and dereferencing out-of-tree symlinks.
   - Sibling prefix collision defense: `inside_root?` verifies `path == @root || path.starts_with?("#{@root}/")`.
   - Zero repo litter: configuration and log directories are created strictly inside central XDG homes; `@root` is never written to.
   - Startup banner: renders a 76-character Unicode box with workspace root, config path, and state path.
4. `src/nightmare/directives/resolver.cr`:
   - 5-tier hierarchical resolution in strict precedence:
     1. CLI flag (`-s` / `--system <path>`)
     2. Repository committed file (`.nightmare/prompt.md` within `@root`)
     3. Workspace central config (`$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/prompt.md`)
     4. Global central config (`$XDG_CONFIG_HOME/nightmare/prompt.md`)
     5. Default general persona fallback (`DEFAULT_PERSONA`)
   - Blank / whitespace file fallthrough: files containing only whitespace fall through to subsequent tiers.
   - `ResolutionResult` struct providing property access (`result.text`, `result.source`, `result.path`) and tuple destructuring (`text, source = ...`).
   - `DirectiveBuffer` (aliased to `Manager`) for in-memory `/prompt edit` operations: edits an ephemeral `/tmp` tempfile and updates in-memory prompt on exit 0, reverting on error, with zero disk mutation.
5. `src/nightmare.cr`:
   - `Nightmare::CLI::Parser` and `Nightmare::CLI::Options` supporting `-s`/`--system`, `-m`/`--model`, `--no-log`, `-v`/`--version`, `-h`/`--help`, and positional workspace directories.
   - CLI execution guarded by `{% if !@top_level.has_constant?("Spec") %}` macro guard.

### 1.3 Compilation and Test Suite Output
- `crystal build src/nightmare.cr --warnings all -o bin/nightmare`:
  Zero warnings, zero errors. Exit code 0.
- `shards build`:
  Zero warnings, zero errors. Produced `bin/nightmare`.
- `./bin/nightmare --version`:
  `NIGHTMARE 0.1.0`
- `./bin/nightmare` (default run output):
  ```text
  ┌── NIGHTMARE ─────────────────────────────────────────────────────────────┐
  │ Workspace : /home/cam/repos/adjutant/nightmare                           │
  │ Config    : ~/.config/nightmare/workspaces/nightmare-b97495a0/           │
  │ State/Logs: ~/.local/state/nightmare/workspaces/nightmare-b97495a0/      │
  └──────────────────────────────────────────────────────────────────────────┘
  ```
- Test run: `crystal spec spec/nightmare_spec.cr spec/workspace_spec.cr spec/directives_spec.cr spec/e2e/test_runner_spec.cr`:
  ```
  ...............................Notice: Editor exited with non-zero status (1). In-memory directive unchanged.
  ...............

  Finished in 5.07 seconds
  46 examples, 0 failures, 0 errors, 0 pending
  ```

---

## 2. Logic Chain

1. **Path Safety & Boundary Isolation (F1.1, F1.2)**:
   - Observation: `sanitize_path` resolves non-existent targets by walking up the path hierarchy to the nearest existing ancestor, resolving its realpath via `File.realpath`, and checking whether the resulting path satisfies `path == @root || path.starts_with?("#{@root}/")`.
   - Deductions:
     - Sibling directories sharing a common prefix (e.g. `/tmp/repo_fake` when root is `/tmp/repo`) are rejected because `/tmp/repo_fake` neither equals `/tmp/repo` nor starts with `/tmp/repo/`.
     - Out-of-tree symlinks are dereferenced to their canonical destination, failing the root containment test and raising `Nightmare::SecurityError`.
     - Path traversals with `../` escape the boundary and raise `Nightmare::SecurityError`.
     - Non-existent files inside `@root` (such as new files created by tools) resolve safely to their intended path inside `@root`.

2. **Deterministic Partitioning & Zero Litter (F1.3, F1.4, F1.5)**:
   - Observation: `workspace_id` is computed as `<slug>-<hash>` where `slug` is derived from `File.basename(@root).gsub(/[^a-zA-Z0-9_-]/, "_")` and `hash` is the first 8 characters of `Digest::SHA256.hexdigest(@root)`.
   - Deductions:
     - The workspace ID is completely deterministic, collision-resistant, and invariant across reboots.
     - All state (`llm_calls.jsonl`), manifests (`workspace.json`), and configurations (`prompt.md`, `allow`) reside under central user XDG directories (`$XDG_CONFIG_HOME`, `$XDG_STATE_HOME`, `$XDG_CACHE_HOME`).
     - Target project repositories remain untouched with zero litter.

3. **Hierarchical Directives Precedence (F1.6, F1.8)**:
   - Observation: `Nightmare::Directives::Resolver` evaluates tiers sequentially (CLI -> repo committed -> workspace config -> global config -> default general persona).
   - Deductions:
     - CLI flags take immediate precedence; non-existent files specified via CLI raise `ArgumentError`.
     - Repository committed prompts are only read if they exist; `.nightmare/prompt.md` is never created automatically.
     - In-memory directive edits occur via `DirectiveBuffer#edit` on a temporary file in `Dir.tempdir`; saving updates RAM only, leaving all on-disk files byte-identical.

---

## 3. Caveats

No caveats. All Milestone 1 requirements (F1.1 - F1.8, F6.1) have been implemented natively in Crystal without facades, mocks, or shortcuts.

---

## 4. Conclusion

Milestone 1 is complete and verified:
- `shard.yml` correctly links local sibling frameworks `mantle`, `salamander`, and `tts_kokoro`.
- `bin/nightmare` builds cleanly with zero compiler warnings or errors.
- All workspace anchoring, path security defenses, central XDG mappings, audit logging with rotation, 5-tier directive resolution, in-memory directive buffering, and CLI entry point logic are fully implemented and covered by 46 unit and integration tests with a 100% pass rate.

---

## 5. Verification Method

To independently verify this milestone:

```bash
# Set working directory
cd /home/cam/repos/adjutant/nightmare

# 1. Verify dependencies
shards check

# 2. Compile binary with zero warnings
shards build

# 3. Test CLI flags and startup banner
./bin/nightmare --version
./bin/nightmare --help
./bin/nightmare

# 4. Run full unit and test runner spec suite
crystal spec spec/nightmare_spec.cr spec/workspace_spec.cr spec/directives_spec.cr spec/e2e/test_runner_spec.cr
```

Expected result: 46 examples, 0 failures, 0 errors, 0 pending.
