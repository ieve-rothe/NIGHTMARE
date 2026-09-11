# NIGHTMARE: System Design & Concept of Operations (CONOPS)

**NIGHTMARE** is a standalone, human-in-the-loop developer REPL (Read-Eval-Print Loop) built on the [Mantle](https://github.com/ieve-rothe/mantle) and [Salamander](https://github.com/ieve-rothe/salamander) frameworks. It is designed as a **general-purpose text and task execution agent** that lives in plain text files and shell scripts, delegating heavy generation or reasoning to online models.

NIGHTMARE is completely unencumbered by cognitive OS machinery: no character personas, no homeostatic drives, no background dream schedulers, no topic frame shifting, and no hidden prompt injections.

---

## 1. Concept of Operations (CONOPS)

```
                       +-------------------------------------------------+
                       |              NIGHTMARE REPL                     |
                       |       (Workspace Root: Dir.current)            |
                       +-----------------------+-------------------------+
                                               |
        +--------------------------------------+--------------------------------------+
        |                                      |                                      |
        v                                      v                                      v
+-------------------+                +-------------------+                  +-------------------+
| Central XDG Config|                | Ephemeral Window  |                  | Pinned Files      |
| $XDG_CONFIG_HOME/ |                | - Turn-unit FIFO  |                  | - User-only /add  |
| nightmare/ws/<id>/|                | - In-turn shedding|                  | - Live re-read    |
| - prompt.md       |                | - Protected user  |                  | - :raw, :lines    |
| - allow list      |                | - Self-calibrating|                  | - /drop to unpin  |
| (Zero repo litter)|                |   ~token meter    |                  | - Cache awareness |
+-------------------+                +-------------------+                  +-------------------+
        |                                      |                                      |
        +--------------------------------------+--------------------------------------+
                                               |
                                               v
                        +-----------------------------------------------+
                        |             SALAMANDER UI LAYER               |
                        | - Startup banner: Workspace -> XDG paths      |
                        | - Live token streaming & spinner teardown     |
                        | - Hidden <think> block accumulation           |
                        | - Ctrl+C turn rollback (session preserved)    |
                        | - Commands (/clear, /cls, /save, /prompt...)  |
                        | - Multi-line paste mode (""" or /paste)       |
                        +----------------------+------------------------+
                                               |
                                               v
                        +-----------------------------------------------+
                        |            MANTLE EXECUTION ENGINE            |
                        | - Mantle::Step with typed Result sum types    |
                        | - Rate limit auto-retry with backoff          |
                        | - Read-only tools (zero approval needed):     |
                        |   list_files, search, read_file, file_info    |
                        |   (ignores .git/ and sensitive patterns)      |
                        | - Mutation tools (workspace-contained):       |
                        |   replace_in_file, append_to_file, write_file |
                        |   (overwrites show diff + require approval)   |
                        |   (strictly forbids .git/)                    |
                        | - Remote delegation: ask_model tool           |
                        | - run_command with interactive approval:      |
                        |   [y]es / [N]o / [e]dit / [a]llow exact /     |
                        |   [p]refix allow; metacharacter injection ban |
                        |   Process group kill; CI=1; stdin=/dev/null   |
                        +----------------------+------------------------+
                                               |
                                               v
                        +-----------------------------------------------+
                        |        CENTRAL CANONICAL PERSISTENCE          |
                        | - Pristine transcript export via /save        |
                        | - Workspace logs isolated in:                 |
                        |   $XDG_STATE_HOME/nightmare/workspaces/<id>/  |
                        |   llm_calls.jsonl                             |
                        | - Zero files written into target repo         |
                        +-----------------------------------------------+
```

### Core Tenets
1. **Workspace-Bound Root**: Anchors directly to `Dir.current`, canonicalized once at boot (`@root = File.realpath(Dir.current)`). All tool operations are strictly confined within `@root`. Symlinks resolving outside the root and path traversal attempts (`../`) are rejected.
2. **Zero Repository Litter (Strict XDG Conformance)**: NIGHTMARE never drops configuration, state, cache, or log files into the target repository. All persistent application files reside in standard XDG user directories, partitioned cleanly per workspace.
3. **Ephemeral by Default, Pristine on Demand**: Conversational state lives in RAM. Exiting the REPL evaporates the context window. However, NIGHTMARE maintains a parallel, un-pruned transcript in RAM so that `/save [path]` writes out a complete, readable Markdown record without truncated tool stubs.
4. **Turn-Unit Pruning & In-Turn Shedding**: Pruning operates on atomic turn units (User $\rightarrow$ Tools $\rightarrow$ Assistant). To prevent mid-turn cap exhaustion during tool loops, older consumed tool outputs within the current turn are truncated to their first ~200 characters plus a stub. The user instruction is strictly protected.
5. **Honest, Transparent Observability**: Raw LLM exchanges are logged to the workspace's central state directory in `$XDG_STATE_HOME`. Token meters are self-calibrating against provider token usage feedback and explicitly prefixed with a tilde (`~2,160t`).
6. **Rigorous Security & Anti-Fatigue Approval**: Read-only tools run autonomously without approval. Mutation tools auto-approve new file creation, but prompt with a unified diff before overwriting existing files. Shell execution provides explicit approval controls (`[y]`, `[N]`, `[e]`, `[a]` exact, `[p]` prefix) with a hard ban on auto-approving shell metacharacters.

---

## 2. XDG Storage Architecture & Workspace Mapping

NIGHTMARE strictly implements the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html) to keep target workspaces clean while maintaining fully isolated configurations and audit logs per project.

### Directory Layout

```text
~/.config/nightmare/                          <-- $XDG_CONFIG_HOME/nightmare/
├── config.json                               <-- Global defaults (model, timeouts, defaults)
├── prompt.md                                 <-- Global fallback persona
└── workspaces/
    └── adjutant-8a4f21bc/                    <-- Workspace Config Directory
        ├── workspace.json                    <-- Metadata linking ID to canonical path
        ├── prompt.md                         <-- Workspace-specific system prompt override
        └── allow                             <-- Workspace-specific shell pattern allowlist

~/.local/state/nightmare/                     <-- $XDG_STATE_HOME/nightmare/
└── workspaces/
    └── adjutant-8a4f21bc/                    <-- Workspace State Directory
        ├── llm_calls.jsonl                   <-- Workspace LLM call log (rotated at 20MB)
        └── session_history.json              <-- Metadata of previous sessions

~/.cache/nightmare/                           <-- $XDG_CACHE_HOME/nightmare/
└── workspaces/
    └── adjutant-8a4f21bc/                    <-- Transient caches (token calibration, diffs)
```

### Workspace Identification & Mapping Algorithm
When NIGHTMARE launches in `Dir.current`:
1. **Canonical Path**: Resolves `@root = File.realpath(Dir.current)`.
2. **Workspace ID Generation**:
   - Computes a human-friendly slug: `slug = File.basename(@root).gsub(/[^a-zA-Z0-9_-]/, "_")`
   - Computes an 8-character deterministic path hash: `hash = Digest::SHA256.hexdigest(@root)[0..7]`
   - Combines to form the ID: `workspace_id = "#{slug}-#{hash}"` (e.g. `adjutant-8a4f21bc`).
3. **Registry & Bootstrap**:
   - Computes config dir: `config_dir = File.join(xdg_config_home, "nightmare", "workspaces", workspace_id)`
   - Computes state dir: `state_dir = File.join(xdg_state_home, "nightmare", "workspaces", workspace_id)`
   - If directories exist $\rightarrow$ loads workspace configuration (`prompt.md`, `allow`).
   - If directories do not exist $\rightarrow$ creates them and writes `workspace.json`:
     ```json
     {
       "id": "adjutant-8a4f21bc",
       "canonical_path": "/home/cam/repos/adjutant",
       "created_at": "2026-09-11T10:15:00Z",
       "last_accessed": "2026-09-11T10:15:00Z"
     }
     ```

### Startup Notification
On boot, NIGHTMARE emits a clean notification banner to STDOUT before presenting the prompt:

```text
┌── NIGHTMARE ─────────────────────────────────────────────────────────────┐
│ Workspace : /home/cam/repos/adjutant                                     │
│ Config    : ~/.config/nightmare/workspaces/adjutant-8a4f21bc/            │
│ State/Logs: ~/.local/state/nightmare/workspaces/adjutant-8a4f21bc/       │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Pluggable Directives & Default Persona

Directives govern the agent's behavior. They are resolved using a strict precedence order:
1. **CLI Flag (Highest Priority)**: `nightmare -s <path>` or `nightmare --system <path>`
2. **Repository File (If Explicitly Committed)**: `.nightmare/prompt.md` in `@root` (optional; not created by tool)
3. **Workspace Central Config**: `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/prompt.md`
4. **Global Config**: `$XDG_CONFIG_HOME/nightmare/prompt.md`
5. **Default General Persona (Fallback)**:
   ```markdown
   You are an execution agent operating in the current working directory.
   - Inspect files and execute tools to determine facts before taking action.
   - Prefer replace_in_file for edits; read before you write; never overwrite a file you have not inspected this session.
   - Be concise, direct, and factual.
   - Do not assume context; rely strictly on provided files, tool outputs, and user instructions.
   ```

### In-Memory Directive Mutation
- Running `/prompt edit` opens `$EDITOR` (falling back to `$VISUAL` or `nano`/`vim`) on a temporary file holding the active prompt.
- Saving updates **only the in-memory directive** for the current process session. If the prompt was loaded from a file, the file on disk remains untouched.
- `/prompt` prints the active directive verbatim to the terminal.

---

## 4. Mantle Step & Strongly-Typed Result Contracts

Mantle provides the `Mantle::Step` loop and generic `StepResult` structures. In NIGHTMARE, we enforce a strict sum-type boundary:

```crystal
module Nightmare
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
    def initialize(@value : T, @thinking : String? = nil, @iterations : Int32 = 0); end
  end

  class Failure
    getter error : StepError
    getter thinking : String?
    getter iterations : Int32
    def initialize(@error : StepError, @thinking : String? = nil, @iterations : Int32 = 0); end
  end
end
```

### Rate Limiting & Auto-Retry
- **Rate Limits (`RateLimited`)**: The harness automatically catches rate limits and applies exponential backoff with jitter (up to 3 retries) before surfacing a `Failure`.
- **Malformed Payload Handling**: When structured extraction fails schema parsing, the harness triggers **one automatic retry turn** with an explicit schema correction reminder (`"Previous response could not be parsed: <error>. Output strictly valid JSON."`).
- **Iteration Limits (`MaxIterationsReached`)**: If a turn hits its tool iteration limit (e.g. 15 iterations), the harness halts cleanly, commits all completed tool results, and informs the user:
  `[Notice] Execution reached iteration limit (15). Workspace modifications preserved. Enter next instruction or /replay to continue.`

---

## 5. Context & Memory: Turn-Unit Pruning & In-Turn Shedding

### The Two-Tier Pruning Contract

$$\text{Turn} = \langle \text{User Message},\, [\text{Assistant Tool Call} \leftrightarrow \text{Tool Result}]^{*},\, \text{Final Assistant Message} \rangle$$

```
+-------------------------------------------------------------------------+
| [System Directive] (Cached prefix block; never pruned)                  |
| [Pinned Files Block] (Re-read live from disk; never pruned)             |
+-------------------------------------------------------------------------+
| [Historical Turns 1 .. N-1]                                             |
|   -> Phase 1: Truncate tool results (>200 chars -> prefix + stub)       |
|   -> Phase 2: Evict oldest atomic turn unit entirely                   |
+-------------------------------------------------------------------------+
| [Current Turn N: Active Execution]                                      |
|   -> User Prompt (Strictly protected; never evicted)                    |
|   -> Consumed Tool Results: Keep first 200 chars + stub                 |
|   -> Last 2 Active Tool Results: Verbatim (active working set)          |
+-------------------------------------------------------------------------+
```

### 1. In-Turn Shedding (Active Turn Defense)
When the active turn's tool iterations cause tokens to exceed `token_hardmax * 0.85`:
- Identify tool results that have already been "consumed" (i.e. the model has already observed them and emitted subsequent tool calls).
- Keep the **last 2 tool results verbatim** (the active working set).
- For all prior tool results in the current turn, retain the **first ~200 characters** (preserving semantic context like file headers or error types) and append: `[... output truncated: was N bytes]`.

### 2. Historical Turn-Unit Pruning
When total tokens exceed `token_hardmax`:
- **Phase 1**: Iterate through completed historical turns. Truncate historical tool results to the first ~200 chars + stub.
- **Phase 2**: If tokens still exceed `token_hardmax`, evict the entire oldest completed turn unit.
- **Turn Cap**: A configurable soft limit (default: 10 completed turns). Oldest turns are pruned once the turn count exceeds this cap.

### 3. Self-Calibrating Token Accounting
Instead of relying on a static `bytes // 4` heuristic (which undercounts code by ~25%), NIGHTMARE calibrates itself dynamically:
- At boot, the character-to-token divisor is initialized to `3.5`.
- On every turn where the provider returns actual `usage.prompt_tokens`, NIGHTMARE computes:
  $$\text{Divisor}_{\text{new}} = 0.8 \times \text{Divisor}_{\text{prev}} + 0.2 \times \left( \frac{\text{Raw Assembled Characters}}{\text{usage.prompt_tokens}} \right)$$
- The UI meter displays the calibrated estimate with a tilde:
  `Working Memory: ~2,450 / 12,000 tokens (Turns: 3/10) | Pinned: 1 file (~850t)`

---

## 6. File-to-Context Pipeline & Pinned Files

### `read_file` vs. `/add` (Pinned Files)

| Characteristic | `read_file` (Transient Observation Tool) | `/add` (User-Pinned Working Set) |
| :--- | :--- | :--- |
| **Actor** | Called autonomously by the agent mid-turn. | Executed exclusively by the user via `/add`. |
| **Placement** | Appears as a standard `tool` result in the turn. | Injected into the `[Pinned Context]` section above history. |
| **Lifecycle** | Subject to in-turn shedding and turn-unit eviction. | Stays present across all turns until dropped via `/drop`. |
| **Staleness** | Static snapshot at read time. | **Live Re-read**: Re-read from disk on every turn assembly. |
| **Cache Impact** | Sits in history; invalidates only turn suffix. | Sits above history; edits invalidate prompt cache prefix. |

### Caching Awareness & Redundancy Short-Circuit
- **Prompt Caching**: Pinned files sit immediately below the system directive. When pinned files are modified, prompt caching for historical turns is invalidated. This is an intentional tradeoff for guaranteed correctness.
- **Redundancy Short-Circuit**: If the agent calls `read_file` on a path that is currently pinned in context, the tool short-circuits immediately with zero token overhead:
  `[Notice: Path 'src/app.cr' is already pinned in the active context block. Refer to pinned context above.]`
- **Budget Protection**: `/add` fails with an error if the added file causes total pinned files to exceed 60% of `token_hardmax`.

---

## 7. Tool Surface & Security Architecture

### Path Containment & Deny-Lists
- **Root Anchor**: `@root = File.realpath(Dir.current)` computed once at boot.
- **Path Resolution**: Every path argument is resolved:
  - For existing targets: `real = File.realpath(path)`
  - For new targets: `real = File.join(File.realpath(File.dirname(path)), File.basename(path))`
  - Invariant: `real.starts_with?(@root)` must be true, or execution errors out.
- **Forbidden Directories**:
  - All write/mutation tools strictly forbid targets inside `.git/`.
  - Central XDG directories live outside `@root` and are automatically protected from bot writes by the root containment invariant.
- **Sensitive File Ignore**:
  - Read tools (`read_file`, `search`, `list_files`) reject files matching sensitive patterns (defaults to `.env*`, `*.pem`, `id_rsa*`, `*secret*`, `*credential*`, `.git/*`).

### A. Read-Only Observation Tools (Autonomous / No Approval)
Zero-prompt execution. Automatically excludes `.git/` and ignored files:
1. **`list_files(directory : String = ".", pattern : String? = nil)`**: Lists directory contents.
2. **`search(pattern : String, glob : String? = nil, max_matches : Int32 = 50)`**: Regex/keyword search across workspace files.
3. **`read_file(path : String, offset : Int32 = 1, limit : Int32 = 200)`**: Reads a slice or entire file.
4. **`file_info(path : String)`**: Returns metadata (size, permissions, mtime, line count).

### B. Mutation Tools (Approval for Overwrites)
1. **`write_file(path : String, content : String)`**:
   - If the file **does not exist**: Created automatically (no modal).
   - If the file **exists**: Displays a unified diff in the terminal and prompts for approval:
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
   - Exact-match substring search-and-replace. Fails if `target` matches 0 or $>1$ instances.
   - Shows diff and prompts for approval using the same modal.
3. **`append_to_file(path : String, content : String)`**: Appends content to a file. Shows appended lines and prompts for approval.

### C. Model Delegation: `ask_model`
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

### D. Shell Execution: `run_command`

#### 1. Metacharacter Ban on Auto-Approval
To prevent shell-injection bypasses (e.g. `git status; rm -rf ~`), **ANY command containing shell metacharacters** (`;&|` `` ` `` `$()` `>` `<` `\n`) is **strictly barred from auto-approval**, regardless of session allowlists or regex patterns. It always forces an interactive modal.

#### 2. Interactive Approval Controls
```text
┌── [NIGHTMARE Shell Request] ───────────────────────────────────────────┐
│ Command: git diff HEAD~1                                               │
│ Timeout: 60s (max 600s) | Cwd: /home/cam/repos/adjutant                │
└────────────────────────────────────────────────────────────────────────┘
Approve? [y]es / [N]o / [e]dit / [a]lways exact / [p]refix allow: 
```
- `[y]`: Runs once.
- `[N]`: Rejects, returning an error to the model.
- `[e]`: Opens inline prompt to edit command. The tool output returned to the model explicitly includes: `[Executed command after user edit: <actual_command>]`.
- `[a]`: Adds exact string to in-memory session allowlist (metacharacter-free commands only).
- `[p]`: Derives the binary + subcommand prefix (e.g. `^git diff\b`) and adds it to the session allowlist.
- **Pattern Allowlist**: Saved in `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/allow` containing regexes anchored at both ends (e.g. `^git status$`, `^crystal spec( [a-zA-Z0-9_\/.-]+)?$`).

#### 3. Subprocess Execution Guardrails
- **Process Group Kill**: Commands execute in a dedicated process group (`Process.new(..., chdir: @root)`). On timeout or cancellation, `Process.kill(Signal::KILL, -pgid)` is sent to the process group, terminating child processes (e.g. `sh` + `crystal spec`).
- **Environment**: Automatically injects `GIT_TERMINAL_PROMPT=0` and `CI=1`.
- **Closed Stdin**: `stdin` is bound to `/dev/null` (`Process::Redirect::Close`) to prevent commands hanging indefinitely on interactive prompts.
- **Output Truncation**: Stdout and stderr are capped at 50 KB / 300 lines (head + tail with omission banner).
- **Timeouts**: Parameterized timeout capped at a hard maximum of 10 minutes (default: 60s).

---

## 8. UI Layer: Salamander & Interaction

### Signal Handling: Turn Rollback
- **`Ctrl+C` During Active Turn**:
  - Immediately terminates the in-flight process group and aborts LLM streaming.
  - **Full Turn Rollback**: The active turn (user message, partial tool calls, and in-flight responses) is dropped from the conversational context buffer, preventing orphaned tool pairs.
  - The user's input prompt is preserved and restored to the input line for editing.
- **Exiting the REPL**: Requires `/exit`, EOF (`Ctrl+D`), or pressing `Ctrl+C` twice in rapid succession while at an empty prompt.

### Command Reference
- `/clear`: Wipes the conversational sliding buffer. Pinned files and active directives remain intact.
- `/cls`: Clears the physical terminal screen (`\e[2J\e[H`).
- `/drop [path]`: Unpins a specific file, or unpins all files if no path is given.
- `/save [path]`: Exports the **pristine, un-pruned transcript** from RAM to a clean Markdown file.
- `/prompt [edit]`: Displays the active system directive. `edit` opens `$EDITOR` for in-memory modification.
- `/review`: Displays the exact, complete prompt assembly currently dispatched to the LLM.
- `/thinking`: Displays the hidden `<think>` reasoning block from the last turn.
- `/model [name]`: Shows or switches the active model provider.
- `/paste` (or `"""`): Toggles multi-line input mode (terminated by `/end` or `"""`).
- `/help`: Displays command syntax and keybindings.
- `/exit`: Terminates the session (ephemeral state evaporates).

---

## 9. Persistence & Logging

### Workspace Cleanliness via XDG State Directories
- Logs live in `$XDG_STATE_HOME/nightmare/workspaces/<workspace_id>/llm_calls.jsonl`.
- Zero files are written into the target git repository.
- Logs rotate automatically upon reaching 20 MB (retaining up to 3 rotated files). Can be disabled via `--no-log`.

---

## 10. MVP Boundary (v1 Scope)

### In Scope for v1 (MVP)
1. **Core Runtime & XDG Mapping**:
   - `@root = File.realpath(Dir.current)`.
   - XDG discovery: computes `<slug>-<sha256[0..7]>` and initializes `$XDG_CONFIG_HOME` and `$XDG_STATE_HOME` directories.
   - Startup banner: prints workspace root, config path, and state path to STDOUT.
   - Directive resolution (CLI flag $>$ repo override $>$ central XDG config $>$ global XDG $>$ default persona).
2. **Context Engine**: `EphemeralSlidingContextStore` with **turn-unit pruning**, **in-turn shedding**, and self-calibrating token meter. `memory_store = nil`.
3. **Pristine Transcript**: In-memory un-pruned history buffer exported via `/save [path]`.
4. **Read-Only Tools**: `list_files`, `search`, `read_file`, `file_info` (autonomous, realpath-checked, sensitive patterns excluded).
5. **Mutation Tools**: `replace_in_file`, `append_to_file`, `write_file` (realpath-checked, `.git/` protected, overwrite diff confirmation modal).
6. **Shell Execution**: `run_command` with process group termination, timeout cap, closed stdin, and approval modal (`[y]es / [N]o / [e]dit / [a]llow exact / [p]refix allow`).
7. **Model Delegation**: `ask_model` tool.
8. **Pinned Files**: `/add` (`:raw` and `--lines` slices only) with live disk re-reads, redundancy short-circuiting, and `/drop`.
9. **Salamander UI**: Spinner teardown, token streaming, `<think>` isolation, **`Ctrl+C` turn rollback**, and ANSI markdown formatter.
10. **Commands**: `/clear`, `/cls`, `/drop`, `/save`, `/prompt`, `/review`, `/thinking`, `/model`, `/paste`, `/exit`.
11. **Audit Log**: Separated per-workspace in `$XDG_STATE_HOME/nightmare/workspaces/<id>/llm_calls.jsonl`.

### Explicitly Deferred to v2 (Extensions)
- Fast-model summarization preprocessor (`/add --summary`).
- Pre-approved scripts directory (`$XDG_CONFIG_HOME/nightmare/workspaces/<id>/scripts/`).
- Multi-agent swarm coordination.
