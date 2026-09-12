# NIGHTMARE: System Architecture & Technical Specification

Module boundaries, data flows, type contracts, and the stochastic-to-deterministic boundary. CONOPS, tenets, requirements (R1–R6), operator-visible behaviour, the command reference, and the MVP boundary live in [`DESIGN.md`](DESIGN.md).

Target: Ollama local inference only. Frameworks: `mantle` (inference, tool loop), `salamander` (terminal UI), both first-party path-linked shards. `tts_kokoro` is a transitive requirement of `Salamander::Terminal` and is always constructed as `nil`.

---

## 1. Module Hierarchy & Namespaces

```
Nightmare
├── CLI                           # ARGV parsing, flag extraction, entrypoint
├── Workspace                     # Canonical root resolution, XDG directory mapping, banner
├── SystemPrompt                  # Precedence resolution, in-memory editor buffer
├── Context
│   ├── SlidingStore              # In-memory turn-unit FIFO context store
│   ├── Shedder                   # In-turn & historical tool output compressor
│   ├── TokenEstimator            # Self-calibrating characters-to-tokens estimator
│   └── PinnedFiles               # Live-disk-re-read pinned working set manager
├── Transcript                    # Pristine un-pruned human transcript (incremental writer + /save)
├── Tools
│   ├── Registry                  # Tool definitions and argument validation schemas
│   ├── Guard                     # Path containment, protected paths, output caps
│   ├── ReadOnly                  # list_files, search, read_file, file_info
│   ├── Mutation                  # replace_in_file, append_to_file, write_file (diff modal)
│   ├── Shell                     # run_command, argv tokenizer, pgid supervisor, allowlists
│   └── Delegation                # ask_model (isolated, stateless one-shot inference)
├── Harness
│   ├── ToolLoop                  # on_iteration hook: capture, calibrate, shed
│   ├── StepRunner                # Mantle::Step construction + Result boundary
│   ├── Types                     # StepOutcome(T) sum type, StepError records
│   ├── Retrier                   # Exponential backoff and schema format retrier
│   └── LoopDetector              # Repeated (tool, args) invocation breaker
├── UI
│   ├── Terminal                  # Salamander::Terminal wrapper, dimensions
│   ├── Prompt                    # Line-mode REPL input, multi-line /paste mode
│   ├── Approval                  # Diff & command approval modals (line mode)
│   ├── StreamController          # Streaming chunk callback, spinner, <think> isolation
│   └── Cancellation              # Cooperative interrupt
└── Commands                      # Slash command router (/clear, /cls, /drop, /save, etc.)
```

---

## 2. Framework Contracts

### 2.1 `Mantle::Step` and the `on_iteration` hook

`Mantle::Step#run` treats `messages` as immutable input, copies it into a local `working_messages`, appends assistant-with-`tool_calls` and `tool` messages across iterations, and returns a `StepResult(String, StepError)` carrying `value`, `thinking`, `iterations`, `raw_response`. The working buffer is otherwise invisible to the caller, and there is no cancellation or abort hook on `Client#execute` or `Step#run`.

`Mantle::Step` is extended with an additive, default-`nil` per-iteration hook (`mantle` TKT-008):

```crystal
# Mantle::Step#initialize — optional property
@on_iteration : Proc(Array(Mantle::Message), Mantle::Clients::Response?, Array(Mantle::Message))? = nil

# Mantle::Step#run — immediately before each client.execute
if hook = @on_iteration
  working_messages = hook.call(working_messages, last_response)
end
```

The hook is a pure insertion; `Step`'s existing control flow is not refactored. It rewrites `Step`'s local ephemeral buffer only — `messages` stays immutable input and the canonical context graph is untouched. It supplies:

| Need | Mechanism |
| :--- | :--- |
| In-turn shedding | Rewrite `working_messages` before the call |
| Message-exact `Turn` (§3.2) | The hook observes the real assistant messages; no synthesis |
| Cumulative token anchor | `last_response.prompt_eval_count` is the exact size of everything but the new delta |
| Per-turn spend cap | Accumulate `eval_count` across iterations |

`Mantle::Step` is the execution path for the primary turn, for one-shot `ask_model` delegation, and for the format-correction retry. `Harness::ToolLoop` is a thin policy layer owning the hook closure, the `LoopDetector`, approval routing, and the `StepOutcome` boundary — not a reimplementation of the loop.

Known limit: a provider length rejection propagates out of `Step#run` and the loop position is lost, so `ContextOverflow` recovery sheds and re-runs the whole turn rather than retrying the single failed call.

Shedding and turn capture are blocked on TKT-008. `TokenEstimator`, `PinnedFiles`, `Transcript`, and the `Turn`/`ToolExchange` data models do not depend on it.

### 2.2 `Mantle::Message`

```crystal
struct Message
  property role : String
  property content : String?
  property tool_calls : Array(Mantle::Clients::ToolCall)?
  property tool_call_id : String?
end
```

- It is a **struct**: `array[i].content = x` mutates a temporary copy and silently no-ops. Every in-place message edit must write back (§3.2).
- There is no field for provider-native reasoning blocks or signatures. Mantle models thinking as `String?` on `Response`, extracted from `<think>` tags by `Response#initialize` via `Mantle::Support::Text.extract_thinking`.
- `Message#initialize`'s third positional parameter is `tool_calls`; `tool_call_id:` is keyword-only.
- Mantle ships one concrete client, `OllamaClient`, plus the `LoggingClient(T)` decorator.

### 2.3 `Mantle::StepError` / `StepResult`

```crystal
enum Mantle::StepError
  MalformedOutput
  MaxIterationsReached
  ClientFailure
  ToolExecutionFailure
  RateLimited

  def retryable? : Bool   # client_failure? || rate_limited?
  def terminal? : Bool
end

class Mantle::StepResult(T, E)
  property value, error, thinking, iterations, raw_response
  def ok? ; def err? ; def unwrap
end
```

### 2.4 Token accounting

`Mantle::Clients::Response` exposes `prompt_eval_count : Int32?` and `eval_count : Int32?` (Ollama naming), plus `done_reason`, `truncated?`, `thinking_only?`, `truncated_in_thinking?`. Both counts are nilable; the estimator must tolerate absence on every turn and never divide by zero or nil.

### 2.5 Salamander terminal

`Salamander::UI#ask_user` is `print prompt; gets`. There is no termios handling, keypress reader, or raw mode. `Salamander::Terminal.run` wraps a `WaybarNotifier` and an optional `TtsKokoro::TTS` and yields a `UI` toolbelt (spinner control, `stream_text`, `terminal_width`, `clear_line`, markdown formatting). `Salamander::ChatSession#process_chunk` runs the `<think>` state machine.

Consequences:

- The terminal stays in cooked mode, so `Ctrl+C` raises a real `SIGINT`. A Crystal signal handler runs on the signal-handling fiber and cannot unwind the streaming fiber, so cancellation is cooperative (§5, Pipeline 5).
- **Approval modals are line mode.** Type the letter and press Enter; empty input is the `[N]` default. No single-keypress input, no termios work. Modal prompt text must read as a line prompt.
- `<think>` is stripped twice — by `Response#initialize` for the non-streaming result and by `ChatSession#process_chunk` for the live stream. `StreamController` owns display; `Response#thinking` owns `/thinking`.

---

## 3. Core Data Types & Contracts

### 3.1 Stochastic boundary sum type

Crystal has no generic aliases, so the boundary is one generic class with a nil-discriminated payload.

```crystal
module Nightmare::Harness
  enum StepErrorKind
    MaxIterationsReached   # iteration cap hit (§7 MAX_ITERATIONS)
    RateLimited            # provider 429; Retrier applies backoff+jitter
    ClientFailure          # transport / API failure
    MalformedOutput        # unparseable or empty completion
    ToolExecutionFailure   # tool handler raised a terminal error
    ExecutionTimeout       # tool/subprocess exceeded its timeout
    Cancelled              # user interrupt; a first-class outcome, not a failure
    ContextOverflow        # provider rejected request for length
    SpendCapExceeded       # per-turn token/cost cap hit (§7)
  end

  record StepError,
    kind : StepErrorKind,
    message : String,
    retryable : Bool = false

  class StepOutcome(T)
    getter value : T?
    getter error : StepError?
    getter thinking : String?
    getter iterations : Int32
    getter prompt_tokens : Int32?   # from Response#prompt_eval_count

    def self.success(value : T, thinking = nil, iterations = 0, prompt_tokens = nil)
    def self.failure(error : StepError, thinking = nil, iterations = 0, prompt_tokens = nil)

    def ok? : Bool
    def err? : Bool
    def cancelled? : Bool
    def unwrap : T        # raises on err?
  end

  alias TurnOutcome = StepOutcome(String)
end
```

Mapping from `Mantle::StepError` (the `ask_model` and format-retry paths):

| `Mantle::StepError` | `StepErrorKind` |
| :--- | :--- |
| `MalformedOutput` | `MalformedOutput` |
| `MaxIterationsReached` | `MaxIterationsReached` |
| `ClientFailure` | `ClientFailure` |
| `ToolExecutionFailure` | `ToolExecutionFailure` |
| `RateLimited` | `RateLimited` |

`Cancelled`, `ContextOverflow`, `ExecutionTimeout`, and `SpendCapExceeded` originate in NIGHTMARE.

**`Cancelled` is not a failure path.** A cancelled turn rolls back (Pipeline 5), keeps its side-effect note, and returns control to the prompt. It is not logged as an error, does not trigger the `Retrier`, and does not count against any failure budget.

**`ContextOverflow` is the reactive backstop.** On a provider length rejection (HTTP 400, `context_length_exceeded`-class body), `ToolLoop` runs an emergency shed → prune cycle against the assembled message array and retries once. Only if the retry also overflows does it surface.

### 3.2 Context & turn representations

`Turn` holds the exact ordered message sequence as sent and received — tool-call grouping and interleaved assistant text preserved verbatim. `ToolExchange` is an index-based view over it.

```crystal
module Nightmare::Context
  # Atomic Turn Unit: pruned together, never split.
  # `messages` is the exact ordered wire sequence for this turn:
  #   [user] ([assistant(+tool_calls, maybe +content)] [tool]+)* [assistant]
  class Turn
    getter messages : Array(Mantle::Message)
    getter exchanges : Array(ToolExchange)   # views into @messages
    property prompt_tokens : Int32?          # Response#prompt_eval_count for this turn
    property started_at : Time
    property interrupted : Bool = false
    property side_effects : Array(String)    # paths mutated; see Pipeline 5

    def initialize(user_message : Mantle::Message)
      @messages = [user_message]
      @exchanges = [] of ToolExchange
      @side_effects = [] of String
      @started_at = Time.utc
    end

    def user_message : Mantle::Message
      @messages.first
    end

    def append_assistant(msg : Mantle::Message) : Nil
    def append_tool_result(call : Mantle::Clients::ToolCall, content : String, raw_size : Int32) : ToolExchange

    def complete? : Bool
      (last = @messages.last?) && last.role == "assistant" && last.tool_calls.nil?
    end

    # Invariant, asserted after every mutation and every prune:
    # every tool_call id in an assistant message has exactly one following
    # tool message with the matching tool_call_id, and every tool message's
    # tool_call_id refers to a preceding assistant tool_call in the same turn.
    def well_formed? : Bool
  end

  class ToolExchange
    getter turn : Turn
    getter index : Int32                     # position in turn.messages
    getter call : Mantle::Clients::ToolCall
    getter raw_size_bytes : Int32
    getter? shed : Bool = false

    def result_message : Mantle::Message
      @turn.messages[@index]
    end

    def shed!(keep_chars : Int32 = 200) : Nil
      return if @shed
      msg = @turn.messages[@index]
      content = msg.content || ""
      return if content.size <= keep_chars
      msg.content = "#{content[0, keep_chars]}\n[... output truncated: was #{@raw_size_bytes} bytes]"
      @turn.messages[@index] = msg     # WRITE-BACK — required
      @shed = true
    end
  end
end
```

Two safe forms for editing a struct message:

- **Inside `Turn`** — index write-back, as in `shed!`. `ToolExchange` holds positional indices, so array length and ordering must stay stable.
- **At the Mantle hook boundary** — `#map`. `on_iteration` returns a new array by contract.

```crystal
working_messages.map do |msg|
  if shed_target?(msg)
    Mantle::Message.new("tool", truncated, tool_call_id: msg.tool_call_id)
  else
    msg
  end
end
```

Dropping the `tool_call_id:` keyword breaks pair integrity.

### 3.3 Pinned files

```crystal
module Nightmare::Context
  class PinnedFile
    getter path : String                     # workspace-relative, as displayed
    getter slice_start : Int32?              # 1-based, inclusive
    getter slice_end : Int32?                # 1-based, inclusive
    property cached_mtime : Time?
    property cached_tokens : Int32?

    # Root containment belongs to Tools::Guard.resolve_read (§4.1), which
    # raises SecurityError outside @root or on a sensitive pattern.
    def read_content(guard : Tools::Guard) : String
      full = guard.resolve_read(@path)
      lines = File.read_lines(full)
      s, e = @slice_start, @slice_end
      return lines.join("\n") if s.nil? || e.nil?
      lo = Math.max(s - 1, 0)
      hi = Math.min(e - 1, lines.size - 1)
      return "" if lo > hi                   # clamp; never raise on a stale slice
      lines[lo..hi].join("\n")
    end
  end
end
```

`/add` rejects a file whose estimated tokens would push the pinned set over `PINNED_BUDGET_RATIO` of `TOKEN_HARDMAX`, with a descriptive error, and does not add it.

### 3.4 Workspace mapping manifest

```crystal
module Nightmare::Workspace
  class Manifest
    include JSON::Serializable

    property id : String
    property canonical_path : String
    property created_at : Time
    property last_accessed : Time

    def touch : Nil
    def save(path : String) : Nil
    def self.load_or_create(path, id, canonical_path) : Manifest
  end
end
```

It is a **class**, not a struct: `env.manifest.touch` on a struct mutates a copy.

**Slug sanitization:** `File.basename(@root).gsub(/[^a-zA-Z0-9_-]/, "_")`, with `"root"` substituted for an empty, `"/"`, or all-underscore result. The SHA-256 suffix preserves uniqueness.

---

## 4. Tool Surface: Guards & Execution

### 4.1 `Tools::Guard` — containment and caps

1. **Nonexistent targets resolve through their nearest existing ancestor.** `File.realpath` fails on a nonexistent path, so `write_file` for a new file walks up to the nearest existing ancestor, `realpath`s that, and re-joins the remaining components (`Environment#resolve_contained_path`).
2. **Prefix check is `root + "/"`, not `root`** — `starts_with?(@root)` accepts `/home/x/proj-evil` for root `/home/x/proj`. `Environment#path_inside_root?` compares against `"#{@root}/"` and separately allows exact equality with `@root`.
3. **Protected paths — mutation tools refuse unconditionally.** Checked on workspace-relative paths after resolution:

   | Pattern | Rationale |
   | :--- | :--- |
   | `.git` and `.git/**` | R3 requirement; repository integrity |
   | `.nightmare/**` | Tier-2 system prompt source; prompt-injection persistence |
   | `.nightmare*` (any sibling) | Reserved namespace |

   Violations return a tool failure (`[Refused: <path> is a protected path]`), never an approval modal. They are not approvable.
4. **Sensitive-read patterns** for `read_file`, `search`, `list_files`: `.env*`, `*.pem`, `id_rsa*`, `*secret*`, `*credential*`, `.git/*`.
5. **Output caps at the tool boundary.** Every tool returns at most `TOOL_OUTPUT_MAX_BYTES` (§7). A capped result ends with `[... truncated at N bytes; call read_file with offset=X limit=Y for more]`.

### 4.2 `Tools::Shell` — argv execution

`run_command` executes via argv, never `sh -c`. Pipes and redirects do not work. Shell features, if ever required, belong behind a separate explicitly-approved, never-auto-approvable `run_shell` tool.

- **Tokenization.** The model's command string is tokenized with POSIX-style quoting rules into argv. Tokenization failure (unbalanced quotes) is a tool failure, never a fallback to shell.
- **Metacharacter ban.** `;`, `&`, `|`, `` ` ``, `$`, `>`, `<`, newline, `(`, `)`, `{`, `}`, `\`, `*` in the raw string bar auto-approval and force the interactive modal. Under argv these characters are inert; the ban is a UX guard against silently-wrong execution plus defense in depth, and is mandatory per R3.
- **Allowlist matches on tokens.** A pattern matches `argv[0]`'s basename plus, where applicable, `argv[1]` as a subcommand — e.g. `git status`, `crystal spec`. Raw-string regexes are not the matching surface.
- **Flag denylist overrides any allowlist.** These force the modal regardless of allowlist state: `-c`, `-e`, `--exec*`, `--eval*`, `-C`, `--config`, `--upload-pack`, `--receive-pack`, and any token containing `=` before the first non-flag argument.
- **`[a]` and `[p]` record token patterns.** `[a]` stores the exact argv; `[p]` derives `argv[0] + argv[1]` as a prefix. Neither may be recorded for a command that tripped the metacharacter ban.

### 4.3 Subprocess guardrails

- **Process group.** Crystal's `Process` has no process-group option. A pgid is established explicitly via `LibC.setpgid(0, 0)` post-fork or by launching under `setsid -w`. Without it, `Process.kill(Signal::KILL, -pgid)` has no group to signal and orphans survive a timeout.
- **Termination ladder.** `SIGTERM` → `PROCESS_GRACE_PERIOD` → `SIGKILL`, both to `-pgid`.
- **Concurrent output drain.** stdout and stderr are drained concurrently into capped buffers; reading one pipe to EOF while the other fills deadlocks the child. Each stream caps at `TOOL_OUTPUT_MAX_BYTES / 2` with a truncation marker.
- **stdin** is `/dev/null`. **cwd** is `@root`.
- **Environment additions:** `GIT_TERMINAL_PROMPT=0`, `CI=1`, `PAGER=cat`, `GIT_PAGER=cat`, `NO_COLOR=1`, `TERM=dumb`.
- **Timeout** defaults to `DEFAULT_COMMAND_TIMEOUT`, capped at `MAX_COMMAND_TIMEOUT` (§7).

---

## 5. Data Flows & Pipelines

### Pipeline 1: Boot & workspace resolution

```text
Dir.current
   │
   ▼
File.realpath(Dir.current) ──> @root (cached immutable anchor)
   │
   ▼
Compute: slug = sanitize(basename(@root)), hash = sha256(@root)[0..7]
   │
   ▼
Workspace ID: "#{slug}-#{hash}"
   ├── Config Dir : $XDG_CONFIG_HOME/nightmare/workspaces/#{id}/
   ├── State Dir  : $XDG_STATE_HOME/nightmare/workspaces/#{id}/
   └── Cache Dir  : $XDG_CACHE_HOME/nightmare/workspaces/#{id}/
   │
   ▼
Bootstrap workspace.json if absent; touch last_accessed
   │
   ▼
STDOUT notification banner emitted
```

### Pipeline 2: Prompt assembly (live re-read)

```text
1. Active System Prompt Block (CLI flag > repo .nightmare/prompt.md > XDG workspace > XDG global > default)
2. Pinned Files Block:
     For each pinned path: re-read via Tools::Guard.resolve_read, format as
       === PINNED FILE: #{path} ===\n#{content}
3. Turn-Unit Sliding Window:
     Concatenate completed historical turns by SPLATTING Turn#messages in order.
     No reconstruction, no synthesis — the stored sequence IS the wire format.
4. Current In-Flight Turn:
     Turn#messages as-is (shed tool messages already rewritten in place).
```

Block order is system prompt → pinned files → history. Pinned files are re-read every turn, so editing a pinned file invalidates the prompt cache for the history behind it. This cost is accepted: live file state must not sit below stale tool results.

### Pipeline 3: In-turn tool loop & shedding

Every loop iteration re-sends the entire accumulated message array, so context grows *within* a turn. Turn-unit pruning cannot help — there may be no completed turns, and the bloat is in the executing turn. A tool result also cannot be deleted: every `tool` message must pair with a `tool_call` id in a preceding assistant message. Shedding keeps the message and its `tool_call_id` and rewrites only its `content`:

```text
tool(id: call_3): "src/config.cr:1: require \"json\"\nmodule Config\n  ...4 KB..."
                   ↓  shed!
tool(id: call_3): "src/config.cr:1: require \"json\"\nmodule Config\n  class Settings
                   [... output truncated: was 4096 bytes]"
```

Two constraints bound it:

- **Last `SHED_KEEP_VERBATIM` consumed results stay verbatim** — the model's active working set.
- **Only *consumed* results are shed.** Consumed means the model has already observed the result and emitted a subsequent tool call.

The pristine `Transcript` (§6) captures every message at append time, so shedding is invisible to `/save` and to the user.

The loop is driven by `Mantle::Step`, with `Harness::ToolLoop` supplying the `on_iteration` hook (§2.1), which is where the predictive check and shedding happen.

```text
Harness::StepRunner
   │  builds Mantle::Step with tools = Tools::Registry definitions
   │  and on_iteration = ToolLoop#on_iteration closure
   ▼
Mantle::Step#run(assembled_messages) { |chunk| StreamController.on_chunk }
   │
   │   ┌──────────────── per iteration, inside Mantle::Step ────────────────┐
   │   │                                                                    │
   ├───┤ on_iteration.call(working_messages, last_response)  [NIGHTMARE]     │
   │   │    ├── ToolLoop mirrors working_messages into turn.messages         │
   │   │    │   (message-exact capture: grouping + interleaved content)      │
   │   │    ├── turn.prompt_tokens = last_response.prompt_eval_count         │
   │   │    ├── TokenEstimator.calibrate!(assembled_chars, prompt_eval_count)│
   │   │    ├── spend += last_response.eval_count                            │
   │   │    │     > TURN_SPEND_CAP_TOKENS ──> StepErrorKind::SpendCapExceeded│
   │   │    ├── cancel flag set? ──> raise Cancelled (Pipeline 5)            │
   │   │    │                                                                │
   │   │    └── PREDICTIVE CHECK:                                            │
   │   │          estimated = last_prompt_tokens + estimate(delta)           │
   │   │          > token_hardmax * SHED_TRIGGER_RATIO                       │
   │   │                                ──> Shedder.shed_active_turn!        │
   │   │          > token_hardmax        ──> Shedder.prune_history!          │
   │   │          returns the rewritten working_messages                     │
   │   │                                                                     │
   │   │ client.execute(working_messages)                                    │
   │   │    ├── cancel flag set? ──> on_chunk raises Cancelled               │
   │   │    ├── 429 ──> Retrier: exponential backoff + jitter                │
   │   │    └── 400 length rejection ──> propagates out of Step#run;         │
   │   │          StepRunner sheds + prunes and re-runs the turn ONCE,       │
   │   │          then StepErrorKind::ContextOverflow                        │
   │   │                                                                     │
   │   │ tool_calls present? ──> Step invokes NIGHTMARE tool handlers:       │
   │   │    ├── LoopDetector.check(tool, args)                               │
   │   │    │     same (tool, args) LOOP_DETECT_THRESHOLD times in a turn    │
   │   │    │     ──> return refusal string, DO NOT EXECUTE:                 │
   │   │    │        "[Refused: identical call repeated N times. Change      │
   │   │    │         approach or ask the user.]"                            │
   │   │    ├── Tools::Guard ──> protected path? refuse (§4.1)               │
   │   │    ├── Approval required? ──> UI::Approval modal (Pipeline 4)       │
   │   │    ├── Execute; cap output at the tool boundary (§4.1)              │
   │   │    └── record mutated paths in turn.side_effects                    │
   │   │       │                                                             │
   │   │       └── Step appends the tool message and loops                   │
   │   │             iteration > MAX_ITERATIONS ──> MaxIterationsReached     │
   │   │             (completed tool results are PRESERVED; turn commits)    │
   │   └─────────────────────────────────────────────────────────────────────┘
   ▼
StepResult(String, Mantle::StepError)  ──>  mapped to StepOutcome(String) (§3.1)
   │
   └── on success: commit Turn to SlidingStore & Transcript (incremental append)
```

Ownership: `Mantle::Step` owns `working_messages` during the loop; `turn.messages` is a mirror the hook copies out. Shedding mutates the array the hook returns, which is what `Step` sends — that is the mechanism by which shedding reaches the wire.

**`Shedder.shed_active_turn!`:** walk `turn.exchanges` oldest-first, `shed!` each consumed exchange, preserving the last `SHED_KEEP_VERBATIM` verbatim, stopping as soon as the estimate is back under `SHED_TRIGGER_RATIO`. The user message is never shed. No message is removed, so `well_formed?` holds by construction.

**`Shedder.prune_history!`:** Phase 1 sheds tool messages in completed historical turns, oldest-first. Phase 2, only if still over budget, evicts the entire oldest completed turn — all of its `messages` together. Never the active turn; never a partial turn. `well_formed?` is re-asserted across the assembled array after every prune.

### Pipeline 4: Interactive approval & execution boundary

```text
Tool Invocation: run_command or a mutation tool
   │
   ├── Tools::Guard: outside @root? protected path? ──> REFUSE (no modal, not approvable)
   │
   ├── Mutation on Existing File?
   │      └── Generate unified diff in RAM
   │          Render diff modal; read line-mode input: y / [N] / a
   │
   └── Shell Execution (run_command)?
          │
          ├── Tokenize to argv (failure ──> tool failure)
          │
          ├── Raw string contains [;&|`$><\n(){}\\*]?
          │      YES ──> Force Interactive Modal (metacharacter ban; §4.2)
          │
          ├── Flag denylist hit (-c, -e, --exec*, --eval*, -C, --config, k=v)?
          │      YES ──> Force Interactive Modal (overrides allowlist)
          │
          ├── argv[0]+argv[1] matches session or persisted allowlist?
          │      YES ──> Execute Autonomously
          │      NO  ──> Approval Modal: y / [N] / e / a / p
          │
          └── Execute in Process Group (§4.3):
                 - pgid via setpgid post-fork
                 - chdir @root; stdin /dev/null
                 - env: GIT_TERMINAL_PROMPT=0 CI=1 PAGER=cat GIT_PAGER=cat
                        NO_COLOR=1 TERM=dumb
                 - concurrent capped drain of stdout+stderr
                 - timeout: SIGTERM(-pgid) -> grace -> SIGKILL(-pgid)
```

### Pipeline 5: Cooperative cancellation & turn rollback

```text
User presses Ctrl+C
   │
   ▼
Signal::INT.trap  (cooked mode delivers a real SIGINT — §2.5)
   │   Handler does the MINIMUM safe work: send to cancel_channel, set a flag.
   │   It never unwinds a fiber and never touches the context store.
   ▼
Consumers poll/select cooperatively:
   ├── Tool subprocess running?   ──> SIGTERM(-pgid) -> grace -> SIGKILL(-pgid)
   ├── LLM stream active?         ──> on_chunk raises Cancelled on next chunk;
   │                                  ToolLoop rescues it. Mantle exposes no
   │                                  abort hook, so a stream that has stopped
   │                                  producing chunks cannot be interrupted
   │                                  until it times out.
   └── Between iterations?        ──> checked before each inference call
   │
   ▼
Roll back the active Turn: drop turn.messages entirely.
   No partial assistant tool_calls, no unpaired tool results.
   │
   ▼
ROLLBACK DOES NOT UNDO SIDE EFFECTS. Files were written; commands ran.
   If turn.side_effects is non-empty, prepend a note to the NEXT user message:
     [Previous turn was interrupted after modifying: a.cr, b.cr]
   │
   ▼
Transcript records the interruption and the side-effect list (never rolled back).
Restore the user's input text to the REPL prompt line for editing.
```

Two `Ctrl+C` in rapid succession at an empty prompt exits, as does `/exit` or EOF. A single `Ctrl+C` never terminates the session.

---

## 6. Persistence Subsystem **[R2, R7]**

- **Config**: `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/`
  - `workspace.json` — metadata linking workspace ID to `@root` (inhibited in ghost mode)
  - `prompt.md` — per-workspace system prompt
  - `allow` — persisted shell allowlist (token patterns; §4.2)
- **State & Logs**: `$XDG_STATE_HOME/nightmare/workspaces/<workspace_id>/`
  - `llm_calls.jsonl` — audit log of raw prompts, completions, latency. Rotates at 20 MB, 3 retained. Completely disabled by `--no-logs` or system configuration.
  - `transcript.md` — incrementally appended pristine transcript (disk appends completely disabled by `--no-logs` or system configuration; RAM-only in ghost mode).
- **Cache**: `$XDG_CACHE_HOME/nightmare/workspaces/<workspace_id>/`
  - `calibrator.json` — persisted token divisor (inhibited in ghost mode)

Zero files are written inside `@root`. `.nightmare/prompt.md`, if present, is read-only to NIGHTMARE and to the model (§4.1).

`Transcript` appends each message to `transcript.md` as it is produced, `O_APPEND` and line-oriented, flushed per turn, with an in-memory mirror retained for `/save` and `/review`. When logging is disabled via `--no-logs` or system configuration, `Transcript` operates in memory-only mode and writes zero files to disk.

`/save [path]` copies the pristine, un-shed, un-pruned history to the requested path on demand.

### Logging Control, Ghost Mode & Anti-Exfiltration Guarantees **[R7, D6]**
- **Complete Log Suppression**: Passing `--no-logs` (or `--no-log`) suppresses all disk logs (`llm_calls.jsonl`) and incremental transcript appends (`transcript.md`), eliminating data exfiltration risks for sensitive code/prompts.
- **Ghost Mode Zero Footprint**: Under `--no-logs`, NIGHTMARE leaves zero footprint under `$XDG_CONFIG_HOME`, `$XDG_STATE_HOME`, and `$XDG_CACHE_HOME` (inhibiting `workspace.json`, bootstrapped `config.json`, and `calibrator.json`). All transient state runs in RAM.
- **System-Level Configuration**: Setting `"logging": false` in `config.json` allows permanent suppression at a system/workspace level without CLI flags. Observability remains enabled by default.

---

## 7. Configuration Constants

All live in `Nightmare::Config` with per-workspace overrides in `$XDG_CONFIG_HOME/nightmare/config.json`.

| Constant | Default | Notes |
| :--- | :--- | :--- |
| `TOKEN_HARDMAX` | `12_000` | Sized for the 8k–32k local models Ollama serves |
| `SHED_TRIGGER_RATIO` | `0.85` | In-turn shedding threshold |
| `PINNED_BUDGET_RATIO` | `0.60` | `/add` rejection threshold |
| `TURN_SOFT_CAP` | `10` | Completed turns retained before FIFO eviction |
| `SHED_KEEP_CHARS` | `200` | Retained prefix on a shed tool result |
| `SHED_KEEP_VERBATIM` | `2` | Most-recent consumed results kept intact |
| `INITIAL_DIVISOR` | `3.5` | chars/token at boot |
| `DIVISOR_ALPHA` | `0.2` | `d' = 0.8·d + 0.2·(chars / prompt_eval_count)` |
| `DIVISOR_CLAMP` | `[1.0, 10.0]` | Guards against a pathological single sample |
| `MAX_ITERATIONS` | `15` | Tool iterations per turn; completed results preserved on cap |
| `RATE_LIMIT_RETRIES` | `3` | Exponential backoff with jitter |
| `FORMAT_RETRIES` | `1` | Single format-correction turn |
| `CONTEXT_OVERFLOW_RETRIES` | `1` | After emergency shed + prune |
| `LOOP_DETECT_THRESHOLD` | `3` | Identical `(tool, args)` calls before refusal |
| `TURN_SPEND_CAP_TOKENS` | `200_000` | Cumulative prompt+completion tokens in one turn → `SpendCapExceeded` |
| `DEFAULT_COMMAND_TIMEOUT` | `60s` | |
| `MAX_COMMAND_TIMEOUT` | `600s` | Hard cap |
| `PROCESS_GRACE_PERIOD` | `2s` | SIGTERM → SIGKILL interval |
| `TOOL_OUTPUT_MAX_BYTES` | `65_536` | Per-tool output cap; split across stdout/stderr for `run_command` |
| `logging` (Setting) | `true` | System/workspace setting in `config.json`. When `false` or `--no-logs`, disables disk audit logs and disk transcripts; ghost mode suppresses XDG config/cache footprints. |

---

## 8. Stochastic vs. Deterministic Boundary Matrix

| Operation | Nature | Deterministic Guard / Invariant | Failure Mode Encapsulation |
| :--- | :--- | :--- | :--- |
| **Audit Logging & State Persistence** | Deterministic | When `--no-logs` is passed or `logging: false` is configured, file sinks for `llm_calls.jsonl`, `transcript.md`, and XDG manifest/cache files are bypassed entirely. | Disk I/O avoided; zero possibility of file-permission failures or disk exfiltration. |
| **Primary Turn LLM Stream** | Stochastic | `Mantle::Step` drives the loop; `Harness::ToolLoop` supplies the `on_iteration` hook that captures and rewrites the working buffer (§2.1). `Salamander::ChatSession` strips `<think>` from the live stream; `Response#thinking` carries the reasoning log for `/thinking`. | Client failure → `ClientFailure`. 429 → `RateLimited`, exponential backoff with jitter. Length rejection → `ContextOverflow`, emergency shed + one turn re-run. |
| **Structured Output Parsing** | Stochastic | Typed boundary parses the raw completion immediately into a Crystal type. | Schema failure → `MalformedOutput`. Harness triggers a single format-correction retry, then returns typed error. |
| **Model Delegation (`ask_model`)** | Stochastic | Stateless one-shot via `Mantle::Step` with **no** `on_iteration` hook (same local Ollama backend, fresh context); returns a self-contained `tool` message with no history contamination. | Model error encapsulated into the tool result string with a failure reason. Never propagates as a turn failure. |
| **Tool Path Resolution** | Deterministic | Nonexistent targets resolve through the nearest existing ancestor; prefix check against `@root + "/"`; protected-path denylist (`.git/`, `.nightmare/`) refuses unconditionally. | Traversal, out-of-tree symlink, or protected target → `SecurityError` returned as a tool failure. Never approvable. |
| **Tool Output Size** | Deterministic | Every tool caps its own output at the boundary with an offset/limit continuation hint. | Oversized output cannot reach the context; no single result can overflow it. |
| **File Overwriting** | Deterministic | Existence check; unified diff computed in RAM; explicit human approval required. | Denied approval returns `[Execution rejected by user]`. Model plans an alternative. |
| **Shell Command Execution** | Deterministic | argv only, never `sh -c`. Token-based allowlist + flag denylist + metacharacter ban. Explicit pgid; SIGTERM→grace→SIGKILL; concurrent capped drain. | Timeout → `[Execution timed out after N seconds]` + `ExecutionTimeout`. Non-zero exit returned with captured stderr. |
| **Tool Call Loop Detection** | Deterministic | Identical `(tool, args)` repeated `LOOP_DETECT_THRESHOLD` times within a turn is refused without execution. | Forced failure tool message instructing a change of approach. |
| **Token Estimation** | Deterministic | Anchored on `Response#prompt_eval_count` — the exact size of everything except the new delta — with the EMA divisor estimating only the delta. Divisor clamped to `DIVISOR_CLAMP`, persisted to the cache dir. | Estimates displayed with a tilde (`~`). `ContextOverflow` is the reactive backstop when the estimate is wrong. |
| **In-Turn Shedding** | Deterministic | Fires on cumulative estimated context, not on any single result's size. Rewrites tool message content in place via write-back; never removes a message. Last `SHED_KEEP_VERBATIM` consumed results verbatim. | Cannot orphan a pair, because no message is removed. |
| **Turn Pruning** | Deterministic | Operates only on complete `Turn` records, evicting `Turn#messages` as a unit. `Turn#well_formed?` asserted across the assembled array after every prune. | Prevents orphaned `tool_calls` API errors. The active turn's user prompt is never evicted. |
| **Cancellation** | Deterministic | Signal handler does minimal work (channel send); consumers poll cooperatively. Rollback drops the whole active turn. | `Cancelled` — a first-class outcome, not a failure. Side effects surfaced in the next user message. |

---

## 9. Invariant Test Contract

**Infrastructure.** A `FakeClient < Mantle::Clients::Client` returns a scripted queue of `Mantle::Clients::Response` values, records every `Array(Mantle::Message)` it was handed, and can be told to raise `ClientFailure`, a 429, or a length rejection on the Nth call. No network, no subprocess, no sleeps. `spec/e2e/test_runner.cr` provides an HTTP-level `MockLlmServer` for the process-level tier.

| ID | Invariant |
| :--- | :--- |
| **T1** | **No orphaned pairs after any prune sequence.** Property test: generate random turn shapes (1–5 exchanges, 1–3 calls per assistant message, with and without interleaved content), apply a random shed/prune sequence, assert `well_formed?` over the full assembled array every time. |
| **T2** | **Shed → rebuild is byte-identical for unchanged history.** Assemble, shed only the active turn, re-assemble; every message belonging to a completed turn is byte-identical. |
| **T3** | **Write-back actually writes back.** Shed a tool exchange, then read the content back through `Turn#messages`. Fails loudly on `msgs[i].content = x` against the struct (§2.2). Companion case: the `#map` rebuild at the hook boundary preserves `tool_call_id` on every rebuilt tool message. |
| **T4** | **Last 2 verbatim.** Six exchanges, forced over the shed trigger: exchanges 1–4 shed, 5–6 verbatim, user message untouched. |
| **T5** | **Active turn and user prompt are never evicted.** Prune under extreme pressure with an active turn in flight. |
| **T6** | **Path-guard fuzz.** `../` chains, absolute paths, symlinks to outside, symlinked ancestors, `root-evil` sibling prefixes, nonexistent nested targets, empty and `.` paths. All rejected or correctly contained. |
| **T7** | **Protected paths are unwritable.** Every mutation tool refuses `.git/**` and `.nightmare/**`, and refusal is not an approval modal. |
| **T8** | **Allowlist bypass corpus.** `git -c core.sshCommand=…`, `git --exec-path=…`, `find . -exec sh -c …`, `xargs`, `env FOO=1 sh`, `python -c`, `FOO=$(id) git status`, `git status; rm -rf ~`, `git status && curl …`. Each must either fail tokenization or force the modal. None may auto-approve under an allowlist containing `git status`. |
| **T9** | **pgid reap.** A command spawning a child that outlives its parent is fully terminated on timeout. No survivors. |
| **T10** | **No pipe deadlock.** A command emitting > `TOOL_OUTPUT_MAX_BYTES` on both stdout and stderr completes and is capped. |
| **T11** | **`ContextOverflow` recovery.** `FakeClient` raises a length rejection on call 1 and succeeds on call 2; the turn succeeds and the retried request is measurably smaller. |
| **T12** | **`Cancelled` is not a failure.** Cancellation mid-stream rolls back the turn, leaves the store `well_formed?`, does not invoke the `Retrier`, and does not terminate the session. |
| **T13** | **Side-effect note survives rollback.** A turn that wrote `a.cr` and is then cancelled causes the next user message to carry the interruption note. |
| **T14** | **`/save` exports pristine history.** Shed and prune aggressively; the exported transcript still contains the full untruncated tool outputs. |
| **T15** | **Transcript survives a crash.** Kill the process mid-turn; `transcript.md` contains the committed turns. |
| **T16** | **Loop detection.** Identical `(tool, args)` `LOOP_DETECT_THRESHOLD` times yields a refusal tool result and no execution. |
| **T17** | **Calibration math.** Divisor converges per the EMA formula, clamps at both bounds, and tolerates `prompt_eval_count == nil` on every response without dividing by zero. |
| **T18** | **Zero repo litter.** After a full scripted session, `@root` contains exactly the files the session intentionally wrote — no config, no logs, no transcript. (`WorkspaceSandbox#assert_zero_repo_litter!`.) |
| **T19** | **`/prompt edit` is memory-only.** The system prompt changes; every on-disk prompt source is byte-identical afterward. |

Unit specs must stay fast — no network, no sleeps, no compiler invocations. Process-level e2e specs gate behind the memoized `Nightmare::E2E.repl_ready?` probe so unimplemented milestones report `pending!` immediately.
