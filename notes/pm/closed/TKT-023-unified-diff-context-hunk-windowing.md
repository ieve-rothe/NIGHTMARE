---
ID: TKT-023
Title: Unified Diff Context Windowing and Hunk Pruning
Status: Closed
Priority: Med
---

## 1. User Need
When reviewing file mutation diffs (for `write_file`, `replace_in_file`, or `append_to_file`), operators currently see the entire file rendered in the terminal as a single diff hunk. On medium or large files with localized edits, large contiguous unchanged sections push the actual changes far up above the terminal viewport, forcing repetitive scrolling to review changes before responding to the approval prompt. Operators need diffs to omit large contiguous unchanged sections and display only the changes surrounded by a standard context window (e.g. 3 lines) so that modifications are immediately visible.

## 2. Specification
1. In `Nightmare::Tools::Diff.unified_diff`:
   - Support standard unified diff hunk windowing with configurable `context_lines` (default: 3).
   - Empty input strings should not emit phantom empty line deletions.
2. In `create_hunks`:
   - Track pre-operation line positions for original and new text.
   - Cluster change operations (`:del`, `:add`) such that consecutive changes separated by `<= 2 * context_lines` unchanged `:keep` lines are merged into the same hunk.
   - For changes separated by `> 2 * context_lines` `:keep` lines, split into distinct hunks and omit intermediate unchanged lines.
   - Expand each cluster with up to `context_lines` leading context before the first change and up to `context_lines` trailing context after the last change.
   - Calculate precise `orig_start`, `orig_count`, `new_start`, and `new_count` for each hunk header (`@@ -orig_start,orig_count +new_start,new_count @@`).
3. Automated Testing in `spec/diff_spec.cr`:
   - Test single change in large file isolates 3 lines before and after, pruning remainder.
   - Test two changes separated by `<= 6` keeps merge into single hunk.
   - Test two changes separated by `> 6` keeps split into distinct hunks with separate headers.
   - Test boundary conditions: change at start of file, change at end of file, additions to empty file, deletions to empty file.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Run unit specs: `crystal spec spec/diff_spec.cr spec/ui/approval_spec.cr`
  - Run full test suite: `crystal spec`
  - Build executable: `shards build`
* **Verification Evidence:**
  - Unit specs: `crystal spec spec/diff_spec.cr spec/ui/approval_spec.cr`: 29 examples, 0 failures, 0 errors, 0 pending (4.64ms).
  - Full test suite: `crystal spec`: 290 examples, 0 failures, 0 errors, 0 pending (11.73s).
  - Compilation: `shards build`: Successfully built `bin/nightmare`.
* **Validation Plan:**
  - Verify unified diff on a simulated 40+ line file mutation renders only 7 lines of hunk content instead of the entire file.
* **Validation Evidence:**
  - Verified simulation of markdown journal edit: only 7 lines of hunk content (3 context lines before, 1 deleted, 1 added, 3 context lines after) are emitted, eliminating terminal scrolling.

## Open Questions & Concurrency Concerns
* None.

## 4. Revision History
* 2026-09-26: Ticket created and marked In-Progress in response to operator feature request.
* 2026-09-26: Implemented context-windowed hunk generation in `src/nightmare/tools/diff.cr`. Added comprehensive unit specs in `spec/diff_spec.cr`. Verified with full test suite (290 examples passing) and clean build. Ticket closed.
---
