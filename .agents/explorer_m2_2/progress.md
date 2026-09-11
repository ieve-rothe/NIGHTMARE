# Progress: Explorer M2.2 (TokenCalibrator & PinnedFiles)

Last visited: 2026-09-11T18:23:15Z

## Status
Investigating specifications, existing codebase, and peer agent divisions. Formulating comprehensive architecture and component design for `TokenCalibrator` and `PinnedFiles`.

## Completed Steps
1. [x] Setup DISPATCH.md, BRIEFING.md, progress.md.
2. [x] Read authoritative files:
   - `ORIGINAL_REQUEST.md` (R1-R6, ACs)
   - `specs.md` (§2.5 Self-Calibrating Token Accounting, §2.6 Pinned Files, AC-C4, AC-C6, AC-C7)
   - `PROJECT.md` (F2.5, F2.7, interfaces, codebase layout)
3. [x] Explored codebase and dependencies:
   - `src/nightmare/workspace/environment.cr` (XDG cache directory structure: `@cache_dir`, `sanitize_path`)
   - `mantle/src/mantle/clients/client.cr` (`Response#prompt_eval_count`, `Message` structure)
   - Discovered peer scopes: `explorer_m2_1` (models, sliding store, shedding), `explorer_m2_3` (transcript, mantle assembly, test specs).
4. [x] Analyzed mathematical invariants and edge cases:
   - Exponential smoothing formula `Divisor_new = 0.8 * Divisor_prev + 0.2 * (chars / prompt_tokens)`
   - Clamping within `[1.0, 10.0]`, initial default divisor `4.0`
   - Cache persistence format in `$XDG_CACHE_HOME/nightmare/workspaces/<id>/calibrator.json`
   - Fast estimation methods: text, message, messages, turn
   - PinnedFiles 60% hardmax budget cap with `BudgetExceededError`
   - Live re-read on prompt assembly with `mtime` comparison
   - Redundancy short-circuit notice for `read_file`

## Next Steps
1. [ ] Write detailed design document `m2_design.md` covering both components completely.
2. [ ] Update BRIEFING.md with findings and decisions.
3. [ ] Write 5-component handoff report `handoff.md`.
4. [ ] Notify parent via `send_message`.
