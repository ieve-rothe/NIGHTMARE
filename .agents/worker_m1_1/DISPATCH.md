## 2026-09-11T17:45:04Z
Your working directory is: /home/cam/repos/adjutant/nightmare/.agents/worker_m1_1
Your parent orchestrator is at: /home/cam/repos/adjutant/nightmare/.agents/orchestrator_1 (Conv ID: 3ad3ad0f-7c04-4b8b-8435-1ed5dba552db)

You MUST read the following authoritative files:
- /home/cam/repos/adjutant/nightmare/.agents/ORIGINAL_REQUEST.md
- /home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1/specs.md
- /home/cam/repos/adjutant/nightmare/.agents/orchestrator_1/PROJECT.md
- /home/cam/repos/adjutant/nightmare/.agents/explorer_m1_1/m1_design.md
- /home/cam/repos/adjutant/nightmare/.agents/explorer_m1_2/m1_design.md
- /home/cam/repos/adjutant/nightmare/.agents/explorer_m1_3/m1_plan.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Scope: Milestone 1 - Workspace Anchoring & Central XDG Mapping (F1.1 - F1.8, F6.1)

Write Ownership (You exclusively own these files):
- shard.yml
- src/nightmare.cr
- src/nightmare/exceptions.cr
- src/nightmare/workspace/environment.cr
- src/nightmare/workspace/manifest.cr
- src/nightmare/directives/resolver.cr
- spec/spec_helper.cr
- spec/workspace_spec.cr
- spec/directives_spec.cr
- Remove the failing template test spec/nightmare_spec.cr or replace it with a passing test.

Key Requirements to Implement:
1. shard.yml: Add path dependencies:
   dependencies:
     mantle:
       path: ../mantle
     salamander:
       path: ../salamander
     tts_kokoro:
       path: ../tts_kokoro
   Run shards install with BypassSandbox: true.
2. src/nightmare/exceptions.cr: Define Nightmare::SecurityError < Exception and other domain exceptions.
3. src/nightmare/workspace/environment.cr:
   - Immutable @root = File.realpath(Dir.current)
   - sanitize_path(path) and inside_root?(path): reject path traversal (../) and out-of-tree symlinks with SecurityError. Guard against prefix collisions (e.g. /path/to/project_fake vs /path/to/project).
   - Deterministic workspace ID: slug = File.basename(@root).gsub(/[^a-zA-Z0-9_-]/, "_"), hash = Digest::SHA256.hexdigest(@root)[0..7], workspace_id = "#{slug}-#{hash}".
   - Central XDG base directories ($XDG_CONFIG_HOME, $XDG_STATE_HOME, $XDG_CACHE_HOME) mapped to .../nightmare/workspaces/<workspace_id>/.
   - startup_banner format matching the 76-column box specified in specs.md and DESIGN.md.
   - Zero repo litter: absolutely no configuration or log files created inside @root.
4. src/nightmare/workspace/manifest.cr:
   - Create and load workspace.json in XDG config dir.
   - Size-based log rotation for llm_calls.jsonl in XDG state dir (rotating at 20MB, retaining 3 files).
5. src/nightmare/directives/resolver.cr:
   - 5-tier hierarchical resolution: CLI flag > .nightmare/prompt.md in repo > workspace config prompt.md > global config prompt.md > default general persona.
   - DirectiveBuffer / in-memory prompt management for /prompt edit: in-memory only, disk is never modified.
6. src/nightmare.cr:
   - CLI OptionParser for -s/--system, -m/--model, --no-log, -v/--version, -h/--help.
   - Guard CLI execution with {% if !@top_level.has_constant?("Spec") %} so running crystal spec does not invoke the CLI main block.
7. Verification:
   - Run shards build (must compile bin/nightmare with zero compiler warnings or errors).
   - Run crystal spec (all workspace_spec, directives_spec, and test_runner_spec must pass 100% with zero failures or errors). Note: always use BypassSandbox: true on run_command.

Write your full handoff report to:
/home/cam/repos/adjutant/nightmare/.agents/worker_m1_1/handoff.md

Remember: maintain progress in /home/cam/repos/adjutant/nightmare/.agents/worker_m1_1/progress.md.
When done, send a message to your parent with the summary and verification results.
