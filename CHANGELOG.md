# Changelog

All notable changes to Nightmare are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2026-10-10

### Added
- **Generalized Prefix Allowlisting & Candidate Deduction (TKT-035)**: Generalized tokenized prefix matching in `Allowlist#matches?`, supporting arbitrary command prefixes (e.g. `sed -n`, `git status`, `cat`) without being restricted to a hardcoded binary list. Fixed silent degradation where non-subcommand utilities with arguments degraded to exact matches.
- **Prefix Candidate Visibility & Modal Customization (TKT-035)**: Security gateway approval modal displays candidate prefixes (`Prefix: <candidate>`). Added one-key candidate saving with `[p]`, inline custom prefixes with `p <prefix>`, and interactive customization with `[pe]`.
- **Pre-Approved Command Inspection & Management (TKT-035)**: Added `/allowlist` (alias `/approvals`) slash command to view the allow file path (`$XDG_CONFIG_HOME/nightmare/workspaces/<id>/allow`), view active persistent and session-only rules, and prune entries via `/allowlist rm <rule>` and `/allowlist clear`.
- **Shell Tool Alias (TKT-034)**: Configured `"shell"` as an alias for `run_command` in `Tools::Registry` across both primary and subagent toolsets, aligning execution with `TurnPresenter`.
- **Display Working Directory in CLI Prompt (TKT-030)**: Render the active workspace / target working directory path in the interactive REPL prompt.
- **Ambient Human-Agent Pairing Header & Speech-Act Prompt (UI)**: Enhanced CLI prompt with ambient pairing header (`Human ⇄ Assistant`) and explicit speech-act lead (`You › `).

### Fixed
- **Context Overflow Recovery & Shell Output Capping (TKT-031)**: Gracefully recover when model responses omit user query blocks due to overflow, and cap shell output to prevent runaway token exhaustion.
- **Spec Suite Workspace Isolation (TKT-032)**: Prevent test suite runs from polluting real user XDG directories by isolating cache, state, and config directories.

## [0.5.0] - 2026-10-03

### Added
- **Globally Readable External Directories (TKT-027)**: New `readable_dirs` config option (CLI `--readable-dir`, env `NIGHTMARE_READABLE_DIRS`) lets agents read files outside the workspace root. Paths are resolved relative to the workspace and validated against the workspace boundary.
- **Globally Writable External Directories (TKT-028)**: New `writable_dirs` config option (CLI `--writable-dir`, env `NIGHTMARE_WRITABLE_DIRS`) lets agents write to specific external directories. Write-path resolution and guard enforcement ensure only explicitly allowed directories are mutable.
- **Adaptive Directory Listing Depth & Result Budget Limiting (TKT-029)**: `list_files` dynamically collapses deep directory trees to depth 1 with item count indicators when total file count exceeds budget (`list_files_max_results`, default 40), preventing context overflow on local models while preserving full multi-level listings for small directories. Added optional `depth` parameter.

## [0.4.0] - 2026-09-27

### Added
- **Apple Dark Mode ("Cupertino") UI Theme**: Added minimalist, high-contrast dark theme with slate graphite borders, crisp typography, and subtle unicode glyphs (`▤`, `⌕`, `◈`, `›`, `·`), replacing loud neon colors and emojis.
- **Dual-Pane Side-by-Side Split Mode**: Automatic split-pane rendering on wide terminals (≥160 columns) with turn cards on the left and streaming model responses/tool outputs on the right.
- **System Events "Source of Truth" Card**: Tracks file writes, mutations, and executed shell commands directly in the turn card deck.
- **Configurable Subagent Iterations & Exit Interviews (TKT-024)**: Independent `subagent_max_iterations` budget, dynamic iteration overrides, and automated exit interview / deterministic telemetry post-mortem upon hitting loop or turn limits.
- **Windowed Unified Diff Previews (TKT-023)**: Localized diff hunk previews with syntax-highlighted context lines during file edits.

### Fixed
- Fixed split pane right-column line wrapping, double-printing of agent streaming tokens, and height misalignment.
- Fixed display of final agent responses in right pane upon turn completion.

## [0.3.5] - 2026-09-25

### Added
- In-harness loop history salvage — recovers partial turn history after loop detector trips.
- `/recover` slash command for session restoration from last known good state.
- `push_turn` API for manual turn injection during recovery.

## [0.3.4] - 2026-09-25

### Fixed
- Cooperative cancellation now works correctly during approval prompts — previously a cancel signal during an approval modal could leave the session in an inconsistent state.
- Session recovery path hardened for edge cases in the approval flow.

## [0.3.3] - 2026-09-25

### Added
- Subagent context resilience — subagents now gracefully degrade when their parent's context is shed.
- In-turn context shedding for long-running tool loops that exceed budget mid-turn.
- Loop circuit breaker with configurable trip threshold.

## [0.3.2] - 2026-09-25

### Added
- `CyclicReadBreaker` middleware wired into tool registry to detect and prevent cyclic read loops.

## [0.3.1] - 2026-09-25

### Fixed
- Subagent cooperative cancellation — child processes now terminate cleanly on parent cancel.
- Process group termination hardened to prevent orphaned subprocesses.
- `read_file` tool no longer overflows on very large files; output is truncated with a diagnostic message.

## [0.3.0] - 2026-09-25

### Added
- Tavily `web_search` tool integration.
- Generic API keys architecture — tools can declare key requirements resolved from config at startup.

## [0.2.1] - 2026-09-25

### Fixed
- Text duplication bug in `replace_in_file` caused by incorrect end_line derivation; now validates target content before applying.

### Added
- Ephemeral current date injected into system context (TKT-017).
- Markdown response boundary with themed separator (TKT-012).
- Shell approval modal: exact compound commands on `[a]`, split pipelines (TKT-011).
- SKILLs subsystem and `/skill` command with local/global discovery.
- `--no-logs` startup banner now indicates zero-persistence mode (TKT-009).
- Loop circuit breaker, line-anchored mutation, and tool-conditioned shedding (TKT-008).

### Fixed
- Loop detector now tracks consecutive repetitions correctly (TKT-015).
- Terminal escape sequences sanitized in approval modals.
- Streaming cancel handled properly in harness.
- Shell tool self-heals stale CWD inode on spawn.

### Changed
- Removed `tts_kokoro` shard dependency.
- Restructured USERS_GUIDE into multi-chapter format.
- Quarantined legacy e2e specs; established integration workflow framework (TKT-005).

## [0.2.0] - 2026-09-17

### Changed
- **BREAKING:** Replaced `ask_model` tool with `spawn_subagent` — completely different invocation schema.
- **BREAKING:** Renamed `directives` to `system prompt` across the entire codebase (TKT-001).
- Isolated `StepRunner` from harness loop for cleaner separation of concerns.
- Extracted `ToolMiddleware` pipeline from inline tool execution.
- Decoupled `$EDITOR` engine into `UI::Editor` module.

### Added
- First-class agent response card with live subagent HUD telemetry.
- Per-file token ceilings and bulk log ingestion guards to prevent context explosion.
- Programmatic plan orchestration with deterministic gates (TKT-004).
- `--no-logs` zero-footprint ghost mode and system config.
- Colorized unified diff in file mutation approval modals (TKT-003).
- Triple-quote multiline entry in REPL.
- Mantle `LoggingClient` integration for tool call observability.

### Fixed
- Visual contradiction on rejected tools resolved; stale input drained before approval.
- Dashboard height budgeted to terminal size; prompt cards wrap correctly.

### Security
- Approval display sanitized against injection.
- Shell process execution hardened.

## [0.1.x] - Pre-0.2.0

Initial development. Core systems built during this period:
- CLI harness with REPL loop, signal cancellation, and slash commands
- StepRunner and ToolLoop with LoopDetector and Retrier
- Tool suite: read_file, write_file, replace_in_file, search_files, list_directory, execute_command
- Shell command allowlist and process group supervisor
- Context engine with shedding, calibration, and token guards
- config.json for model/api_url resolution
