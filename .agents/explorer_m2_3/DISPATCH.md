## 2026-09-11T18:21:05Z
Scope: Milestone 2 - RAM Transcript, Mantle Assembly & Test Specs (F2.6, F2.1 - F2.7)
Your mission:
Design the parallel RAM transcript, Mantle message assembly, and M2 test suite:
1. `Transcript` (`src/nightmare/context/transcript.cr`):
   - Parallel in-memory store preserving unpruned, unshed conversational history in RAM.
   - Export implementation for `/save [path]`: exports pristine markdown or text log without truncation.
2. Mantle Message Conversion in `SlidingStore`:
   - `assemble_mantle_messages(system_directive : String) : Array(Mantle::Message)`
   - Assembles:
     1. System message (directive + pinned file contents)
     2. Pruned turns: User message -> [Tool call -> Tool result]* -> Assistant message
     3. Active turn with shed/unshed tool outputs
   - Converts cleanly to Mantle's `Mantle::Message` types (`role: "system"`, `"user"`, `"assistant"`, `"tool"`).
3. Concrete unit test specifications for `spec/context_spec.cr`:
   - Test atomic turn eviction (never orphans tool calls/results; never evicts active turn).
   - Test in-turn shedding (>85% budget triggers compression; last 2 verbatim).
   - Test token calibration exponential smoothing.
   - Test RAM transcript `/save` export integrity.
   - Test pinned files 60% budget cap and live re-read.
4. Formulate the M2 worker implementation plan.

Write your plan and design to:
`/home/cam/repos/adjutant/nightmare/.agents/explorer_m2_3/m2_plan.md`
And write your handoff report to:
`/home/cam/repos/adjutant/nightmare/.agents/explorer_m2_3/handoff.md`

Remember: maintain progress in `/home/cam/repos/adjutant/nightmare/.agents/explorer_m2_3/progress.md`.
When done, send a message to parent with your summary and handoff path.
