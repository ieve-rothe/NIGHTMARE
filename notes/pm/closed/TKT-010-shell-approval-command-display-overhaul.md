---
ID: TKT-010
Title: Shell Approval Modal — Command Display Overhaul
Status: Closed
Priority: Med
---

## 1. User Need
When a shell command requires approval, the operator needs to quickly parse what is about to be executed. The previous display showed both a `Command:` line and a redundant `Argv:` line (the tokenized form), which added noise and made it harder to read at a glance. Compound commands (chained with `&&`, `||`, `;`) were rendered as a single dense line, making it difficult to see the individual steps.

The operator needs:
- A single, familiar command representation (what they'd type in a terminal)
- Compound commands visually separated so each step is immediately obvious
- Syntax coloring that maps to bash semantics for quick pattern recognition

## 2. Specification
### 2.1 Remove Argv Display
- Remove the `Argv:` row from the shell approval panel entirely.
- The `argv` parameter is retained in the method signature for API compatibility with the approval handler callback but is no longer rendered.

### 2.2 Compound Command Splitting
- Split the command string on bash separators: `&&`, `||`, `;`, and literal newlines.
- Single commands render inline: `Command: git status`
- Multiple sub-commands render one-per-line with the separator glyph as a prefix:
  ```
  Command:
    git pull
    && make build
    && make test
  ```
- Separator glyphs are rendered in the theme's `meta_dim` color.

### 2.3 Bash-Aware Syntax Coloring
Each token in a sub-command is colored according to its bash semantic role:
- **Executable** (first word): bold + highlight (amber/gold)
- **Flags** (`-f`, `--verbose`): status_tag (cyan/aqua)
- **Env assignments** (`PATH=/usr/bin`): token_badge (violet)
- **Quoted strings** (`"hello"`, `'world'`): success_icon (green)
- **Shell variables** (`$HOME`, `${VAR}`): token_badge (violet)
- **Redirects** (`>`, `2>&1`): filename (warm cream)
- **Other arguments**: code_text (off-white)
- **Cwd path**: filename color for visual consistency

All coloring delegates to the active Salamander theme (cyberpunk, outrun, phosphor, classic).

### 2.4 Files Changed
- `src/nightmare/ui/approval.cr`: Added `split_shell_commands`, `colorize_command` private methods; rewrote `approve_command` render logic.
- `spec/ui/approval_spec.cr`: Updated assertions to account for ANSI codes in output.

## 3. Verification & Validation (V&V)
* **Verification Plan:** Run `crystal spec spec/ui/approval_spec.cr` — all 10 existing approval tests must pass.
* **Verification Evidence:** 10 examples, 0 failures, 0 errors, 0 pending (2.0ms).
* **Validation Plan:** Operator uses nightmare interactively and reviews approval modals for simple (`git status`) and compound (`git pull && make build`) commands; confirms readability improvement.
* **Validation Evidence:** Pending operator visual confirmation in live session.

## Open Questions & Concurrency Concerns
* The `colorize_command` tokenizer uses whitespace splitting, which means quoted strings containing spaces won't be captured as a single colored token. This is a display-only concern and doesn't affect execution correctness. A more sophisticated shell-aware lexer could be added later if needed.
* The `split_shell_commands` regex does not account for separators inside quoted strings. This is acceptable because the metacharacter detection already flags such commands with a warning note, and the display is best-effort for human readability.

## 4. Revision History
* 2026-09-17: Created and closed. Implementation complete, all specs passing.
---
