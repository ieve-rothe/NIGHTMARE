# BRIEFING — 2026-09-11T18:21:05Z

## Mission
Investigate and design TokenCalibrator and PinnedFiles context components (F2.5, F2.7) for Milestone 2 in Nightmare.

## 🔒 My Identity
- Archetype: explorer
- Roles: investigation, synthesis
- Working directory: /home/cam/repos/adjutant/nightmare/.agents/explorer_m2_2
- Original parent: 3ad3ad0f-7c04-4b8b-8435-1ed5dba552db
- Milestone: Milestone 2 - Self-Calibrating Token Estimator & Pinned Files Manager (F2.5, F2.7)

## 🔒 Key Constraints
- Read-only investigation — do NOT implement code in src/ or spec/
- Zero repo litter: cache persistence must be in central XDG cache dir ($XDG_CACHE_HOME/nightmare/workspaces/<id>/calibrator.json)
- Exponential smoothing token estimation: Divisor_new = 0.8 * Divisor_prev + 0.2 * (Raw Assembled Chars / usage.prompt_tokens)
- Initial default divisor: 4.0 chars/token. Clamp within [1.0, 10.0].
- Pinned files budget cap: maximum 60% of token_hardmax
- Live re-read on prompt assembly if mtime changed
- Redundancy short-circuit helper for already pinned & up-to-date files
- Write outputs only to .agents/explorer_m2_2/

## Current Parent
- Conversation ID: 3ad3ad0f-7c04-4b8b-8435-1ed5dba552db
- Updated: not yet

## Investigation State
- **Explored paths**: [TBD]
- **Key findings**: [TBD]
- **Unexplored areas**: codebase architecture, types, existing context and workspace models in nightmare, peer explorer outputs

## Key Decisions Made
- Initiated M2.2 exploration for TokenCalibrator and PinnedFiles.

## Artifact Index
- /home/cam/repos/adjutant/nightmare/.agents/explorer_m2_2/m2_design.md — Detailed design for TokenCalibrator and PinnedFiles
- /home/cam/repos/adjutant/nightmare/.agents/explorer_m2_2/handoff.md — 5-component handoff report for M2.2
