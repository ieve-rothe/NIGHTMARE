# BRIEFING — 2026-09-11T17:35:50Z

## Mission
Investigate local frameworks (/home/cam/repos/adjutant/mantle and /home/cam/repos/adjutant/salamander) to determine their architecture, classes, types, streaming, tool calling, error handling, shard specs, and compatibility with Nightmare.

## 🔒 My Identity
- Archetype: explorer
- Roles: Read-only investigation, synthesize findings, produce structured reports
- Working directory: /home/cam/repos/adjutant/nightmare/.agents/explorer_frameworks_1
- Original parent: 3ad3ad0f-7c04-4b8b-8435-1ed5dba552db
- Milestone: Framework Exploration & Compatibility Analysis

## 🔒 Key Constraints
- Read-only investigation — do NOT implement
- Investigate /home/cam/repos/adjutant/mantle and /home/cam/repos/adjutant/salamander
- Write detailed findings to frameworks.md and handoff report to handoff.md
- Maintain progress.md

## Current Parent
- Conversation ID: 3ad3ad0f-7c04-4b8b-8435-1ed5dba552db
- Updated: not yet

## Investigation State
- **Explored paths**:
  - `/home/cam/repos/adjutant/mantle` (all source files, specs, ARCHITECTURE.md, shard.yml)
  - `/home/cam/repos/adjutant/salamander` (all source files, specs, README.md, shard.yml)
  - `/home/cam/repos/adjutant/nightmare` (docs/ARCHITECTURE.md, docs/DESIGN.md, shard.yml)
- **Key findings**:
  - Mantle provides `Mantle::Step`, `Mantle::StepResult`, `Mantle::StepError`, `Mantle::Message`, `Mantle::Tools::Tool`.
  - Mantle does not have sum-type `Result(T) = Success(T) | Failure`; Nightmare wraps `StepResult` in its own sum type.
  - Nightmare bypasses `Mantle::ContextManager` (which requires disk-based `JSONLayeredMemoryStore`) and feeds pure RAM messages to `Mantle::Step`.
  - In-turn shedding can be supported cleanly via an optional 3-line backward-compatible hook in `Mantle::Step` (`before_iteration`).
  - Salamander provides `ChatSession` (real-time <think> tag stripper), `UI::MarkdownFormatter` (ANSI code converter), `UI#spin_while`, and terminal queries.
  - Salamander's default `Signal::INT.trap` can be overridden by Nightmare at runtime to support Ctrl+C turn rollback.
  - Shard linking works with local path dependencies (`../mantle`, `../salamander`, `../tts_kokoro`).
  - Specs verified: Mantle (303/303 pass), Salamander (20/20 pass).
- **Unexplored areas**: None.

## Key Decisions Made
- Confirmed that Mantle and Salamander can be consumed almost entirely as-is, with one optional minor enhancement suggested for in-turn shedding in `Mantle::Step`.

## Artifact Index
- `/home/cam/repos/adjutant/nightmare/.agents/explorer_frameworks_1/frameworks.md` — Detailed framework findings
- `/home/cam/repos/adjutant/nightmare/.agents/explorer_frameworks_1/handoff.md` — 5-component handoff report
