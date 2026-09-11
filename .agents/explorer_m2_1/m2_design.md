# Milestone 2: Context Engine Architecture & Detailed Design
**Target Path:** `src/nightmare/context/`
**Author:** Explorer Subagent (Milestone 2 Context Engine)
**Date:** 2026-09-11
**Status:** Approved Specification & Implementation Blueprint

---

## 1. Executive Summary & Architectural Position

Milestone 2 implements the core conversational context engine for **NIGHTMARE**, encapsulating:
- **F2.1: Ephemeral Context Store** — Pure in-memory context management; zero disk session files; evaporates on REPL exit.
- **F2.2: Atomic Turn Units** — Turn data structures strictly binding user message, sequence of tool calls & results (`ToolExchange`), and final assistant response.
- **F2.3: Atomic Turn Pruning** — Two-phase sliding window eviction: Phase 1 historical tool output truncation; Phase 2 whole-turn unit eviction. Invariants: never orphan tool call / tool result pairs; never evict active turn.
- **F2.4: In-Turn Tool Shedding** — Active turn defense: when active turn token usage reaches $\ge 85\%$ of `token_hardmax`, truncates older consumed tool outputs to ~200 chars while preserving the last 2 verbatim. User message is strictly protected.
- **F2.5: Self-Calibrating Token Estimator** — Adaptive chars-per-token accounting initialized to 3.5 chars/token, updated via exponential moving average against provider usage feedback.
- **F2.6: Parallel Pristine RAM Transcript & `/save`** — In-memory preservation of un-pruned, un-shed conversational turns for un-truncated Markdown export.
- **F2.7: Pinned Files Working Set** — Live-reread files injected into system prefix, subject to a 60% context budget ceiling and tool redundancy short-circuiting.

### Architectural Diagram
```
                     ┌─────────────────────────────────────────┐
                     │            Nightmare::CLI / REPL        │
                     └────────────────────┬────────────────────┘
                                          │
                        Turn Operations & Prompt Assembly
                                          ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                               Nightmare::Context                                       │
│                                                                                        │
│  ┌───────────────────────┐   ┌───────────────────────┐   ┌──────────────────────────┐  │
│  │     Pinned Files      │   │    TokenCalibrator    │   │       Transcript         │  │
│  │  - Live disk re-read  │   │  - Boot divisor: 3.5  │   │  - Pristine RAM buffer   │  │
│  │  - 60% budget ceiling │   │  - 0.8/0.2 EMA update │   │  - Un-truncated export   │  │
│  │  - Redundancy check   │   │  - Token estimates    │   │  - /save Markdown writer │  │
│  └──────────┬────────────┘   └──────────┬────────────┘   └────────────┬─────────────┘  │
│             │                           │                             │                │
│             └───────────────────┐       │       ┌─────────────────────┘                │
│                                 ▼       ▼       ▼                                      │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                                 SlidingStore                                     │  │
│  │  - FIFO deque of Turn units                                                      │  │
│  │  - Active Turn Rollback (Ctrl+C recovery)                                        │  │
│  │  - In-Turn Tool Shedding (85% budget threshold; last 2 verbatim)                 │  │
│  │  - Two-Phase Sliding Window Pruning (Phase 1 Truncation, Phase 2 Turn Eviction)  │  │
│  │  - Prompt Assembly: Directive + Pinned + History + Active Turn                  │  │
│  └──────────────────────────────────────┬───────────────────────────────────────────┘  │
│                                         │ Array(Mantle::Message)                       │
└─────────────────────────────────────────┼──────────────────────────────────────────────┘
                                          ▼
                     ┌─────────────────────────────────────────┐
                     │            Nightmare::Harness           │
                     │          (Mantle::Step Runner)          │
                     └─────────────────────────────────────────┘
```

---

## 2. File & Module Structure

The context engine resides entirely in `src/nightmare/context/` and is partitioned into four decoupled source files:

```
src/nightmare/context/
├── models.cr           # Turn, ToolExchange, PinnedFile data models
├── calibrator.cr       # TokenCalibrator (EMA estimator, UI meter formatter)
├── sliding_store.cr    # SlidingStore (in-turn shedding, two-phase pruning, rollback)
└── transcript.cr       # Transcript (un-pruned RAM buffer, Markdown export)
```

---

## 3. Data Models (`src/nightmare/context/models.cr`)

### 3.1 `ToolExchange`

A `ToolExchange` models a single tool invocation cycle: an assistant tool call, its execution result, and shedding metadata. It maintains both the active `output` (which may be truncated) and `raw_output` (which preserves pristine execution data for `/save`).

```crystal
require "json"
require "mantle"

module Nightmare::Context
  class ToolExchange
    # Unique identifier of the tool call (matched with tool result)
    property call_id : String

    # Name of the tool invoked (e.g. "read_file", "run_command")
    property name : String

    # Parsed arguments supplied by the model
    property args : Hash(String, JSON::Any)

    # Active output returned to the LLM during prompt assembly (may be truncated)
    property output : String

    # Pristine original output preserved for un-pruned RAM transcript export
    getter raw_output : String

    # Byte size of original un-truncated output
    getter raw_size_bytes : Int32

    # Whether this tool result has been shed/truncated by in-turn or historical shedding
    property? shed : Bool

    def initialize(
      @call_id : String,
      @name : String,
      @args : Hash(String, JSON::Any),
      output : String,
      @shed : Bool = false
    )
      @raw_output = output
      @raw_size_bytes = output.bytesize
      @output = output
    end

    # Sunk tool result truncation
    # Preserves first ~keep_chars characters (default 200) and appends truncation stub
    def truncate!(keep_chars : Int32 = 200) : Nil
      return if @shed
      if @output.size > keep_chars
        prefix = @output[0, keep_chars]
        @output = "#{prefix}\n[... output truncated: was #{@raw_size_bytes} bytes]"
      else
        @output = "#{@output}\n[... output truncated: was #{@raw_size_bytes} bytes]"
      end
      @shed = true
    end

    # Converts tool call into Mantle::Clients::ToolCall structure
    def to_mantle_tool_call : Mantle::Clients::ToolCall
      func = Mantle::Clients::ToolCallFunction.new(
        name: @name,
        arguments: @args.to_json
      )
      Mantle::Clients::ToolCall.new(
        id: @call_id,
        function: func,
        type: "function"
      )
    end

    # Converts tool result into Mantle::Message with role: "tool"
    def to_mantle_tool_message : Mantle::Message
      Mantle::Message.new(
        role: "tool",
        content: @output,
        tool_call_id: @call_id
      )
    end

    # Converts assistant tool call wrapper into Mantle::Message with role: "assistant"
    def to_mantle_assistant_call_message : Mantle::Message
      Mantle::Message.new(
        role: "assistant",
        content: nil,
        tool_calls: [to_mantle_tool_call]
      )
    end
  end
```

### 3.2 `Turn`

A `Turn` is the atomic unit of conversational context. It models the lifecycle:
$$\text{Turn} = \langle \text{User Message},\, [\text{ToolExchange}]^{*},\, \text{Final Assistant Message} \rangle$$

```crystal
  class Turn
    # Prompt text entered by the user
    property user_message : String

    # Sequence of tool calls and results executed within this turn
    property tool_exchanges : Array(ToolExchange)

    # Final textual response from the assistant (nil while turn is in-flight)
    property assistant_message : String?

    # Calibrated estimated token count for this entire turn
    property token_estimate : Int32

    # Timestamp when turn was initiated
    property timestamp : Time

    def initialize(@user_message : String, @timestamp : Time = Time.utc)
      @tool_exchanges = [] of ToolExchange
      @assistant_message = nil
      @token_estimate = 0
    end

    # Indicates whether turn has completed its lifecycle with a final assistant message
    def complete? : Bool
      !@assistant_message.nil?
    end

    # Indicates whether turn is still in-flight (active execution or tool loop)
    def active? : Bool
      !complete?
    end

    # Appends a tool exchange to the active turn
    def add_tool_exchange(exchange : ToolExchange) : Nil
      @tool_exchanges << exchange
    end

    # Completes the turn with the final assistant response
    def complete!(message : String) : Nil
      @assistant_message = message
    end

    # Assembles this turn into a sequence of Mantle::Message objects
    def to_mantle_messages : Array(Mantle::Message)
      msgs = [] of Mantle::Message
      # 1. User message
      msgs << Mantle::Message.new(role: "user", content: @user_message)

      # 2. Intermediate tool exchanges
      @tool_exchanges.each do |exchange|
        msgs << exchange.to_mantle_assistant_call_message
        msgs << exchange.to_mantle_tool_message
      end

      # 3. Final assistant response (if present)
      if final_msg = @assistant_message
        msgs << Mantle::Message.new(role: "assistant", content: final_msg)
      end

      msgs
    end
  end
```

### 3.3 `PinnedFile`

`PinnedFile` models a user-staged file (`/add <path> [--lines S-E]`). Files are **never cached statically in memory**; they are re-read live from disk on every prompt assembly so external disk edits are reflected immediately.

```crystal
  class PinnedFile
    # Path relative to workspace root or canonical
    getter path : String

    # Optional 1-indexed start line (inclusive)
    getter slice_start : Int32?

    # Optional 1-indexed end line (inclusive)
    getter slice_end : Int32?

    # Cached token count calculated on last disk read
    property cached_token_count : Int32

    # Last observed modification time on disk
    property mtime : Time?

    def initialize(
      @path : String,
      @slice_start : Int32? = nil,
      @slice_end : Int32? = nil,
      @cached_token_count : Int32 = 0,
      @mtime : Time? = nil
    )
    end

    # Re-reads content live from disk within root
    def read_content(root : String) : String
      full_path = File.expand_path(@path, root)
      unless File.exists?(full_path)
        return "[File '#{@path}' not found on disk]"
      end

      @mtime = File.info(full_path).modification_time
      lines = File.read_lines(full_path)

      if s = @slice_start, e = @slice_end
        s_idx = [s - 1, 0].max
        e_idx = [e - 1, lines.size - 1].min
        return "" if s_idx > e_idx
        lines[s_idx..e_idx].join("\n")
      else
        lines.join("\n")
      end
    end

    # Formats the pinned file block for injection into prompt assembly
    def formatted_block(root : String) : String
      content = read_content(root)
      range_suffix = if s = @slice_start, e = @slice_end
                       " (lines #{s}-#{e})"
                     else
                       ""
                     end
      "=== PINNED FILE: #{@path}#{range_suffix} ===\n#{content}"
    end
  end
end
```

---

## 4. Self-Calibrating Token Estimator (`src/nightmare/context/calibrator.cr`)

A static `bytes // 4` heuristic undercounts source code and AST formatting by ~25%. `TokenCalibrator` dynamically calibrates its characters-per-token divisor using exponential moving average (EMA) smoothing upon provider usage feedback.

### Calibration Mathematics
$$\text{Divisor}_{\text{new}} = 0.8 \times \text{Divisor}_{\text{prev}} + 0.2 \times \left( \frac{\text{Raw Assembled Characters}}{\text{usage.prompt_tokens}} \right)$$

```crystal
module Nightmare::Context
  class TokenCalibrator
    DEFAULT_DIVISOR = 3.5_f64
    MIN_DIVISOR     = 1.0_f64
    MAX_DIVISOR     = 8.0_f64

    getter divisor : Float64
    getter sample_count : Int32

    def initialize(@divisor : Float64 = DEFAULT_DIVISOR)
      @sample_count = 0
    end

    # Estimates token count for a given text string
    def estimate(text : String) : Int32
      return 0 if text.empty?
      (text.size / @divisor).ceil.to_i
    end

    # Estimates token count for a ToolExchange
    def estimate_exchange(exchange : ToolExchange) : Int32
      # Framing overhead: ~10 tokens for JSON structure and role markers
      overhead = 10
      arg_tokens = estimate(exchange.args.to_json)
      output_tokens = estimate(exchange.output)
      overhead + arg_tokens + output_tokens
    end

    # Estimates token count for a Turn
    def estimate_turn(turn : Turn) : Int32
      tokens = 4 # Base user message framing
      tokens += estimate(turn.user_message)
      turn.tool_exchanges.each do |ex|
        tokens += estimate_exchange(ex)
      end
      if asst = turn.assistant_message
        tokens += 4 + estimate(asst)
      end
      tokens
    end

    # Updates divisor dynamically from provider token usage feedback
    # Only applies when prompt_tokens > 0 and raw_assembled_chars > 0
    def update_with_feedback(raw_assembled_chars : Int32, prompt_tokens : Int32) : Float64
      return @divisor if prompt_tokens <= 0 || raw_assembled_chars <= 0

      observed_divisor = raw_assembled_chars.to_f64 / prompt_tokens.to_f64
      # Clamp observed divisor to sanity range [1.0, 8.0]
      clamped_observed = observed_divisor.clamp(MIN_DIVISOR, MAX_DIVISOR)

      # 0.8 / 0.2 Exponential Moving Average
      @divisor = (0.8 * @divisor) + (0.2 * clamped_observed)
      @sample_count += 1
      @divisor
    end

    # Formats the status line meter with tilde (~) notation
    def format_meter(
      used_tokens : Int32,
      hardmax : Int32,
      turn_count : Int32,
      turn_cap : Int32,
      pinned_count : Int32,
      pinned_tokens : Int32
    ) : String
      "Working Memory: ~#{used_tokens.format} / #{hardmax.format} tokens (Turns: #{turn_count}/#{turn_cap}) | Pinned: #{pinned_count} file#{pinned_count == 1 ? "" : "s"} (~#{pinned_tokens.format}t)"
    end
  end
end
```

---

## 5. Ephemeral Context Engine & Sliding Store (`src/nightmare/context/sliding_store.cr`)

`SlidingStore` is the central coordinator for in-memory context management. It enforces:
1. **Turn Atomicity**: Messages within a turn are never pruned individually.
2. **Active Turn Protection**: The active turn's user prompt is never evicted by sliding window pruning.
3. **In-Turn Tool Shedding (85% Threshold)**: Active turn tool output compression preserving the last 2 verbatim.
4. **Two-Phase Pruning**: Historical tool truncation before whole-turn eviction.
5. **Rollback on Cancellation**: Complete disposal of in-flight turn upon `Ctrl+C`.

### In-Turn Tool Shedding Algorithm
```
When active_turn token usage >= token_hardmax * 0.85:
  1. Inspect tool_exchanges in active_turn.
  2. If tool_exchanges.size <= 2:
       Preserve all verbatim (active working set).
  3. If tool_exchanges.size > 2:
       Target slice = tool_exchanges[0 .. (size - 3)]
       For each exchange in target slice:
         if !exchange.shed?:
           exchange.truncate!(keep_chars: 200)
       Preserve tool_exchanges[-2 .. -1] verbatim.
  4. Recalculate active_turn token estimate.
  5. Active user message is never touched.
```

### Two-Phase Sliding Window Pruning Algorithm
```
When total_estimated_tokens > token_hardmax OR completed_turns.size > turn_cap:
  Phase 1 (Historical Tool Truncation):
    For each turn in completed_turns (oldest to newest):
      For each exchange in turn.tool_exchanges:
        if !exchange.shed? and exchange.output.size > 200:
          exchange.truncate!(keep_chars: 200)
          recalculate turn tokens
          break if total_tokens <= token_hardmax and completed_turns.size <= turn_cap

  Phase 2 (Atomic Turn-Unit Eviction):
    While (total_tokens > token_hardmax OR completed_turns.size > turn_cap) AND has completed turns:
      Evict oldest completed Turn entirely (pop from front of completed turns)
      Recalculate total_tokens
  
  Active Turn Invariant:
    If only the active turn remains and exceeds token_hardmax, it is NOT evicted.
```

### Complete Class Definition
```crystal
require "./models"
require "./calibrator"

module Nightmare::Context
  class BudgetExceededError < Exception; end

  class SlidingStore
    DEFAULT_HARDMAX  = 100_000
    DEFAULT_TURN_CAP = 10
    SHED_THRESHOLD   = 0.85_f64
    PINNED_MAX_RATIO = 0.60_f64

    getter turns : Array(Turn)
    getter pinned_files : Hash(String, PinnedFile)
    getter token_calibrator : TokenCalibrator
    property token_hardmax : Int32
    property turn_cap : Int32
    getter active_turn : Turn?

    def initialize(
      @token_hardmax : Int32 = DEFAULT_HARDMAX,
      @turn_cap : Int32 = DEFAULT_TURN_CAP,
      @token_calibrator : TokenCalibrator = TokenCalibrator.new
    )
      @turns = [] of Turn
      @pinned_files = {} of String => PinnedFile
      @active_turn = nil
    end

    # -------------------------------------------------------------------------
    # Turn Lifecycle
    # -------------------------------------------------------------------------

    # Initiates a new active turn with user message
    def add_user_message(text : String) : Turn
      turn = Turn.new(user_message: text)
      turn.token_estimate = @token_calibrator.estimate_turn(turn)
      @active_turn = turn
      @turns << turn
      turn
    end

    # Records a tool exchange into the active turn
    def record_tool_exchange(
      call_id : String,
      name : String,
      args : Hash(String, JSON::Any),
      output : String
    ) : ToolExchange
      active = @active_turn || raise "Cannot record tool exchange: no active turn in progress"
      exchange = ToolExchange.new(
        call_id: call_id,
        name: name,
        args: args,
        output: output
      )
      active.add_tool_exchange(exchange)
      active.token_estimate = @token_calibrator.estimate_turn(active)

      # Check in-turn tool shedding trigger
      shed_in_turn_tools

      exchange
    end

    # Finalizes the active turn with the assistant response
    def record_assistant_message(text : String) : Nil
      active = @active_turn || raise "Cannot record assistant message: no active turn in progress"
      active.complete!(text)
      active.token_estimate = @token_calibrator.estimate_turn(active)
      @active_turn = nil

      # Prune sliding window after turn completion
      prune_sliding_window
    end

    # Rolls back active in-flight turn on user interrupt (Ctrl+C)
    # Returns the discarded turn so caller can restore user prompt to input buffer
    def rollback_active_turn : Turn?
      active = @active_turn
      return nil unless active

      @turns.delete(active)
      @active_turn = nil
      active
    end

    # Clears all conversational history while keeping pinned files intact
    def clear : Nil
      @turns.clear
      @active_turn = nil
    end

    # -------------------------------------------------------------------------
    # Token Accounting & Queries
    # -------------------------------------------------------------------------

    def completed_turns : Array(Turn)
      @turns.select(&.complete?)
    end

    def active_turn_estimated_tokens : Int32
      if active = @active_turn
        @token_calibrator.estimate_turn(active)
      else
        0
      end
    end

    def total_estimated_tokens(system_directive : String = "", root : String = Dir.current) : Int32
      tokens = @token_calibrator.estimate(system_directive)
      @pinned_files.each_value do |pf|
        tokens += pf.cached_token_count
      end
      @turns.each do |t|
        tokens += @token_calibrator.estimate_turn(t)
      end
      tokens
    end

    # -------------------------------------------------------------------------
    # In-Turn Tool Shedding (Active Turn Defense)
    # -------------------------------------------------------------------------

    # Evaluates active turn against 85% threshold and compresses older consumed tools
    def shed_in_turn_tools : Nil
      active = @active_turn
      return unless active

      budget_limit = (@token_hardmax * SHED_THRESHOLD).to_i
      current_active_tokens = @token_calibrator.estimate_turn(active)

      return if current_active_tokens < budget_limit
      return if active.tool_exchanges.size <= 2

      # Retain last 2 tool outputs verbatim (active working set).
      # Truncate earlier consumed tool results (indices 0 .. size - 3).
      truncate_limit = active.tool_exchanges.size - 2
      (0...truncate_limit).each do |i|
        exchange = active.tool_exchanges[i]
        exchange.truncate!(keep_chars: 200) unless exchange.shed?
      end

      # Recalculate token estimate
      active.token_estimate = @token_calibrator.estimate_turn(active)
    end

    # -------------------------------------------------------------------------
    # Sliding Window Pruning (Historical Turn Eviction)
    # -------------------------------------------------------------------------

    def prune_sliding_window(system_directive : String = "", root : String = Dir.current) : Nil
      # Phase 1: Historical tool result truncation across completed turns
      if over_budget?(system_directive, root)
        completed = completed_turns
        completed.each do |turn|
          turn.tool_exchanges.each do |exchange|
            unless exchange.shed?
              exchange.truncate!(keep_chars: 200)
              turn.token_estimate = @token_calibrator.estimate_turn(turn)
              break unless over_budget?(system_directive, root)
            end
          end
          break unless over_budget?(system_directive, root)
        end
      end

      # Phase 2: Whole atomic turn-unit eviction (oldest completed turn first)
      while over_budget?(system_directive, root) || completed_turns.size > @turn_cap
        oldest_completed = @turns.find(&.complete?)
        break unless oldest_completed # Invariant: Never evict active turn!

        @turns.delete(oldest_completed)
      end
    end

    private def over_budget?(system_directive : String, root : String) : Bool
      total_estimated_tokens(system_directive, root) > @token_hardmax
    end

    # -------------------------------------------------------------------------
    # Pinned Files Working Set
    # -------------------------------------------------------------------------

    def add_pinned_file(
      path : String,
      slice_start : Int32? = nil,
      slice_end : Int32? = nil,
      root : String = Dir.current
    ) : PinnedFile
      pinned = PinnedFile.new(path, slice_start, slice_end)
      content = pinned.read_content(root)
      tokens = @token_calibrator.estimate(content)
      pinned.cached_token_count = tokens

      # Budget ceiling: total pinned tokens must not exceed 60% of token_hardmax
      current_pinned_tokens = @pinned_files.values.sum(&.cached_token_count)
      if (current_pinned_tokens + tokens) > (@token_hardmax * PINNED_MAX_RATIO).to_i
        raise BudgetExceededError.new(
          "Cannot pin '#{path}': total pinned tokens would exceed 60% context budget (#{@token_hardmax * PINNED_MAX_RATIO}t)"
        )
      end

      @pinned_files[path] = pinned
      pinned
    end

    def drop_pinned_file(path : String? = nil) : Bool
      if path
        !@pinned_files.delete(path).nil?
      else
        @pinned_files.clear
        true
      end
    end

    def pinned?(path : String) : Bool
      @pinned_files.has_key?(path)
    end

    def pinned_context_block(root : String = Dir.current) : String
      return "" if @pinned_files.empty?

      String.build do |io|
        io.puts "=== PINNED CONTEXT ==="
        @pinned_files.each_value do |pf|
          content = pf.read_content(root)
          pf.cached_token_count = @token_calibrator.estimate(content)
          io.puts pf.formatted_block(root)
          io.puts
        end
        io.puts "======================"
      end.strip
    end

    # -------------------------------------------------------------------------
    # Prompt Assembly Pipeline
    # -------------------------------------------------------------------------

    # Assembles the full array of Mantle::Message objects for LLM dispatch:
    # 1. System Directive + Pinned Context Block
    # 2. Historical completed turns
    # 3. Current active turn (if present)
    def assemble_mantle_messages(
      system_directive : String,
      root : String = Dir.current
    ) : Array(Mantle::Message)
      messages = [] of Mantle::Message

      # 1. System directive & pinned context
      pinned_block = pinned_context_block(root)
      combined_system = if pinned_block.empty?
                          system_directive
                        else
                          "#{system_directive}\n\n#{pinned_block}"
                        end
      messages << Mantle::Message.new(role: "system", content: combined_system)

      # 2. Historical completed turns
      @turns.each do |turn|
        messages.concat(turn.to_mantle_messages)
      end

      messages
    end
  end
end
```

---

## 6. Parallel Pristine RAM Transcript (`src/nightmare/context/transcript.cr`)

In parallel with `SlidingStore`, NIGHTMARE maintains an un-truncated, un-pruned `Transcript` buffer in RAM. When `/save [path]` is executed:
- Sunk tool results truncated in the active sliding window appear **completely intact** in the exported transcript.
- Pruned historical turns remain present in the transcript.
- Generates standard GitHub Flavored Markdown (GFM).

```crystal
require "./models"

module Nightmare::Context
  class Transcript
    # Pristine turns preserved across the entire REPL session
    getter turns : Array(Turn)

    def initialize
      @turns = [] of Turn
    end

    # Records a completed turn into the permanent transcript buffer
    def record(turn : Turn) : Nil
      @turns << turn
    end

    # Exports un-truncated transcript to a GitHub Flavored Markdown file
    def save_to(destination_path : String) : Int32
      content = export_markdown
      File.write(destination_path, content)
      content.bytesize
    end

    # Formats transcript as clean GitHub Flavored Markdown
    def export_markdown : String
      String.build do |io|
        io.puts "# NIGHTMARE Session Transcript"
        io.puts "*Generated: #{Time.utc.to_s}*\n"

        @turns.each_with_index(1) do |turn, idx|
          io.puts "## Turn #{idx} — #{turn.timestamp.to_s}"
          io.puts "### User"
          io.puts turn.user_message
          io.puts

          turn.tool_exchanges.each do |exchange|
            io.puts "#### Tool Invocation: `#{exchange.name}`"
            io.puts "```json"
            io.puts exchange.args.to_pretty_json
            io.puts "```"
            io.puts "##### Result (Pristine Un-truncated)"
            io.puts "```"
            io.puts exchange.raw_output
            io.puts "```"
            io.puts
          end

          if asst = turn.assistant_message
            io.puts "### Assistant"
            io.puts asst
            io.puts
          end
          io.puts "---\n"
        end
      end
    end
  end
end
```

---

## 7. Invariants, Boundary Conditions & State Transitions

### Invariant Table
| Invariant | Description | Enforcing Mechanism |
| :--- | :--- | :--- |
| **I1: No Orphaned Pairs** | Assistant tool call and matching tool result messages are NEVER separated. | Pruning occurs strictly at `Turn` level; single turn produces both messages during `to_mantle_messages`. |
| **I2: Active Turn Protection** | Active turn user message is NEVER evicted by sliding window pruning. | `prune_sliding_window` explicitly filters on `turn.complete?` and never deletes the active turn. |
| **I3: Working Set Verbatim** | Last 2 tool results in active turn are NEVER truncated by in-turn shedding. | `shed_in_turn_tools` only operates on `active.tool_exchanges[0 .. (size - 3)]`. |
| **I4: Pinned Budget Cap** | Pinned files cannot consume $> 60\%$ of total context window. | `add_pinned_file` calculates token usage and raises `BudgetExceededError` before adding. |
| **I5: Clean Rollback** | `Ctrl+C` purges incomplete active turn without leaving orphaned state. | `rollback_active_turn` removes in-flight turn from `@turns` and returns user prompt for REPL line restoration. |
| **I6: Pristine RAM Transcript** | Tool shedding and sliding window pruning NEVER mutate `raw_output` in RAM. | `ToolExchange#truncate!` modifies `@output` only, leaving `@raw_output` 100% intact for `Transcript`. |

### Turn Lifecycle State Machine
```
   [User Input]
        │
        ▼
   ┌─────────┐
   │ ACTIVE  │◄─────────────────────────────┐
   └────┬────┘                              │
        │                                   │
        ├─────────► [Tool Execution]        │
        │                │                  │
        │                ▼                  │
        │          [ToolExchange]           │
        │                │                  │
        │                ▼                  │
        │        [Check 85% Limit]          │
        │         ├── >= 85%: Truncate 0..N-3
        │         └── <  85%: Keep Verbatim │
        │                │                  │
        │                └──────────────────┘
        │
        ├─────────► [Signal::INT (Ctrl+C)]
        │                │
        │                ▼
        │        [rollback_active_turn]
        │                │
        │                ▼
        │        [Discard Active Turn & Restore Line]
        │
        ▼
 [Assistant Response]
        │
        ▼
   ┌───────────┐
   │ COMPLETE  │
   └─────┬─────┘
         │
         ▼
   [prune_sliding_window]
   ├── Phase 1: Historical Tool Truncation
   └── Phase 2: Whole-Turn Eviction (Oldest First)
```

---

## 8. Verification & Spec Coverage (`spec/context_spec.cr`)

To ensure 100% compliance with acceptance criteria (`AC-C1` through `AC-C7`), the test suite in `spec/context_spec.cr` must validate:

1. **`ToolExchange` & `Turn` Modeling**:
   - Verify `to_mantle_messages` preserves tool call IDs and JSON arguments.
   - Verify `raw_output` remains unchanged when `truncate!` is called.
2. **In-Turn Tool Shedding (Active Turn Defense)**:
   - Enqueue 6 verbose tool exchanges in an active turn.
   - Trigger shedding when token usage $\ge 85\%$ of `token_hardmax`.
   - Assert exchanges 1–4 are truncated (`output` ends with `[... output truncated: was N bytes]`, `shed? == true`).
   - Assert exchanges 5 and 6 remain verbatim (`shed? == false`).
   - Assert active turn user prompt is unmodified.
3. **Turn-Unit Sliding Window Pruning**:
   - Populate store with 5 completed turns with tool exchanges.
   - Exceed `token_hardmax`.
   - Assert Phase 1 truncates historical tool outputs.
   - If still over budget, assert Phase 2 evicts Turn 1 entirely (no orphaned tool call messages).
   - Assert active turn is NOT evicted.
4. **Signal Rollback**:
   - Start active turn with 2 tool exchanges.
   - Call `rollback_active_turn`.
   - Assert store has 0 turns, active turn returned with user prompt intact.
5. **Token Calibrator**:
   - Verify boot divisor is `3.5`.
   - Simulate provider returning `prompt_tokens = 1000` for 2800 characters ($2800 / 1000 = 2.8$).
   - Expected divisor: $0.8 \times 3.5 + 0.2 \times 2.8 = 2.8 + 0.56 = 3.36$.
   - Assert divisor updates smoothly.
6. **Pinned Files Budget & Redundancy**:
   - Add file $> 60\%$ of hardmax -> raises `BudgetExceededError`.
   - Verify `pinned?("src/app.cr")` returns true.
   - Verify disk modifications are immediately reflected in `pinned_context_block`.
7. **Pristine RAM Transcript**:
   - Execute turns with tool shedding.
   - Export via `Transcript#save_to`.
   - Verify exported Markdown contains full un-truncated tool outputs.

---

## 9. Implementation Checklist for Milestone 2

- [x] Architectural design complete (`m2_design.md`)
- [ ] Create `src/nightmare/context/models.cr`
  - [ ] Implement `ToolExchange`
  - [ ] Implement `Turn`
  - [ ] Implement `PinnedFile`
- [ ] Create `src/nightmare/context/calibrator.cr`
  - [ ] Implement `TokenCalibrator` with 0.8/0.2 EMA update
- [ ] Create `src/nightmare/context/sliding_store.cr`
  - [ ] Implement `SlidingStore`
  - [ ] Implement in-turn shedding (85% limit, last 2 verbatim)
  - [ ] Implement two-phase sliding window pruning
  - [ ] Implement active turn rollback
  - [ ] Implement pinned file budget enforcement (60%)
  - [ ] Implement prompt assembly pipeline
- [ ] Create `src/nightmare/context/transcript.cr`
  - [ ] Implement parallel RAM transcript buffer
  - [ ] Implement un-pruned GFM export
- [ ] Create `spec/context_spec.cr`
  - [ ] Full test coverage for all M2 components
- [ ] Run `crystal spec spec/context_spec.cr` and verify zero errors
