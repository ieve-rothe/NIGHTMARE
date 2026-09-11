# Handoff Report: Milestone 1 Directives Resolution & CLI OptionParser

**Agent**: `explorer_m1_2`  
**Milestone**: Milestone 1 - System Directives Resolution & Configuration Precedence (F1.6, F1.8)  
**Deliverable Document**: `/home/cam/repos/adjutant/nightmare/.agents/explorer_m1_2/m1_design.md`  
**Target Implementation Files**:
- `src/nightmare/directives/resolver.cr`
- `src/nightmare/cli/parser.cr` (or in `src/nightmare.cr`)
- `src/nightmare.cr`
- `spec/directives_spec.cr`

---

## 1. Observation

1. **Directives Precedence & Fallback Persona**:
   - In `/home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1/specs.md` (lines 68-81) and `docs/DESIGN.md` (lines 143-157), the hierarchical precedence order is explicitly defined as:
     1. CLI Flag (`-s <path>` / `--system <path>`)
     2. Repository Committed File (`.nightmare/prompt.md` within `@root`)
     3. Workspace Central Config (`$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/prompt.md`)
     4. Global Central Config (`$XDG_CONFIG_HOME/nightmare/prompt.md`)
     5. Default General Persona (Fallback)
   - Verbatim persona text (lines 76-81 of `specs.md`):
     ```markdown
     You are an execution agent operating in the current working directory.
     - Inspect files and execute tools to determine facts before taking action.
     - Prefer replace_in_file for edits; read before you write; never overwrite a file you have not inspected this session.
     - Be concise, direct, and factual.
     - Do not assume context; rely strictly on provided files, tool outputs, and user instructions.
     ```

2. **In-Memory Directive Mutation (`/prompt edit`)**:
   - In `specs.md` §1.5 (lines 83-90) and `ORIGINAL_REQUEST.md` (line 53, AC-U2):
     - Resolves editor via `$EDITOR` $\rightarrow$ `$VISUAL` $\rightarrow$ `nano` $\rightarrow$ `vim` $\rightarrow$ `vi`.
     - Spawns editor on temporary file in RAM/OS temp directory.
     - Updates **strictly the in-memory directive** for the running session.
     - Underlying files on disk remain **untouched**.
     - Reverts to prior prompt if editor exits with error (Feature 6, line 486).

3. **Interface Contract in `PROJECT.md`**:
   - In `orchestrator_1/PROJECT.md` lines 111-115:
     ```crystal
     module Nightmare::Directives
       class Resolver
         def self.resolve(env : Workspace::Environment, cli_override : String? = nil) : String
       end
     end
     ```

4. **Empirical System Tool Checks**:
   - Ran `crystal --version`:
     ```text
     Crystal 1.21.0 (2026-07-23)
     LLVM: 22.1.8
     Default target: x86_64-pc-linux-gnu
     ```
   - Ran `crystal eval` for `Process.find_executable`:
     - `Process.find_executable("nano")` $\rightarrow$ `nil`
     - `Process.find_executable("vim")` $\rightarrow$ `"/usr/bin/vim"`
     - `Process.find_executable("vi")` $\rightarrow$ `"/usr/bin/vi"`
     This confirms that on the current host system, `nano` is absent while `vim` and `vi` are available, validating the necessity of the complete fallback sequence.
   - Tested temporary directory creation:
     - `Dir.mktmpdir` does not exist in Crystal 1.21.0 (`undefined method 'mktmpdir' for Dir.class`).
     - Tested `with_test_env` utilizing `Dir.tempdir` and `Random::Secure.hex(8)` with `FileUtils.rm_rf` in `ensure`, which works cleanly.
   - Tested `OptionParser`:
     - Successfully parsed `-s PATH`, `--system=PATH`, `--no-log`, `-m MODEL`, and unknown arguments for positional workspace directories. Catches `OptionParser::InvalidOption` and `OptionParser::MissingOption`.

---

## 2. Logic Chain

1. **Hierarchical Resolution Mechanism**:
   - Observation: Requirement R1 and `specs.md` §1.4 define a 5-tier hierarchy where higher tiers override lower ones, with no repository litter.
   - Deduction: `Nightmare::Directives::Resolver.resolve_with_source` sequentially checks each tier. If `cli_override` is passed, it expands the path against `env.root`. If missing, it raises `ArgumentError`. If present, it returns immediately with `Source::CliFlag`.
   - Deduction: For tiers 2, 3, and 4, `Resolver` inspects `File.file?(path)` and verifies `!File.read(path).strip.empty?`. This avoids adopting empty files.
   - Deduction: If all 4 tiers are absent or blank, it returns `ResolutionResult` with `DEFAULT_PERSONA` and `Source::DefaultPersona`.

2. **In-Memory Directive Mutation and Zero Repo Litter**:
   - Observation: R1, R5, and AC-U2 mandate that `/prompt edit` updates directive state in RAM only, leaving disk files pristine.
   - Deduction: `Nightmare::Directives::Manager` encapsulates the active directive in memory (`@active_directive : String`), initialized from `Resolver`.
   - Deduction: When `#edit` is triggered, it writes `@active_directive` to a temporary file via `File.tempfile("nightmare_prompt_", ".md")` in `Dir.tempdir`. It launches the resolved editor command (`/bin/sh -c "#{editor} #{Process.quote(path)}"`).
   - Deduction: If `status.success?` is true and content is non-empty, `@active_directive` is updated and `modified?` becomes true. If `status.success?` is false (e.g. user aborts in editor), it restores the previous directive without mutation. In all cases, the tempfile is deleted in an `ensure` block. Target repository files and XDG files are never written.

3. **CLI Argument Parsing Foundation**:
   - Observation: `src/nightmare.cr` serves as entry point and CLI option parser.
   - Deduction: Creating `Nightmare::CLI::Parser` and `Nightmare::CLI::Options` separates option parsing from REPL execution, allowing the argument parser to be tested in isolation with 100% unit test coverage.
   - Deduction: The parser captures `-s`, `--system`, `--no-log`, `-m`, `--version`, `-h`, and positional directory paths, and catches parser errors cleanly without unhandled crashes.

4. **Testing Strategy**:
   - Observation: Tests require isolated workspaces and mock XDG paths without polluting the user's `~/.config` or the active repo.
   - Deduction: `with_test_env` creates an isolated directory tree under `Dir.tempdir` and tears it down in `ensure`. Tests cover all 5 precedence combinations, relative paths, missing file errors, in-memory mutation, disk invariance, mock editor success/failure, and CLI option parsing.

---

## 3. Caveats

1. **Mantle/Salamander Linking**:
   - `shard.yml` dependency path linking (`../mantle`, `../salamander`) is scoped to `explorer_m1_3`. However, the Directives subsystem (`Nightmare::Directives`) and CLI OptionParser (`Nightmare::CLI`) depend exclusively on the Crystal Standard Library (`option_parser`, `file_utils`, `process`, `random`). They can compile, execute, and pass unit tests independently of framework shard installation.
2. **Editor Terminal IO in REPL vs Unit Tests**:
   - In interactive REPL sessions, `#edit` inherits `STDIN`, `STDOUT`, and `STDERR`. In automated unit tests, interactive terminal editors cannot be launched interactively; unit tests must pass mock non-interactive shell commands (e.g. `editor_override: "sh -c 'echo \"edited\" >> \"$1\"' --"`) to verify process spawning and status code handling.
3. **Global Config Directory Interoperability**:
   - `Nightmare::Workspace::Environment` (assigned to `explorer_m1_1`) provides `config_dir` (`~/.config/nightmare/workspaces/<workspace_id>/`). `Resolver` provides multi-tier fallback for locating the global config directory (`env.global_prompt_path` $\rightarrow$ `env.global_config_dir` $\rightarrow$ `Path[env.config_dir].parent.parent` $\rightarrow$ `$XDG_CONFIG_HOME/nightmare`), guaranteeing compatibility regardless of minor interface variances in `Environment`.

---

## 4. Conclusion

The technical design and blueprint for Milestone 1 Directives and CLI OptionParser is complete and documented at:
`/home/cam/repos/adjutant/nightmare/.agents/explorer_m1_2/m1_design.md`

Key outcomes:
- **`Nightmare::Directives::Resolver`**: Strict 5-tier resolution hierarchy satisfying `PROJECT.md` contracts, with exact verbatim `DEFAULT_PERSONA` text, path expansion, and blank-file fallthrough.
- **`Nightmare::Directives::Manager`**: In-memory session directive holding active prompt in RAM, modifiable via `/prompt edit` with editor fallback chain (`$EDITOR` $\rightarrow$ `$VISUAL` $\rightarrow$ `nano` $\rightarrow$ `vim` $\rightarrow$ `vi`), zero-leak tempfile management, exit-error rollback, and guaranteed zero repository/disk litter.
- **`Nightmare::CLI::Parser`**: Decoupled, unit-testable CLI parser foundation using Crystal standard library's `OptionParser`.
- **`spec/directives_spec.cr`**: Exhaustive unit test suite covering all 5 tiers, relative paths, missing file exceptions, in-memory mutation, disk invariance, editor lifecycle, and CLI flags.

---

## 5. Verification Method

Once implemented by the worker:

1. **Unit Spec Execution**:
   Run Crystal unit specs directly in the repository:
   ```bash
   crystal spec spec/directives_spec.cr
   ```
   *Expected result*: All precedence, mutation, disk invariance, editor, and CLI option parsing specs pass with 0 failures and 0 errors.

2. **Precedence Hierarchy Verification**:
   - Run test verifying Tier 1 overrides all tiers.
   - Run test verifying Tier 2 overrides Tiers 3-5.
   - Run test verifying Tier 3 overrides Tiers 4-5.
   - Run test verifying Tier 4 overrides Tier 5.
   - Run test verifying Tier 5 returns exact verbatim persona string.

3. **In-Memory Directive Mutation Verification**:
   - Verify `manager.active_directive` changes upon `manager.update`.
   - Verify disk files (`.nightmare/prompt.md` and XDG files) are not modified (byte-identical before and after).
   - Verify `manager.edit` with a failing command (`exit 1`) preserves the original active directive.

4. **CLI OptionParser Verification**:
   - Verify `-s path` and `--system path` populate `Options#system_prompt_path`.
   - Verify `--no-log` sets `Options#no_log = true`.
   - Verify positional arguments set `Options#target_dir`.
   - Verify invalid options populate `Options#error_message`.
