---
ID: TKT-026
Title: Utility Command /print_last to Echo Most Recent User Request
Status: Closed
Priority: Med
---

## 1. User Need
During interactive sessions in the NIGHTMARE REPL, an agent's turn frequently involves substantial output, such as streaming multi-step reasoning, tool execution summaries, file diffs, and conversational responses. By the time the bot completes its turn, the user's original prompt is pushed far up into the terminal scrollback or lost completely off-screen.

Users frequently need to reuse, adjust, or iterate on their prior prompt for the next turn. When the text is not readily accessible, they must manually scroll back through pages of output to find, select, and copy it. The operator needs a straightforward utility slash command (e.g., `/print_last`) that immediately prints the exact text of their last request to the terminal output so it can be viewed, copied, edited, and resubmitted without scrollback navigation.

## 2. Specification
### 2.1 Slash Command Registration
- Register a new slash command `/print_last` (and short alias `/last`) in `Nightmare::Commands::Router#handle`.
- Update `/help` command text in `Router#print_help` to list `/print_last`.

### 2.2 Turn Prompt Extraction
- The command inspects the context store (`@store` / `Mantle::Storage::SlidingStore`):
  1. If an active uncommitted turn exists (`@store.active_turn`), inspect its initial user message.
  2. Otherwise, check the most recent completed turn in history (`@store.history.last?`).
- Retrieve the user prompt string via `turn.user_message.content`.
- If side-effect advisories or system notes were prepended by `SlidingStore` (e.g., `[Previous turn was interrupted after modifying: ...]`), extract or cleanly present the user prompt text.

### 2.3 Output Formatting & UX
- When a previous user prompt is found:
  - Display the prompt delineated clearly to the console (via `@stdout`), with clean separation so the text is easily mouse-selected or copied.
  - Format with clean delimiters:
    ```
    === Last Request ===
    <prompt text>
    ====================
    ```
  - When invoked with `raw` argument (`/print_last raw` or `/last raw`), emit only the raw prompt string without banner formatting.
- When no previous turn exists in session history:
  - Print a clear advisory notice: `No previous user request found.`
- Return `{true, nil}` from `handle` so the REPL immediately prompts for the next input without dispatching an LLM turn.

### 2.4 Affected Components
- `src/nightmare/commands/router.cr`:
  - Route `/print_last` and `/last`.
  - Add `private def handle_print_last(args : String = "") : Nil`.
  - Update `print_help` documentation.
- `docs/guide/09-commands.md`:
  - Document `/print_last` and `/last` in quick reference and inspection sections.
- `spec/commands/router_spec.cr`:
  - Test `/print_last` handling with empty store history.
  - Test `/print_last` handling with active turn and committed history.
  - Test `/last` alias and `/print_last raw`.
  - Test handling with previous interruption advisory note.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Add unit tests in `spec/commands/router_spec.cr`:
    1. Verify `/print_last` output when `@store.history` is empty.
    2. Verify `/print_last` outputs the exact user prompt string after a turn has been added to `@store`.
    3. Verify `/help` output includes `/print_last`.
  - Execute `crystal spec spec/commands/router_spec.cr` and verify all tests pass.
  - Run full test suite `crystal spec` to ensure zero regressions across the codebase.
* **Verification Evidence:**
  - `spec/commands/router_spec.cr`: 16 examples, 0 failures, 0 errors, 0 pending (22.09ms).
  - Full suite `crystal spec`: 298 examples, 0 failures, 0 errors, 0 pending (1:36m).
* **Validation Plan:**
  - Exercise `/print_last` and `/last` commands against active and committed store turns, validating formatting and clean extraction.
* **Validation Evidence:**
  - Verified via router execution specs covering empty history, active in-progress turns, committed history turns, `/last` alias, raw output mode, and advisory prefix stripping.

## Open Questions & Concurrency Concerns
* **Raw vs Decorated Display**: Resolved; supported both framed banner output by default and raw unformatted output via `/print_last raw` or `/last raw`.
* **Clipboard Integration**: Future enhancement could detect system clipboard utilities (`pbcopy`, `xclip`, `wl-copy`) to optionally copy automatically.

## 4. Revision History
* 2026-10-02: Initial creation and implementation. Verified with unit specs and full test suite. Closed.
---
