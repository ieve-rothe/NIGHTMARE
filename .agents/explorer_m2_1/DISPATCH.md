## 2026-09-11T18:21:05Z

Your working directory is: /home/cam/repos/adjutant/nightmare/.agents/explorer_m2_1
Your parent orchestrator is at: /home/cam/repos/adjutant/nightmare/.agents/orchestrator_1 (Conv ID: 3ad3ad0f-7c04-4b8b-8435-1ed5dba552db)

You MUST read the following authoritative files:
- /home/cam/repos/adjutant/nightmare/.agents/ORIGINAL_REQUEST.md
- /home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1/specs.md
- /home/cam/repos/adjutant/nightmare/.agents/orchestrator_1/PROJECT.md

Scope: Milestone 2 - Context Models, Turn-Unit Sliding Window & In-Turn Tool Shedding (F2.1, F2.2, F2.3, F2.4)
Your mission:
Design the core context engine for NIGHTMARE in `src/nightmare/context/`:
1. Data models (`src/nightmare/context/models.cr`):
   - `Turn`: user message, array of `ToolExchange`, assistant message, token estimate, timestamp.
   - `ToolExchange`: `call_id : String`, `name : String`, `args : Hash(String, JSON::Any)`, `output : String`, `shed : Bool`.
   - `PinnedFile`: path, cached token count, mtime.
2. `SlidingStore` (`src/nightmare/context/sliding_store.cr`):
   - Atomic turn-unit sliding window eviction: evicts entire oldest turns when total estimated tokens exceed `token_hardmax`.
   - Invariants: Never evict active turn; never separate tool call / tool result messages.
   - In-turn tool shedding: when active turn token usage exceeds 85% of budget (`token_hardmax * 0.85`), compress older consumed tool exchanges, preserving the last 2 verbatim. Sunk tool results are truncated to first ~200 chars + `\n[... output truncated: was N bytes]`.
   - Active turn rollback on cancellation (`rollback_active_turn`).

Write your detailed design to:
`/home/cam/repos/adjutant/nightmare/.agents/explorer_m2_1/m2_design.md`
And write your handoff report to:
`/home/cam/repos/adjutant/nightmare/.agents/explorer_m2_1/handoff.md`

Remember: maintain progress in `/home/cam/repos/adjutant/nightmare/.agents/explorer_m2_1/progress.md`.
When done, send a message to parent with your summary and handoff path.
