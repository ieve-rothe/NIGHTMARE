# Comprehensive Framework Analysis: Mantle & Salamander

This report details the architectural investigation of local frameworks `mantle` (`/home/cam/repos/adjutant/mantle`) and `salamander` (`/home/cam/repos/adjutant/salamander`), their type contracts, execution models, streaming mechanisms, error handling, shard configurations, and their integration into NIGHTMARE.

---

## 1. Mantle Framework Analysis

### 1.1 Overview & Shard Specification
- **Repository Location**: `/home/cam/repos/adjutant/mantle`
- **Version**: `1.1.0` (as declared in `shard.yml`)
- **Crystal Version**: `>= 1.18.2` (System compiler is `1.21.0`)
- **Dependencies**: Zero external shard dependencies. Mantle relies solely on the Crystal Standard Library (`http/client`, `json`, `log`, `digest/sha256`, `uuid`, etc.).
- **Spec Suite**: 303 examples passing with 0 failures, 0 errors, 0 pending.

### 1.2 Module Hierarchy & Key Components

```text
Mantle
├── Log                                  # ::Log.for("mantle")
├── Message                              # Core message struct (role, content, tool_calls, tool_call_id)
├── Clients
│   ├── Client                           # Abstract base client contract
│   ├── OllamaClient                     # Concrete streaming/standard Ollama HTTP client
│   ├── LoggingClient(T)                 # JSONL receipt decorator wrapping any Client
│   ├── ReceiptWriter                    # Non-blocking fiber-based JSONL audit queue
│   ├── ModelConfig                      # Configuration record (model, stream, temp, top_p, tokens, url)
│   ├── ToolCall                         # Tool call payload struct (id, type, function)
│   ├── ToolCallFunction                 # Function name & arguments (with custom JSON converter)
│   └── Response                         # LLM completion response struct with token stats & thinking
├── Tools
│   ├── Tool                             # Canonical tool schema struct (function, handler, type)
│   ├── FunctionDefinition               # Name, description, parameters schema
│   ├── ParametersSchema                 # Object parameter schema
│   ├── PropertyDefinition               # Single parameter type & description
│   ├── BuiltinTool                      # Enum (ReadFile, ListDirectory, NotifySend, WriteFile, SearchFiles)
│   ├── BuiltinToolRegistry              # Maps BuiltinTool enum values to Tool definitions
│   ├── BuiltinToolExecutor              # Safely executes builtins within sandboxed paths
│   ├── ToolExecutor                     # Routes tool calls to built-in or custom handlers (with recovery)
│   ├── ToolFormatter                    # Serializes tool interactions into natural language
│   └── Exceptions                       # TerminalToolError, TerminalToolInterrupt
├── Steps
│   ├── Step                             # Primary inference & multi-turn tool execution loop
│   ├── StepError                        # Enum (MalformedOutput, MaxIterationsReached, ClientFailure, etc.)
│   ├── StepResult(T, E)                 # Strongly-typed outcome class with value, error, thinking, iterations
│   └── StepUnwrapError                  # Exception raised when unwrapping error results
├── Storage
│   ├── ContextStore                     # Abstract base context store
│   ├── EphemeralSlidingContextStore     # In-memory Deque-backed sliding window
│   ├── JSONContextStore                 # Persisted tree/graph store with ancestors/descendants
│   ├── ContextNode                      # Node in JSONContextStore
│   ├── ContextManager                   # Orchestrator between ContextStore and JSONLayeredMemoryStore
│   └── JSONLayeredMemoryStore           # Hierarchical long-term memory with recursive consolidation
├── Session
│   ├── Session                          # High-level turn orchestrator with queue consumption & retries
│   └── QueueItem                        # Asynchronous turn queue task record
├── Subagents
│   ├── Profile                          # Subagent configuration struct
│   ├── Runner                           # Recursive subagent depth supervisor
│   └── SpawnSubagentTool                # Built-in tool wrapper for spawning subagents
└── Support
    ├── Text                             # <think> extraction & stripping regex helpers
    └── LogContext                       # Fiber-safe sequence_id storage
```

### 1.3 Detailed Component Contracts

#### A. LLM Provider Clients (`Mantle::Clients`)
- **`Client`**: Abstract base class defining:
  - `abstract def execute(messages : Array(Mantle::Message), tools : Array(Mantle::Tools::Tool)? = nil, &on_chunk : String -> Nil) : Response`
  - `def execute(messages : Array(Mantle::Message), tools : Array(Mantle::Tools::Tool)? = nil) : Response` (non-streaming overload)
  - `def temperature : Float64` / `def temperature=(value : Float64)`
- **`OllamaClient < Client`**:
  - Implements HTTP POST requests to `@api_url` (`/api/chat`).
  - Supports streaming via chunked IO reading and standard JSON responses.
  - Normalizes token counts (`prompt_eval_count`, `eval_count`) and automatically assigns generated IDs (`call_#{hex}`) to tool calls if omitted by the provider.
- **`LoggingClient(T) < Client`**:
  - Decorator that wraps any underlying client `T`.
  - Captures input SHA256 hash, sequence ID, model name, prompt messages, raw output, latency in milliseconds, and status.
  - Dispatches tasks asynchronously to `ReceiptWriter` which flushes JSONL receipts to disk in a dedicated fiber.
- **`Response`**:
  - Properties: `content : String?`, `thinking : String?`, `tool_calls : Array(ToolCall)?`, `done_reason : String?`, `prompt_eval_count : Int32?`, `eval_count : Int32?`, `raw_request : String?`, `raw_response : String?`.
  - Helper predicates: `truncated?` (`done_reason == "length"`), `thinking_only?`, `truncated_in_thinking?`.
  - Automatically runs `Mantle::Support::Text.extract_thinking(raw)` if `content` includes `<think>`.

#### B. Message Types (`Mantle::Message`)
```crystal
struct Message
  include JSON::Serializable
  property role : String                                      # "user", "assistant", "system", "tool"
  property content : String?
  @[JSON::Field(emit_null: false)]
  property tool_calls : Array(Mantle::Clients::ToolCall)?
  @[JSON::Field(emit_null: false)]
  property tool_call_id : String?
end
```

#### C. Tool System (`Mantle::Tools`)
- **`Tool`**:
  - Contains `function : FunctionDefinition` (JSON schema compatible with OpenAI/Ollama).
  - Contains an optional execution handler: `handler : Proc(Hash(String, JSON::Any), String)?`.
  - Can be instantiated with a block: `Tool.new(func_def) { |args| ... }`.
  - Method `execute(arguments : Hash(String, JSON::Any)) : String`.
- **Built-in Tools**:
  - `BuiltinTool` enum: `ReadFile`, `ListDirectory`, `NotifySend`, `WriteFile`, `SearchFiles`.
  - `BuiltinToolExecutor` provides path traversal protections and autonomous zone write checks.
- **Tool Exceptions**:
  - `TerminalToolInterrupt < Exception`: Immediately halts the step loop and returns success with `value = ex.message`.
  - `TerminalToolError < Exception`: Immediately halts the step loop and returns `StepError::ToolExecutionFailure`.

#### D. Execution Step Harness (`Mantle::Steps`)
- **`Step`**:
  - Constructor:
    ```crystal
    def initialize(
      @client : Mantle::Clients::Client,
      @tools : Array(Mantle::Tools::Tool) = [] of Mantle::Tools::Tool,
      @max_iterations : Int32 = 10,
      @on_status : Proc(Symbol, Nil)? = nil,
      @tool_callback : Proc(String, Hash(String, JSON::Any), String)? = nil,
    )
    ```
  - Execution Method:
    `def run(messages : Array(Mantle::Message), &block : String -> Nil) : StepResult(String, StepError)`
  - **Graph Isolation**: `working_messages = messages.dup`. Input `messages` is never mutated in-place.
  - **Loop Mechanics**:
    1. Iterates up to `@max_iterations`. If exceeded, emits `:idle` and returns `StepResult` with `StepError::MaxIterationsReached`.
    2. Emits status `:thinking` to `@on_status`.
    3. Calls `@client.execute(working_messages, tools, &block)`.
    4. If the client raises an exception: catches it, maps `429` / `"rate limit"` to `StepError::RateLimited`, otherwise `StepError::ClientFailure`.
    5. If response contains `tool_calls`:
       - Emits status `:tool_loop`.
       - Appends assistant message with `tool_calls` to `working_messages`.
       - Executes each tool call via `tool_def.execute(args)` or `@tool_callback`.
       - Appends tool message (`role: "tool"`, `content: tool_result_str`, `tool_call_id: call.id`) to `working_messages`.
       - Loops to next iteration.
    6. If response has final content: emits `:idle` and returns `StepResult.ok(content, thinking, iterations, raw_response)`.
    7. If response has neither content nor tool calls: returns `StepError::MalformedOutput`.

#### E. Sum Types & Error Handling in Mantle
- **`StepError` Enum**:
  - Values: `MalformedOutput`, `MaxIterationsReached`, `ClientFailure`, `ToolExecutionFailure`, `RateLimited`.
  - Predicates: `retryable?` (returns true for `ClientFailure` and `RateLimited`), `terminal?` (negation of `retryable?`).
- **`StepResult(T, E)` Class**:
  - Holds `value : T?`, `error : E?`, `thinking : String?`, `iterations : Int32`, `raw_response : Mantle::Clients::Response?`.
  - Predicates: `ok?` (`@error.nil?`), `err?` (`!ok?`).
  - Methods: `unwrap : T` (raises `StepUnwrapError` if failed), `self.ok(...)`, `self.error(...)`.
- **Note on Result Sum Type**:
  - Mantle uses a class `StepResult(T, E)` with nullable properties (`value : T?`, `error : E?`).
  - Mantle **does NOT define** a Crystal sum type `alias Result(T) = Success(T) | Failure`.
  - In NIGHTMARE, Requirement R4 and ARCHITECTURE.md require encapsulating LLM interactions into a strict `Result(T) = Success(T) | Failure` sum-type boundary. This is defined in `Nightmare::Harness` and wraps `Mantle::StepResult`.

---

## 2. Salamander Framework Analysis

### 2.1 Overview & Shard Specification
- **Repository Location**: `/home/cam/repos/adjutant/salamander`
- **Version**: `0.2.0` (as declared in `shard.yml`)
- **Dependencies**:
  - `mantle: path: ../mantle`
  - `tts_kokoro: path: ../tts_kokoro`
- **Spec Suite**: 20 examples passing with 0 failures, 0 errors, 0 pending.

### 2.2 Module Hierarchy & Key Components

```text
Salamander
├── VERSION                              # "0.2.0"
├── Terminal                             # Yielding sandbox wrapper (run)
├── UI                                   # Toolbelt class yielded to the application
│   ├── ask_user                         # Synchronous input prompt (gets)
│   ├── stream_text                      # Real-time stdout text streaming & TTS buffer push
│   ├── spin_while                       # Animated Braille spinner fiber
│   ├── print_separator                  # Full-width double-line boxed separator
│   ├── clear_line                       # Erases current line (\e[2K\r)
│   ├── clear_and_reposition             # Moves cursor up and clears physical lines
│   ├── terminal_width                   # ioctl TIOCGWINSZ terminal width query
│   └── MarkdownFormatter                # Markdown to ANSI escape sequence renderer
│       └── IncrementalLexer             # In-flight stream chunk formatter
├── ChatSession                          # Streaming state machine (<think> tag stripper)
│   ├── State                            # Enum: Evaluating, Thinking, Responding
│   ├── process_chunk                    # Ingests chunk, transitions state, strips <think>
│   ├── thinking_log                     # Accessor for accumulated hidden thinking text
│   └── ProcessedChunk                   # Struct (content, state, state_changed, old_state)
├── Menu                                 # Interactive terminal number selection chooser
└── WaybarNotifier                       # Waybar socket/file & desktop notification manager
```

### 2.3 Detailed Component Contracts

#### A. The Yielding Sandbox Pattern (`Salamander::Terminal`)
- `Terminal.run` initializes `WaybarNotifier` and yields `UI` to the caller block:
  ```crystal
  Salamander::Terminal.run(bot_name: "Emma", icon: "🐾") do |ui|
    # Application controls loop and flow
  end
  ```
- Important: In `WaybarNotifier#start`, default signal handlers are attached:
  ```crystal
  Signal::INT.trap { exit }
  Signal::TERM.trap { exit }
  ```
  In NIGHTMARE, `Ctrl+C` must cancel execution and roll back the active turn without terminating the session (R5). Therefore, NIGHTMARE must override `Signal::INT.trap` with its own turn rollback handler.

#### B. Streaming State Machine & Thinking Isolation (`Salamander::ChatSession`)
- Encapsulates state transitions across three phases:
  1. `:evaluating` (initial state when inference begins)
  2. `:thinking` (triggered by `<think>` or `<|think|>`)
  3. `:responding` (triggered by `</think>`, `</|think|>`, or plain content with no think tags)
- In `:thinking` state:
  - Thinking tokens are stripped from `ProcessedChunk.content` (content is empty string `""`).
  - Thinking tokens are accumulated into `@hidden_thinking_log`.
- In `:responding` state:
  - Think tags are stripped and clean visible text is returned in `ProcessedChunk.content`.
- Caller retrieves full internal monologue at any time via `session.thinking_log`.

#### C. ANSI Markdown Formatter (`Salamander::UI::MarkdownFormatter`)
- Converts Markdown syntax to ANSI escape codes:
  - Code blocks (` ``` ` and ` ` `) -> Dark gray background `\e[48;5;236m`.
  - Headers (`#`, `##`, ...) -> Bold cyan `\e[1;36m`.
  - Blockquotes (`>`) -> Italic gray `\e[3;90m`.
  - Bold (`**`) -> Bold white `\e[1;97m`.
  - Italic (`*`) -> Italic `\e[3m`.
  - Links (`[text](url)`) -> Blue text with underlined URL `\e[34m ... (\e[4;34m ... \e[0m)`.
- Protected Placeholder Replacement: Extracts code blocks into null-byte delimited placeholders (`\x00CODE_BLOCK_n\x00`) before processing inline spans, preventing code formatting corruption.
- Nested Style Restoration: When inner spans (bold/italic) inside headers or blockquotes close, they restore the parent style instead of hard `\e[0m` reset, preventing color bleeding.
- `IncrementalLexer`: Provides `process_chunk(chunk)` for streaming text.

#### D. Animated Spinner (`Salamander::UI#spin_while`)
- Runs in a separate fiber cycling Unicode Braille frames `['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']` every 80ms.
- Reads state from an optional `state_getter : Proc(Symbol)?`:
  - `:evaluating` -> Displays message in cyan.
  - `:thinking` -> Displays "Thinking..." in magenta.
  - `:responding` -> Automatically stops the spinner fiber so text streaming can immediately begin.
- Synchronized via `Channel(Nil)` for clean teardown.

#### E. Input & Terminal Queries (`Salamander::UI`)
- `ask_user(prompt : String)`: Prints prompt in bold cyan and reads with `gets`.
- `terminal_width`: Uses C `ioctl(1, TIOCGWINSZ, ...)` on Linux and macOS, falling back to 80 columns.
- `count_physical_lines(text)`: Calculates how many wrapped lines text occupies based on terminal width.
- `clear_line`: Emits `\e[2K\r` to clear the current active terminal row.

---

## 3. Compatibility & Integration Analysis for NIGHTMARE

### 3.1 Shard Configuration & Path Linking
In `nightmare/shard.yml`, the dependencies must be declared using local relative paths:

```yaml
name: nightmare
version: 0.1.0

targets:
  nightmare:
    main: src/nightmare.cr

crystal: '>= 1.21.0'

license: MIT

dependencies:
  mantle:
    path: ../mantle
  salamander:
    path: ../salamander
  tts_kokoro:
    path: ../tts_kokoro
```

**Key Findings on Path Linking**:
1. All three repositories (`mantle`, `salamander`, `tts_kokoro`) exist as immediate siblings in `/home/cam/repos/adjutant/`.
2. Running `shards install` creates symlinks in `nightmare/lib/`:
   - `lib/mantle -> /home/cam/repos/adjutant/mantle`
   - `lib/salamander -> /home/cam/repos/adjutant/salamander`
   - `lib/tts_kokoro -> /home/cam/repos/adjutant/tts_kokoro`
3. Including `tts_kokoro: path: ../tts_kokoro` is necessary because `salamander` declares `tts_kokoro: path: ../tts_kokoro`. In offline or containerized environments, explicitly declaring `tts_kokoro` prevents `shards` from attempting any remote git fetches.
4. Test compilation was verified directly:
   `CRYSTAL_PATH="$(crystal env CRYSTAL_PATH):../mantle/src:../salamander/src:../tts_kokoro/src" crystal eval 'require "mantle"; require "salamander"; puts Mantle::Log; puts Salamander::VERSION'`
   Success: emitted Mantle's logger and Salamander `0.2.0` with zero compile errors.

### 3.2 Framework Consumption vs. Enhancements Assessment

#### A. Mantle Evaluation
1. **Can Mantle be consumed as-is?**
   - **Yes, for core execution**: `Mantle::Step`, `Mantle::Message`, `Mantle::Tools::Tool`, `Mantle::Clients::Client`, and `Mantle::Clients::OllamaClient` can all be consumed directly.
2. **Context & Storage (R2)**:
   - NIGHTMARE requires an ephemeral, in-memory context engine with turn-unit sliding window and pristine RAM transcript (`Nightmare::Context::SlidingStore`, `Nightmare::Context::Turn`).
   - Mantle's `ContextManager` requires `@memory_store : JSONLayeredMemoryStore` (which expects a disk file path).
   - Because NIGHTMARE's `StepRunner` directly wraps `Mantle::Step` rather than `Mantle::Session` or `Mantle::ContextManager`, NIGHTMARE does not need to touch `JSONLayeredMemoryStore`.
   - *Optional Enhancement*: If `Mantle::Storage::ContextManager` were ever to be used by NIGHTMARE, a backward-compatible enhancement would be making `@memory_store` optional or providing a `NullMemoryStore` / in-memory store. However, because NIGHTMARE builds its own `SlidingStore` as specified in ARCHITECTURE.md, this is not strictly required.
3. **In-Turn Shedding (R2) & `Mantle::Step` Multi-Turn Tool Loop**:
   - In `Mantle::Step#run`, `working_messages = messages.dup` is looped internally.
   - When multiple tools are invoked in a single turn, intermediate tool outputs are appended directly to `working_messages`.
   - NIGHTMARE's R2 requires: *"When approaching token limits during multi-step tool iterations, truncate older consumed tool results within the active turn while preserving the last 2 verbatim."*
   - In `Mantle::Step`, there is currently no callback hook executed between iterations inside `Step#run`.
   - *Recommended Backward-Compatible Enhancement to Mantle*:
     Add an optional hook property to `Mantle::Step`:
     ```crystal
     property before_iteration : Proc(Array(Mantle::Message), Int32, Nil)? = nil
     ```
     Called at the top of the loop in `Step#run`:
     ```crystal
     @before_iteration.try &.call(working_messages, iteration)
     ```
     This is 100% backward-compatible (defaults to `nil`), requires 3 lines in `mantle/src/mantle/steps/step.cr`, and allows NIGHTMARE's `StepRunner` to inspect `working_messages` and perform in-turn shedding on older consumed tool results while keeping the last 2 verbatim.
   - Alternatively, NIGHTMARE's tool handlers can truncate their individual return values if the single return value exceeds the threshold, or `StepRunner` can implement its own single-iteration stepping loop. The hook enhancement is the cleanest and preserves full fidelity.

#### B. Salamander Evaluation
1. **Can Salamander be consumed as-is?**
   - **Yes**: `Salamander::ChatSession`, `Salamander::UI`, `Salamander::UI::MarkdownFormatter`, and `Salamander::Menu` can all be consumed as-is.
2. **Signal Handling (R5)**:
   - `Salamander::WaybarNotifier#start` installs a default `Signal::INT.trap { exit }`.
   - NIGHTMARE requires `Ctrl+C` to roll back the current turn and restore the user prompt without exiting the REPL.
   - NIGHTMARE simply needs to install its custom signal trap:
     ```crystal
     Signal::INT.trap do
       Nightmare::UI::Signals.handle_interrupt
     end
     ```
     Because Crystal allows signal handlers to be overridden at runtime, installing NIGHTMARE's handler after initializing the UI seamlessly satisfies R5 with zero modifications to Salamander.
3. **Line Editing**:
   - `Salamander::UI#ask_user` provides standard `gets`.
   - For slash command handling, prompt editing, and pasting, NIGHTMARE's `Nightmare::UI::Terminal` can wrap input reading or extend line editing as needed.

---

## 4. Summary Matrix of Requirements & Framework Mapping

| Nightmare Requirement | Framework Component | Direct Fit or Adaptation |
| :--- | :--- | :--- |
| **R1. Workspace & Central XDG** | Pure Nightmare (`Nightmare::Workspace`) | Independent; no framework modifications needed |
| **R2. In-Memory Context Engine** | `Nightmare::Context::SlidingStore` using `Mantle::Message` | Custom in-memory store feeding `Mantle::Step` |
| **R2. In-Turn Shedding** | `Mantle::Step` | Recommended minor 3-line hook in `Mantle::Step` (`before_iteration`) |
| **R3. Sandboxed Tool Suite** | `Mantle::Tools::Tool`, `FunctionDefinition` | Native fit; Nightmare tools return `Mantle::Tools::Tool` structs |
| **R4. Result Sum Type** | `Nightmare::Harness::Result(T)` wrapping `Mantle::StepResult` | Nightmare defines sum type `Success(T) \| Failure` |
| **R4. Backoff & Retries** | `Nightmare::Harness::Retrier` wrapping `Mantle::Step` | Harness applies backoff on `Mantle::StepError::RateLimited` |
| **R5. Token Streaming & Think Stripping** | `Salamander::ChatSession` | 100% native fit (`process_chunk`, `thinking_log`) |
| **R5. Spinner & Lifecycle** | `Salamander::UI#spin_while` + `Mantle::Step#on_status` | 100% native fit (`:evaluating`, `:thinking`, `:responding`) |
| **R5. ANSI Markdown Formatting** | `Salamander::UI::MarkdownFormatter` | 100% native fit (`format`, code block protection) |
| **R5. Ctrl+C Turn Rollback** | `Signal::INT.trap` override | Overrides `WaybarNotifier` default trap cleanly in application |
| **R6. Path Linking** | `shard.yml` with `path: ../mantle`, `path: ../salamander` | Verified cleanly with `CRYSTAL_PATH` and shards |
