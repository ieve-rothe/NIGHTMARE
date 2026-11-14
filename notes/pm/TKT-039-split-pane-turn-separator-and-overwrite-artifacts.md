---
ID: TKT-039
Title: Split-Pane Multi-Turn Visual Separator and Cursor Repositioning Overwrite Fix
Status: Resolved
Priority: Med
---

## 1. User Need
When running interactive sessions in Nightmare's wide-terminal split-pane mode (`TurnPresenter#split_mode_active?`, observed in workspace `/home/cam/.local/state/nightmare/workspaces/furuniv-231c860b`), users experience two compounding visual issues across consecutive turns:

1. **Unseparated Multi-Turn Responses in the Right Pane:** When content from multiple turns appears in the right-hand pane, responses run together without any turn boundary. For example, Turn 1's text remains visible at the top of the right pane while Turn 2's response (`"Oh wow, Cam!..."`) begins directly beneath a blank line with no separator, and after Turn 3 (`"Oh, absolutely they do!..."`), fragments from Turn 1 and Turn 2 remain above Turn 3's text with no visual delimiter showing where one turn ends and the next begins.
2. **Stranded Partial-Turn Artifacts Across Turns:** Moving from Turn 1 to Turn 2 and Turn 3 causes the dashboard redraw to partially overwrite previous turns rather than cleanly redrawing or delineating them. This leaves truncated panel fragments stranded at the top of the left pane (e.g., Turn 1's box and a half-overwritten Turn 2 box cut off mid-panel above Turn 3) and orphaned opening paragraphs from earlier turns stranded at the top of the right pane while their lower paragraphs are overwritten.

Whenever multiple turns are displayed, users need a clear visual separator delineating turns on the right-hand pane, and clean full-dashboard redraws across turns so partial boxes and truncated paragraphs from prior turns are not left behind as visual artifacts.

## 2. Specification

### 2.1 Route All Streaming Chunks Through `@on_print` (`nightmare/src/nightmare/ui/stream_controller.cr`)
- In `StreamController#process_pending` (around line 94), replace the direct `print @pending; STDOUT.flush` call in the non-`<think>` fallback branch with `@on_print.call(@pending)`.
- Ensures that in split-pane mode, every non-thinking streamed chunk routes through `@turn_presenter.append_stream_text(s)` (`repl.cr:192-199`) instead of writing raw unformatted text directly to `STDOUT` below the dashboard.

### 2.2 Fix Inter-Turn Cursor Repositioning Drift (`nightmare/src/nightmare/ui/turn_presenter.cr`)
- Between turns, `REPL#start` prints the 2-line prompt (`⯌ Human ⇄ Assistant · <cwd>\nYou › <input>\n`), and `@output.puts screen` in `TurnPresenter#render_dashboard` (line 401) appends a trailing newline that is not included in `@last_render = screen`.
- Because `TurnPresenter#reset_for_new_turn` does not clear `@last_render`, on Turn 2+ `Salamander::UI.clear_and_reposition(last, @output)` moves the cursor up by only `count_physical_lines(prev_screen) - 1` rows, landing below the top of the previous turn's render and overwriting from the middle of the previous turn downward.
- Fix by:
  1. Resetting `@last_render = nil` in `TurnPresenter#reset_for_new_turn` (or issuing `Salamander::UI.clear_screen` on the first render of a new turn) so inter-turn prompt lines never introduce cursor offset drift.
  2. Accounting for the trailing newline emitted by `@output.puts screen` (e.g., storing `screen + "\n"` in `@last_render` or passing the exact emitted string to `clear_and_reposition`) for accurate intra-turn redraws.

### 2.3 Multi-Turn Right-Pane History and Visual Turn Separator (`nightmare/src/nightmare/ui/turn_presenter.cr`)
- Preserve completed turn outputs in the right-pane history buffer across turns (bounded by viewport height `disp_h`):
  - During Turn `N`, raw streaming tokens append unformatted below Turn `N`'s divider as they arrive.
  - Upon turn completion (`format_right_pane: true`), replace only the active Turn `N`'s raw streamed lines in-place beneath its divider with the Markdown-formatted final response, leaving prior completed turns (`1..N-1`) formatted above it within viewport bounds.
- When starting a new turn (or upon emitting the first right-pane output of Turn `N > 1` when prior turn history is non-empty):
  - Flush any pending `@stream_current` into history.
  - Insert a themed visual separator labeled `"Turn #{@turn_number}"` constrained to `right_w` columns via `Salamander::UI.render_separator("Turn #{@turn_number}", right_w)` so consecutive turns displayed in the right pane are visually separated.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Add unit specs in `nightmare/spec/ui/turn_presenter_spec.cr` verifying that across multiple turns in split mode (`COLUMNS=180`, `LINES=40`):
    - Right-pane output preserves prior turn text separated by a `Turn N` visual separator line sized to `right_w`.
    - Left-pane renders only the current turn's `NIGHTMARE REPL · TURN N` card without stranded partial boxes from earlier turns.
    - `StreamController` routes all non-thinking chunks through `@on_print`.
  - Run `crystal spec` in `nightmare` and `salamander` to confirm zero regressions.
* **Verification Evidence:**
  - `salamander`: `CRYSTAL_PATH=salamander/lib:salamander/src:/usr/lib/crystal crystal spec salamander/spec` passed (`76 examples, 0 failures, 0 errors, 0 pending`), including new visual-width line counting spec in `salamander/spec/ui_spec.cr` verifying ANSI-styled lines within `COLUMNS=10` count as 1 physical line via `Salamander::UI.count_physical_lines` using `Panel.visual_width`.
  - `nightmare`: `CRYSTAL_PATH=nightmare/lib:nightmare/src:/usr/lib/crystal crystal spec nightmare/spec/ui/turn_presenter_spec.cr` (`13 examples, 0 failures, 0 errors, 0 pending`) and full suite `CRYSTAL_PATH=nightmare/lib:nightmare/src:/usr/lib/crystal crystal spec nightmare/spec` (`382 examples, 0 failures, 0 errors, 0 pending`) passed, verifying:
    - `StreamController` routes all non-thinking chunks through `@on_print` into `TurnPresenter#append_stream_text`.
    - `TurnPresenter#reset_for_new_turn` resets `@last_render` to `nil` and increments `@turn_number`, preventing stale inter-turn cursor repositioning offsets.
    - `TurnPresenter#render_dashboard` stores `"#{screen}\n"` in `@last_render` so intra-turn `Salamander::UI.clear_and_reposition` emits `\r\e[<prev_lines - 1>A\e[J` accurately.
    - Right-pane history preserves completed turns separated by `─── Turn N ───` dividers sized to `right_w`, streaming raw tokens below the divider and replacing only Turn `N`'s streamed slice in-place with Markdown-formatted output upon `format_right_pane: true`.
* **Validation Plan:**
  - Reproduce a 3-turn interactive conversation in split mode (`≥160` columns) matching the `furuniv-231c860b` session and verify that:
    1. Turn 1, Turn 2, and Turn 3 responses displayed in the right pane are clearly separated by horizontal turn dividers (`─── Turn 2 ───`, `─── Turn 3 ───`).
    2. No truncated partial boxes or overwritten paragraph fragments from Turn 1 or Turn 2 remain stranded at the top of the left or right pane.
* **Validation Evidence:**
  - Simulated the 3-turn split-mode (`COLUMNS=180`, `LINES=40`) `StreamController` + `TurnPresenter` flow in `nightmare/spec/ui/turn_presenter_spec.cr`: confirmed Turn 1, `─── Turn 2 ───`, Turn 2, `─── Turn 3 ───`, and Turn 3 appear sequentially in the right pane with raw `*spins*` formatted to ANSI italics (`\e[3mspins\e[0m`) upon turn completion, while each turn's left pane renders only the active `NIGHTMARE REPL · TURN N` card without earlier turn boxes. Live interactive TTY validation awaits manual user run.

## Open Questions & Concurrency Concerns
* **Separator Label & Formatting (Resolved 2026-11-13):** Confirmed `"Turn #{@turn_number}"` via `Salamander::UI.render_separator("Turn #{@turn_number}", right_w)`.
* **Streaming vs. Final Markdown Replacement (Resolved 2026-11-13):** Confirmed that during Turn `N`, raw streaming tokens append unformatted below the `─── Turn N ───` divider and are replaced in-place beneath that divider by the Markdown-formatted response upon turn completion, while completed turns `1..N-1` remain formatted above it within viewport bounds.

## 4. Revision History
* 2026-11-13: Ticket created from user bug / interface tweak report on workspace `furuniv-231c860b`.
* 2026-11-13: Confirmed `"Turn #"` separator label and stream-then-format replacement lifecycle per user feedback.
* 2026-11-13: Implemented across `salamander` (`ui.cr`) and `nightmare` (`stream_controller.cr`, `turn_presenter.cr`); added specs and verified both suites pass; marked `Resolved`.
---
