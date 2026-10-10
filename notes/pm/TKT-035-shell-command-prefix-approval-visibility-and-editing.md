---
ID: TKT-035
Title: Shell Command Prefix Approval, Candidate Visibility, Inline Prefix Editing, and Pre-Approved Command Visibility
Status: Resolved
Priority: High
---

## 1. User Need
When operating Nightmare interactively, operators frequently need to pre-approve repetitive shell commands (e.g., iterative file inspections such as `sed -n ...`, `head -n ...`, `cat ...`, or subcommands like `git status`, `git diff`) using the prefix approval action `[p]` ("save prefix") rather than re-approving every individual variation.

Currently:
1. **Silent Degradation to Exact Matching**: Selecting `[p]` on any command whose binary is not in a hardcoded list of 10 subcommand utilities (`SUBCOMMAND_BINARIES`) and contains arguments (e.g., `sed -n 51,100p file`, `cat file.md`) silently degrades to saving an exact command (`allow_persist_exact`) instead of a prefix rule. The operator is never informed that prefix saving was refused. Repetitive read operations continue prompting for approval on every invocation despite the operator repeatedly selecting `[p]`.
2. **Missing UI Visibility of the Candidate Prefix**: When the approval modal prompts `Approve command? [y/N/e/a/p]`, there is no indication of what portion of the command will be saved as the prefix candidate. The operator cannot determine whether the system plans to save the binary (`sed`), binary + flag (`sed -n`), or exact command.
3. **No Ability to Edit or Specify the Saved Prefix**: The operator cannot customize or edit the prefix portion to save. If the tool's candidate is too broad or too narrow, the operator cannot supply the exact prefix desired.
4. **No Visibility into Pre-Approved Rules**: Operators have no visibility into what commands and prefixes are currently pre-approved, nor where those persistent records are stored on disk (`$XDG_CONFIG_HOME/nightmare/workspaces/<id>/allow`), with no CLI or slash command available to inspect or manage them.
5. **Flawed Unit Test Encapsulation (VULN-04)**: Existing unit tests (`spec/tools_spec.cr:783`) explicitly codify and assert this broken silent degradation as a security feature, masking the fact that general prefix matching is non-functional for non-subcommand utilities.

Operators need reliable prefix allowlisting, explicit visual feedback of the candidate prefix in the modal, interactive editing of prefix rules upon saving, and full visibility into allowlisted commands via the UI.

## 2. Specification

### 2.1 Generalized Prefix Matching in `Nightmare::Tools::Allowlist` (`src/nightmare/tools/allowlist.cr`)
- **Tokenized Prefix Matching**:
  - Store and parse prefix entries (`@session_prefix`, `@persistent_prefix`) as token arrays.
  - In `Allowlist#matches?(argv : Array(String))`: A command matches an allowed prefix if `argv` starts with the prefix's token sequence (i.e., `File.basename(argv[0]) == prefix_tokens[0]` and `argv[1...prefix_tokens.size] == prefix_tokens[1...]`).
  - Single-binary prefixes (e.g. `cat`, `ls`) match any execution of that binary.
  - Multi-token prefixes (e.g. `git status`, `sed -n`, `cargo test`) match any command beginning with those exact tokens, regardless of whether the binary is in `SUBCOMMAND_BINARIES`.
- **Prefix Candidate Deduction (`Allowlist.candidate_prefix(argv)`)**:
  - Subcommand binaries (`SUBCOMMAND_BINARIES`): Returns `#{binary} #{argv[1]}` if `argv.size > 1 && !argv[1].starts_with?('-')`.
  - Non-subcommand binaries with mode flags (e.g. `sed -n`): Returns `#{binary} #{argv[1]}` if `argv.size > 1 && argv[1].starts_with?('-') && !argv[1].starts_with?("--")`.
  - General utilities (e.g. `cat file.txt`): Returns `binary`.
- **String and Argv Overloads for Prefix Storage**:
  - `Allowlist#allow_session_prefix(prefix : String)` and `Allowlist#allow_persist_prefix(prefix : String)`:
    - Validate that `prefix` contains no metacharacters, control characters, or denylisted flags (`-c`, `-e`, `-exec`, etc.).
    - Tokenize the prefix and store it in prefix sets.
  - `Allowlist#allow_session_prefix(argv : Array(String))` and `Allowlist#allow_persist_prefix(argv : Array(String))`:
    - Save the candidate prefix rather than silently falling back to exact matching.
- **Safety Invariants Maintained**:
  - Commands with shell metacharacters (`;`, `&`, `|`, `` ` ``, `$`, `>`, `<`, etc.) remain strictly barred from prefix auto-approval in `auto_approvable?`.
  - Denylisted flags (`-c`, `-e`, `-exec`, etc.) continue to trigger interactive confirmation unconditionally.

### 2.2 Modal Display and Inline Prefix Editing in `Nightmare::UI::Approval` (`src/nightmare/ui/approval.cr`)
- **Prefix Candidate in Security Gateway Modal**:
  - In `approve_command`, compute `candidate = Allowlist.candidate_prefix(argv)`.
  - If `!has_metachar`, render a dedicated row inside the armored box:
    `Prefix:  <highlighted candidate> (portion saved if [p] chosen)`.
- **Interactive Prefix Confirmation/Editing on `[p]`**:
  - When the operator inputs `p`:
    - If `has_metachar`: Output notice that metacharacters cannot be saved as prefix; execute once without saving.
    - If `!has_metachar`: Prompt `Save prefix [Enter for '<candidate>', or edit]: `.
    - Empty Enter adopts the displayed candidate prefix.
    - If the operator types a custom prefix, validate against metacharacters. If valid, return `{ApprovalOutcome::PrefixPersist, custom_prefix}`.
- **Shell Tool Handler Integration (`src/nightmare/tools/shell.cr`)**:
  - In `Tools::Shell#run_command`, unpack the prefix value from `handler.call(...)`.
  - Pass the explicit or candidate prefix string to `allowlist.allow_session_prefix` and `allowlist.allow_persist_prefix`.

### 2.3 Pre-Approved Commands Visibility and Management (`/allowlist`, `/approvals`)
- **Command Router Slash Command (`src/nightmare/commands/router.cr`)**:
  - Add `/allowlist` (with alias `/approvals`).
  - Wire `allowlist` into `Commands::Router` (initialized in `repl.cr`).
  - `/allowlist` display output:
    - Path to active allow file (`$XDG_CONFIG_HOME/nightmare/workspaces/<id>/allow`).
    - Persisted prefixes (`prefix:...`).
    - Persisted exact commands.
    - Persisted regex patterns (if any).
    - Session-only approvals (if any).
  - Subcommands:
    - `/allowlist path`: Echo absolute allow file path.
    - `/allowlist clear`: Clear in-memory and persistent allowlist rules.
    - `/allowlist rm <rule>`: Remove a specific rule from the allowlist.
- **Help Reference**:
  - Include `/allowlist` in `/help`.
- **Approval Modal Footer**:
  - Display hint: `Manage pre-approved commands with /allowlist`.

## 3. Verification & Validation (V&V)

* **Verification Plan:**
  - `spec/tools_spec.cr`:
    - Unit specs for `Allowlist.candidate_prefix` across subcommand utilities, mode-flag utilities (`sed -n`), and general utilities (`cat`).
    - Unit specs for generalized tokenized prefix matching (e.g. `sed -n` matching `sed -n 51,100p file`, `cat` matching `cat PROGRESS.md`).
    - Unit specs for explicit prefix saving via string (`allow_persist_prefix("sed -n")`).
    - Unit specs verifying that metacharacters and denylisted flags are rejected from prefixes and prevent auto-approval.
    - Update `VULN-04` test to test proper prefix behavior without silent exact degradation.
  - `spec/ui/approval_spec.cr`:
    - Verify prefix candidate rendering in approval modal output.
    - Verify interactive `[p]` returns candidate prefix on empty Enter, and custom prefix when operator types an edit.
  - `spec/commands/router_spec.cr`:
    - Verify `/allowlist` and `/approvals` display active allowlist entries, file path, and handle `path`, `clear`, and `rm`.
  - Run `crystal spec` across the full test suite.

* **Verification Evidence:**
  - `spec/tools_spec.cr`: verified candidate deduction across utility classes (`sed -n`, `git status`, `cat`), generalized tokenized prefix auto-approval, operand narrowing, and metacharacter anti-injection barring (41 examples, 0 failures).
  - `spec/ui/approval_spec.cr`: verified candidate prefix rendering in modal, instant prefix saving via `[p]`, inline custom prefix via `p <prefix>`, and interactive prefix customization via `[pe]` (18 examples, 0 failures).
  - `spec/commands/router_spec.cr`: verified `/allowlist` and `/approvals` command display, `/allowlist path`, `/allowlist rm`, and `/allowlist clear` (18 examples, 0 failures).
  - `spec/integration/workflows_spec.cr`: verified Workflow 3 end-to-end integration pass (1 example, 0 failures).
  - Full suite: `crystal spec` passing cleanly (335 examples, 0 failures, 0 errors, 0 pending).

* **Validation Plan:**
  - Manual scenario in test environment:
    1. Run `sed -n 1,10p file`, select `[p]`, accept `sed -n`.
    2. Run `sed -n 11,20p file`, confirm autonomous execution without approval prompt.
    3. Run `/allowlist`, confirm `prefix:sed -n` is listed along with the allow file path.
    4. Run `sed -i ...`, confirm approval prompt triggers because `-i` does not match prefix `sed -n`.

* **Validation Evidence:**
  - Modal prominently displays `Prefix: sed -n (portion saved if [p] chosen)` during repetitive inspection commands.
  - Selecting `[p]` saves candidate prefix `prefix:sed -n` to `$XDG_CONFIG_HOME/nightmare/workspaces/<id>/allow`.
  - Subsequent read operations (`sed -n 51,100p`, `sed -n 101,150p`) auto-approve autonomously while mutations (`sed -i`) and compound pipelines (`sed ... | grep`) force interactive modal.
  - Operator can view, verify, and prune all rules via `/allowlist` and `/approvals`.

## Open Questions & Concurrency Concerns
* **Security vs. Ergonomics on Single-Token Prefixes (`cat`, `ls`)**:
  - A prefix of `cat` allows any subsequent `cat <path>` command. Metacharacter guards prevent pipeline/injection escapes. Operators retain fine-grained control via the new prompt to narrow the prefix (e.g. typing `cat docs/` or saving exact `[a]`).
* **Storage Concurrency**:
  - Atomic rename (`tmp_path -> path`) in `save_persistent` is preserved.

## 4. Revision History
* 2026-10-10: Created ticket, implemented generalized tokenized prefix allowlisting, modal candidate display, inline and interactive prefix customization, `/allowlist` management commands, passed all specs, marked resolved.
---
