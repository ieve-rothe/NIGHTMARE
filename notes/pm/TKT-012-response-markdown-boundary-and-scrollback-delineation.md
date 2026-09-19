---
ID: TKT-012
Title: Visual Delineation and Response Boundary for Markdown REPL Output
Status: Resolved
Priority: Med
---

## 1. User Need
When interacting with the REPL, the user reads assistant responses streaming in real time. Upon turn completion, the raw streamed tokens are replaced with a full ANSI-formatted Markdown rendering. When responses are longer than the terminal viewport, terminal emulator specifications prevent ANSI cursor movements (`\e[<N>A`) from traversing or clearing the terminal's scrollback buffer. Consequently, the upper lines of the raw stream remain stranded in scrollback, immediately abutting the newly rendered Markdown response. The user needs a clear visual separator delineating the start of the formatted response so they can easily distinguish the formatted content from any stranded stream remnants when scrolling back through their terminal history.

## 2. Specification
1. **Visual Separator Primitive (`Salamander::UI`):**
   - Provide `Salamander::UI.render_separator(label : String? = nil, width : Int32? = nil) : String` (and corresponding instance method).
   - Format a horizontal rule using the active `Theme.border`, `Theme.status_tag`, and `Theme::RESET`.
   - When a label is supplied (e.g. `"Response"`), render:
     `─── Response ──────────────────────────────────────────────────────────`
   - Clamp the separator width to `Salamander::UI::Panel.clamp_width(terminal_width)` when width is not explicitly specified.
   - Maintain strict visual monospace column alignment matching Salamander's UI panels.

2. **REPL Markdown Formatting Integration (`Nightmare::REPL`):**
   - In `Nightmare::REPL#execute_turn`, when `@markdown_formatting && STDOUT.tty?` is active:
     - Issue `Salamander::UI.clear_and_reposition(visible_text)`.
     - Output `Salamander::UI.render_separator("Response")` immediately prior to outputting `Salamander::UI::MarkdownFormatter.format(...)`.
   - For non-streaming fallback responses formatted with Markdown, output the separator prior to the formatted block as well.
   - Flush `STDOUT` to guarantee complete terminal rendering.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Add unit tests in `salamander/spec/ui_spec.cr` asserting that `render_separator` correctly renders the separator line with and without labels, respecting custom and clamped widths, and including appropriate ANSI escapes.
  - Add integration tests in `nightmare/spec/markdown_spec.cr` verifying that the separator is emitted when markdown formatting is active on TTY.
  - Run `crystal spec` across both `salamander` and `nightmare` suites to confirm zero regressions.
* **Verification Evidence:**
  - `salamander`: 52 examples, 0 failures (`crystal spec` in `salamander`). Verified `render_separator` with label ("Response"), without label, with custom explicit width (40 and 50 columns), and with default clamped terminal width (`Panel.clamp_width`).
  - `nightmare`: 248 examples, 0 failures (`crystal spec` in `nightmare`). Verified integration in `markdown_spec.cr` and REPL lifecycle.
* **Validation Plan:**
  - Manually inspect formatted outputs in various terminal widths and themes (`cyberpunk`, `classic`, etc.).
  - Simulate multi-screen responses to verify that scrolling backward clearly distinguishes the stranded streaming output from the final markdown response via the separator.
* **Validation Evidence:**
  - Executed dynamic evaluation across all four active themes (`cyberpunk`, `outrun`, `phosphor`, `classic`). Confirmed that the rendered separator produces exact monospace alignment and appropriate ANSI escape sequences. When scrolling backward past long outputs, the `─── Response ───` separator forms an unmistakable visual landmark separating the initial streaming fragment from the final formatted Markdown block.

## Open Questions & Concurrency Concerns
* *Investigation Notes & Terminal Mechanics:* ANSI escape `\e[<N>A` (Cursor Up) is clamped at row 1 of the visible viewport in all standard terminal emulators (xterm, libvte, kitty, alacritty). True rewind into the scrollback buffer is physically unsupported by the VT100 terminal architecture without entering an alternate screen buffer (`\e[?1049h`). Because entering alternate screen buffers impairs standard copy/paste and linear REPL history, adding an explicit visual separator provides immediate landmark identification in terminal scrollback with minimal overhead.

## 4. Revision History
* 2026-09-18: Ticket created and set to In-Progress with initial root-cause analysis and specification.
* 2026-09-18: Implementation completed in salamander (`render_separator`) and nightmare (`repl.cr`). All unit and integration specs passing. Marked Resolved.
---
