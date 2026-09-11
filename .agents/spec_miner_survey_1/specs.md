# NIGHTMARE: Exhaustive Technical Specifications & Architecture Blueprint

This document represents the authoritative and exhaustive specification inventory for **NIGHTMARE**, a standalone, human-in-the-loop developer REPL in Crystal for general-purpose text and task execution. It synthesizes and formalizes all requirements, architectural constraints, data contracts, algorithms, component designs, and acceptance criteria from `ORIGINAL_REQUEST.md`, `docs/DESIGN.md`, and `docs/ARCHITECTURE.md`.

---

## Table of Contents
1. [Workspace Anchoring & Central XDG Mapping](#1-workspace-anchoring--central-xdg-mapping)
2. [Ephemeral Context Engine, Turn Pruning & In-Turn Shedding](#2-ephemeral-context-engine-turn-pruning--in-turn-shedding)
3. [Sandboxed Tool Suite & Anti-Fatigue Approval Boundary](#3-sandboxed-tool-suite--anti-fatigue-approval-boundary)
4. [Mantle Step Harness & Typed Result Sum Types](#4-mantle-step-harness--typed-result-sum-types)
5. [Interactive Salamander REPL & Slash Command Router](#5-interactive-salamander-repl--slash-command-router)
6. [Acceptance Criteria & Verification Suite](#6-acceptance-criteria--verification-suite)
7. [Stochastic vs. Deterministic Boundary Matrix](#7-stochastic-vs-deterministic-boundary-matrix)
8. [Features Discovered](#features-discovered)
9. [Edge Cases](#edge-cases)

---

## 1. Workspace Anchoring & Central XDG Mapping

### 1.1 Canonical Root Resolution
- **Anchor Invariant**: Upon startup, NIGHTMARE anchors immutably to `Dir.current` using its realpath:
  ```crystal
  @root = File.realpath(Dir.current)
  ```
- **Strict Confinement**: All tool operations, file reads, directory scans, searches, file modifications, and process executions are strictly confined within `@root`.
- **Path Traversal & Symlink Protection**:
  - Traversal patterns (`../`, `..`) resolving above or outside `@root` are rejected with security errors.
  - Symlinks within `@root` that resolve to targets outside `@root` are dereferenced via `File.realpath` and strictly rejected.
  - Invariant checked on every path:
    ```crystal
    resolved = File.exists?(path) ? File.realpath(path) : File.join(File.realpath(File.dirname(path)), File.basename(path))
    raise SecurityError.new("Path traversal violation: #{path}") unless resolved.starts_with?(@root)
    ```

### 1.2 Deterministic Workspace Identification (Slug & Hash)
To cleanly partition persistent configuration and logs across projects without littering the repository:
1. **Slug Generation**:
   - Extracts the directory basename: `File.basename(@root)`
   - Sanitizes characters: `slug = File.basename(@root).gsub(/[^a-zA-Z0-9_-]/, "_")`
2. **Deterministic Hash**:
   - Computes SHA-256 digest of the canonical path `@root`.
   - Truncates to the first 8 hex characters: `hash = Digest::SHA256.hexdigest(@root)[0..7]`
3. **Workspace Identifier**:
   - Format: `workspace_id = "#{slug}-#{hash}"` (e.g. `adjutant-8a4f21bc`).

### 1.3 XDG Base Directory Resolution & Hierarchy
NIGHTMARE strictly complies with the FreeDesktop XDG Base Directory Specification:
- **`$XDG_CONFIG_HOME`** (Default: `~/.config`):
  - Global config: `$XDG_CONFIG_HOME/nightmare/config.json`
  - Global default prompt: `$XDG_CONFIG_HOME/nightmare/prompt.md`
  - Workspace config dir: `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/`
    - `workspace.json`: Mapping manifest linking `workspace_id` to `canonical_path`, created timestamp, and last accessed timestamp.
    - `prompt.md`: Per-workspace system directive override.
    - `allow`: Per-workspace shell command pattern allowlist (regex rules).
- **`$XDG_STATE_HOME`** (Default: `~/.local/state`):
  - Workspace state dir: `$XDG_STATE_HOME/nightmare/workspaces/<workspace_id>/`
    - `llm_calls.jsonl`: Formatted JSONL log of all raw prompts, completions, token usage, and latency.
      - Log rotation: Automatically rotates when file size reaches 20 MB; retains up to 3 historical rotated files.
      - Can be disabled via `--no-log`.
    - `session_history.json`: Metadata summary of past REPL sessions.
- **`$XDG_CACHE_HOME`** (Default: `~/.cache`):
  - Workspace cache dir: `$XDG_CACHE_HOME/nightmare/workspaces/<workspace_id>/`
    - Transient data: token calibration divisors, cached diffs.
- **Zero Repository Litter Invariant**: No configuration, cache, state, or log files may be written into the target repository. Central XDG paths live outside `@root` and are also protected from tool modifications by the root containment invariant.

### 1.4 Configuration & Directive Resolution Precedence
System directives (system prompts) govern agent behavior and must be resolved in strict hierarchical precedence:
1. **CLI Flag (Highest Priority)**: `-s <path>` or `--system <path>` passed explicitly on launch.
2. **Repository Committed File (Optional)**: `.nightmare/prompt.md` within `@root` (read if present, never created automatically by NIGHTMARE).
3. **Workspace Central Config**: `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/prompt.md`.
4. **Global Central Config**: `$XDG_CONFIG_HOME/nightmare/prompt.md`.
5. **Default General Persona (Fallback)**:
   ```markdown
   You are an execution agent operating in the current working directory.
   - Inspect files and execute tools to determine facts before taking action.
   - Prefer replace_in_file for edits; read before you write; never overwrite a file you have not inspected this session.
   - Be concise, direct, and factual.
   - Do not assume context; rely strictly on provided files, tool outputs, and user instructions.
   ```

### 1.5 In-Memory Directive Mutation
- Invoked via `/prompt edit`.
- Resolves editor via `$EDITOR`, then `$VISUAL`, then fallbacks (`nano`, `vim`).
- Launches editor on a temporary file containing the current active directive.
- Upon editor exit, loads the content and updates **strictly the in-memory directive** for the running session.
- Underlying files on disk (CLI target, `.nightmare/prompt.md`, or XDG prompt) remain **untouched**.
- `/prompt` (without edit) displays the active in-memory directive.

### 1.6 Startup Banner
Upon REPL launch, NIGHTMARE emits a structured box banner to STDOUT before displaying the input prompt:
```text
┌── NIGHTMARE ─────────────────────────────────────────────────────────────┐
│ Workspace : /home/cam/repos/adjutant                                     │
│ Config    : ~/.config/nightmare/workspaces/adjutant-8a4f21bc/            │
│ State/Logs: ~/.local/state/nightmare/workspaces/adjutant-8a4f21bc/       │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Ephemeral Context Engine, Turn Pruning & In-Turn Shedding

### 2.1 Atomic Turn Unit Structure
Context in NIGHTMARE is modeled as a FIFO deque of atomic `Turn` records. A turn unit encapsulates the entire interaction cycle:
$$\text{Turn} = \langle \text{User Message},\, [\text{Assistant Tool Call} \leftrightarrow \text{Tool Result}]^{*},\, \text{Final Assistant Message} \rangle$$

- **Data Models**:
  ```crystal
  class Turn
    property user_message : Mantle::Message
    property tool_exchanges : Array(ToolExchange)
    property assistant_message : Mantle::Message?

    def initialize(@user_message : Mantle::Message)
      @tool_exchanges = [] of ToolExchange
      @assistant_message = nil
    end

    def complete? : Bool
      !@assistant_message.nil?
    end
  end

  class ToolExchange
    property call : Mantle::Clients::ToolCall
    property result_message : Mantle::Message
    property raw_size_bytes : Int32
    property truncated : Bool = false

    def initialize(@call : Mantle::Clients::ToolCall, @result_message : Mantle::Message, @raw_size_bytes : Int32)
    end

    def truncate!(keep_chars : Int32 = 200)
      return if @truncated
      content = @result_message.content || ""
      prefix = content[0, keep_chars]
      @result_message.content = "#{prefix}\n[... output truncated: was #{@raw_size_bytes} bytes]"
      @truncated = true
    end
  end
  ```
- **Atomicity Invariant**: Pruning operates exclusively on complete turn units. An assistant message with `tool_calls` and its matching `role: "tool"` responses are never partitioned, eliminating orphaned tool call errors.

### 2.2 Prompt Assembly Pipeline
Every LLM call reassembles context dynamically:
1. **System Directive**: Active system prompt (cached prefix; never pruned).
2. **Pinned Files Block**: User-pinned working set files, re-read live from disk (`=== PINNED FILE: #{path} ===\n#{content}`). Never pruned.
3. **Turn-Unit Sliding Window**: Completed historical turns (with truncated tool stubs where pruned).
4. **Active Turn**: Current in-flight turn (protected user message + active tool exchanges).

### 2.3 Sliding Window Pruning Rules
1. **Protected Boundaries**:
   - The system directive and pinned files are never evicted by pruning.
   - The current active turn's user message is **strictly protected** and never evicted.
2. **Turn Soft Cap**:
   - Default soft limit: 10 completed turns.
   - When turn count exceeds the cap, the oldest completed turn is evicted.
3. **Token Hardmax Threshold (`token_hardmax`)**:
   - When estimated total tokens exceed `token_hardmax`:
     - **Phase 1 (Historical Result Shedding)**: Iterate through historical turns in chronological order. Truncate tool results exceeding 200 characters to their first 200 characters plus stub: `[... output truncated: was N bytes]`.
     - **Phase 2 (Turn Eviction)**: If tokens still exceed `token_hardmax` after Phase 1, evict the entire oldest completed `Turn` unit from the window. Repeat until within budget.

### 2.4 In-Turn Tool Shedding Algorithm (Active Turn Defense)
During complex multi-step tool iterations within a single turn, cumulative tool outputs can threaten context limits before the turn completes.
- **Trigger**: When estimated active turn tokens reach `token_hardmax * 0.85`.
- **Algorithm**:
  1. Inspect all `ToolExchange` records in the current active turn.
  2. Identify consumed tool results: tool results that the model has already processed and followed with subsequent tool calls.
  3. Keep the **last 2 tool outputs verbatim** (active working set).
  4. For all earlier consumed tool outputs in the active turn, invoke `truncate!(keep_chars: 200)`:
     - Preserve first 200 characters (retaining headers, file structure, or error types).
     - Append `\n[... output truncated: was #{raw_size_bytes} bytes]`.
  5. The user's input prompt remains completely untouched.

### 2.5 Self-Calibrating Token Accounting
Instead of a static `bytes // 4` rule (which undercounts programming languages and ASTs by ~25%):
- **Initial State**: Boot divisor set to `3.5` chars/token.
- **Dynamic Feedback Loop**: On every turn where the LLM provider returns token usage (`usage.prompt_tokens` or `prompt_eval_count`):
  $$\text{Divisor}_{\text{new}} = 0.8 \times \text{Divisor}_{\text{prev}} + 0.2 \times \left( \frac{\text{Raw Assembled Characters}}{\text{usage.prompt_tokens}} \right)$$
- **UI Meter Representation**: Displayed with an explicit tilde (`~`) to denote calibrated estimation:
  ```text
  Working Memory: ~2,450 / 12,000 tokens (Turns: 3/10) | Pinned: 1 file (~850t)
  ```

### 2.6 Pinned Files Working Set (`PinnedFiles`)
- **Execution**: User manages via `/add [path] [--lines S-E]` and `/drop [path]`.
- **Live Re-read**: Pinned files are never cached statically in memory. They are re-read from disk on every prompt assembly. If the file is modified on disk or by a tool, the next turn immediately reflects the fresh content.
- **Line Slicing**: Supports optional 1-indexed range: `--lines 10-50`.
- **Redundancy Short-Circuit**: If the agent calls `read_file` on a file currently pinned in context, `read_file` short-circuits with zero token duplication:
  `[Notice: Path 'src/app.cr' is already pinned in the active context block. Refer to pinned context above.]`
- **Budget Protection Limit**: `/add` fails with a descriptive error if adding the file causes total pinned tokens to exceed 60% of `token_hardmax`.
- **Cache Awareness**: Pinned files precede conversational turns. Modifying pinned files invalidates prefix prompt caches, a conscious design tradeoff for guaranteed freshness.

### 2.7 Parallel Pristine RAM Transcript (`/save`)
- Conversational sliding store is ephemeral; closing the REPL evaporates the context window.
- In parallel with the sliding window, NIGHTMARE maintains an un-truncated, un-pruned `Transcript` buffer in RAM.
- When the user runs `/save [path]` (or `/save` defaulting to `transcript_<timestamp>.md`):
  - Exports a clean, readable GitHub Flavored Markdown document containing all full user inputs, complete assistant reasoning, and full un-truncated tool call inputs and outputs.
  - Does not write into repo unless explicitly directed to a path inside `@root`.

---

## 3. Sandboxed Tool Suite & Anti-Fatigue Approval Boundary

### 3.1 Path Resolution & Safety Invariants
- Every tool accepting a path argument computes:
  - Existing target: `real = File.realpath(path)`
  - New target: `real = File.join(File.realpath(File.dirname(path)), File.basename(path))`
- **Invariant**: `real.starts_with?(@root)` must evaluate to true. Out-of-tree targets, path traversal attempts (`../`), and external symlinks raise `SecurityError`.
- **Git Protection**: All mutation tools (`write_file`, `replace_in_file`, `append_to_file`) strictly reject any target inside `.git/` or subpaths thereof.
- **Sensitive Files Exclusion**: Read tools (`list_files`, `search`, `read_file`) automatically filter out and reject files matching sensitive glob patterns:
  - Patterns: `.env*`, `*.pem`, `id_rsa*`, `*secret*`, `*credential*`, `.git/*`.

### 3.2 Read-Only Observation Tools (Zero Approval / Autonomous)
Autonomous execution without interactive modals:
1. **`list_files(directory : String = ".", pattern : String? = nil)`**:
   - Lists directory entries within `@root`.
   - Automatically skips `.git/` and sensitive patterns.
2. **`search(pattern : String, glob : String? = nil, max_matches : Int32 = 50)`**:
   - Performs regex or keyword search across files in `@root`.
   - Filters out `.git/` and sensitive files. Returns matches with path and line numbers.
3. **`read_file(path : String, offset : Int32 = 1, limit : Int32 = 200)`**:
   - Reads 1-indexed line slice or entire file.
   - Short-circuits with notice if path is already pinned.
   - Enforces sensitive file filter and path containment.
4. **`file_info(path : String)`**:
   - Returns file metadata: size in bytes, line count, permissions, and mtime.

### 3.3 Mutation Tools (Unified Diff & Overwrite Modal)
1. **`write_file(path : String, content : String)`**:
   - **New File**: If target does not exist, file is created automatically without prompting (auto-approved).
   - **Existing File**: Overwrite requires human approval. NIGHTMARE computes a unified git-style diff in RAM, renders the diff modal to the terminal, and prompts:
     ```text
     ┌── [NIGHTMARE File Overwrite: src/config.cr] ───────────────────────────┐
     │ --- src/config.cr                                                      │
     │ +++ src/config.cr (proposed)                                           │
     │ @@ -12,3 +12,3 @@                                                      │
     │ -  timeout: 30                                                         │
     │ +  timeout: 60                                                         │
     └────────────────────────────────────────────────────────────────────────┘
     Approve overwrite? [y]es / [N]o / [a]lways allow for session: 
     ```
2. **`replace_in_file(path : String, target : String, replacement : String)`**:
   - Exact substring match search-and-replace.
   - Fails with explicit error if `target` matches 0 occurrences or >1 occurrences.
   - Computes proposed diff and presents overwrite modal.
3. **`append_to_file(path : String, content : String)`**:
   - Appends content to existing file. Displays appended lines and prompts with modal.
- **Rejection Semantics**: If user enters `[N]` (or rejects), the tool returns `[Execution rejected by user]`. The agent receives this as tool output and can adjust its plan.

### 3.4 Model Delegation Tool (`ask_model`)
- **Signature**:
  ```json
  {
    "name": "ask_model",
    "description": "Delegate an isolated task to an online model without carrying conversational history.",
    "parameters": {
      "prompt": "Summarize the AST changes in...",
      "model": "optional-model-alias",
      "context_files": ["src/types.cr"]
    }
  }
  ```
- **Semantics**:
  - Performs an isolated, stateless remote inference call.
  - Does NOT carry the main REPL conversation history.
  - Re-reads specified `context_files` from disk and prepends them to the delegation prompt.
  - Returns the output string as the tool result. Any API error is captured and returned as a `Result(String)` tool message.

### 3.5 Shell Execution Tool (`run_command`) & Anti-Fatigue Modal
- **Signature**:
  ```crystal
  run_command(command : String, timeout : Int32 = 60)
  ```
- **Subprocess Execution Guardrails**:
  1. **Working Directory**: Always executed with `chdir: @root`.
  2. **Process Group Isolation**: Spawns process in a dedicated process group (`pgid`).
  3. **Timeout Cap**: Parameterized timeout capped at a hard maximum of 600 seconds (10 minutes). On timeout or user interrupt (`Ctrl+C`), executes `Process.kill(Signal::KILL, -pgid)` to terminate all spawned child processes.
  4. **Closed Stdin**: `stdin` is bound to `/dev/null` (`Process::Redirect::Close`) to prevent subprocesses hanging indefinitely waiting for terminal input.
  5. **Environment Sanitization**: Injects `GIT_TERMINAL_PROMPT=0` and `CI=1`.
  6. **Output Truncation**: Stdout and stderr are captured and capped at 50 KB / 300 lines (head + tail with an omission banner: `[... output truncated: N lines omitted ...]`).
- **Interactive Approval Modal**:
  ```text
  ┌── [NIGHTMARE Shell Request] ───────────────────────────────────────────┐
  │ Command: git diff HEAD~1                                               │
  │ Timeout: 60s (max 600s) | Cwd: /home/cam/repos/adjutant                │
  └────────────────────────────────────────────────────────────────────────┘
  Approve? [y]es / [N]o / [e]dit / [a]lways exact / [p]refix allow: 
  ```
  - `[y]`: Execute once.
  - `[N]`: Reject execution. Returns `[Execution rejected by user]` tool message.
  - `[e]`: Edit command inline in REPL. The edited command executes, and tool result returned to the model explicitly contains:
    `[Executed command after user edit: <actual_command>]`
  - `[a]`: Add exact command string to the in-memory session allowlist (metacharacter-free commands only).
  - `[p]`: Derive binary + subcommand prefix (e.g. `^git diff\b`) and add to in-memory session allowlist.
- **Strict Shell Metacharacter Auto-Approval Ban**:
  - **Rule**: Any command containing shell metacharacters:
    ```
    ;   &   |   `   $(   >   <   \n
    ```
    is **STRICTLY BARRED from auto-approval**, regardless of whether it matches an entry in the session allowlist or regex pattern file.
  - Every command with metacharacters **ALWAYS** forces the interactive approval modal.
- **Pattern Allowlist Persistence**:
  - Stored in `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/allow`.
  - Format: one regex per line, anchored at both ends (e.g. `^git status$`, `^crystal spec( [a-zA-Z0-9_\/.-]+)?$`).

---

## 4. Mantle Step Harness & Typed Result Sum Types

### 4.1 Integration with `Mantle::Step`
NIGHTMARE wraps Mantle's execution loop (`Mantle::Step`):
- **Graph Isolation**: `messages` input is treated as immutable. Tool execution loops append only to an isolated local working buffer (`working_messages = messages.dup`).
- **Status Lifecycle Hooks**: Hooks into `on_status`: `:evaluating` $\rightarrow$ `:thinking` $\rightarrow$ `:tool_loop` $\rightarrow$ `:idle`.

### 4.2 Strongly-Typed Result Sum Types
All boundary operations return a strict sum type:
```crystal
module Nightmare::Harness
  enum StepErrorKind
    MaxIterationsReached
    RateLimited
    ClientFailure
    MalformedPayload
    ExecutionTimeout
  end

  record StepError, kind : StepErrorKind, message : String

  alias Result(T) = Success(T) | Failure

  class Success(T)
    getter value : T
    getter thinking : String?
    getter iterations : Int32

    def initialize(@value : T, @thinking : String? = nil, @iterations : Int32 = 0)
    end
  end

  class Failure
    getter error : StepError
    getter thinking : String?
    getter iterations : Int32

    def initialize(@error : StepError, @thinking : String? = nil, @iterations : Int32 = 0)
    end
  end
end
```

### 4.3 Rate Limiting & Auto-Retry with Backoff / Jitter
- When underlying client returns HTTP 429 or an error message containing `"rate limit"`, the harness catches `StepErrorKind::RateLimited`.
- Automatically executes exponential backoff with full jitter:
  $$\text{Delay} = \text{random}(0,\, \text{base\_delay} \times 2^{\text{attempt}})$$
- Retries up to 3 times before surfacing a `Failure(StepError(RateLimited))`.

### 4.4 Single Format-Correction Retry Turn
- When model output produces malformed payloads (unparseable JSON for tool calls or structured schemas):
  - Harness triggers **exactly one automatic retry turn**.
  - Injects an explicit system/tool correction reminder:
    `"Previous response could not be parsed: <error>. Output strictly valid JSON."`
  - If the retry payload also fails to parse, returns `Failure(StepError(MalformedPayload))`.

### 4.5 Iteration Limit Handling
- Default max iterations per turn: 15.
- If iteration limit is reached:
  - Halts execution cleanly without crashing or discarding turn state.
  - Retains all committed tool results up to that point.
  - Returns message to user:
    `[Notice] Execution reached iteration limit (15). Workspace modifications preserved. Enter next instruction or /replay to continue.`

---

## 5. Interactive Salamander REPL & Slash Command Router

### 5.1 Terminal Streaming & Spinner Teardown
- Live token streaming via `Salamander::UI#stream_text`.
- Spinner management via `Salamander::UI#start_spinner` and `#stop_spinner`:
  - Starts animated spinner on `:evaluating` / `:thinking`.
  - When state transitions to `:responding` (first visible token arrives), spinner is cleanly torn down (`clear_line`), preventing terminal artifact collision.

### 5.2 `<think>` Block Isolation
- Real-time token filtering using `Salamander::ChatSession`:
  - Detects `<think>` / `<|think|>` and `</think>` / `</|think|>`.
  - Content within think tags is diverted into an in-memory `thinking_log` builder and hidden from stdout.
  - Accessible on demand via `/thinking`.

### 5.3 ANSI Markdown Formatting
All assistant output is styled in real-time or upon completion using `Salamander::UI::MarkdownFormatter`:
- **Code Blocks (```)**: Background styled with dark gray (`\e[48;5;236m`), protected during span parsing via placeholder extraction (`\x00CODE_BLOCK_N\x00`).
- **Inline Code (`...`)**: Styled with dark gray background (`\e[48;5;236m`).
- **Headers (`#` to `######`)**: Bold cyan (`\e[1;36m`).
- **Blockquotes (`>`)**: Italic dark gray (`\e[3;90m`).
- **Bold (`**...**`)**: High-intensity bold white (`\e[1;97m`).
- **Italic (`*...*`)**: Italic (`\e[3m`).
- **Links (`[text](url)`)**: Blue text with underlined URL (`\e[34mtext\e[0m (\e[4;34murl\e[0m)`).
- **Style Stack Restoration**: Inner inline spans restore parent style (e.g. bold inside cyan header) rather than resetting to `\e[0m`.

### 5.4 Signal Handling & Turn Rollback (`Ctrl+C`)
- **Signal Trap**: `Signal::INT` (`Ctrl+C`) is intercepted during active execution:
  1. If a subprocess is running in `run_command`: sends `SIGKILL` to `-pgid`.
  2. If an LLM HTTP stream is active: aborts the client connection immediately.
  3. **Turn Rollback**: The current in-flight `Turn` (user prompt, partial tool calls, and partial responses) is purged from the `SlidingStore`.
  4. Context consistency is guaranteed: no orphaned tool calls or responses remain.
  5. The user's input prompt text is restored to the REPL input line for re-editing.
  6. **The REPL session does NOT exit.**
- **Session Termination**: Exiting the REPL requires `/exit`, EOF (`Ctrl+D`), or pressing `Ctrl+C` twice in rapid succession while at an empty prompt.

### 5.5 Complete Slash Command Router & Semantics

| Slash Command | Argument Syntax | Semantics & Behavior |
| :--- | :--- | :--- |
| `/clear` | None | Wipes the ephemeral conversational sliding window. Pinned files and active system directive remain intact. |
| `/cls` | None | Clears the physical terminal screen (`\e[2J\e[H`) without touching context memory. |
| `/add` | `<path> [--lines S-E]` | Pins a file into working context. Re-read live on each turn assembly. Rejects if total pinned files exceed 60% of `token_hardmax`. |
| `/drop` | `[path]` | Unpins the specified file from context. If no path is given, unpins all currently pinned files. |
| `/save` | `[path]` | Exports the pristine, un-truncated, un-pruned RAM transcript to a GitHub Flavored Markdown file. Defaults to timestamped name. |
| `/prompt` | `[edit]` | Without args: prints active system directive. With `edit`: opens `$EDITOR` to modify directive in-memory only (disk untouched). |
| `/review` | None | Displays the exact, complete prompt assembly (directive + pinned files + history + turn) currently queued for LLM dispatch. |
| `/thinking` | None | Displays the accumulated `<think>` reasoning block from the most recent LLM turn. |
| `/model` | `[name]` | Without args: displays active model name and parameters. With arg: switches active model configuration for current session. |
| `/paste` | None (or `"""`) | Toggles multi-line input mode; lines accumulate until terminated by `/end` or closing `"""`. |
| `/help` | None | Displays available slash commands, descriptions, and interactive approval keybindings. |
| `/exit` | None | Cleanly terminates the REPL session; ephemeral in-memory context evaporates. |

---

## 6. Acceptance Criteria & Verification Suite

### 6.1 Build & Static Verification
- **AC-B1**: `shards build` succeeds cleanly with zero compiler warnings and zero errors.
- **AC-B2**: `crystal spec` passes all unit and integration tests across all modules.

### 6.2 Path Traversal & Security Verification
- **AC-S1 (Path Traversal)**: Any tool invocation attempting path traversal (`../`) that escapes `@root` raises a security error and fails execution.
- **AC-S2 (Symlink Escape)**: Any file access targeting a symlink pointing outside `@root` is detected via `File.realpath` and rejected.
- **AC-S3 (Git Protection)**: Mutation tools (`write_file`, `replace_in_file`, `append_to_file`) reject any write path containing `.git/`.
- **AC-S4 (Sensitive Files Exclusion)**: Read tools (`list_files`, `search`, `read_file`) automatically exclude sensitive patterns (`.env*`, `*.pem`, `id_rsa*`, `*secret*`, `*credential*`, `.git/*`).
- **AC-S5 (Metacharacter Ban)**: Shell commands containing `;`, `&&`, `||`, `|`, `` ` ``, `$()`, `>`, `<`, or `\n` can NEVER be auto-approved and always require explicit modal interaction.

### 6.3 Context & Pruning Verification
- **AC-C1 (Atomic Turn Units)**: Pruning never splits a turn; tool calls and their matching tool results are evicted together, never leaving orphaned `tool_calls`.
- **AC-C2 (Protected User Prompt)**: Active turn user prompt is never evicted by sliding window pruning.
- **AC-C3 (In-Turn Shedding)**: When active turn exceeds 85% of `token_hardmax`, consumed tool results older than the last 2 are truncated to 200 chars + stub. The last 2 tool results remain verbatim.
- **AC-C4 (Calibrated Token Accounting)**: Token estimator updates divisor via exponential moving average when actual token usage is reported by the provider.
- **AC-C5 (Pristine Transcript)**: `/save` exports full, un-truncated tool call arguments and results, regardless of in-turn shedding or historical pruning.
- **AC-C6 (Pinned File Live Re-read)**: Modifying a pinned file on disk is immediately reflected in the next turn prompt assembly without re-running `/add`.
- **AC-C7 (Pinned Redundancy Short-Circuit)**: Calling `read_file` on a pinned file returns a zero-token notice without re-reading the file into history.

### 6.4 UI & Signal Verification
- **AC-U1 (Ctrl+C Rollback)**: Pressing `Ctrl+C` during tool execution or LLM generation terminates subprocess/stream, drops the active turn from context, restores prompt text, and preserves the REPL session.
- **AC-U2 (Prompt In-Memory Edit)**: `/prompt edit` updates the active system directive in RAM only; source files on disk remain untouched.
- **AC-U3 (Diff Display)**: Overwriting an existing file displays a unified diff before prompting for approval.
- **AC-U4 (Shell Approval Options)**: Shell modal supports `[y]`, `[N]`, `[e]` (with command editing), `[a]` (exact match session allowlist), and `[p]` (prefix allowlist).

---

## 7. Stochastic vs. Deterministic Boundary Matrix

| Boundary Operation | Nature | Deterministic Guard / Invariant | Failure Mode Encapsulation |
| :--- | :--- | :--- | :--- |
| **Primary LLM Streaming** | Stochastic | Real-time `<think>` token isolation via `Salamander::ChatSession`; clean spinner teardown. | Mapped to `StepError(ClientFailure)` or `StepError(RateLimited)`. Rate limits trigger exponential backoff. |
| **Structured Output / Tool JSON** | Stochastic | Strictly parsed into Crystal data structures; single retry turn with explicit schema correction on failure. | Mapped to `StepError(MalformedPayload)`. |
| **Model Delegation (`ask_model`)** | Stochastic | Stateless, isolated execution; does not pollute REPL conversation history. | Returned as `Result(String)` tool result string containing failure reason. |
| **Path Resolution** | Deterministic | Canonical path resolution via `File.realpath` checked against `@root`; `.git/` forbidden. | Traversal attempts raise `SecurityError` returned as tool failure message. |
| **File Overwrite** | Deterministic | Checks existence; renders RAM-generated unified diff; requires explicit modal approval. | Rejection returns `[Execution rejected by user]` tool message. |
| **Shell Command Execution** | Deterministic | Metacharacter ban enforces modal; executed with `chdir: @root`, `stdin: /dev/null`, `CI=1`, process group kill on timeout. | Timeout returns `[Execution timed out after N seconds]`; non-zero exit code returned with stderr. |
| **Token Estimation** | Deterministic | Exponential moving average divisor update from actual provider usage tokens; tilde (`~`) indicator. | Prevents premature or delayed sliding window eviction. |
| **Context Pruning** | Deterministic | Atomic `Turn` eviction; in-turn shedding keeps last 2 outputs verbatim, truncates prior consumed outputs to 200 chars. | Completely eliminates orphaned `tool_calls` API errors. |
| **Signal Handling** | Deterministic | `Signal::INT` terminates subprocess tree via `-pgid`, rolls back active turn, restores input line. | Preserves session state and eliminates corrupted partial turns. |

---

## Features Discovered

| # | Category | Feature | Description | Inputs | Outputs | Error Behavior | Discovered Via |
|---|---|---|---|---|---|---|---|
| 1 | Workspace | Canonical Root Resolution | Locks agent root to `File.realpath(Dir.current)`. All tool operations must be within root. | `Dir.current` | `@root : String` (canonicalized path) | Aborts boot if directory inaccessible | `DESIGN.md` §1, `ARCHITECTURE.md` §1.1 |
| 2 | Workspace | Deterministic Workspace ID | Generates human-readable slug and SHA-256 8-char hash (`<slug>-<hash>`). | `@root` string | `workspace_id : String` (e.g. `adjutant-8a4f21bc`) | Deterministic; no error possible | `DESIGN.md` §2, `ARCHITECTURE.md` §1.2 |
| 3 | Workspace | XDG Storage Resolution | Maps config, state, and cache paths into user XDG directories partitioned by workspace ID. | `ENV["XDG_*"]`, `workspace_id` | Config, state, cache directory paths | Creates directories if absent | `DESIGN.md` §2, `ARCHITECTURE.md` §2 |
| 4 | Workspace | Startup Notification Banner | Prints bordered banner with workspace root, config path, and state path to STDOUT. | `@root`, config dir, state dir | Formatted terminal box | None (silent failure on IO error) | `DESIGN.md` §2, `ARCHITECTURE.md` §1.3 |
| 5 | Workspace | System Directive Precedence | Resolves active prompt in 5 tiers (CLI flag > repo file > XDG workspace > XDG global > default). | CLI args, repo `.nightmare/prompt.md`, XDG paths | `active_directive : String` | Falls back to default persona if no file exists | `DESIGN.md` §3, `ORIGINAL_REQUEST.md` R1 |
| 6 | Workspace | In-Memory Directive Edit | `/prompt edit` launches `$EDITOR` on temp file; modifies in-memory prompt without touching disk. | User terminal input, `$EDITOR` | Updated active directive in RAM | Reverts to prior prompt if editor exits with error | `DESIGN.md` §3, `ARCHITECTURE.md` §1.5 |
| 7 | Context | Atomic Turn Units | Groups user prompt, assistant tool calls, tool results, and final assistant message into atomic `Turn`. | `Mantle::Message`, `ToolExchange` | `Turn` record | Never splits turns during eviction | `DESIGN.md` §5, `ARCHITECTURE.md` §2.B |
| 8 | Context | Sliding Window Turn Pruning | Evicts oldest completed turn units when token count exceeds `token_hardmax` or turn cap. | `SlidingStore`, `token_hardmax` | Pruned `SlidingStore` | Never evicts active turn user prompt | `DESIGN.md` §5, `ORIGINAL_REQUEST.md` R2 |
| 9 | Context | In-Turn Tool Shedding | Truncates consumed tool results to 200 chars + stub when active turn exceeds 85% of token limit. | Active turn tool exchanges | Truncated older tool messages | Preserves last 2 tool outputs verbatim | `DESIGN.md` §5, `ORIGINAL_REQUEST.md` R2 |
| 10 | Context | Self-Calibrating Token Estimator | Updates character-to-token divisor using exponential moving average against provider usage feedback. | Provider `usage.prompt_tokens` | Calibrated `divisor : Float64` | Falls back to default `3.5` if no feedback | `DESIGN.md` §5, `ARCHITECTURE.md` §2.3 |
| 11 | Context | Pinned Files (`/add`) | Stages files re-read live from disk on each turn assembly; supports line slicing (`--lines`). | `path : String`, optional range | Pinned section in prompt assembly | Fails if total pinned files > 60% of hardmax | `DESIGN.md` §6, `ARCHITECTURE.md` §2.B |
| 12 | Context | Pinned File Redundancy Short-Circuit | `read_file` detects if path is already pinned and returns zero-token reference notice. | Tool argument `path` | Notice string | Short-circuits tool execution | `DESIGN.md` §6 |
| 13 | Context | Unpinned Files (`/drop`) | Unpins a specific file or all files from the pinned context block. | Optional `path` | Cleared pinned list | Informs user if path was not pinned | `DESIGN.md` §8 |
| 14 | Context | Pristine RAM Transcript (`/save`) | Exports parallel un-truncated in-memory conversation history to Markdown file. | Optional destination path | Markdown file on disk | Returns error if path cannot be written | `DESIGN.md` §7, `ORIGINAL_REQUEST.md` R2 |
| 15 | Tools | `list_files` | Lists files in workspace root or subdirectory; automatically excludes `.git/` and sensitive files. | `directory`, `pattern` | JSON/formatted array of file paths | Raises error if path outside `@root` | `DESIGN.md` §7.A, `ORIGINAL_REQUEST.md` R3 |
| 16 | Tools | `search` | Searches workspace files using regex or substring match; excludes `.git/` and secrets. | `pattern`, `glob`, `max_matches` | Array of matching file paths and lines | Raises error if invalid regex | `DESIGN.md` §7.A, `ORIGINAL_REQUEST.md` R3 |
| 17 | Tools | `read_file` | Reads 1-indexed line slice or entire file within `@root`; rejects sensitive files. | `path`, `offset`, `limit` | File slice content string | Raises error if outside root or sensitive | `DESIGN.md` §7.A, `ORIGINAL_REQUEST.md` R3 |
| 18 | Tools | `file_info` | Retrieves file metadata (size, permissions, mtime, line count) for file within `@root`. | `path` | File metadata struct/JSON | Raises error if file not found or outside root | `DESIGN.md` §7.A, `ORIGINAL_REQUEST.md` R3 |
| 19 | Tools | `write_file` | Creates new file autonomously; overwriting existing file displays unified diff and prompts modal. | `path`, `content` | Confirmation string or diff modal | Rejects writes to `.git/` or outside root | `DESIGN.md` §7.B, `ORIGINAL_REQUEST.md` R3 |
| 20 | Tools | `replace_in_file` | Replaces unique substring match in file; displays diff modal for approval. | `path`, `target`, `replacement` | Confirmation string | Fails if target matches 0 or >1 times | `DESIGN.md` §7.B, `ORIGINAL_REQUEST.md` R3 |
| 21 | Tools | `append_to_file` | Appends content to end of file; displays appended content and prompts modal. | `path`, `content` | Confirmation string | Rejects writes to `.git/` or outside root | `DESIGN.md` §7.B, `ORIGINAL_REQUEST.md` R3 |
| 22 | Tools | `ask_model` | Delegates isolated, stateless subtask to remote model; returns output without history pollution. | `prompt`, `model`, `context_files` | Remote model response string | Returns error string in tool message | `DESIGN.md` §7.C, `ARCHITECTURE.md` §2.5 |
| 23 | Tools | `run_command` | Executes shell command in dedicated process group with timeout, closed stdin, and `CI=1`. | `command : String`, `timeout : Int32` | Truncated stdout + stderr | Non-zero exit code or timeout returned | `DESIGN.md` §7.D, `ORIGINAL_REQUEST.md` R3 |
| 24 | Tools | Shell Metacharacter Ban | Automatically forces interactive modal for commands containing `;`, `&`, `|`, `` ` ``, `$()`, `>`, `<`, `\n`. | Command string | Forces approval modal | Auto-approval strictly barred | `DESIGN.md` §7.D.1, `ORIGINAL_REQUEST.md` R3 |
| 25 | Tools | Anti-Fatigue Shell Modal | Interactive approval modal offering `[y]`, `[N]`, `[e]` (edit), `[a]` (exact allow), `[p]` (prefix allow). | Terminal keystroke | Execution, rejection, edit, or allowlist add | Denied approval returns user rejection error | `DESIGN.md` §7.D.2 |
| 26 | Tools | Workspace Allowlist Persistence | Persists regex command allowlist in `$XDG_CONFIG_HOME/nightmare/workspaces/<id>/allow`. | Regex rules | Loaded allowlist in memory | Ignored if metacharacters present in command | `DESIGN.md` §7.D.2 |
| 27 | Harness | Mantle Step Runner Wrapper | Drives multi-turn inference and tool calling loops using Mantle's decoupled step runner. | `messages : Array(Message)` | `StepResult` | Returns typed `StepError` | `DESIGN.md` §4, `ARCHITECTURE.md` §2 |
| 28 | Harness | Strongly-Typed `Result(T)` | Encapsulates step outcomes in `Success(T)` or `Failure(StepError)` sum types. | Step evaluation | `Result(T)` | Type-safe error handling | `DESIGN.md` §4, `ARCHITECTURE.md` §2.A |
| 29 | Harness | Rate Limit Exponential Backoff | Detects 429 / rate limits and executes exponential backoff with jitter up to 3 retries. | Client error | Retry attempt or `Failure(RateLimited)` | Returns typed `Failure` if all 3 retries fail | `DESIGN.md` §4, `ORIGINAL_REQUEST.md` R4 |
| 30 | Harness | Single Format Retry Turn | Triggers one automatic retry turn with correction message when structured/tool JSON is malformed. | Malformed model payload | Correction prompt dispatched to model | Returns `Failure(MalformedPayload)` if 2nd fail | `DESIGN.md` §4, `ORIGINAL_REQUEST.md` R4 |
| 31 | Harness | Bounded Iterations Limit | Halts turn cleanly at max iterations (default 15), preserving modifications and informing user. | Loop iteration count | Halts turn loop; emits notice | Prevents infinite tool execution loops | `DESIGN.md` §4 |
| 32 | UI | Live Token Streaming | Streams visible response tokens directly to terminal via `Salamander::UI#stream_text`. | Token stream chunk | Rendered characters on stdout | None | `DESIGN.md` §8, `ORIGINAL_REQUEST.md` R5 |
| 33 | UI | Spinner Management | Displays spinner during evaluating/thinking; tears down cleanly when visible content begins. | Model status | Animated terminal spinner | Cleanly cleared on status change | `DESIGN.md` §8, `salamander/ui.cr` |
| 34 | UI | `<think>` Tag Isolation | Real-time state machine accumulates thinking tokens in `thinking_log`, hiding from visible stdout. | Stream chunk containing tags | Clean text to screen, think log in RAM | Accessible via `/thinking` | `DESIGN.md` §8, `salamander/chat_session.cr` |
| 35 | UI | ANSI Markdown Formatting | Styles markdown headers, bold, italics, code blocks, and blockquotes with terminal ANSI escape codes. | Markdown text | ANSI-escaped terminal string | Preserves code blocks from corruption | `DESIGN.md` §8, `salamander/ui/markdown_formatter.cr` |
| 36 | UI | `Ctrl+C` Turn Rollback | Aborts active stream/subprocess, drops in-flight turn from context, and restores prompt to REPL line. | `Signal::INT` | Clean prompt restored; session preserved | Does not terminate REPL session | `DESIGN.md` §8, `ORIGINAL_REQUEST.md` R5 |
| 37 | UI | `/clear` Command | Wipes conversational sliding buffer while keeping pinned files and system directive intact. | Slash command | Cleared context confirmation | None | `DESIGN.md` §8 |
| 38 | UI | `/cls` Command | Sends terminal clear escape sequence (`\e[2J\e[H`) to clear physical screen. | Slash command | Cleared terminal display | None | `DESIGN.md` §8 |
| 39 | UI | `/review` Command | Renders the exact assembled prompt payload that would be sent to the LLM. | Slash command | Assembled prompt printed to screen | None | `DESIGN.md` §8 |
| 40 | UI | `/thinking` Command | Prints the accumulated `<think>` reasoning block from the last turn. | Slash command | Formatted reasoning block printed | Displays notice if no thinking occurred | `DESIGN.md` §8 |
| 41 | UI | `/model` Command | Displays active model configuration or switches model provider for session. | Optional model name | Model configuration status | Displays error if model unknown | `DESIGN.md` §8 |
| 42 | UI | `/paste` / `"""` Mode | Enters multi-line accumulation mode until `/end` or closing `"""`. | Multi-line text input | Single accumulated user prompt | None | `DESIGN.md` §8 |
| 43 | UI | `/exit` Command | Exits REPL cleanly, allowing ephemeral RAM state to evaporate. | Slash command | Process termination (exit 0) | None | `DESIGN.md` §8 |
| 44 | Persistence | Audit Log Rotation | Appends LLM exchanges to `$XDG_STATE_HOME/.../llm_calls.jsonl`; rotates at 20 MB up to 3 files. | Request/response metadata | Rotated log files | Disabled if `--no-log` is passed | `DESIGN.md` §9 |

---

## Edge Cases

| # | Feature | Input | Observed Behavior |
|---|---------|-------|-------------------|
| 1 | Canonical Root Resolution | Launching NIGHTMARE inside a symlinked directory (e.g. `cd /var/repo_symlink && nightmare`). | Resolves `File.realpath` immediately to canonical destination; all boundary checks validate against the real path. |
| 2 | Path Containment | Tool argument `path = "../../../etc/passwd"`. | `File.realpath` or `File.expand_path` resolves outside `@root`. System raises `SecurityError` and rejects execution. |
| 3 | Path Containment | Tool argument targeting an existing symlink inside repo pointing to `/etc/hosts`. | `File.realpath` dereferences the symlink, discovers target is outside `@root`, and raises `SecurityError`. |
| 4 | Mutation Tools | Tool `write_file(path: ".git/hooks/pre-commit", content: "...")`. | Explicitly rejected by `.git/` write protection rule; returns error to model without modifying disk. |
| 5 | Mutation Tools | Tool `write_file(path: "src/new_file.cr", content: "...")` for a non-existent file. | Automatically created without prompting user (auto-approved for new files). |
| 6 | Mutation Tools | Tool `write_file(path: "src/existing.cr", content: "...")` for an existing file. | Generates unified git diff in RAM and displays interactive overwrite approval modal. |
| 7 | Substring Replacement | Tool `replace_in_file(path: "src/app.cr", target: "foo", replacement: "bar")` when "foo" appears twice. | Fails immediately with descriptive error (`Target substring matches 2 instances; must match exactly 1`). |
| 8 | Substring Replacement | Tool `replace_in_file(path: "src/app.cr", target: "nonexistent", replacement: "bar")`. | Fails immediately with descriptive error (`Target substring not found in file`). |
| 9 | Shell Auto-Approval | Command `git status; rm -rf /`. | Contains metacharacter `;`. Auto-approval strictly barred; forces interactive approval modal despite any allowlist. |
| 10 | Shell Auto-Approval | Command `cat file | grep pattern`. | Contains metacharacter `|`. Auto-approval strictly barred; forces interactive modal. |
| 11 | Shell Auto-Approval | Command `echo $(whoami)`. | Contains metacharacter `$()`. Auto-approval strictly barred; forces interactive modal. |
| 12 | Shell Approval Modal | User selects `[e]` (edit) and changes `rm temp.txt` to `ls temp.txt`. | REPL executes edited command `ls temp.txt` and returns `[Executed command after user edit: ls temp.txt]` to model. |
| 13 | Shell Execution | Command executes long-running loop: `while true; do sleep 1; done` exceeding timeout (60s). | Timeout supervisor fires, sends `SIGKILL` to negative process group (`-pgid`), killing shell and children. |
| 14 | Shell Execution | Subprocess attempts interactive read from stdin (e.g. `read -p "Password: "`). | Closed stdin (`/dev/null`) causes read to immediately return EOF, preventing indefinite hangs. |
| 15 | Shell Execution | Command outputs 5 MB of logs (e.g. `cat huge_file.log`). | Output truncated at 50 KB / 300 lines with an omission banner; prevents context buffer blowup. |
| 16 | Ephemeral Context | User exits session via `/exit` and starts a new session in same repo. | Prior conversation is completely gone (evaporated from RAM); only central XDG config and logs persist. |
| 17 | Transcript Export | User runs `/save` after multiple historical turns were pruned and in-turn shedding occurred. | Writes complete, un-truncated transcript from pristine RAM buffer containing full tool outputs and reasoning. |
| 18 | In-Turn Shedding | Active turn invokes 6 tools; total tokens hit 85% of `token_hardmax`. | Tools 1 through 4 truncated to first 200 chars + stub. Tools 5 and 6 retained verbatim. User prompt untouched. |
| 19 | Context Pruning | Sliding window hits `token_hardmax` with 4 completed turns. | Truncates historical tool results to 200 chars. If still over budget, evicts Turn 1 in its entirety (never orphaned tool calls). |
| 20 | Pinned Files | User executes `/add massive_file.cr` which is 75% of `token_hardmax`. | Fails with budget protection error (`File exceeds 60% of context budget limit`); not added to pinned set. |
| 21 | Pinned Files | Pinned file `src/app.cr` is edited by developer in external editor. | On next turn assembly, `read_content` re-reads disk; prompt assembly contains fresh code immediately. |
| 22 | Pinned Files | Model invokes `read_file("src/app.cr")` for a file already in Pinned Files. | Short-circuits immediately with notice: `[Notice: Path 'src/app.cr' is already pinned...]` (0 token overhead). |
| 23 | Signal Interruption | User presses `Ctrl+C` while LLM is generating text. | Aborts HTTP stream, rolls back in-flight turn from context store, restores prompt text to REPL, keeps session alive. |
| 24 | Signal Interruption | User presses `Ctrl+C` while `run_command` is running a slow compiler build. | Kills process group (`-pgid`), rolls back active turn, restores prompt text to REPL, keeps session alive. |
| 25 | Signal Interruption | User presses `Ctrl+C` at an empty input line prompt. | Does not exit on single press; requires double `Ctrl+C`, `Ctrl+D`, or `/exit` to terminate session. |
| 26 | LLM Rate Limiting | Provider returns HTTP 429 Too Many Requests. | Harness detects rate limit, applies exponential backoff with jitter up to 3 times before failing with `RateLimited`. |
| 27 | Malformed Output | Model emits invalid JSON for tool call arguments. | Triggers single automatic retry turn with schema correction prompt; if second attempt fails, returns typed `Failure`. |
| 28 | Max Iterations | Multi-step tool loop reaches iteration 15. | Halts loop cleanly, preserves all workspace modifications, returns iteration limit notice to user. |
| 29 | Directive Precedence | Both `.nightmare/prompt.md` in repo and `$XDG_CONFIG_HOME/.../prompt.md` exist. | Repository committed file takes precedence over XDG workspace config. |
| 30 | Directive Precedence | CLI flag `-s custom_prompt.md` passed when `.nightmare/prompt.md` exists. | CLI flag takes absolute precedence over repository file. |
