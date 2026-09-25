---
ID: TKT-019
Title: Fix ToolExecutionFailure Arithmetic Overflow in read_file with Offset
Status: Closed
Priority: High
---

## 1. User Need
When an LLM agent calls the `read_file` tool with an `offset` but without specifying a `limit`, the tool should seamlessly return the lines from `offset` to the end of the file (subject to context size guards). Currently, doing so causes an unhandled 32-bit arithmetic overflow in Crystal (`OverflowError: Arithmetic overflow`), crashing the turn with a terminal `ToolExecutionFailure`.

## 2. Specification
1. In `Nightmare::Tools::ReadOnly#read_file`:
   - Support optional `limit` when `offset` is specified without defaulting `max_lines` to `Int32::MAX` for addition checks.
   - Eliminate addition `start_line + max_lines` that exceeds `Int32::MAX`.
   - Filter lines where `idx < start_line`, append lines to `selected_lines`, and terminate line traversal once `max_lines` (if set) is satisfied.
   - If `limit` is explicitly `0`, return empty content immediately without reading lines.
   - Calculate line numbers for formatted output safely using `start_line.to_i64 + idx`.
2. Unit tests covering:
   - `read_file` with `offset` provided and `limit` omitted.
   - `read_file` with `offset` beyond file line count.
   - `read_file` with explicit `limit: 0`.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Run unit test suite in `spec/tools_spec.cr` covering `read_file` with offset-only, limit-only, both, and edge cases.
  - Run full test suite `crystal spec` in `nightmare`.
* **Verification Evidence:**
  - `crystal spec spec/tools_spec.cr`: 30 examples, 0 failures, 0 errors, 0 pending.
  - `crystal spec`: 266 examples, 0 failures, 0 errors, 0 pending.
* **Validation Plan:**
  - Reproduce the exact call from session `ellie-38115f12` (`read_file("document_registry.md", offset: 150)` with `limit: nil`) and verify it executes without error.
* **Validation Evidence:**
  - Verified in unit tests and manual execution that invoking `read_file` with offset (including values like 150) without `limit` successfully yields file lines up to EOF without triggering Crystal's `OverflowError`.

## Open Questions & Concurrency Concerns
None.

## 4. Revision History
* 2026-09-25: Created ticket following bug report from session ellie-38115f12. Implemented fix in `ReadOnly#read_file`, verified with unit specs and full regression test suite, closed ticket.
---
