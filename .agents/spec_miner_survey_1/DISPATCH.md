## 2026-09-11T17:30:28Z
Your working directory is: /home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1
Your parent orchestrator is at: /home/cam/repos/adjutant/nightmare/.agents/orchestrator_1 (Conv ID: 3ad3ad0f-7c04-4b8b-8435-1ed5dba552db)

You MUST read the following authoritative specification files:
- /home/cam/repos/adjutant/nightmare/.agents/ORIGINAL_REQUEST.md
- /home/cam/repos/adjutant/nightmare/docs/DESIGN.md
- /home/cam/repos/adjutant/nightmare/docs/ARCHITECTURE.md

Your mission:
Extract and document an exhaustive, structured inventory of all specifications, requirements, architecture constraints, component designs, data models, error handling, algorithms, and acceptance criteria for NIGHTMARE.
Specifically detail:
1. Workspace Anchoring & XDG Central Mapping: slug/hash algorithm, XDG directory resolution, config resolution precedence, banner format.
2. Ephemeral Context Engine & Turn Pruning: turn unit structure, sliding window pruning rules, in-turn tool shedding algorithm (keeping last 2 outputs verbatim), token estimation & feedback calibration, RAM-only unpruned transcript for /save.
3. Sandboxed Tool Suite & Anti-Fatigue Approval: read-only tools, mutation tools, unified diff display, ask_model tool, run_command with isolation, timeout, closed stdin, approval modal ([y],[N],[e],[a],[p]), and the shell metacharacter auto-approval ban.
4. Mantle Step Harness & Result Sum Types: Mantle step runner integration, Result(T) sum types, backoff/jitter, single format-correction retry turn.
5. Salamander REPL & Slash Commands: token streaming, spinner management, <think> block isolation, ANSI markdown, Ctrl+C handling (cancel turn rollback without exiting REPL), complete list of slash commands and their semantics.
6. Acceptance Criteria: All functional, security, path traversal, pruning, and signal test requirements.

Write your comprehensive findings to:
`/home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1/specs.md`
And write your final handoff report to:
`/home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1/handoff.md`

Remember: maintain progress in `/home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1/progress.md`.
When finished, send a message to your parent with the summary and path to your handoff.
