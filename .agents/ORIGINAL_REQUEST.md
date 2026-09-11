# Original User Request

## Initial Request — 2026-09-11T17:28:38Z

Implement NIGHTMARE, a standalone, human-in-the-loop developer REPL in Crystal for general-purpose text and task execution based on the specifications in docs/DESIGN.md and docs/ARCHITECTURE.md.

Working directory: /home/cam/repos/adjutant/nightmare
Integrity mode: development

References:
- Architecture Specification: docs/ARCHITECTURE.md
- Concept of Operations: docs/DESIGN.md
- Local frameworks: ../mantle and ../salamander

## Requirements

### R1. Workspace Anchoring and Central XDG Mapping
The application must anchor to `Dir.current` using its realpath and strictly prevent operations outside this root. All persistent configuration and logs must reside in central XDG user directories partitioned by a deterministic workspace identifier (`<slug>-<hash>`). No configuration or log files may be created inside the target project repository. On launch, print a clear notification banner displaying the workspace root, config path, and state path. Resolve system directives in strict precedence (CLI flag > optional repo override > central workspace config > central global config > default general persona).

### R2. Ephemeral Context Engine, Turn-Unit Pruning, and In-Turn Shedding
Maintain conversational context strictly in-memory using an atomic turn-unit sliding window. Pruning must never orphan tool pairs and must never evict the current turn's user prompt. When approaching token limits during multi-step tool iterations, truncate older consumed tool results within the active turn while preserving the last 2 verbatim. Provide self-calibrated token estimation updated from provider token usage feedback. Maintain a parallel un-pruned transcript in RAM for export via `/save`.

### R3. Sandboxed Tool Suite and Anti-Fatigue Approval Boundary
Provide read-only workspace observation tools (`list_files`, `search`, `read_file`, `file_info`) that execute autonomously without prompts, automatically excluding `.git/` and sensitive files. Provide mutation tools (`replace_in_file`, `append_to_file`, `write_file`) that auto-approve new file creation but require interactive approval with a unified diff before modifying existing files. Mutations to `.git/` must be forbidden. Provide a model delegation tool (`ask_model`) for stateless remote calls. Provide a shell execution tool (`run_command`) with process group isolation, a hard timeout cap, closed stdin, and an interactive approval modal (`[y]`, `[N]`, `[e]`, `[a]` exact, `[p]` prefix), with a strict ban on auto-approving any command containing shell metacharacters.

### R4. Mantle Step Harness and Typed Result Sum Types
Orchestrate execution via Mantle's step runner, encapsulating all LLM interactions within a strict `Result(T) = Success(T) | Failure` sum-type boundary. Apply automatic exponential backoff with jitter on rate limits. Trigger a single format-correction retry turn upon receiving malformed payloads before returning a typed error.

### R5. Interactive Salamander REPL and Slash Command Router
Provide a terminal REPL powered by Salamander with live token streaming, spinner management, `<think>` block isolation, and ANSI markdown formatting. `Ctrl+C` during generation must immediately cancel execution and roll back the active turn without terminating the session. Support slash commands: `/clear`, `/cls`, `/drop`, `/save`, `/prompt [edit]`, `/review`, `/thinking`, `/model`, `/paste`, `/exit`.

### R6. Framework Integration Constraints
Link dependencies to local paths `../mantle` and `../salamander`. Minor backward-compatible enhancements to Mantle and Salamander are permitted if strictly necessary (such as allowing optional memory stores), but major structural refactorings of the frameworks are prohibited.

## Acceptance Criteria

### Build & Verification
- [ ] `shards build` succeeds cleanly with zero compiler warnings or errors.
- [ ] `crystal spec` passes all unit and integration tests across all modules.

### Path & Security Verification
- [ ] Test cases verify that path traversal attempts (`../`) and out-of-tree symlinks are rejected with security errors.
- [ ] Test cases verify that mutation tools reject any write targeting `.git/`.
- [ ] Test cases verify that shell commands containing metacharacters (`;`, `&&`, `||`, `|`, `` ` ``, `$()`, `>`, `<`) always prompt for approval and cannot be auto-approved.

### Context & Pruning Verification
- [ ] Test cases verify that pruning evicts entire turn units and never leaves orphaned `tool_calls` messages.
- [ ] Test cases verify that in-turn tool shedding compresses consumed tool results while keeping the last 2 tool outputs verbatim.
- [ ] Test cases verify that `/save` exports the pristine un-truncated transcript.

### UI & Signal Verification
- [ ] Test cases verify that `Ctrl+C` triggers turn rollback rather than process termination.
- [ ] Test cases verify that `/prompt edit` updates only the in-memory prompt without modifying source files on disk.
