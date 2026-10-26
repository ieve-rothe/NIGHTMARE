---
ID: TKT-037
Title: Home Directory Tilde Path Expansion and External PWD Mutation Elevation
Status: Resolved
Priority: High
---

## 1. User Need
When operators instruct agents to set up user-level services, background timers, or tool configurations (such as systemd user units in `~/.config/systemd/user/`, shell aliases, or application dotfiles), agents naturally reference paths using standard home-relative syntax (e.g., `~/.config/...`). Furthermore, agents frequently coordinate tasks across multiple directories and need to write files outside their current working directory (`pwd`).

Currently, file path resolution does not expand the tilde (`~`) to the operator's home directory. Instead, the harness interprets `~` as a relative path component within the active working directory, writing files to `<pwd>/~/.config/...`. This causes service configurations to silently misfire, misleads the agent into believing a daemon or service is configured, pollutes the workspace repository with unwanted `~` directories, and prevents operators from allowing agents to manage configuration files relative to their home directory.

Additionally, when an agent legitimately needs to write outside of its working directory (such as installing a systemd service into `~/.config/systemd/user/` or writing to a sibling repository), strict path containment previously triggered hard `SecurityError: Path traversal violation` crashes unless the path was pre-configured in `writable_directories`. This forced agents to circumvent tools and use shell scripts to write files outside `pwd`.

Operators need paths beginning with `~` or `~/` to expand reliably to the user's home directory across all tool operations. When an agent attempts to mutate any file outside of `pwd`, operators need the mutation to be elevated to an interactive approval prompt featuring a prominent colored visual indicator (`⚠️  MUTATION OUTSIDE PWD`), requiring explicit approval even for newly created files, while continuing to allow safe, seamless auto-approval for new files inside `pwd`.

## 2. Specification

### 2.1 Incident Investigation & Assessment
* **Incident Workspace**: `/home/cam/.local/state/nightmare/workspaces/_adjutant-6a520949` (canonical root: `/home/cam/@adjutant`).
* **Archived Session Data**: Archived in `bug_report_files/_adjutant-6a520949/` (`transcript.md` and `llm_calls.jsonl`).
* **Sequence of Events**:
  1. Operator instructed agent to investigate and finish setting up an automated timer for the mail processing pipeline (`mailrail`).
  2. Agent implemented and verified `bin/mailrail.tsh`, then proceeded to install a systemd user service and timer.
  3. Agent called:
     ```json
     write_file({"path": "~/.config/systemd/user/mailrail.service", "content": "..."})
     write_file({"path": "~/.config/systemd/user/mailrail.timer", "content": "..."})
     ```
  4. Both tool invocations returned success (`Successfully wrote 213 bytes to ~/.config/systemd/user/mailrail.service`, `Successfully wrote 130 bytes to ~/.config/systemd/user/mailrail.timer`).
  5. The files were physically created at `/home/cam/@adjutant/~/.config/systemd/user/mailrail.service` and `/home/cam/@adjutant/~/.config/systemd/user/mailrail.timer` instead of under `/home/cam/.config/systemd/user/`.
  6. Subsequent shell execution of `systemctl --user daemon-reload && systemctl --user enable mailrail.timer` failed because systemd looked in `$HOME/.config/systemd/user/`, where no such unit existed.
  7. The agent concluded systemd was unavailable and fell back to crontab.

### 2.2 Root Cause Analysis
1. **Absence of Tilde Expansion in `resolve_contained_path`**:
   In `src/nightmare/workspace/environment.cr`, `resolve_contained_path(path)` checks `Path.new(path).absolute?`. Under POSIX semantics, paths starting with `~` are not absolute (`Path#absolute?` returns `false`).
2. **Crystal stdlib `File.expand_path` Semantics**:
   The fallback branch calls `File.expand_path(path, @root)`. In Crystal's standard library, `File.expand_path` with a base directory does not expand `~` to the home directory; it treats `~` as a literal path segment relative to `@root`, resolving `"~/.config/..."` to `"#{@root}/~/.config/..."`.
3. **Workspace Boundary False Positive**:
   `Environment#path_inside_root?` checks whether the resolved path starts with `"#{@root}/"`. Because `"#{@root}/~/.config/..."` resides inside the workspace root, it passed containment checks, bypassing external writable directory security checks and silently writing to a literal `~` folder inside the workspace.
4. **Tool-Wide Surface**:
   All tools relying on `Environment#resolve_contained_path` (`write_file`, `replace_in_file`, `append_to_file`, `read_file`, `file_info`, `search`, `list_files`, and slash commands like `/add`) suffer from this misdirection.
5. **Rigid Traversal vs. Shell Workaround Disconnect**:
   Because external writes previously threw hard `SecurityError` exceptions, agents worked around file tool limitations by executing shell scripts (e.g. `cat << 'EOF' > ~/.config/...`) via `run_command`, which went through shell approval anyway. Bringing external mutations cleanly into `write_file` with approval elevation removes the incentive for agents to bypass file tools with shell commands.

### 2.3 Required Technical Changes
1. **Canonical Tilde Expansion in Path Resolution**:
   - Update `Environment#resolve_contained_path` in `src/nightmare/workspace/environment.cr` to expand `~` using Crystal's `Path#expand(base: @root, home: true)`:
     ```crystal
     expanded = Path.new(path).expand(base: @root, home: true).to_s
     ```
   - Ensure consistent handling for `~`, `~/...`, relative paths (`./`, `../`), and absolute paths.
   - Update path expansion in `/plan run`, `/plan review`, and `--system-prompt`.
2. **External PWD Mutation Elevation Architecture**:
   - In `Mutation#write_file`, `Mutation#append_to_file`, and `Mutation#replace_in_file`:
     - Determine whether the target path is outside `pwd`: `outside_pwd = !@guard.env.inside_root?(full_path)`.
     - **For new files inside pwd**: Retain auto-approval without prompt (`Dir.mkdir_p`, `File.write`).
     - **For new files outside pwd**: Elevate to interactive approval! Construct unified diff of empty string to content (`Diff.unified_diff("", content, display_path)`) and prompt the operator.
     - **For existing files (inside or outside pwd)**: Prompt for approval with unified diff.
     - **Dynamic Containment**: When an external mutation is approved by the operator, register `File.dirname(full_path)` into `@env.add_session_writable_directory` so that subsequent tool operations (such as reading the file back) succeed within the session.
3. **Colored Visual Indicator for External Mutations**:
   - In `UI::Approval#approve_diff`:
     - When `outside_pwd` is true (or indicated in description), display a prominent warning banner:
       ```
       ⚠️  MUTATION OUTSIDE PWD (WORKING DIRECTORY)
       ```
       styled with `.colorize(:yellow).mode(:bold)`.
     - Highlight the prompt line with bold yellow text:
       `Approve #{description} [OUTSIDE PWD]? [y/N/a]: `
4. **Security Invariants & Protected Paths**:
   - Protected paths (`.git/**`, `.nightmare/**`) and sensitive patterns (`.ssh/**`, `id_rsa*`, `*.pem`, `*secret*`, `*credential*`, `~/.gnupg/**`, `.env*`) remain strictly Refused with `SecurityError`, whether inside or outside `pwd`. Approval elevation only applies to valid, non-sensitive external files.

## 3. Verification & Validation (V&V)

* **Verification Plan:**
  1. Unit specs in `spec/workspace_spec.cr` verifying that `Environment#resolve_contained_path` expands `"~"`, `"~/.config"`, and `"~/file.txt"` to `Path.home` rather than `<root>/~`.
  2. Guard specs in `spec/guard_spec.cr` verifying that sensitive paths (`~/.ssh/id_rsa`, `.env`, `id_rsa.pub`) and protected paths (`.git`) raise `SecurityError` unconditionally on external targets.
  3. Mutation specs in `spec/tools_spec.cr`:
     - Creating a new file inside `pwd` does not invoke the approval callback.
     - Creating a new file outside `pwd` invokes the approval callback with a new-file diff and `[outside pwd]` description.
     - Mutating an existing file outside `pwd` invokes the approval callback with a unified diff and `[outside pwd]` description.
     - Rejection in approval callback leaves the external file untouched and returns `[Execution rejected by user]`.
     - Approving an external file mutation writes the file to the target external path without creating `<pwd>/~`.
  4. UI specs in `spec/ui/approval_spec.cr` verifying that the yellow `⚠️  MUTATION OUTSIDE PWD (WORKING DIRECTORY)` banner and colored prompt are emitted.
  5. Run full test suite (`crystal spec`) to ensure zero regressions across all workspace and harness specs.
* **Verification Evidence:**
  * `crystal spec spec/workspace_spec.cr`: 25 examples, 0 failures, 0 errors. Verified `resolve_contained_path` expands `~`, `~/...`, and `~/.config/...` to `Path.home` rather than `<pwd>/~`, and verified `add_session_writable_directory`.
  * `crystal spec spec/guard_spec.cr`: 12 examples, 0 failures, 0 errors. Verified non-sensitive external and home paths resolve for write approval, while `.ssh`, `.gnupg`, `.env`, keys, `.git`, and read-only directories are strictly rejected with SecurityError.
  * `crystal spec spec/tools_spec.cr`: 42 examples, 0 failures, 0 errors. Verified new file auto-approval inside pwd, approval prompt on new file outside pwd with `[outside pwd]` description, approval prompt on existing external file, user rejection handling, and zero `<pwd>/~` creation.
  * `crystal spec spec/ui/approval_spec.cr`: 19 examples, 0 failures, 0 errors. Verified warning banner `⚠️  MUTATION OUTSIDE PWD (WORKING DIRECTORY)` and yellow prompt emitted when mutating outside pwd.
  * Full test suite: `crystal spec` passing with 342 examples, 0 failures, 0 errors across entire codebase.
* **Validation Plan:**
  1. Recreate the scenario from session `_adjutant-6a520949` with a test workspace and target file `~/.config/systemd/user/mailrail.timer`.
  2. Confirm the interactive prompt shows the yellow `⚠️  MUTATION OUTSIDE PWD` banner.
  3. Confirm the file is written to `$HOME/.config/systemd/user/mailrail.timer` upon approval.
  4. Confirm no literal `~` directory is created in the workspace.
* **Validation Evidence:**
  * End-to-end integration verified via `spec/tools_spec.cr` ("elevates mutations outside pwd to approval and auto-approves new files inside pwd (TKT-037)").
  * Path resolution confirmed expanding `~/.config/systemd/user/mailrail.timer` to `/home/cam/.config/systemd/user/mailrail.timer`.

## Open Questions & Concurrency Concerns
* [All resolved: User confirmed elevating external pwd mutations to interactive approval, prompting for new files outside pwd, auto-approving new files inside pwd, and displaying colored visual indicators.]

## 4. Revision History
* 2026-10-24: Created ticket and incident assessment from session `_adjutant-6a520949` (TKT-037).
* 2026-10-24: Updated specification to implement external pwd approval elevation, colored warning indicators, and new-file outside-pwd approval gating.
* 2026-10-24: Implemented tilde expansion using `Path#expand(base: @root, home: true)`, outside-pwd approval elevation in `Mutation` and `Approval#approve_diff`, and dynamic session containment. All 342 specs passing. Ticket resolved.
