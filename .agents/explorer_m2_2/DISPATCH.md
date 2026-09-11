## 2026-09-11T18:21:05Z

Your working directory is: /home/cam/repos/adjutant/nightmare/.agents/explorer_m2_2
Your parent orchestrator is at: /home/cam/repos/adjutant/nightmare/.agents/orchestrator_1 (Conv ID: 3ad3ad0f-7c04-4b8b-8435-1ed5dba552db)

You MUST read the following authoritative files:
- /home/cam/repos/adjutant/nightmare/.agents/ORIGINAL_REQUEST.md
- /home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1/specs.md
- /home/cam/repos/adjutant/nightmare/.agents/orchestrator_1/PROJECT.md

Scope: Milestone 2 - Self-Calibrating Token Estimator & Pinned Files Manager (F2.5, F2.7)
Your mission:
Design the token calibration and pinned files components in `src/nightmare/context/`:
1. `TokenCalibrator` (`src/nightmare/context/calibrator.cr`):
   - Exponential smoothing token estimation: `Divisor_new = 0.8 * Divisor_prev + 0.2 * (Raw Assembled Chars / usage.prompt_tokens)`.
   - Initial default divisor: 4.0 chars/token. Clamp divisor within [1.0, 10.0].
   - Cache persistence to central XDG cache dir (`$XDG_CACHE_HOME/nightmare/workspaces/<id>/calibrator.json`) with zero repo litter.
   - Fast token estimation methods for text, turns, and messages.
2. `PinnedFiles` (`src/nightmare/context/pinned_files.cr`):
   - Add/remove/list pinned files.
   - Budget cap: pinned files cannot exceed 60% of `token_hardmax`.
   - Live re-read on prompt assembly: re-reads disk content if mtime changed.
   - Redundancy short-circuit helper: checks if a file is already pinned and up to date.

Write your detailed design to:
`/home/cam/repos/adjutant/nightmare/.agents/explorer_m2_2/m2_design.md`
And write your handoff report to:
`/home/cam/repos/adjutant/nightmare/.agents/explorer_m2_2/handoff.md`

Remember: maintain progress in `/home/cam/repos/adjutant/nightmare/.agents/explorer_m2_2/progress.md`.
When done, send a message to parent with your summary and handoff path.
