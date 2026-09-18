---
ID: TKT-011
Title: Shell Pipeline Execution, Exact Allowlisting, and Modal Display
Status: Closed
Priority: High
---

## 1. User Need
The agent is post-trained to construct UNIX pipelines (`cat file | head -n 50`) and chained shell commands (`git add . && git status`).
1. Under direct `argv` execution, pipelines crashed because `|` was interpreted as a filename operand. The execution layer must run commands through `/bin/bash -c`.
2. When the agent uses compound or piped commands, the operator currently faces extreme prompt fatigue. Even when the operator explicitly approves with `[a]` (save exact), the allowlist system unconditionally rejected saving any command containing shell metacharacters (`|`, `&&`, `;`). The operator needs Nightmare to remember exact compound commands when explicitly approved with `[a]` so identical subsequent commands run autonomously without interrupting the workflow.
3. In the shell approval modal, compound commands chained with `&&`, `||`, and `;` were rendered on separate lines, but pipelines (`|`) remained crammed onto a single line. The operator needs pipelines visually split per stage for rapid inspection.

## 2. Specification
### 2.1 Revert Execution to `bash -c`
- In `Tools::Shell#execute_process_group`, dynamically resolve `bash` via `Process.find_executable("bash") || "/bin/sh"`.
- Launch via `["-w", bash_bin, "-c", command_string]` under `setsid` (or `["-c", command_string]` without `setsid`).
- Retain session and process group supervision, timeout caps, capped streams, and clean environment isolation.

### 2.2 Exact-Match Allowlisting for Compound / Piped Commands (`[a]`)
- `Allowlist#allow_session_exact` and `Allowlist#allow_persist_exact` record exact full command strings (even if containing compound separators `|`, `&&`, `;`), provided they contain no non-printable or dangerous control characters (`\0`, `\e`, `\r`, unescaped raw newlines).
- `Allowlist#auto_approvable?` returns `true` if the full command string exactly matches an entry in `@session_exact` or `@persistent_exact` and contains no denylisted flags (`!has_denylisted_flags?`).
- Prefix allowlisting (`Allowlist#allow_session_prefix` and `Allowlist#allow_persist_prefix`) strictly continues to reject any command with `METACHARACTERS` to prevent wildcard command injection.
- In `Tools::Shell#run_command`, `ApprovalOutcome::AllSession` saves exact compound commands to allowlists.

### 2.3 Visual Pipeline Splitting in Approval Modal
- `UI::Approval#split_shell_commands` splits on single pipe `|` in delimiter splitting while preserving `||`.
- Piped stages render with a `|` glyph prefix on their own lines.
- Updated modal note: `Note: Shell metacharacters cannot be saved as prefix [p]; [a] saves exact command`.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - `crystal spec spec/tools_spec.cr`: Verify pipeline execution under `bash -c`, verify exact compound command allowlisting on `[a]`, and verify prefix refusal on metacharacters.
  - `crystal spec spec/ui/approval_spec.cr`: Verify that pipelines split properly across lines in the approval modal.
  - `crystal spec spec/integration/workflows_spec.cr`: Ensure end-to-end workflows pass.
* **Verification Evidence:**
  - `spec/tools_spec.cr` passing (25 examples, 0 failures).
  - `spec/ui/approval_spec.cr` passing (11 examples, 0 failures).
  - `spec/integration/workflows_spec.cr` passing (13 examples, 0 failures).
* **Validation Plan:** Live interactive inspection with piped commands; confirm that approving with `[a]` auto-approves subsequent identical pipeline executions.
* **Validation Evidence:** Operator verified pipeline execution under bash; modal renders multi-line pipeline stages, and exact allowlisting eliminates repetitive prompts on identical compound commands.

## Open Questions & Concurrency Concerns
* Exact string allowlisting requires identical whitespace and arguments. Minor variations will safely fall back to the interactive modal, which is the desired conservative behavior.

## 4. Revision History
* 2026-09-17: Created ticket, implemented specification, passed all unit and integration specs, closed ticket.
---
