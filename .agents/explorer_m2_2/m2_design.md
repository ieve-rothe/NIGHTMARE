# Milestone 2 Technical Design: TokenCalibrator & PinnedFiles

**Document Status**: COMPLETE  
**Author**: Explorer M2.2  
**Target Module**: `src/nightmare/context/`  
**Components**:
1. `Nightmare::Context::TokenCalibrator` (`src/nightmare/context/calibrator.cr`)
2. `Nightmare::Context::PinnedFiles` (`src/nightmare/context/pinned_files.cr`)

---

## 1. Architectural Overview & Context Integration

NIGHTMARE employs an ephemeral, in-memory context engine with atomic turn units and sliding-window pruning. To prevent premature eviction or context overflow, context accounting requires accurate token estimates. Because static rules of thumb (such as `bytes // 4`) severely misestimate programming language syntax, indentation, and AST structures, NIGHTMARE implements a self-calibrating token estimator alongside a pinned files manager.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            Nightmare::Context                               │
│                                                                             │
│  ┌───────────────────────┐             ┌─────────────────────────────────┐  │
│  │    TokenCalibrator    │             │           PinnedFiles           │  │
│  │  - Divisor: 1.0..10.0 │             │  - Working set files            │  │
│  │  - EMA Smoothing      │◄────────────┤  - Budget cap: 60% hardmax      │  │
│  │  - Central XDG Cache  │  estimates  │  - Live re-read on mtime change │  │
│  │  - Fast text/msg/turn │             │  - Redundancy short-circuit     │  │
│  └───────────┬───────────┘             └────────────────┬────────────────┘  │
│              │                                          │                   │
│              │ estimates tokens                         │ pinned block      │
│              ▼                                          ▼                   │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                             SlidingStore                              │  │
│  │  - Prompt Assembly: [System Directive + Pinned Files] + [Turns]       │  │
│  │  - Sliding Window Turn Eviction (token_hardmax)                       │  │
│  │  - In-Turn Tool Shedding (token_hardmax * 0.85)                       │  │
│  └───────────────────────────────────┬───────────────────────────────────┘  │
└──────────────────────────────────────┼──────────────────────────────────────┘
                                       │
                         Feedback Loop │ Provider prompt_tokens
                                       ▼
                     ┌───────────────────────────────────┐
                     │         Nightmare::Harness        │
                     │  - Captures prompt_eval_count     │
                     │  - Invokes calibrator.calibrate   │
                     └───────────────────────────────────┘
```

### 1.1 Zero Repository Litter Invariant
Both `TokenCalibrator` and `PinnedFiles` strictly honor the FreeDesktop XDG Base Directory specification and workspace anchoring:
- The persistent calibrator cache is stored **exclusively** at:
  `$XDG_CACHE_HOME/nightmare/workspaces/<workspace_id>/calibrator.json`
- Zero files, cache entries, or logs are ever written inside the target repository (`@root`).
- All pinned file paths are validated against `Environment#sanitize_path` to prevent path traversal (`../`) and external symlink escapes.

---

## 2. Component 1: `TokenCalibrator` (`src/nightmare/context/calibrator.cr`)

### 2.1 Exponential Moving Average (EMA) Algorithm
The token calibrator dynamically adjusts the character-to-token ratio based on empirical feedback returned by LLM providers (`usage.prompt_tokens` or `prompt_eval_count`).

#### Mathematical Formula:
$$\text{Sample Ratio} = \frac{\text{Raw Assembled Chars}}{\text{usage.prompt\_tokens}}$$

$$\text{Divisor}_{\text{new}} = (0.8 \times \text{Divisor}_{\text{prev}}) + (0.2 \times \text{Sample Ratio})$$

$$\text{Divisor}_{\text{clamped}} = \max(1.0, \min(10.0, \text{Divisor}_{\text{new}}))$$

#### Invariants & Constraints:
1. **Initial Default Divisor**: Starts at `4.0` characters per token.
2. **Strict Clamping**: Clamped strictly to the range `[1.0, 10.0]` chars/token.
   - `1.0`: Extreme upper bound for dense byte-pair tokenization (e.g. CJK or dense hex).
   - `10.0`: Extreme lower bound for sparse whitespace / repetitive text.
3. **Weighting Factor ($\alpha$)**:
   - `ALPHA = 0.2` (weight of the incoming empirical measurement).
   - `1.0 - ALPHA = 0.8` (weight of historical smoothed divisor).
4. **Outlier Dampening**: The incoming `Sample Ratio` is clamped to `[1.0, 10.0]` prior to smoothing to prevent single anomalous turns (e.g. 1-character prompts with large model system priming) from causing sudden jumps.

### 2.2 Cache Persistence Schema
The calibrator serializes its state to a compact JSON file in `$XDG_CACHE_HOME/nightmare/workspaces/<id>/calibrator.json`.

```json
{
  "version": 1,
  "divisor": 3.8421,
  "samples_count": 17,
  "last_updated_at": "2026-09-11T18:25:30.123456789Z"
}
```

#### Persistence Rules:
- **Directory Creation**: Ensures `$XDG_CACHE_HOME/nightmare/workspaces/<id>/` exists prior to writing via `Dir.mkdir_p`.
- **Atomic Writes**: Writes to a temporary file (`calibrator.json.tmp.<pid>`) and renames to `calibrator.json` to prevent corruption if the process is terminated during write.
- **Resilient Loading**: If the cache file does not exist, starts with `DEFAULT_DIVISOR = 4.0`. If the file is unparseable or corrupted, logs a warning (or silently recovers) and defaults to `4.0` without interrupting startup.
- **Auto-Save on Calibration**: Every call to `calibrate` that updates the divisor automatically persists the state if a `@cache_path` is present.

### 2.3 Token Estimation Methods
The calibrator provides fast, non-blocking token estimation methods for all context levels:

1. **`estimate_text(text : String?) : Int32`**:
   - If `text.nil?` or `text.empty?`, returns `0`.
   - Returns `(text.size / @divisor).ceil.to_i`. Ceiling ensures non-empty text counts as at least 1 token.
2. **`estimate_chars(char_count : Int32) : Int32`**:
   - Fast numeric conversion: `char_count <= 0 ? 0 : (char_count / @divisor).ceil.to_i`.
3. **`estimate_message(message : Mantle::Message) : Int32`**:
   - Sums characters across:
     - `message.content` (if present)
     - `message.role` (e.g., "user", "assistant", "system", "tool")
     - `message.tool_call_id` (if present)
     - `message.tool_calls`: iterates over each `ToolCall`, adding `id.size`, `function.name.size`, and JSON stringified `function.arguments`.
   - Computes base tokens: `(total_chars / @divisor).ceil.to_i`.
   - Adds **4 tokens** for ChatML message framing overhead (`<|im_start|>{role}\n...<|im_end|>\n`).
4. **`estimate_messages(messages : Enumerable(Mantle::Message)) : Int32`**:
   - Sums `estimate_message(m)` for each message in the sequence.
   - Adds **3 tokens** for generation prompt priming (`<|im_start|>assistant\n`).
5. **`estimate_tool_exchange(exchange : ToolExchange) : Int32`**:
   - Estimates the assistant tool call framing plus the tool result message content.
6. **`estimate_turn(turn : Turn) : Int32`**:
   - Estimates `turn.user_message` + all `turn.tool_exchanges` + optional `turn.assistant_message`.
7. **`format_estimate(tokens : Int32) : String`**:
   - Emits formatted string with leading tilde (`~`) and thousands separator (e.g. `~2,450 tokens`).

### 2.4 Complete Type Specification (`calibrator.cr`)

```crystal
# src/nightmare/context/calibrator.cr
require "json"
require "mutex"
require "mantle/clients/message"
require "../workspace/environment"

module Nightmare::Context
  class TokenCalibrator
    DEFAULT_DIVISOR = 4.0_f64
    MIN_DIVISOR     = 1.0_f64
    MAX_DIVISOR     = 10.0_f64
    ALPHA           = 0.2_f64
    MESSAGE_OVERHEAD_TOKENS = 4
    PRIMING_OVERHEAD_TOKENS = 3

    getter divisor : Float64
    getter samples_count : Int32
    getter cache_path : String?
    getter last_updated_at : Time?

    struct CacheData
      include JSON::Serializable

      property version : Int32
      property divisor : Float64
      property samples_count : Int32
      property last_updated_at : Time?

      def initialize(@version : Int32, @divisor : Float64, @samples_count : Int32, @last_updated_at : Time?)
      end
    end

    def initialize(@cache_path : String? = nil, initial_divisor : Float64 = DEFAULT_DIVISOR)
      @divisor = initial_divisor.clamp(MIN_DIVISOR, MAX_DIVISOR)
      @samples_count = 0
      @last_updated_at = nil
      @lock = Mutex.new

      load_from_cache if @cache_path
    end

    # Factory method binding to a Workspace::Environment
    def self.for_environment(env : Workspace::Environment) : self
      cache_file = File.join(env.cache_dir, "calibrator.json")
      new(cache_path: cache_file)
    end

    # Calibrate divisor using empirical feedback from provider.
    # Returns the updated divisor.
    def calibrate(raw_assembled_chars : Int32, prompt_tokens : Int32) : Float64
      return @divisor if raw_assembled_chars <= 0 || prompt_tokens <= 0

      @lock.synchronize do
        # 1. Compute empirical sample ratio and clamp to plausible bounds
        sample_ratio = (raw_assembled_chars.to_f64 / prompt_tokens.to_f64).clamp(MIN_DIVISOR, MAX_DIVISOR)

        # 2. Apply Exponential Moving Average (EMA)
        # Divisor_new = 0.8 * Divisor_prev + 0.2 * sample_ratio
        new_divisor = ((1.0 - ALPHA) * @divisor + ALPHA * sample_ratio)

        # 3. Clamp smoothed divisor to absolute [MIN_DIVISOR, MAX_DIVISOR]
        @divisor = new_divisor.clamp(MIN_DIVISOR, MAX_DIVISOR)
        @samples_count += 1
        @last_updated_at = Time.utc

        save_to_cache if @cache_path
        @divisor
      end
    end

    # Estimates token count from plain string
    def estimate_text(text : String?) : Int32
      return 0 if text.nil? || text.empty?
      (text.size.to_f64 / @divisor).ceil.to_i
    end

    # Estimates token count from raw character count
    def estimate_chars(char_count : Int32) : Int32
      return 0 if char_count <= 0
      (char_count.to_f64 / @divisor).ceil.to_i
    end

    # Estimates token count of a Mantle::Message including protocol framing
    def estimate_message(message : Mantle::Message) : Int32
      chars = message.role.size
      if content = message.content
        chars += content.size
      end
      if tcid = message.tool_call_id
        chars += tcid.size
      end
      if tool_calls = message.tool_calls
        tool_calls.each do |tc|
          chars += tc.id.size
          chars += tc.function.name.size
          chars += tc.function.arguments.to_s.size
        end
      end

      base_tokens = estimate_chars(chars)
      base_tokens + MESSAGE_OVERHEAD_TOKENS
    end

    # Estimates token count of an entire array of Mantle::Message objects
    def estimate_messages(messages : Enumerable(Mantle::Message)) : Int32
      total = 0
      messages.each do |msg|
        total += estimate_message(msg)
      end
      total > 0 ? (total + PRIMING_OVERHEAD_TOKENS) : 0
    end

    # Helper formatting token count with tilde and commas (~1,234)
    def format_estimate(tokens : Int32) : String
      formatted = tokens.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
      "~#{formatted}"
    end

    # Load serialized divisor from disk
    def load_from_cache : Bool
      path = @cache_path
      return false unless path && File.exists?(path)

      begin
        content = File.read(path)
        data = CacheData.from_json(content)
        @divisor = data.divisor.clamp(MIN_DIVISOR, MAX_DIVISOR)
        @samples_count = data.samples_count
        @last_updated_at = data.last_updated_at
        true
      rescue ex : Exception
        # Gracefully handle unparseable or corrupted cache
        @divisor = DEFAULT_DIVISOR
        false
      end
    end

    # Persist state atomically to disk
    def save_to_cache : Nil
      path = @cache_path
      return unless path

      begin
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)

        data = CacheData.new(
          version: 1,
          divisor: @divisor,
          samples_count: @samples_count,
          last_updated_at: @last_updated_at
        )

        tmp_file = "#{path}.tmp.#{Process.pid}"
        File.write(tmp_file, data.to_pretty_json)
        File.rename(tmp_file, path)
      rescue ex : Exception
        # Suppress filesystem write errors to never crash REPL
      end
    end

    # For testing: reset to initial default
    def reset!(initial_divisor : Float64 = DEFAULT_DIVISOR)
      @lock.synchronize do
        @divisor = initial_divisor.clamp(MIN_DIVISOR, MAX_DIVISOR)
        @samples_count = 0
        @last_updated_at = nil
      end
    end
  end
end
```

---

## 3. Component 2: `PinnedFiles` (`src/nightmare/context/pinned_files.cr`)

### 3.1 Role & Requirements
The pinned files working set allows users to mount critical project files directly into the LLM's system/context block across all turns.
Key architectural requirements:
1. **Budget Cap**: Total estimated tokens in all pinned files cannot exceed **60% of `token_hardmax`**.
   $$\text{Max Pinned Tokens} = \lfloor \text{token\_hardmax} \times 0.60 \rfloor$$
   If an `/add` operation would exceed this threshold, it is strictly rejected with a `BudgetExceededError`.
2. **Live Re-read on Prompt Assembly**:
   Pinned files are never statically frozen in memory. On every prompt assembly, the manager stat-checks each file's modification timestamp (`mtime`). If the file has changed on disk (either modified by the user in an external editor or modified by a tool execution like `write_file` or `replace_in_file`), the disk content is re-read live.
3. **Line Slicing**:
   Supports 1-indexed line ranges (e.g. `--lines 10-50`). Only the requested slice is injected into context, and mtime changes re-slice the file cleanly.
4. **Redundancy Short-Circuit Helper**:
   If the LLM triggers a `read_file` tool call for a path that is already pinned and covers the requested lines, the tool short-circuits with a zero-token reference notice:
   `[Notice: Path 'src/app.cr' is already pinned in the active context block. Refer to pinned context above.]`
5. **Path Sandboxing**:
   All paths are canonicalized and verified within `@root` using `Workspace::Environment#sanitize_path`. Pinned files cannot escape the repository or target `.git/`.

### 3.2 Data Models

#### `PinnedFile` Model:
```crystal
module Nightmare::Context
  class PinnedFile
    getter path : String             # Canonical realpath on disk
    getter display_path : String     # Relative path from workspace root
    getter line_start : Int32?       # 1-indexed start line (inclusive), or nil
    getter line_end : Int32?         # 1-indexed end line (inclusive), or nil
    property content : String        # Fresh content of file or slice
    property estimated_tokens : Int32
    property mtime : Time            # Disk mtime at last read
    property file_size_bytes : Int64 # Disk size in bytes
    property line_count : Int32      # Total lines in content

    def initialize(
      @path : String,
      @display_path : String,
      @content : String,
      @estimated_tokens : Int32,
      @mtime : Time,
      @file_size_bytes : Int64,
      @line_count : Int32,
      @line_start : Int32? = nil,
      @line_end : Int32? = nil
    )
    end

    def sliced? : Bool
      !@line_start.nil? || !@line_end.nil?
    end

    def header_label : String
      if sliced?
        "=== PINNED FILE: #{@display_path} (lines #{@line_start}-#{@line_end}) ==="
      else
        "=== PINNED FILE: #{@display_path} ==="
      end
    end

    def formatted_block : String
      "#{header_label}\n#{@content}"
    end
  end
end
```

### 3.3 Manager Design & Algorithms

#### Budget Cap Calculation:
Let $T_{\text{hard}}$ be `token_hardmax`. The pinned budget limit is:
$$B_{\text{pinned}} = \lfloor T_{\text{hard}} \times 0.60 \rfloor$$

When `/add <path>` is executed:
1. Canonical path is resolved.
2. Read proposed file (or slice) content.
3. Compute proposed token count: $K_{\text{new}} = \text{calibrator.estimate\_text}(\text{content})$.
4. If path is already pinned, compute current token contribution $K_{\text{existing}}$; otherwise $K_{\text{existing}} = 0$.
5. Test candidate total:
   $$T_{\text{candidate}} = T_{\text{current}} - K_{\text{existing}} + K_{\text{new}}$$
6. If $T_{\text{candidate}} > B_{\text{pinned}}$, reject with `BudgetExceededError`:
   `"Cannot pin 'src/large.cr': estimated ~3,500 tokens would bring pinned context to ~62,000 tokens, exceeding the 60% budget cap (60,000 tokens of 100,000 hardmax)."`

#### Live Re-read Algorithm (`refresh_if_modified!`):
Called before assembling prompt messages for Mantle:
1. Acquire mutex lock.
2. Iterate through each `PinnedFile` in `@files`:
   - Perform `stat(2)` via `File.info?(file.path)`.
   - If file was removed from disk:
     - Mark as deleted / retain cached content with a notice: `"[Notice: File was deleted from disk; cached snapshot retained]"`.
   - If `info.modification_time != file.mtime`:
     - Re-read raw content from disk.
     - If `file.sliced?`, re-apply line slicing `[start-1 .. end-1]`.
     - Re-calculate tokens: `new_tokens = @calibrator.estimate_text(new_content)`.
     - Update `file.content = new_content`, `file.mtime = info.modification_time`, `file.estimated_tokens = new_tokens`, `file.file_size_bytes = info.size`, `file.line_count = new_content.lines.size`.
     - Mark `any_modified = true`.
3. Return `any_modified : Bool`.

#### Redundancy Short-Circuit Algorithm (`redundancy_notice`):
Called by tool execution harness when `read_file(path, offset, limit)` is dispatched:
1. Sanitize/canonicalize `path`.
2. Check if `@files.has_key?(canonical_path)`. If not, return `nil`.
3. If pinned:
   - Check coverage:
     - If `pinned_file.sliced?`:
       - Let pinned range be $[S_p, E_p]$.
       - If `offset` and `limit` are passed: requested range is $[S_r, E_r] = [\text{offset}, \text{offset} + \text{limit} - 1]$.
       - If $S_r \ge S_p$ and $E_r \le E_p$, the request is **fully contained**.
       - Otherwise, return `nil` (model needs lines outside the pinned slice, so allow tool execution).
     - If not sliced (entire file is pinned), it is **always fully contained**.
4. Return formatted short-circuit message:
   `"[Notice: Path '#{pinned.display_path}' is already pinned in the active context block. Refer to pinned context above.]"`

### 3.4 Complete Type Specification (`pinned_files.cr`)

```crystal
# src/nightmare/context/pinned_files.cr
require "file_utils"
require "mutex"
require "./calibrator"
require "../workspace/environment"
require "../exceptions"

module Nightmare::Context
  class BudgetExceededError < Error
  end

  class PinnedFiles
    PINNED_BUDGET_RATIO = 0.60_f64

    getter root : String
    getter token_hardmax : Int32
    getter calibrator : TokenCalibrator

    def initialize(@root : String, @calibrator : TokenCalibrator, @token_hardmax : Int32 = 100_000)
      @files = Hash(String, PinnedFile).new # Keyed by canonical realpath
      @lock = Mutex.new
    end

    # Factory method binding to Workspace::Environment
    def self.for_environment(env : Workspace::Environment, calibrator : TokenCalibrator, token_hardmax : Int32 = 100_000) : self
      new(root: env.root, calibrator: calibrator, token_hardmax: token_hardmax)
    end

    # Maximum allowed tokens for all pinned files combined
    def max_budget_tokens : Int32
      (@token_hardmax.to_f64 * PINNED_BUDGET_RATIO).to_i
    end

    # Total estimated tokens currently pinned
    def total_estimated_tokens : Int32
      @lock.synchronize do
        @files.values.sum(&.estimated_tokens)
      end
    end

    # Number of pinned files
    def count : Int32
      @lock.synchronize { @files.size }
    end

    # Returns true if no files are pinned
    def empty? : Bool
      @lock.synchronize { @files.empty? }
    end

    # Returns array of all pinned files sorted by relative display path
    def list : Array(PinnedFile)
      @lock.synchronize do
        @files.values.sort_by(&.display_path)
      end
    end

    # Add or update a pinned file, optionally sliced by 1-indexed line range
    def add(path : String, line_start : Int32? = nil, line_end : Int32? = nil) : PinnedFile
      @lock.synchronize do
        # 1. Resolve and validate path containment within workspace root
        canonical_path = resolve_and_verify_path(path)

        unless File.exists?(canonical_path)
          raise File::NotFoundError.new("File not found: #{path}")
        end

        if Dir.exists?(canonical_path)
          raise ArgumentError.new("Cannot pin directory: #{path}. Only regular files may be pinned.")
        end

        info = File.info(canonical_path)
        raw_content = File.read(canonical_path)

        # 2. Process optional line slicing (1-indexed, inclusive)
        content, actual_start, actual_end = process_line_slice(raw_content, line_start, line_end)

        # 3. Estimate token count with calibrator
        file_tokens = @calibrator.estimate_text(content)

        # 4. Enforce 60% budget cap
        existing_tokens = @files[canonical_path]?.try(&.estimated_tokens) || 0
        current_total = @files.values.sum(&.estimated_tokens)
        new_total = current_total - existing_tokens + file_tokens
        max_tokens = max_budget_tokens

        if new_total > max_tokens
          display = relative_path(canonical_path)
          raise BudgetExceededError.new(
            "Cannot pin '#{display}': estimated ~#{file_tokens} tokens would bring pinned context " \
            "to ~#{new_total} tokens, exceeding the 60% budget cap (#{max_tokens} of #{@token_hardmax} tokens)."
          )
        end

        # 5. Create entry and save
        display_path = relative_path(canonical_path)
        lines = content.lines
        entry = PinnedFile.new(
          path: canonical_path,
          display_path: display_path,
          content: content,
          estimated_tokens: file_tokens,
          mtime: info.modification_time,
          file_size_bytes: info.size,
          line_count: lines.size,
          line_start: actual_start,
          line_end: actual_end
        )

        @files[canonical_path] = entry
        entry
      end
    end

    # Remove a pinned file by path. Returns true if removed, false if not found.
    def remove(path : String) : Bool
      @lock.synchronize do
        canonical_path = begin
          resolve_and_verify_path(path)
        rescue
          nil
        end

        if canonical_path && @files.has_key?(canonical_path)
          @files.delete(canonical_path)
          true
        else
          # Fallback: check matching relative display paths
          clean = path.lstrip("./")
          if key = @files.keys.find { |k| @files[k].display_path == clean }
            @files.delete(key)
            true
          else
            false
          end
        end
      end
    end

    # Unpins all files
    def clear : Nil
      @lock.synchronize do
        @files.clear
      end
    end

    # Live re-read: inspects mtime of all pinned files and refreshes content if modified.
    # Returns true if any file was refreshed.
    def refresh_if_modified! : Bool
      @lock.synchronize do
        any_modified = false

        @files.each do |canonical_path, entry|
          info = File.info?(canonical_path)
          next unless info

          # Check if file has been modified on disk
          if info.modification_time != entry.mtime
            begin
              raw = File.read(canonical_path)
              new_content, actual_start, actual_end = process_line_slice(raw, entry.line_start, entry.line_end)
              new_tokens = @calibrator.estimate_text(new_content)

              entry.content = new_content
              entry.mtime = info.modification_time
              entry.file_size_bytes = info.size
              entry.line_count = new_content.lines.size
              entry.estimated_tokens = new_tokens
              any_modified = true
            rescue ex : Exception
              # If read fails mid-turn, keep previous cached snapshot
            end
          end
        end

        any_modified
      end
    end

    # Redundancy short-circuit helper: checks if path is already pinned and covers requested range.
    # Returns the formatted notice string if covered, nil otherwise.
    def redundancy_notice(path : String, offset : Int32? = nil, limit : Int32? = nil) : String?
      @lock.synchronize do
        canonical = begin
          resolve_and_verify_path(path)
        rescue
          return nil
        end

        entry = @files[canonical]?
        return nil unless entry

        # Check if line range is fully covered
        if entry.sliced?
          start_line = entry.line_start.not_nil!
          end_line = entry.line_end.not_nil!

          if offset && limit
            req_start = offset
            req_end = offset + limit - 1
            # If requested window falls completely within the pinned slice
            return nil unless (req_start >= start_line && req_end <= end_line)
          else
            # Requesting whole file but only slice is pinned -> not fully covered
            return nil
          end
        end

        "[Notice: Path '#{entry.display_path}' is already pinned in the active context block. Refer to pinned context above.]"
      end
    end

    # Renders the formatted markdown text block of all pinned files for prompt assembly
    def render_prompt_block : String
      @lock.synchronize do
        return "" if @files.empty?

        blocks = @files.values.sort_by(&.display_path).map(&.formatted_block)
        blocks.join("\n\n")
      end
    end

    # Update hardmax dynamically (e.g. if user switches models)
    def update_hardmax(new_hardmax : Int32) : Nil
      @lock.synchronize do
        @token_hardmax = new_hardmax
      end
    end

    # Private helper: resolve canonical path and check containment
    private def resolve_and_verify_path(path : String) : String
      expanded = if Path.new(path).absolute?
        File.expand_path(path)
      else
        File.expand_path(path, @root)
      end

      real = File.realpath(expanded)

      # Containment check
      prefix = @root.ends_with?('/') ? @root : "#{@root}/"
      unless real == @root || real.starts_with?(prefix)
        raise SecurityError.new("Path traversal violation: target \"#{path}\" resolves outside root \"#{@root}\"")
      end

      # Reject writes/pins to .git
      rel = Path.new(real).relative_to(@root).to_s
      if rel == ".git" || rel.starts_with?(".git/")
        raise SecurityError.new("Access denied: .git directory is protected")
      end

      real
    end

    private def relative_path(canonical : String) : String
      Path.new(canonical).relative_to(@root).to_s
    end

    private def process_line_slice(
      raw : String,
      line_start : Int32?,
      line_end : Int32?
    ) : Tuple(String, Int32?, Int32?)
      return {raw, nil, nil} if line_start.nil? && line_end.nil?

      all_lines = raw.lines
      total_lines = all_lines.size

      start_idx = line_start ? line_start.clamp(1, [total_lines, 1].max) : 1
      end_idx = line_end ? line_end.clamp(start_idx, [total_lines, 1].max) : total_lines

      if line_start && line_end && line_start > line_end
        raise ArgumentError.new("Invalid line range: start line (#{line_start}) cannot exceed end line (#{line_end})")
      end

      slice = if all_lines.empty?
        ""
      else
        all_lines[(start_idx - 1)..(end_idx - 1)].join("\n")
      end

      {slice, start_idx, end_idx}
    end
  end
end
```

---

## 4. Integration Contracts & Prompt Assembly Pipeline

### 4.1 Integration with `SlidingStore`
In `src/nightmare/context/sliding_store.cr`:
```crystal
class SlidingStore
  getter token_calibrator : TokenCalibrator
  getter pinned_files : PinnedFiles
  getter turns : Array(Turn)

  def initialize(@token_hardmax : Int32 = 100_000, @env : Workspace::Environment? = nil)
    @token_calibrator = @env ? TokenCalibrator.for_environment(@env.not_nil!) : TokenCalibrator.new
    @pinned_files = @env ? PinnedFiles.for_environment(@env.not_nil!, @token_calibrator, @token_hardmax) : PinnedFiles.new(Dir.current, @token_calibrator, @token_hardmax)
    @turns = [] of Turn
  end

  # Prompt Assembly Pipeline
  def assemble_mantle_messages(system_directive : String) : Array(Mantle::Message)
    # 1. Trigger live re-read for pinned files if disk files changed
    @pinned_files.refresh_if_modified!

    # 2. Build root System Message: Directive + Pinned Files Block
    pinned_block = @pinned_files.render_prompt_block
    full_system_content = if pinned_block.empty?
      system_directive
    else
      "#{system_directive}\n\n#{pinned_block}"
    end

    messages = [Mantle::Message.new(role: "system", content: full_system_content)]

    # 3. Add sliding window historical turns & active turn...
    # (orchestrated by SlidingStore)
    messages
  end
end
```

### 4.2 Integration with Mantle Step Harness
When an LLM call finishes in `Nightmare::Harness::StepRunner`:
```crystal
# If provider returned prompt evaluation count
if (eval_tokens = response.prompt_eval_count) && eval_tokens > 0
  raw_chars = assembled_prompt_chars # Measured during prompt assembly
  store.token_calibrator.calibrate(raw_chars, eval_tokens)
end
```

### 4.3 Integration with Read-Only Tool `read_file`
In `src/nightmare/tools/observation.cr`:
```crystal
class ReadFileTool < BaseTool
  def execute(args : Hash(String, JSON::Any), context : ExecutionContext) : ToolResult
    path = args["path"].as_s
    offset = args["offset"]?.try(&.as_i?)
    limit = args["limit"]?.try(&.as_i?)

    # Redundancy Short-Circuit Check
    if notice = context.pinned_files.redundancy_notice(path, offset, limit)
      return ToolResult.success(notice)
    end

    # Normal file read execution...
  end
end
```

---

## 5. Edge Cases & Boundary Conditions

| # | Scenario | Component | Input Condition | Expected Behavior & Invariant |
|---|----------|-----------|-----------------|-------------------------------|
| 1 | Zero prompt tokens returned | `TokenCalibrator` | `prompt_tokens = 0` | Calibration skipped; divisor remains unchanged; division by zero prevented. |
| 2 | Extreme outlier ratio (astronomical tokens) | `TokenCalibrator` | 10 chars, 500 tokens (ratio 0.02) | Ratio clamped to `MIN_DIVISOR = 1.0`; smoothed divisor clamped to `[1.0, 10.0]`. |
| 3 | Extreme outlier ratio (huge chars, tiny tokens) | `TokenCalibrator` | 50,000 chars, 5 tokens (ratio 10,000) | Ratio clamped to `MAX_DIVISOR = 10.0`; smoothed divisor clamped to `[1.0, 10.0]`. |
| 4 | Corrupted cache JSON | `TokenCalibrator` | `$XDG_CACHE_HOME/.../calibrator.json` invalid JSON | Rescues `JSON::ParseException`; falls back cleanly to `DEFAULT_DIVISOR = 4.0`. |
| 5 | Cache dir does not exist | `TokenCalibrator` | First run on fresh workspace | Creates parent directory via `Dir.mkdir_p`; saves cache cleanly without errors. |
| 6 | Pinned file exceeds 60% hardmax | `PinnedFiles` | Adding 70,000 token file when hardmax = 100,000 | Raises `BudgetExceededError`; file is not added; existing pinned files untouched. |
| 7 | Path traversal in `/add` | `PinnedFiles` | `/add ../../etc/passwd` | Raises `SecurityError`; execution aborted before reading file. |
| 8 | Protected `.git/` in `/add` | `PinnedFiles` | `/add .git/config` | Raises `SecurityError` (.git is protected); pin rejected. |
| 9 | Pinned file modified on disk | `PinnedFiles` | External editor edits pinned file | `refresh_if_modified!` detects mtime delta, re-reads file, re-estimates tokens. |
| 10 | Pinned file deleted on disk | `PinnedFiles` | File removed while REPL is running | `refresh_if_modified!` preserves last known cached snapshot, preventing crash. |
| 11 | Line slice with invalid range | `PinnedFiles` | `line_start: 50, line_end: 10` | Raises `ArgumentError` ("start line cannot exceed end line"). |
| 12 | Line slice beyond EOF | `PinnedFiles` | 20-line file, requested `--lines 10-100` | Clamped to total lines: lines 10 to 20 returned cleanly. |
| 13 | Partial line slice redundancy check | `PinnedFiles` | File pinned with lines 1-50; tool calls `read_file` lines 60-100 | Returns `nil`; redundancy check does not trigger because requested range is outside pinned range. |

---

## 6. Unit Test Specifications

The following test suites must be implemented in `spec/context_spec.cr` (or dedicated `spec/context/calibrator_spec.cr` and `spec/context/pinned_files_spec.cr`):

### 6.1 `TokenCalibrator` Spec Suite
1. **Initial State**:
   - Default divisor is `4.0`.
   - Sample count is `0`.
   - `estimate_text("")` returns `0`.
   - `estimate_text("1234")` returns `1`.
2. **Smoothing Formula Verification**:
   - Starting at `4.0`:
   - Calibrate with `1000` chars and `200` tokens (empirical ratio = `5.0`).
   - Expected divisor: $0.8 \times 4.0 + 0.2 \times 5.0 = 3.2 + 1.0 = 4.2$.
   - Sample count increments to `1`.
3. **Clamping Bounds**:
   - Starting at `1.5`, calibrate with `10` chars and `100` tokens (ratio clamped to `1.0`):
     $0.8 \times 1.5 + 0.2 \times 1.0 = 1.4$.
   - Multiple extreme updates cannot push divisor below `1.0` or above `10.0`.
4. **Cache Serialization & Roundtrip**:
   - Writes to temp file; creates a new instance pointing to same path; loads exact divisor and sample count.
   - Handles corrupted JSON by reverting to default `4.0`.
5. **Message and Turn Estimation**:
   - Correctly accounts for role, content, tool calls, and framing overhead.

### 6.2 `PinnedFiles` Spec Suite
1. **Adding and Listing Files**:
   - Adds regular file in temp workspace; verifies `path`, `display_path`, `content`, and token estimate.
   - Lists files alphabetically by relative path.
2. **Budget Cap Enforcement (60%)**:
   - With `hardmax = 1,000`, budget is `600` tokens.
   - Adding a file estimated at `700` tokens raises `BudgetExceededError`.
   - Adding two files totaling `650` tokens rejects the second file and keeps the first.
3. **Live Re-read on Mtime Change**:
   - Pin file with content `"version 1"`.
   - Update file content to `"version 2"` on disk (updating mtime).
   - Calling `refresh_if_modified!` returns `true` and updates `entry.content` to `"version 2"`.
4. **Line Slicing**:
   - File with 10 lines: pin with `line_start: 3, line_end: 6`.
   - Verify content contains exactly lines 3, 4, 5, and 6.
   - Verify header is `=== PINNED FILE: <path> (lines 3-6) ===`.
5. **Redundancy Short-Circuit**:
   - Pinned entire file `src/app.cr`.
   - Calling `redundancy_notice("src/app.cr")` returns notice string.
   - Calling `redundancy_notice("src/other.cr")` returns `nil`.
   - Pinned with lines 10..50:
     - `redundancy_notice("src/app.cr", offset: 15, limit: 10)` (lines 15..24) returns notice.
     - `redundancy_notice("src/app.cr", offset: 60, limit: 10)` (lines 60..69) returns `nil`.
6. **Path Traversal & Security**:
   - Pinning `../../etc/passwd` raises `SecurityError`.
   - Pinning `.git/config` raises `SecurityError`.
