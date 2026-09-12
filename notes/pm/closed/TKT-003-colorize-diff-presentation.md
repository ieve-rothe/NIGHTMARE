---
ID: TKT-003
Title: Colorize Diff Presentation for File Changes
Status: Closed
Priority: Med
---

## 1. User Need
When the agent proposes modifying existing workspace files via mutation tools (`write_file`, `replace_in_file`, `append_to_file`), reviewing a plain monochrome unified diff in the terminal makes it cumbersome and slow for the operator to distinguish additions, deletions, and context. Colorizing the diff (green additions, red deletions, cyan hunk markers, bold headers) enhances readability and reduces operator error when approving file changes.

## 2. Specification
1. Add `Diff.colorize(diff : String) : String` to `Nightmare::Tools::Diff`:
   - Highlight additions starting with `+` in green (`:green`).
   - Highlight deletions starting with `-` in red (`:red`).
   - Highlight hunk headers starting with `@@` in cyan (`:cyan`).
   - Highlight file headers starting with `--- ` or `+++ ` with bold mode (`mode(:bold)`).
   - Preserve context lines and other lines unchanged.
   - Maintain raw string format in `Diff.unified_diff` to avoid corrupting programmatic consumers or test assertions.
2. Update `Nightmare::UI::Approval`:
   - Inject configurable `@input : IO = STDIN` and `@output : IO = STDOUT` for testability and non-TTY decoupling.
   - In `approve_diff`, render the diff body using `Tools::Diff.colorize(diff)`.
   - Style the diff demarcation banners (`--- Diff ---`, `------------`) with bold cyan styling.
3. Automated Testing:
   - Create `spec/diff_spec.cr` testing `Diff.unified_diff` edge cases and `Diff.colorize` ANSI color output.
   - Create `spec/ui/approval_spec.cr` verifying interactive approvals and output formatting for `approve_diff` and `approve_command`.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Run unit specs: `crystal spec spec/diff_spec.cr spec/ui/approval_spec.cr spec/tools_spec.cr`
  - Run full test suite: `crystal spec`
  - Verify clean compilation: `shards build`
* **Verification Evidence:**
  - Unit specs: `crystal spec spec/diff_spec.cr spec/ui/approval_spec.cr spec/tools_spec.cr`: 22 examples, 0 failures, 0 errors, 0 pending (1.03s).
  - Full test suite: `crystal spec`: 232 examples, 0 failures, 0 errors, 0 pending (14.4s).
  - Compilation: `shards build`: Successfully compiled `bin/nightmare`.
* **Validation Plan:**
  - Verify terminal output with ANSI colors enabled displays colored diff lines (+ green, - red, @@ cyan) when presenting approvals.
* **Validation Evidence:**
  - Verified `Diff.colorize` maps additions to `\e[32m`, deletions to `\e[31m`, hunk markers to `\e[36m`, and headers to `\e[1m` when color is enabled, while retaining raw unmodified text when color is disabled.
  - Verified `UI::Approval#approve_diff` formats diff with bold cyan banners and colored diff lines before prompting the operator.

## Open Questions & Concurrency Concerns
* Does `Colorize` automatically respect TTY detection and `NO_COLOR`?
  - *Resolution*: Crystal's `Colorize` stdlib natively respects `Colorize.enabled?` / `Colorize.on_tty_only!` and terminal capabilities.

## 4. Revision History
* 2026-09-11: Ticket created in response to operator feature request. Status set to In-Progress.
* 2026-09-11: Implemented `Diff.colorize`, updated `UI::Approval#approve_diff`, added specs in `spec/diff_spec.cr` and `spec/ui/approval_spec.cr`. All 232 tests passing. Ticket closed.
---
