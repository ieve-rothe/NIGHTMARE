---
ID: TKT-030
Title: Display Current Working Directory in CLI Interface and Prompt
Status: Closed
Priority: Med
---

## 1. User Need
Operators running interactive sessions in the NIGHTMARE CLI interface need clear visibility of the current working directory (`cwd`). Because development frequently occurs across multi-repository workspaces, monorepos, and subdirectories (and operations or tools may navigate or execute across different paths), it is currently ambiguous where the CLI session and bot are operating. Displaying the current working directory in the prompt area ensures the user always has clear spatial context before issuing commands or reviewing changes.

## 2. Specification
### 2.1 Prompt Area CWD Presentation
- Added `Nightmare::UI::Prompt` module in `src/nightmare/ui/prompt.cr`.
- Updated the interactive REPL prompt loop in `Nightmare::REPL#start` to include the current working directory.
- Dynamically queries `Dir.current` on each REPL input loop (with fallback rescue to `@env.root`), ensuring any directory changes during the session are immediately visible in the prompt.
- Formats path for terminal ergonomics:
  - Tildifies home directory (e.g., replaces `$HOME` prefix with `~`).
  - Leaves non-home paths intact.
- Applies subtle theme styling (`Salamander::UI::Theme.meta_dim`) so the working directory is clear without overpowering the prompt glyph or user input.

### 2.2 Integration with Existing Prompt Elements
- Maintains compatibility with active skill indicators:
  - Without skill: `~/repos/adjutant/nightmare ❯ `
  - With skill: `~/repos/adjutant/nightmare [skill_name] ❯ `
- Applies `Salamander::UI::Theme.user_prompt` styling to user input and ensures terminal resets occur after input acquisition.

### 2.3 Affected Components
- `src/nightmare/ui/prompt.cr`: Created `Nightmare::UI::Prompt` with `.format_path` and `.render`.
- `src/nightmare/repl.cr`: Integrated `UI::Prompt.render` into the main REPL input loop.
- `spec/ui/prompt_spec.cr`: Comprehensive unit specs covering path formatting and prompt rendering.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Implement unit specs covering path formatting logic (e.g. tildification of home path, formatting when in workspace root or subdirectories).
  - Verify prompt composition with and without active skills attached.
  - Run `crystal spec spec/ui/prompt_spec.cr` and `spec/ui/` to guarantee zero regressions.
  - Run `shards build` to verify clean compilation of `bin/nightmare`.
* **Verification Evidence:**
  - `spec/ui/prompt_spec.cr`: 7 examples, 0 failures, 0 errors, 0 pending (1.52ms).
  - `spec/ui/`: 44 examples, 0 failures, 0 errors, 0 pending (427.05ms).
  - `spec/nightmare_spec.cr`: 2 examples, 0 failures, 0 errors, 0 pending (1.08ms).
  - `spec/commands/router_spec.cr`: 17 examples, 0 failures, 0 errors, 0 pending (24.93ms).
  - `shards build`: Successfully built `bin/nightmare`.
* **Validation Plan:**
  - Validate prompt rendering across various directories (home root, deep subdirectories, non-home paths).
  - Verify prompt renders correctly, preserves color boundaries, and accurately reflects directory changes.
* **Validation Evidence:**
  - Verified via unit test suite covering home tildification (`~`), subpaths (`~/repos/project`), external paths (`/var/log/syslog`), prefix collisions, and active skill presence (`[deploy-runner]`). Tested CLI binary help and execution.

## Open Questions & Concurrency Concerns
* **Prompt Layout**: Inline layout (`<cwd> [skill] ❯ `) was selected for clean horizontal compactness, matching standard modern CLI UX (starship, fish, claudecode).
* **Robustness**: In the event `Dir.current` raises due to an unlinked directory, `REPL#start` rescues gracefully to `@env.root`.

## 4. Revision History
* 2026-10-03: Initial ticket creation based on user UI request.
* 2026-10-03: Implemented `Nightmare::UI::Prompt`, integrated into `REPL#start`, verified with unit specs and binary compilation. Closed.
---
