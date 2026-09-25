---
ID: TKT-017
Title: Inject Ephemeral Current Date into Context Assembly
Status: Closed
Priority: Med
---

## 1. User Need
When interacting with the agent, the model frequently requires awareness of the real-world temporal context (e.g., today's date) to handle date-sensitive instructions, format logs, plan milestones, or reference current time without hallucination. While NIGHTMARE's documentation describes ephemeral data (e.g., today's date) as part of assembled context, the harness only passed static system prompts, active skills, pinned files, and conversational turns. The user needs the current local date to be dynamically and consistently injected into the prompt context for every turn.

## 2. Specification
1. Update `Nightmare::Context::SlidingStore#assemble_messages` (`src/nightmare/context/sliding_store.cr`) to inject current local date string via `SlidingStore.current_date_note` (`Today's date: #{Time.local.to_s("%Y-%m-%d")}`) into `system_parts`.
2. Placement order within the single compiled `system` message:
   - System prompt (base / custom persona)
   - Current date ephemeral note
   - Active skill block (if present)
   - Pinned files block (if present)
3. Ensure `assemble_messages` generates the `system` message even if `system_prompt` is nil or empty, provided the date injection is present.
4. Ensure character and token estimation methods (`total_characters`, `total_estimated_tokens`, and `/context` command) reflect the date injection seamlessly.
5. Display `--- Ephemeral Context ---` in `/context` inspection within `Nightmare::Commands::Router#handle_context`.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  1. Add unit specs in `spec/shedder_and_store_spec.cr` checking that `SlidingStore#assemble_messages` includes `Today's date: YYYY-MM-DD` formatted with `Time.local`.
  2. Verify ordering relative to system prompt, active skill, and pinned files.
  3. Execute `crystal spec spec/shedder_and_store_spec.cr` and verify test suite passes cleanly.
* **Verification Evidence:**
  - `crystal spec spec/shedder_and_store_spec.cr` passed cleanly (7 examples, 0 failures).
  - Full test suite `crystal spec` passed cleanly (251 examples, 0 failures).
* **Validation Plan:**
  1. Inspect output of `/context` command to confirm `--- Ephemeral Context ---` and `Today's date: YYYY-MM-DD` are displayed.
  2. Confirm wire format messages constructed during turn execution have date injected between system prompt and skills/pinned blocks.
* **Validation Evidence:**
  - Tested `/context` output rendering and confirmed `assemble_messages` injects `Today's date: #{Time.local.to_s("%Y-%m-%d")}` into the system message.

## Open Questions & Concurrency Concerns
* Format: Defaulting to ISO-8601 date (`YYYY-MM-DD`) via `Time.local.to_s("%Y-%m-%d")`. If time-of-day or timezone is needed later, this can be expanded or made configurable.

## 4. Revision History
* 2026-09-25: Ticket created.
* 2026-09-25: Implemented in `SlidingStore#assemble_messages` and `Router#handle_context`. Verified with unit and integration specs. Ticket closed.
