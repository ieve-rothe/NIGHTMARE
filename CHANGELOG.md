# Changelog

All notable changes to Nightmare are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
