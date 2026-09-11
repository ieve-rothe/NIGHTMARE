## 2026-09-11T17:36:48Z

Your working directory is: /home/cam/repos/adjutant/nightmare/.agents/explorer_m1_1
Your parent orchestrator is at: /home/cam/repos/adjutant/nightmare/.agents/orchestrator_1 (Conv ID: 3ad3ad0f-7c04-4b8b-8435-1ed5dba552db)

You MUST read the following authoritative files:
- /home/cam/repos/adjutant/nightmare/.agents/ORIGINAL_REQUEST.md
- /home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1/specs.md
- /home/cam/repos/adjutant/nightmare/.agents/orchestrator_1/PROJECT.md

Scope: Milestone 1 - Workspace Anchoring & Central XDG Mapping (F1.1 - F1.5, F1.7, F6.1)
Your mission:
Analyze and formulate the exact technical design and implementation blueprint for:
1. `Nightmare::Workspace::Environment`:
   - Canonical root anchor via `File.realpath(Dir.current)`.
   - Containment checking and path sanitization (`sanitize_path`, `inside_root?`) that strictly rejects `../` traversal and out-of-tree symlinks with `SecurityError`.
   - Deterministic workspace identification: slug sanitization + SHA256 8-char hash (`<slug>-<hash>`).
   - Central XDG base directories ($XDG_CONFIG_HOME, $XDG_STATE_HOME, $XDG_CACHE_HOME) resolution and workspace subdirectories.
   - Strict zero-repository-litter guarantees.
   - Startup box banner format and generation.
2. `Nightmare::Workspace::Manifest`:
   - Management of `workspace.json` in central XDG workspace config dir.
   - Safe creation and rotation of `llm_calls.jsonl` in central XDG state dir.
3. Concrete unit test specifications for `spec/workspace_spec.cr`.

Write your detailed design to:
`/home/cam/repos/adjutant/nightmare/.agents/explorer_m1_1/m1_design.md`
And write your handoff report to:
`/home/cam/repos/adjutant/nightmare/.agents/explorer_m1_1/handoff.md`

Remember: maintain progress in `/home/cam/repos/adjutant/nightmare/.agents/explorer_m1_1/progress.md`.
When finished, send a message to your parent with your summary and handoff path.
