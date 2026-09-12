# NIGHTMARE: System Architecture & Technical Specification

This document defines the module boundaries, data flows, type contracts, and stochastic-to-deterministic boundaries for NIGHTMARE. It is the living technical specification for implementation — *how* and *how much*.

CONOPS, tenets, requirements (R1–R6), operator-visible behaviour, the command reference, and the MVP boundary live in [`DESIGN.md`](DESIGN.md) and are **not** duplicated here. Where the two disagree, this document wins on mechanism; DESIGN wins on intent.

**Revision 2 — 2026-09-11.** Incorporates the review in `UPDATE_ARCHITECTURE.md` plus framework-reality findings verified directly against `../mantle` and `../salamander`. §9 is the invariant test contract, §10 the settled design decisions, §11 the change log. Sections marked **[R2]** changed in this revision; anything an in-flight agent already designed against the previous revision should be re-checked against `.agents/ARCHITECTURE_CHANGE_NOTICE.md`.

---

## 1. Module Hierarchy & Namespaces **[R2]**

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
│   ├── Guard                     # [R2] Path containment, protected paths, output caps
│   ├── ReadOnly                  # list_files, search, read_file, file_info
│   ├── Mutation                  # replace_in_file, append_to_file, write_file (diff modal)
│   ├── Shell                     # run_command, argv tokenizer, pgid supervisor, allowlists
│   └── Delegation                # ask_model (isolated, stateless one-shot inference)
├── Harness
│   ├── ToolLoop                  # [R2] on_iteration hook: capture, calibrate, shed
│   ├── StepRunner                # Mantle::Step construction + Result boundary
│   ├── Types                     # StepOutcome(T) sum type, StepError records
│   ├── Retrier                   # Exponential backoff and schema format retrier
│   └── LoopDetector              # [R2] Repeated (tool, args) invocation breaker
├── UI
│   ├── Terminal                  # Salamander::Terminal wrapper, dimensions
│   ├── Prompt                    # [R2] Line-mode REPL input, multi-line /paste mode
│   ├── Approval                  # [R2] Diff & command approval modals (line mode, D3)
│   ├── StreamController          # Streaming chunk callback, spinner, <think> isolation
│   └── Cancellation              # [R2] Cooperative interrupt (replaces UI::Signals)
└── Commands                      # Slash command router (/clear, /cls, /drop, /save, etc.)
```

---

## 2. Framework Reality: Verified Constraints **[R2]**

Everything in this section was verified by reading the framework source, not inferred from its docs. These facts are load-bearing for §3–§5.

### 2.1 `Mantle::Step` owns the tool loop and discards its message buffer

`Mantle::Step#run` (`../mantle/src/mantle/steps/step.cr:48`) treats its `messages` argument as immutable input, copies it into a local `working_messages = messages.dup`, appends assistant-with-`tool_calls` and `tool` messages to that local buffer across iterations, and returns only a `StepResult(String, StepError)` carrying `value`, `thinking`, `iterations`, and `raw_response`.

Consequences:

- **In-turn shedding (R2) is not implementable through `Step#run` as it stands.** The buffer the shedder must rewrite is local to Mantle and invisible to the caller.
- **A message-exact `Turn` (§3.2) cannot be captured through `Step#run` as it stands.** The intermediate assistant messages — including tool-call grouping and interleaved assistant text — are discarded when `run` returns.
- Tool *handlers* are NIGHTMARE closures, so approval modals, path guards, and pgid supervision work fine inside `Step`. Only the loop's context buffer is inaccessible.
- There is no cancellation or abort hook on `Client#execute` or `Step#run`.

**Decision (D1): extend `Mantle::Step` with a per-iteration hook.** Mantle is a first-party repository under the same ownership as NIGHTMARE, so surfacing the data is preferable to duplicating the loop. The enhancement is additive and backward-compatible, which R6 permits:

```crystal
# Mantle::Step#initialize — new optional property
@on_iteration : Proc(Array(Mantle::Message), Mantle::Clients::Response?, Array(Mantle::Message))? = nil

# Mantle::Step#run — immediately before each client.execute
if hook = @on_iteration
  working_messages = hook.call(working_messages, last_response)
end
```

Default `nil` → identity → every existing caller is unaffected. Tracked as **`mantle` TKT-008**.

This single hook supplies everything the context engine needs:

| Need | How the hook serves it |
| :--- | :--- |
| In-turn shedding | Rewrite `working_messages` in place before the call |
| Message-exact `Turn` (§3.2) | The hook observes the real assistant messages, so tool-call grouping and interleaved content need no synthesis |
| Cumulative token anchor | `last_response.prompt_eval_count` is the exact size of everything but the new delta (§2.4) |
| Per-turn spend cap | Accumulate `eval_count` across iterations |

`last_response` is in the signature for the bottom two rows; messages alone would force the estimator to re-estimate the whole array from scratch every iteration.

**This does not violate the graph isolation Mantle TKT-007 established.** The hook rewrites `Step`'s *local* `working_messages` buffer, which is already ephemeral and already discarded on return. The canonical context graph is untouched and `messages` remains immutable input. Graph isolation is about `Step` not mutating the caller's persistent state; this is the caller shaping its own ephemeral projection.

**Residual gap:** `ContextOverflow` recovery (§3.1). If the provider rejects a request for length, the error propagates out of `Step#run` and the loop position is lost — NIGHTMARE can shed and restart the turn, but not shed and retry the single failed call in place. Accepted: this is the reactive backstop, not the primary path, and the predictive check ahead of each iteration is what should keep it from firing. If it fires often in practice, the follow-on is an `on_error` hook, not a NIGHTMARE-owned loop.

`Mantle::Step` therefore remains the execution path for the primary turn as well as for one-shot `ask_model` delegation and the format-correction retry, satisfying R4 literally. `Nightmare::Harness::ToolLoop` is the thin policy layer that owns the hook closure, the `LoopDetector`, approval routing, and the `StepOutcome` boundary — not a reimplementation of the loop. **Do not refactor `Mantle::Step`'s existing control flow; the hook is a pure insertion.**

Until TKT-008 lands, shedding and turn capture are **blocked on the hook**. M2 work that does not depend on it — `TokenEstimator`, `PinnedFiles`, `Transcript`, and the `Turn`/`ToolExchange` data models themselves — proceeds unblocked.

### 2.2 `Mantle::Message` is a struct with no reasoning-block channel

```crystal
# ../mantle/src/mantle/clients/message.cr
struct Message
  property role : String
  property content : String?
  property tool_calls : Array(Mantle::Clients::ToolCall)?
  property tool_call_id : String?
end
```

- **It is a `struct`.** `array[i].content = x` mutates a temporary copy and silently no-ops. Every in-place message edit must be write-back: read out, mutate, assign back to the index. This is the single most likely source of a silent shedding bug; see §3.2.
- **There is no field for provider-native reasoning blocks or signatures.** Mantle models thinking as a plain `String?` on `Response`, extracted from `<think>` tags by `Response#initialize` via `Mantle::Support::Text.extract_thinking`.
- Mantle ships exactly one concrete client: `OllamaClient`, plus the `LoggingClient(T)` decorator. There is no Anthropic client.

**Decision (D2): Ollama local inference is the only target.** The "echo provider-native thinking blocks back verbatim" requirement from the review (`UPDATE_ARCHITECTURE.md` §1, third bullet) is therefore **not a constraint at all** — not merely deferred. No provider in scope demands it, so nothing in the context engine needs to accommodate it, and no forward-compat scaffolding should be built speculatively.

The other two bullets of that review point — tool-call grouping and interleaved assistant text — are real, provider-independent, and fixed by §3.2. `Turn` is message-exact for *those* reasons. That it would also make reasoning-block support additive later is a side benefit, not a design driver.

### 2.3 `Mantle::StepError` and `StepResult` already exist

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

Note the name is `MalformedOutput`, not `MalformedPayload`. `StepResult#raw_response` exposes `Mantle::Clients::Response`, which is where token accounting comes from (§2.4).

### 2.4 The usage field is `prompt_eval_count`, not `usage.prompt_tokens`

`Mantle::Clients::Response` exposes `prompt_eval_count : Int32?` and `eval_count : Int32?` (Ollama naming), plus `done_reason`, `truncated?`, `thinking_only?`, and `truncated_in_thinking?`. Every spec reference to `usage.prompt_tokens` means `response.prompt_eval_count`. Both fields are nilable — the estimator must tolerate their absence on every turn and never divide by zero or nil.

### 2.5 Salamander is line-buffered and has no raw mode

`Salamander::UI#ask_user` (`../salamander/src/salamander/ui.cr:36`) is `print prompt; gets`. There is no termios handling, no keypress reader, and no raw mode anywhere in Salamander. `Salamander::Terminal.run` wraps a `WaybarNotifier` and an optional `TtsKokoro::TTS` and yields a `UI` toolbelt (spinner control, `stream_text`, `terminal_width`, `clear_line`, markdown formatting). `Salamander::ChatSession#process_chunk` performs the `<think>` state machine.

Consequences:

- **The review's premise in `UPDATE_ARCHITECTURE.md` §6 is inverted for this stack.** The terminal stays in cooked mode, so `Ctrl+C` *does* raise `SIGINT`. The recommendation still holds for a different reason: a Crystal signal handler runs on the signal-handling fiber and cannot unwind the streaming fiber, so cancellation must still be cooperative. See §5.5.
- **Single-keypress modals (`[y]`/`[N]`/`[a]`) are not available.** **Decision (D3): line mode.** Type the letter and press Enter; empty input is the `[N]` default. No termios work in v1. Modal prompt text must read as a line prompt, not imply a keypress.
- `<think>` is stripped twice — once by `Response#initialize` for the non-streaming result, once by `ChatSession#process_chunk` for the live stream. Intentional; the `StreamController` owns display, `Response#thinking` owns `/thinking`.

### 2.6 Framework dependency surface

`shard.yml` links `mantle`, `salamander`, and `tts_kokoro` by path. `tts_kokoro` is a transitive requirement of `Salamander::Terminal`/`UI`, not a NIGHTMARE feature: TTS is constructed as `nil` and never enabled.

---

## 3. Core Data Types & Contracts

### 3.1 Stochastic Boundary Sum Type **[R2]**

The previous revision declared `alias Result(T) = Success(T) | Failure`. **Crystal does not support generic aliases** — that line does not compile (`Error: expecting token '=', not '('`). The boundary is expressed as a single generic class instead.

```crystal
module Nightmare::Harness
  enum StepErrorKind
    MaxIterationsReached   # iteration cap hit (§8 MAX_ITERATIONS)
    RateLimited            # provider 429; Retrier applies backoff+jitter
    ClientFailure          # transport / API failure
    MalformedOutput        # unparseable or empty completion (matches Mantle naming)
    ToolExecutionFailure   # tool handler raised a terminal error
    ExecutionTimeout       # tool/subprocess exceeded its timeout
    Cancelled              # [R2] user interrupt; a first-class outcome, not a failure
    ContextOverflow        # [R2] provider rejected request for length
    SpendCapExceeded       # [R2] per-turn token/cost cap hit (§8)
  end

  record StepError,
    kind : StepErrorKind,
    message : String,
    retryable : Bool = false

  # Generic aliases are illegal in Crystal; use one generic class with a
  # nil-discriminated payload, mirroring Mantle::StepResult.
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

Mapping from `Mantle::StepError` (used on the `ask_model` / format-retry paths that still run through `Mantle::Step`):

| `Mantle::StepError` | `StepErrorKind` |
| :--- | :--- |
| `MalformedOutput` | `MalformedOutput` |
| `MaxIterationsReached` | `MaxIterationsReached` |
| `ClientFailure` | `ClientFailure` |
| `ToolExecutionFailure` | `ToolExecutionFailure` |
| `RateLimited` | `RateLimited` |

`Cancelled`, `ContextOverflow`, `ExecutionTimeout`, and `SpendCapExceeded` originate in NIGHTMARE and have no Mantle analogue.

**`Cancelled` is not a failure path.** A cancelled turn rolls back (§5.5), keeps its side-effect note, and returns control to the prompt. It must not be logged as an error, must not trigger the `Retrier`, and must not count against any failure budget.

**`ContextOverflow` is the reactive safety net.** When the provider rejects a request for length (HTTP 400 with a `context_length_exceeded`-class body), `ToolLoop` catches it, runs an emergency shed → prune cycle against the assembled message array, and retries **once**. Only if the retry also overflows does it surface. This is the one place the shedder is reactive rather than predictive; it is what covers estimator error, so it is not optional.

### 3.2 Context & Turn Representations **[R2]**

**The `Turn` is now message-exact.** The previous shape — `user_message`, a flat `Array(ToolExchange)`, and one `assistant_message` — required *synthesizing* the intermediate assistant messages that carried the `tool_calls` in order to rebuild a request. That destroyed tool-call grouping (two calls in one assistant message is a different history from two sequential messages) and any interleaved assistant text. `Turn` now holds the exact ordered message sequence as it was sent and received; `ToolExchange` becomes an index-based view over it.

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
    property side_effects : Array(String)    # [R2] paths mutated; see §5.5

    def initialize(user_message : Mantle::Message)
      @messages = [user_message]
      @exchanges = [] of ToolExchange
      @side_effects = [] of String
      @started_at = Time.utc
    end

    def user_message : Mantle::Message
      @messages.first
    end

    # Appends the exact assistant message the provider returned — grouping,
    # interleaved content, and tool_calls preserved verbatim. No synthesis.
    def append_assistant(msg : Mantle::Message) : Nil

    # Appends a tool result and records a view over its index.
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

  # A view/index into Turn#messages. Shedding rewrites the tool message in
  # place via write-back — Mantle::Message is a STRUCT, so `msgs[i].content = x`
  # mutates a copy and silently does nothing (§2.2).
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
      @turn.messages[@index] = msg     # WRITE-BACK — required, not stylistic
      @shed = true
    end
  end
end
```

**Write-back vs. `#map`.** Two safe forms exist for editing a `struct` message; use each where it fits.

- **Inside `Turn`** — index write-back, as in `shed!` above. `ToolExchange` holds positional indices, so the array's length and ordering must stay stable. `#map` would also preserve both, but write-back keeps the mutation local to the one exchange being shed.
- **At the Mantle hook boundary** — `#map`. `on_iteration` returns a new array by contract, and Mantle's own docs recommend the rebuild form because it makes struct copy semantics explicit instead of relying on the caller remembering to assign back:

```crystal
working_messages.map do |msg|
  if shed_target?(msg)
    Mantle::Message.new("tool", truncated, tool_call_id: msg.tool_call_id)
  else
    msg
  end
end
```

`tool_call_id:` is **keyword**, not positional — the third positional parameter of `Message#initialize` is `tool_calls`. Dropping it is precisely what breaks pair integrity, and it is an easy slip.

`Transcript` (§6) captures every message at append time, so shedding is lossless from the user's point of view and `/save` still exports the pristine history.

### 3.3 Pinned Files **[R2]**

The previous revision's `read_content` contained `if s = @slice_start, e = @slice_end`, which is not valid Crystal, would raise on an out-of-range slice, and applied no root guard.

```crystal
module Nightmare::Context
  class PinnedFile
    getter path : String                     # workspace-relative, as displayed
    getter slice_start : Int32?              # 1-based, inclusive
    getter slice_end : Int32?                # 1-based, inclusive
    property cached_mtime : Time?
    property cached_tokens : Int32?

    # Root containment is the tool guard's job, not this class's: every read
    # goes through Tools::Guard.resolve_read (§4.1), which raises SecurityError
    # for anything outside @root or matching a sensitive pattern.
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

`/add` rejects a file whose estimated tokens would push the pinned set over **60% of `token_hardmax`**, with a descriptive error, and does not add it.

### 3.4 Workspace Mapping Manifest **[R2]**

`Manifest` was a `struct` with `property` and a mutating `#touch`. That works only by accident in `load_or_create` (which touches a local variable); any `env.manifest.touch` mutates a copy and silently no-ops. **It is a class.**

```crystal
module Nightmare::Workspace
  class Manifest                             # [R2] was `struct`
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

**Slug sanitization** (already implemented in `Workspace::Environment`, recorded here as the contract): `File.basename(@root).gsub(/[^a-zA-Z0-9_-]/, "_")`, with `"root"` substituted for an empty, `"/"`, or all-underscore result. Spaces, unicode, and separators in odd mount names collapse to `_`; the SHA-256 suffix preserves uniqueness, so collisions after sanitization are harmless.

---

## 4. Tool Surface: Guards & Execution **[R2]**

### 4.1 `Tools::Guard` — path containment and protected paths

Containment rules (the first two are already implemented correctly in `Workspace::Environment` and are recorded here as invariants to preserve):

1. **Nonexistent targets resolve through their nearest existing ancestor.** `File.realpath` fails on a path that does not exist, so `write_file` for a new file must walk up to the nearest existing ancestor, `realpath` that, and re-join the remaining components. `Environment#resolve_contained_path` does this.
2. **Prefix check is `root + "/"`, not `root`.** `starts_with?(@root)` accepts `/home/x/proj-evil` for root `/home/x/proj`. `Environment#path_inside_root?` compares against `"#{@root}/"` and separately allows exact equality with `@root`.
3. **Protected paths — mutation tools refuse unconditionally.** Root containment is not sufficient, because some in-tree files are part of NIGHTMARE's own trust boundary. `.nightmare/prompt.md` is a Tier-2 system prompt source that lives *inside* `@root` and, without this rule, is model-writable: a **persistent prompt injection** that survives restarts. The protected set, checked on workspace-relative paths after resolution:

   | Pattern | Rationale |
   | :--- | :--- |
   | `.git` and `.git/**` | R3 explicit requirement; repository integrity |
   | `.nightmare/**` | System prompt source — prompt-injection persistence |
   | `.nightmare*` (any sibling) | Reserved namespace |

   Violations return a tool failure (`[Refused: <path> is a protected path]`), not an approval modal. They are never approvable.
4. **Sensitive-read patterns** for `read_file`, `search`, and `list_files`: `.env*`, `*.pem`, `id_rsa*`, `*secret*`, `*credential*`, `.git/*`.
5. **Output caps at the tool boundary.** Every tool returns at most `TOOL_OUTPUT_MAX_BYTES` (§8). A capped result ends with an explicit continuation hint — `[... truncated at N bytes; call read_file with offset=X limit=Y for more]` — so a single oversized result can never be the thing that blows the context. This is a precondition for Pipeline 3's shedding trigger.

### 4.2 `Tools::Shell` — argv execution

**Decision (D4): `run_command` executes via argv, never `sh -c`.**

The previous revision left this undefined, which made the security model unanalyzable. A regex allowlist over a raw command string that is then handed to a shell is trivially escaped — `git -c core.sshCommand=…`, `git --exec-path=…`, `find -exec`, `xargs`, `env`, `python -c`, `FOO=$(…) cmd` all pass an anchored `^git …$`-style pattern or slip past it entirely. Under argv there is no shell, so there is nothing to escape.

Under argv the rules become:

- **Tokenization.** The model's command string is tokenized with POSIX-style quoting rules into argv. Tokenization failure (unbalanced quotes) is a tool failure, not a fallback to shell.
- **Metacharacter ban stays, with honest framing.** `;`, `&`, `|`, `` ` ``, `$`, `>`, `<`, newline, `(`, `)`, `{`, `}`, `\`, `*` in the raw string bar auto-approval and force the interactive modal. Under argv these characters are inert — they would be passed as literal arguments and the pipe or redirect simply would not happen. The ban is therefore **a UX guard against silently-wrong execution, plus defense in depth**, not the security boundary. It remains mandatory per R3.
- **Allowlist matches on tokens, not on the raw string.** A pattern matches `argv[0]`'s basename plus, where applicable, `argv[1]` as a subcommand — e.g. `git status`, `crystal spec`. Raw-string regexes are not the matching surface.
- **Flag denylist overrides any allowlist.** Regardless of allowlist state, these force the modal: `-c`, `-e`, `--exec*`, `--eval*`, `-C`, `--config`, `--upload-pack`, `--receive-pack`, and any token containing `=` before the first non-flag argument. This closes the `git -c` / `python -c` class of escapes that survive a per-binary allowlist.
- **`[a]` and `[p]` record token patterns.** `[a]` stores the exact argv. `[p]` derives `argv[0] + argv[1]` as a prefix. Neither may be recorded for a command that tripped the metacharacter ban.

### 4.3 Subprocess guardrails

- **Process group.** Crystal's `Process` has **no process-group option**. A pgid must be established explicitly: either `LibC.setpgid(0, 0)` immediately post-fork, or by launching under `setsid -w`. This is a real implementation gap and must not be quietly dropped — without it, `Process.kill(Signal::KILL, -pgid)` has no group to signal and orphaned children survive a timeout. A spec asserts that a command spawning a child that outlives its parent is fully reaped on timeout.
- **Termination ladder.** `SIGTERM` → `PROCESS_GRACE_PERIOD` → `SIGKILL`, both to `-pgid`. Not straight to `SIGKILL`: `SIGTERM` first lets test runners and compilers clean up temp state.
- **Concurrent output drain.** stdout and stderr are drained **concurrently** into capped buffers. Sequentially reading one pipe to EOF while a chatty command fills the other deadlocks the child. Each stream caps at `TOOL_OUTPUT_MAX_BYTES / 2` with a truncation marker.
- **stdin** is `/dev/null`. **cwd** is `@root`.
- **Environment additions:** `GIT_TERMINAL_PROMPT=0`, `CI=1`, `PAGER=cat`, `GIT_PAGER=cat`, `NO_COLOR=1`, `TERM=dumb`. Without the pager and `TERM` settings, `git log`/`git diff` block forever on a pager that never gets a TTY, and ANSI escapes pollute the context.
- **Timeout** defaults to `DEFAULT_COMMAND_TIMEOUT`, capped at `MAX_COMMAND_TIMEOUT` (§8).

---

## 5. Data Flows & Pipelines

### Pipeline 1: Boot & Workspace Resolution

```text
Dir.current
   │
   ▼
File.realpath(Dir.current) ──> @root (Cached immutable anchor)
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
STDOUT Notification Banner emitted
```

### Pipeline 2: Prompt Assembly (Live Re-Read) **[R2]**

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

Block ordering: system prompt, then pinned files, then history. **This is a deliberate cache trade-off.** Pinned files are re-read every turn, so when the model edits a pinned file the prefix changes and prompt caching is invalidated for the entire history behind it. Placing the pinned block *after* history would preserve the cached prefix but would put live file state below stale tool results, which is the correctness problem `/add` exists to solve. **Decision (D5): pinned-before-history**, accepting the cache cost consciously. Correctness over cache locality.

### Pipeline 3: In-Turn Tool Loop & Shedding **[R2]**

#### What in-turn shedding is for

Every iteration of a tool loop re-sends the **entire accumulated message array**. Context therefore grows *within* a single turn, not only across turns:

```text
iteration 1:  [user]                                                →  ~200 tokens
iteration 2:  + asst(run_command), tool(8 KB of build errors)       →  ~2,200
iteration 3:  + asst(read_file),   tool(4 KB of src/config.cr)      →  ~3,300
iteration 4:  + asst(read_file),   tool(4 KB of src/parser.cr)      →  ~4,400
iteration 5:  + asst(search),      tool(2 KB of grep hits)          →  ~5,000
iteration 6:  + asst(run_command), tool(8 KB, build errors again)   →  ~7,200
...
iteration 12: ──────────────────────────────────────────────────────>  over budget
```

One user message, no history at all, and the window is exhausted. Turn-unit pruning cannot help: there are no completed turns to evict, and all the bloat is in the turn currently executing.

Nor can a tool result simply be **deleted**. Every `tool` message must pair with a `tool_call` id in a preceding assistant message; removing one produces a malformed history that providers reject. Shedding is the answer to "this must get smaller and nothing can be removed": keep the message and its `tool_call_id`, rewrite only its `content`.

```text
tool(id: call_3): "src/config.cr:1: require \"json\"\nmodule Config\n  ...4 KB..."
                   ↓  shed!
tool(id: call_3): "src/config.cr:1: require \"json\"\nmodule Config\n  class Settings
                   [... output truncated: was 4096 bytes]"
```

Two rules keep this from destroying the turn:

- **Last 2 verbatim.** Those are the model's active working set — what it just read and is reasoning about now.
- **Only shed *consumed* results.** Consumed means the model has already seen the result and emitted a *subsequent* tool call, so the information has already done its work: it is baked into the decision the model just made. It read `config.cr`, concluded the bug was in `parser.cr`, and moved on. A 200-character prefix is enough to remember "I looked at that; it was the Settings class."

The pristine `Transcript` (§6) captures every message at append time, so shedding is invisible to `/save` and to the user.

**Scale note.** At `TOKEN_HARDMAX = 12_000` this is load-bearing, not theoretical: one failed `crystal build` plus three file reads reaches the threshold, and a debugging turn routinely runs 10+ iterations. Against a 200k-context frontier model shedding would rarely fire — but Mantle ships an `OllamaClient` and local models run 8k–32k, which is the target this budget reflects.

#### The loop

Driven by `Mantle::Step`, with `Harness::ToolLoop` supplying the `on_iteration` hook (§2.1, D1). The hook is where the predictive check and shedding happen.

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
   │   │    ├── cancel flag set? ──> raise Cancelled (§ Pipeline 5)          │
   │   │    │                                                                │
   │   │    └── PREDICTIVE CHECK:                                            │
   │   │          estimated = last_prompt_tokens + estimate(delta)           │
   │   │          > token_hardmax * 0.85 ──> Shedder.shed_active_turn!       │
   │   │          > token_hardmax        ──> Shedder.prune_history!          │
   │   │          returns the rewritten working_messages                     │
   │   │                                                                     │
   │   │ client.execute(working_messages)                                    │
   │   │    ├── cancel flag set? ──> on_chunk raises Cancelled               │
   │   │    ├── 429 ──> Retrier: exponential backoff + jitter                │
   │   │    └── 400 length rejection ──> propagates out of Step#run;         │
   │   │          StepRunner sheds + prunes and re-runs the turn ONCE,       │
   │   │          then StepErrorKind::ContextOverflow  (residual gap, D1)    │
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

Two things to note about ownership. **`turn.messages` is a mirror, not the source of truth during the loop** — `Mantle::Step` owns `working_messages`, and the hook is where NIGHTMARE reads it, rewrites it, and copies it. They are the same content by construction because the hook returns what it captured. **Shedding mutates the array the hook returns**, which is what `Step` then sends; that is the entire mechanism by which shedding reaches the wire.

**Shedding scope (`Shedder.shed_active_turn!`):** walk `turn.exchanges` oldest-first, `shed!` each consumed exchange, **preserving the last 2 verbatim**, stopping as soon as the estimate is back under 85%. "Consumed" means the model has already observed the result and emitted a subsequent tool call. The user message is never shed. Shedding never removes a message — only rewrites `content` — so `well_formed?` holds by construction.

**Historical pruning (`Shedder.prune_history!`):** Phase 1 sheds tool messages in completed historical turns, oldest-first. Phase 2, only if still over budget, evicts the **entire oldest completed turn** — all of its `messages` together. Never the active turn; never a partial turn. `well_formed?` is re-asserted across the assembled array after every prune.

### Pipeline 4: Interactive Approval & Execution Boundary **[R2]**

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
                 - pgid via setpgid post-fork (Crystal Process has no option)
                 - chdir @root; stdin /dev/null
                 - env: GIT_TERMINAL_PROMPT=0 CI=1 PAGER=cat GIT_PAGER=cat
                        NO_COLOR=1 TERM=dumb
                 - concurrent capped drain of stdout+stderr
                 - timeout: SIGTERM(-pgid) -> grace -> SIGKILL(-pgid)
```

### Pipeline 5: Cooperative Cancellation & Turn Rollback **[R2]**

```text
User presses Ctrl+C
   │
   ▼
Signal::INT.trap  (cooked mode delivers a real SIGINT — see §2.5)
   │   Handler does the MINIMUM safe work: send to cancel_channel, set a flag.
   │   It never unwinds a fiber and never touches the context store.
   ▼
Consumers poll/select cooperatively:
   ├── Tool subprocess running?   ──> SIGTERM(-pgid) -> grace -> SIGKILL(-pgid)
   ├── LLM stream active?         ──> on_chunk raises Cancelled on next chunk;
   │                                  ToolLoop rescues it. (Mantle exposes NO
   │                                  abort hook — §2.1 — so the next-chunk
   │                                  raise is the only mechanism. A stream
   │                                  that has stopped producing chunks cannot
   │                                  be interrupted until it times out.)
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
   Without this the model reasons about a disk state that no longer matches
   its context.
   │
   ▼
Transcript records the interruption and the side-effect list (never rolled back).
Restore the user's input text to the REPL prompt line for editing.
```

Two `Ctrl+C` in rapid succession at an empty prompt exits, as does `/exit` or EOF. A single `Ctrl+C` never terminates the session.

---

## 6. Persistence Subsystem **[R2, R7]**

### Central XDG Isolation

- **Config**: `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/`
  - `workspace.json` — metadata linking workspace ID to `@root` (inhibited in ghost mode)
  - `prompt.md` — per-workspace system prompt
  - `allow` — persisted shell allowlist (token patterns; §4.2)
- **State & Logs**: `$XDG_STATE_HOME/nightmare/workspaces/<workspace_id>/`
  - `llm_calls.jsonl` — audit log of raw prompts, completions, latency. Rotates at 20 MB, 3 retained. Completely disabled by `--no-logs` or system configuration.
  - `transcript.md` — **[R2]** incrementally appended pristine transcript (disk appends completely disabled by `--no-logs` or system configuration; RAM-only in ghost mode).
- **Cache**: `$XDG_CACHE_HOME/nightmare/workspaces/<workspace_id>/`
  - `calibrator.json` — persisted token divisor (inhibited in ghost mode)

Zero files are written inside `@root`. `.nightmare/prompt.md`, if present, is read-only to NIGHTMARE and to the model (§4.1).

### Transcript: incremental persistence vs. ghost mode

In normal operation, **`Transcript` appends each message to `$XDG_STATE_HOME/.../transcript.md` as it is produced**, with an in-memory mirror retained for `/save` and `/review`. Appends are `O_APPEND` line-oriented and flushed per turn to ensure crash resilience.

However, when logging is disabled via `--no-logs` or system configuration, **`Transcript` operates in memory-only mode**: `file_path` is `nil`, no file handle is opened, and nothing is appended to disk. `/save [path]` still operates by writing the in-memory transcript directly to the user-specified destination path on demand.

### Logging Control, Ghost Mode & Anti-Exfiltration Guarantees **[R7, D6]**

1. **Threat Model & Anti-Exfiltration**:
   In sensitive development environments, LLM prompt and completion logs (`llm_calls.jsonl`) or session transcripts (`transcript.md`) may record confidential proprietary code, tokens, internal API responses, or sensitive queries. If stored on disk, these artifacts represent a persistent data exfiltration vector.
2. **Complete Log Suppression (`--no-logs`)**:
   Passing `--no-logs` (or `--no-log`) disables all disk logging completely:
   - `Mantle::Clients::LoggingClient` is omitted or bypassed; no `llm_calls.jsonl` is opened or written.
   - `Transcript` does not open or append to `transcript.md`.
   - Zero logs or data access traces are persisted to disk.
3. **Ghost Mode Zero Footprint**:
   Beyond suppressing audit logs and transcripts, "ghost mode" ensures NIGHTMARE leaves zero footprint on disk:
   - Inhibit creation of `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/` (no `workspace.json` manifest, no auto-bootstrapping of `config.json`).
   - Inhibit creation of `$XDG_CACHE_HOME/.../calibrator.json` (token calibration divisor operates ephemerally in RAM).
   - Inhibit creation of `$XDG_STATE_HOME/...` directories.
   - All session state, context buffers, and tokens evaporate entirely from RAM upon process exit.
4. **Permanent System-Level Configuration**:
   A boolean setting `"logging": false` in `config.json` (at either the global level `$XDG_CONFIG_HOME/nightmare/config.json` or workspace level) allows users to permanently disable logging without needing to pass `--no-logs` on every invocation.
5. **Precedence & Default Stance**:
   - `CLI flag (--no-logs)` > `workspace config.json` > `global config.json` > default.
   - Default: `logging = true`. Logs remain enabled by default for observability, troubleshooting, and crash-safe transcripts, but yield unconditionally when suppressed.

---

## 7. Stochastic vs. Deterministic Boundary Matrix **[R2]**

| Operation | Nature | Deterministic Guard / Invariant | Failure Mode Encapsulation |
| :--- | :--- | :--- | :--- |
| **Audit Logging & State Persistence** | Deterministic | When `--no-logs` is passed or `logging: false` is configured, file sinks for `llm_calls.jsonl`, `transcript.md`, and XDG manifest/cache files are bypassed entirely. | Disk I/O avoided; zero possibility of file-permission failures or disk exfiltration. |
| **Primary Turn LLM Stream** | Stochastic | `Mantle::Step` drives the loop; `Harness::ToolLoop` supplies the `on_iteration` hook that captures and rewrites the working buffer (§2.1, D1). `Salamander::ChatSession` strips `<think>` from the live stream; `Response#thinking` carries the reasoning log for `/thinking`. | Client failure → `ClientFailure`. 429 → `RateLimited`, exponential backoff with jitter. Length rejection → `ContextOverflow`, emergency shed + one turn re-run. |
| **Structured Output Parsing** | Stochastic | Typed boundary parses the raw completion immediately into a Crystal type. | Schema failure → `MalformedOutput`. Harness triggers a single format-correction retry, then returns typed error. |
| **Model Delegation (`ask_model`)** | Stochastic | Stateless one-shot via `Mantle::Step` with **no** `on_iteration` hook (same local Ollama backend, fresh context); returns a self-contained `tool` message with no history contamination. | Model error encapsulated into the tool result string with a failure reason. Never propagates as a turn failure. |
| **Tool Path Resolution** | Deterministic | Nonexistent targets resolve through the nearest existing ancestor; prefix check against `@root + "/"`; protected-path denylist (`.git/`, `.nightmare/`) refuses unconditionally. | Traversal, out-of-tree symlink, or protected target → `SecurityError` returned as a tool failure. Never approvable. |
| **Tool Output Size** | Deterministic | Every tool caps its own output at the boundary with an offset/limit continuation hint. | Oversized output cannot reach the context; no single result can overflow it. |
| **File Overwriting** | Deterministic | Existence check; unified diff computed in RAM; explicit human approval required. | Denied approval returns `[Execution rejected by user]`. Model plans an alternative. |
| **Shell Command Execution** | Deterministic | argv only, never `sh -c`. Token-based allowlist + flag denylist + metacharacter ban. Explicit pgid; SIGTERM→grace→SIGKILL; concurrent capped drain. | Timeout → `[Execution timed out after N seconds]` + `ExecutionTimeout`. Non-zero exit returned with captured stderr. |
| **Tool Call Loop Detection** | Deterministic | Identical `(tool, args)` repeated `LOOP_DETECT_THRESHOLD` times within a turn is refused without execution. | Forced failure tool message instructing a change of approach. |
| **Token Estimation** | Deterministic | Anchored on `Response#prompt_eval_count` — the *exact* size of everything except the new delta — with the EMA divisor estimating only the delta. Divisor clamped to `[1.0, 10.0]`, persisted to the cache dir. | Estimates displayed with a tilde (`~`). `ContextOverflow` is the reactive backstop when the estimate is wrong. |
| **In-Turn Shedding** | Deterministic | Fires on **cumulative estimated context**, not on any single result's size. Rewrites tool message content in place via write-back; never removes a message. Last 2 consumed results verbatim. | Cannot orphan a pair, because no message is removed. |
| **Turn Pruning** | Deterministic | Operates only on complete `Turn` records, evicting `Turn#messages` as a unit. `Turn#well_formed?` asserted across the assembled array after every prune. | Prevents orphaned `tool_calls` API errors. The active turn's user prompt is never evicted. |
| **Cancellation** | Deterministic | Signal handler does minimal work (channel send); consumers poll cooperatively. Rollback drops the whole active turn. | `Cancelled` — a first-class outcome, not a failure. Side effects surfaced in the next user message. |

---

## 8. Configuration Constants **[R2]**

Previously undefined or scattered. Single source of truth; all live in `Nightmare::Config` with per-workspace overrides in `$XDG_CONFIG_HOME/nightmare/config.json`.

| Constant | Default | Notes |
| :--- | :--- | :--- |
| `TOKEN_HARDMAX` | `12_000` | Sized for the 8k–32k local models Mantle's client targets |
| `SHED_TRIGGER_RATIO` | `0.85` | In-turn shedding threshold |
| `PINNED_BUDGET_RATIO` | `0.60` | `/add` rejection threshold |
| `TURN_SOFT_CAP` | `10` | Completed turns retained before FIFO eviction |
| `SHED_KEEP_CHARS` | `200` | Retained prefix on a shed tool result |
| `SHED_KEEP_VERBATIM` | `2` | Most-recent consumed results kept intact |
| `INITIAL_DIVISOR` | `3.5` | chars/token at boot. `specs.md` §2.5 agrees; a dispatch brief saying 4.0 is wrong |
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
| `logging` (Setting) | `true` | System/workspace setting in `config.json`. When `false` or overridden by `--no-logs`, completely disables disk audit logs (`llm_calls.jsonl`) and disk transcripts (`transcript.md`); ghost mode suppresses XDG config/cache footprints. |

---

## 9. Invariant Test Contract **[R2, R7]**

Nothing in the previous revision said how correctness was to be verified, which left every autonomous agent to invent its own bar. These are **coordination points**: a red test is a far better contract than prose. They are required before the corresponding milestone can gate.

**Infrastructure.** A `FakeClient < Mantle::Clients::Client` that returns a scripted queue of `Mantle::Clients::Response` values, records every `Array(Mantle::Message)` it was handed, and can be told to raise `ClientFailure`, a 429, or a length rejection on the Nth call. No network, no subprocess, no sleeps. (`spec/e2e/test_runner.cr` already provides an HTTP-level `MockLlmServer` for the process-level tier; `FakeClient` is the in-process unit-level equivalent.)

| ID | Invariant |
| :--- | :--- |
| **T1** | **No orphaned pairs after any prune sequence.** Property test: generate random turn shapes (1–5 exchanges, 1–3 calls per assistant message, with and without interleaved content), apply a random shed/prune sequence, assert `well_formed?` over the full assembled array every time. |
| **T2** | **Shed → rebuild is byte-identical for unchanged history.** Assemble, shed only the active turn, re-assemble; every message belonging to a completed turn is byte-identical. Catches accidental reconstruction. |
| **T3** | **Write-back actually writes back.** Shed a tool exchange, then read the content back through `Turn#messages`. Fails loudly if anyone reintroduces `msgs[i].content = x` on the struct (§2.2). Companion case: the `#map` rebuild at the hook boundary preserves `tool_call_id` on every rebuilt tool message. |
| **T4** | **Last 2 verbatim.** Six exchanges, forced over 85%: exchanges 1–4 shed, 5–6 verbatim, user message untouched. |
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
| **T15** | **Transcript survives a crash.** Kill the process mid-turn; `transcript.md` contains the committed turns (when logging is enabled). |
| **T16** | **Loop detection.** Identical `(tool, args)` `LOOP_DETECT_THRESHOLD` times yields a refusal tool result and no execution. |
| **T17** | **Calibration math.** Divisor converges per the EMA formula, clamps at both bounds, and tolerates `prompt_eval_count == nil` on every response without dividing by zero. |
| **T18** | **Zero repo litter.** After a full scripted session, `@root` contains exactly the files the session intentionally wrote — no config, no logs, no transcript. (Already implemented as `WorkspaceSandbox#assert_zero_repo_litter!`.) |
| **T19** | **`/prompt edit` is memory-only.** The system prompt changes; every on-disk prompt source is byte-identical afterward. |
| **T20** | **Zero disk footprint under `--no-logs` (Ghost mode).** Starting with `--no-logs` writes nothing to `$XDG_STATE_HOME`, `$XDG_CONFIG_HOME`, or `$XDG_CACHE_HOME`. No `llm_calls.jsonl`, no `transcript.md`, no `workspace.json`, no `calibrator.json`. `Transcript` captures turns in memory only; `/save [path]` writes only if explicitly requested. |
| **T21** | **System config log suppression.** Setting `"logging": false` in `config.json` disables disk audit logging (`llm_calls.jsonl`) and incremental transcript writes (`transcript.md`) without requiring CLI flags. Observability remains enabled when `logging: true`. |

Unit specs must stay fast — no network, no sleeps, no compiler invocations. Process-level e2e specs gate behind the memoized `Nightmare::E2E.repl_ready?` probe so that unimplemented milestones report `pending!` immediately rather than accumulating timeouts.

---

## 10. Design Decisions **[R2, R7]**

**All six are settled as of 2026-09-11.** Build on them; none is an open question for an implementing agent.

| ID | Question | Resolution |
| :--- | :--- | :--- |
| **D1** | ~~R4 says "orchestrate via Mantle's step runner", but `Mantle::Step` structurally cannot support in-turn shedding or a message-exact turn (§2.1). Own the loop, or add an `on_iteration` hook to Mantle?~~ | **RESOLVED 2026-09-11 — add the hook.** Mantle is first-party, so surfacing the data beats duplicating the loop. `Mantle::Step` keeps driving the primary turn; `on_iteration` gives NIGHTMARE shedding, message-exact capture, the token anchor, and spend accounting. Additive, default-`nil`, graph isolation preserved. Tracked as `mantle` **TKT-008**. Residual gap: `ContextOverflow` retries the turn rather than the single call — accepted. Full rationale in §2.1. |
| **D2** | Provider-native reasoning blocks with signatures cannot be represented in `Mantle::Message` (§2.2), and no Anthropic client exists in Mantle. | **RESOLVED — Ollama local inference is the only target.** Not "deferred": there is no second provider in scope, so reasoning-block echo is not a v1 constraint to design around. `Turn` stays message-exact regardless — that is required for tool-call grouping (§3.2), independent of reasoning blocks. |
| **D3** | Salamander is line-buffered with no raw mode (§2.5). `[y]`/`[N]`/`[a]` single-keypress modals are not available. | **RESOLVED — line mode.** Type the letter, press Enter; empty input is the `[N]` default. No termios work in v1. Modal prompts must read as line input, not as keypress hints. |
| **D4** | argv vs. `sh -c` for `run_command`. | **RESOLVED — argv only** (§4.2). Pipes and redirects will not work; that is the intended trade. If shell features are later required, they belong behind an explicitly-approved, never-auto-approvable `run_shell` tool, not as a widening of `run_command`. |
| **D5** | Pinned files before or after history (§ Pipeline 2). | **RESOLVED — before history**, accepting prompt-cache invalidation whenever the model edits a pinned file. Correctness over cache locality. Revisit only if cache cost shows up in the audit log. |
| **D6** | Complete log suppression, ghost mode zero-footprint, and system config (R7). | **RESOLVED — `--no-logs` suppresses all disk logs including transcript; ghost mode avoids leaving `.config` footprints; `logging: false` in `config.json` allows permanent system-level suppression; default remains enabled for observability.** Prevents data exfiltration of repository files, prompts, and model responses to disk. In ghost mode, directory creation and manifest/calibrator persistence are inhibited (`ensure_dirs: false`), operating ephemerally in RAM. |

---

## 11. Change Log

### Revision 2.1 — 2026-09-11: Logging Control, Ghost Mode & Anti-Exfiltration (R7, D6)

Clarified user need and architectural specification for logging suppression and ghost mode:
- Added R7 and D6 establishing complete disk logging suppression under `--no-logs` (no `llm_calls.jsonl` audit log, no `transcript.md` on disk; transcript is in-memory only).
- Specified "ghost mode" zero-footprint behavior: suppresses creating `$XDG_CONFIG_HOME` manifests (`workspace.json`), bootstrapped `config.json`, or cache files (`calibrator.json`). Ephemeral state resides purely in RAM.
- Documented persistent system-level configuration option (`logging: false` in `config.json`), while maintaining logging enabled by default for observability.
- Added invariants T20 and T21 to the verification test contract.

### Revision 2 — 2026-09-11

Driven by `UPDATE_ARCHITECTURE.md` (items 1–9) plus findings from reading `../mantle` and `../salamander` directly.

Amended the same day: D1 resolved in favour of the Mantle `on_iteration` hook (`mantle` TKT-008) rather than a NIGHTMARE-owned loop; hook signature fixed at two args with pre-flight-only semantics and `#map` as the recommended rewrite form; the shedding rationale that Pipeline 3 previously assumed rather than stated was added; and `DESIGN.md` was rewritten to a strict CONOPS/requirements scope so the two documents stop overlapping. D2–D5 then settled: Ollama-only target, line-mode approvals, argv-only shell, pinned-before-history. All five decisions in §10 are now closed.

Accepted from the review:

1. `Turn` is message-exact; `ToolExchange` is an index view (§3.2).
2. argv-only shell execution, token allowlist, flag denylist, pgid via `setpgid`, SIGTERM ladder, concurrent capped drain, pager/`NO_COLOR`/`TERM` env (§4.2, §4.3).
3. Path-guard gaps: nearest-existing-ancestor resolution, `root + "/"` prefix, protected-path denylist covering the prompt-injection vector, corrected `PinnedFile#read_content` (§3.3, §4.1).
4. `Cancelled` and `ContextOverflow` error kinds, with `ContextOverflow` as the reactive shed-and-retry backstop (§3.1).
5. Shedding fires on cumulative estimated context anchored to `prompt_eval_count`; per-result capping moved to the tool boundary; loop detection added (§4.1, Pipeline 3).
6. Cooperative cancellation and the post-rollback side-effect note (Pipeline 5).
7. Incremental transcript persistence (§6).
8. `Manifest` is a class; slug sanitization recorded; pinned-block cache trade-off made explicit; iteration and spend caps defined (§3.4, §8, Pipeline 2).
9. Invariant test contract as the swarm's coordination surface (§9).

Corrected or qualified against framework reality:

- **`alias Result(T) = Success(T) | Failure` does not compile** — Crystal has no generic aliases. Replaced with `StepOutcome(T)` (§3.1).
- **`Mantle::Message` is a struct**, so the review's "mutate the tool message in place" requires explicit write-back or it silently no-ops. Verified experimentally; guarded by T3 (§2.2, §3.2).
- **`Mantle::Step` discards its working message buffer**, so in-turn shedding is impossible through it as written. This is the largest structural finding in this revision. Resolved by an additive `on_iteration` hook in Mantle rather than a NIGHTMARE-owned loop (§2.1, D1; `mantle` TKT-008).
- **Provider-native reasoning blocks are unrepresentable** in the current Mantle types, and Mantle has only an `OllamaClient`. Moot — Ollama local inference is the only target (§2.2, D2).
- **Salamander has no raw mode** — `Ctrl+C` *does* deliver `SIGINT` here, inverting the review's premise, though cooperative cancellation is still required because a Crystal signal handler cannot unwind the streaming fiber. Single-keypress modals are unavailable; v1 is line mode (§2.5, D3).
- **The usage field is `Response#prompt_eval_count`**, not `usage.prompt_tokens` (§2.4).
- **`Mantle::StepError::MalformedOutput`**, not `MalformedPayload`; `ToolExecutionFailure` was missing from the enum (§2.3, §3.1).
- **`INITIAL_DIVISOR` is 3.5.** `specs.md` §2.5 agrees; a `4.0` value in one dispatch brief is incorrect (§8).

Already correct in the implementation, recorded here as invariants to preserve: nearest-existing-ancestor path resolution and the `root + "/"` prefix check in `Workspace::Environment`, and slug sanitization.
