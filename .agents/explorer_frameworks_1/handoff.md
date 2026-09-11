# Handoff Report: Framework Exploration (Mantle & Salamander)

## 1. Observation

1. **Mantle Specifications and Test Suite**:
   - `mantle/shard.yml`: Lines 1-14 specify `name: mantle`, `version: 1.1.0`, `crystal: '>= 1.18.2'`. Zero external shard dependencies.
   - Command `crystal spec` in `/home/cam/repos/adjutant/mantle` passed with `303 examples, 0 failures, 0 errors, 0 pending`.
   - `mantle/src/mantle/steps/step.cr`: Lines 17-51 define `class Mantle::Step` with `@client : Mantle::Clients::Client`, `@tools : Array(Mantle::Tools::Tool)`, `@max_iterations : Int32 = 10`, `@on_status : Proc(Symbol, Nil)?`, and `@tool_callback`. `run(messages : Array(Mantle::Message), &block : String -> Nil) : StepResult(String, StepError)` clones messages with `working_messages = messages.dup` to prevent mutating caller inputs.
   - `mantle/src/mantle/steps/step_error.cr`: Lines 7-32 define `enum StepError` (`MalformedOutput`, `MaxIterationsReached`, `ClientFailure`, `ToolExecutionFailure`, `RateLimited`), with helper methods `retryable?` and `terminal?`.
   - `mantle/src/mantle/steps/step_result.cr`: Lines 16-73 define `class StepResult(T, E)` containing `@value : T?`, `@error : E?`, `@thinking : String?`, `@iterations : Int32`, and `@raw_response : Mantle::Clients::Response?`. Mantle does not define a Crystal sum type `alias Result(T) = Success(T) | Failure`.
   - `mantle/src/mantle/tools/tools.cr`: Lines 101-143 define `struct Tool` with `function : FunctionDefinition`, `handler : Proc(Hash(String, JSON::Any), String)?`, and `execute` methods.
   - `mantle/src/mantle/storage/context_manager.cr`: Line 39 requires `@memory_store : JSONLayeredMemoryStore`, which persists to a JSON file on disk.

2. **Salamander Specifications and Test Suite**:
   - `salamander/shard.yml`: Lines 1-20 specify `name: salamander`, `version: 0.2.0`, `crystal: '>= 1.18.2'`, with dependencies `mantle: path: ../mantle` and `tts_kokoro: path: ../tts_kokoro`.
   - Command `crystal spec` in `/home/cam/repos/adjutant/salamander` passed with `20 examples, 0 failures, 0 errors, 0 pending`.
   - `salamander/src/salamander/chat_session.cr`: Lines 12-121 define `class ChatSession` with enum `State` (`Evaluating`, `Thinking`, `Responding`), `process_chunk(chunk : String) : ProcessedChunk`, and `thinking_log : String`. Strips `<think>` and `<|think|>` tags while accumulating thoughts in memory.
   - `salamander/src/salamander/ui.cr`: Lines 64-71 define `spin_while(message, state_getter, &block)` running a Braille spinner fiber (`'⠋'`, `'⠙'`, `'⠹'`, etc.) that transitions colors and automatically halts when state reaches `:responding`. Lines 177-201 query terminal dimensions via C `ioctl(1, TIOCGWINSZ, pointerof(ws))`. Line 36 defines `ask_user(prompt)` using `print` with `colorize` and `gets`.
   - `salamander/src/salamander/ui/markdown_formatter.cr`: Lines 9-121 implement `MarkdownFormatter.format(text)` converting code blocks, headers, blockquotes, bold, italic, and links to ANSI sequences with code block extraction and parent style restoration.
   - `salamander/src/salamander/waybar.cr`: Lines 26-29 install `Signal::INT.trap { puts ...; exit }`.

3. **Compatibility & Linking Verification**:
   - System Crystal compiler: `Crystal 1.21.0 (2026-07-23)`.
   - Verified requiring both frameworks simultaneously via:
     `CRYSTAL_PATH="$(crystal env CRYSTAL_PATH):../mantle/src:../salamander/src:../tts_kokoro/src" crystal eval 'require "mantle"; require "salamander"; puts Mantle::Log; puts Salamander::VERSION'`
     Exited with code 0, emitting `#<Log:0x7fc64abfa740>` and `0.2.0`.
   - Sibling repositories in `/home/cam/repos/adjutant`: `mantle`, `salamander`, and `tts_kokoro` are all present.

## 2. Logic Chain

1. **Sum Types & Error Handling (R4)**:
   - Observation: Mantle exposes `Mantle::StepError` enum and `Mantle::StepResult(T, E)` class with nullable value and error fields.
   - Deduction: Because Mantle does not have a language-level sum type `Result(T) = Success(T) | Failure`, NIGHTMARE must define its own `Result(T)` alias in `Nightmare::Harness` and wrap `Mantle::StepResult` within it, matching the architectural specification in `docs/ARCHITECTURE.md`.

2. **In-Memory Context & In-Turn Shedding (R2)**:
   - Observation: Mantle's `ContextManager` requires a disk-based `JSONLayeredMemoryStore`. However, `Mantle::Step` is decoupled from `ContextManager` and operates strictly on an input array of `Mantle::Message`.
   - Deduction: NIGHTMARE can bypass Mantle's `ContextManager` and `Session`, implementing its own pure RAM `Nightmare::Context::SlidingStore` and `Turn` structures, and feeding messages directly into `Mantle::Step`.
   - Observation: `Mantle::Step#run` executes an internal loop appending tool outputs directly to `working_messages` without an intermediate iteration hook.
   - Deduction: To support NIGHTMARE's R2 requirement of in-turn shedding (compressing older tool outputs during multi-step tool iterations while keeping the last 2 verbatim), either:
     (a) A minor, 3-line backward-compatible hook `property before_iteration : Proc(Array(Mantle::Message), Int32, Nil)? = nil` can be added to `Mantle::Step`, or
     (b) Tool handlers can perform truncation when individual outputs exceed thresholds, or
     (c) `Nightmare::Harness::StepRunner` can drive single iterations.
     The optional callback hook (a) in `Mantle::Step` is the cleanest and fully aligns with R6's allowance for minor backward-compatible enhancements.

3. **UI, Streaming & Signal Handling (R5)**:
   - Observation: `Salamander::ChatSession` strips thinking tags in real-time, isolates internal monologue into `thinking_log`, and provides clear state transitions. `Salamander::UI::MarkdownFormatter` provides code-block-protected ANSI rendering.
   - Observation: `Salamander::WaybarNotifier#start` installs a default `Signal::INT.trap` that exits the process.
   - Deduction: NIGHTMARE can consume `Salamander::ChatSession` and `Salamander::UI::MarkdownFormatter` completely as-is. For `Ctrl+C` handling, NIGHTMARE simply needs to define its own `Signal::INT.trap` to roll back the active turn without exiting, taking advantage of Crystal's runtime signal handler override semantics.

4. **Shard Linking & Dependency Resolution (R6)**:
   - Observation: `salamander/shard.yml` depends on `mantle` and `tts_kokoro` via relative paths (`../mantle`, `../tts_kokoro`).
   - Deduction: In `nightmare/shard.yml`, declaring `mantle: path: ../mantle`, `salamander: path: ../salamander`, and `tts_kokoro: path: ../tts_kokoro` ensures local linking without external network dependencies.

## 3. Caveats

1. `tts_kokoro` is required as a transitive dependency by `salamander/shard.yml` even if NIGHTMARE does not actively use text-to-speech audio streaming.
2. In-turn shedding during multi-step execution requires either the minor hook in `Mantle::Step` or managing tool execution within individual tool callbacks.
3. No other areas were left unexamined.

## 4. Conclusion

1. **Mantle**: Can be consumed directly for client abstractions, tool schemas (`Tool`), messages (`Message`), and step execution (`Step`). We recommend adding a minor backward-compatible hook (`before_iteration`) to `Mantle::Step` to support R2 in-turn shedding.
2. **Salamander**: Can be consumed directly for the streaming state machine (`ChatSession`), ANSI formatting (`MarkdownFormatter`), terminal width detection, and spinners. NIGHTMARE overrides `Signal::INT.trap` at runtime to support turn rollback.
3. **Shard Integration**: Ready to link via `path: ../mantle`, `path: ../salamander`, and `path: ../tts_kokoro`.

## 5. Verification Method

1. **Verify Mantle Tests**:
   `Cwd: /home/cam/repos/adjutant/mantle`, run `crystal spec`. Must pass all 303 examples.
2. **Verify Salamander Tests**:
   `Cwd: /home/cam/repos/adjutant/salamander`, run `crystal spec`. Must pass all 20 examples.
3. **Verify Joint Compilation**:
   `CRYSTAL_PATH="$(crystal env CRYSTAL_PATH):../mantle/src:../salamander/src:../tts_kokoro/src" crystal eval 'require "mantle"; require "salamander"; puts "SUCCESS"'`
4. **Inspect Detailed Analysis**:
   Inspect `/home/cam/repos/adjutant/nightmare/.agents/explorer_frameworks_1/frameworks.md`.
