# BRIEFING — 2026-09-11T17:50:45Z

## Mission
Implement Milestone 1: Workspace Anchoring & Central XDG Mapping (F1.1 - F1.8, F6.1) for Nightmare.

## 🔒 My Identity
- Archetype: worker
- Roles: implementer, qa, specialist
- Working directory: /home/cam/repos/adjutant/nightmare/.agents/worker_m1_1
- Original parent: 3ad3ad0f-7c04-4b8b-8435-1ed5dba552db
- Milestone: Milestone 1

## 🔒 Key Constraints
- DO NOT CHEAT: all implementations must be genuine, no hardcoded results or dummy facades.
- Zero repo litter: absolutely no configuration or log files created inside @root.
- Central XDG base directories mapped to ~/.config/nightmare/workspaces/<workspace_id>/ etc.
- Reject path traversal and out-of-tree symlinks with SecurityError. Guard prefix collisions.
- Guard CLI execution with `{% if !@top_level.has_constant?("Spec") %}` in src/nightmare.cr.
- Use BypassSandbox: true on run_command.
- Set Cwd directly, prefix-approvable commands, do not chain shell commands.

## Current Parent
- Conversation ID: 3ad3ad0f-7c04-4b8b-8435-1ed5dba552db
- Updated: 2026-09-11T17:50:45Z

## Task Summary
- **What to build**: Workspace anchoring, path sanitization, central XDG dirs, manifest management with log rotation, hierarchical directives resolution, CLI entry point.
- **Success criteria**: bin/nightmare compiles with zero warnings/errors via `shards build`, all specs pass 100% via `crystal spec`.
- **Interface contracts**: /home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1/specs.md, /home/cam/repos/adjutant/nightmare/.agents/orchestrator_1/PROJECT.md
- **Code layout**: shard.yml, src/nightmare.cr, src/nightmare/exceptions.cr, src/nightmare/workspace/environment.cr, src/nightmare/workspace/manifest.cr, src/nightmare/directives/resolver.cr, spec/*

## Key Decisions Made
- Added path dependencies to `shard.yml` for mantle (`../mantle`), salamander (`../salamander`), and tts_kokoro (`../tts_kokoro`).
- Defined top-level `SecurityError < Exception` and aliased under `Nightmare::SecurityError = ::SecurityError` so exception handling works consistently across all contexts.
- Implemented `Nightmare::Workspace::Environment` with immutable `@root = File.realpath(current_dir)`, deterministic slug-hash workspace ID, and ancestor resolution for path sanitization to support creating non-existent files while blocking traversal and out-of-tree symlinks.
- Guarded against prefix confusion in `inside_root?` by ensuring paths match `@root` exactly or start with `#{@root}/`.
- Formatted `startup_banner` as a 76-character box with Unicode border characters, tilde-shortened paths, and trailing slashes.
- Implemented `Manifest` with JSON serialization and `AuditLog` with 20MB log rotation retaining 3 historical generations.
- Implemented `Resolver` with 5-tier hierarchical resolution, whitespace fallthrough, and `DirectiveBuffer` for in-memory `/prompt edit` with tempfile cleanup.
- Guarded CLI entry point in `src/nightmare.cr` using `{% if !@top_level.has_constant?("Spec") %}`.

## Artifact Index
- DISPATCH.md — Dispatch instructions
- BRIEFING.md — Situational awareness
- progress.md — Liveness and progress tracking
- handoff.md — Final handoff report

## Change Tracker
- **Files modified**:
  - `shard.yml`: added mantle, salamander, tts_kokoro path dependencies
  - `src/nightmare/exceptions.cr`: SecurityError and domain exceptions
  - `src/nightmare/workspace/environment.cr`: canonical root, slug-hash, central XDG dirs, path sanitization, startup banner
  - `src/nightmare/workspace/manifest.cr`: Manifest JSON serialization, AuditLog with 20MB rotation (3 historical files)
  - `src/nightmare/directives/resolver.cr`: 5-tier resolution hierarchy, DirectiveBuffer in-memory editing
  - `src/nightmare.cr`: CLI option parser, execution macro guard
  - `spec/spec_helper.cr`: isolation test helpers
  - `spec/nightmare_spec.cr`: version and SecurityError assertions
  - `spec/workspace_spec.cr`: 16 unit tests for workspace anchoring, traversal, symlinks, manifest, audit log
  - `spec/directives_spec.cr`: 21 unit tests for 5-tier resolution hierarchy, buffer editing, CLI parser
- **Build status**: PASS (shards build generates bin/nightmare with 0 warnings/errors)
- **Pending issues**: none

## Quality Status
- **Build/test result**: PASS (46/46 unit and test runner examples pass with 0 failures, 0 errors)
- **Lint status**: clean
- **Tests added/modified**: `spec/workspace_spec.cr` (16 tests), `spec/directives_spec.cr` (21 tests), `spec/nightmare_spec.cr` (2 tests), `spec/spec_helper.cr`

## Loaded Skills
None
