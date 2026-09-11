# Handoff Report: NIGHTMARE Specification Survey & Mining

## 1. Observation
Authoritative specifications and framework dependencies were directly inspected via `view_file` and directory exploration:

1. **`/home/cam/repos/adjutant/nightmare/.agents/ORIGINAL_REQUEST.md`** (Lines 1–54):
   - Defines R1 to R6 and acceptance criteria:
     - *R1. Workspace Anchoring and Central XDG Mapping*: "anchor to `Dir.current` using its realpath and strictly prevent operations outside this root... central XDG user directories partitioned by a deterministic workspace identifier (`<slug>-<hash>`). No configuration or log files may be created inside the target project repository."
     - *R2. Ephemeral Context Engine, Turn-Unit Pruning, and In-Turn Shedding*: "Maintain conversational context strictly in-memory using an atomic turn-unit sliding window. Pruning must never orphan tool pairs and must never evict the current turn's user prompt. When approaching token limits... truncate older consumed tool results within the active turn while preserving the last 2 verbatim. Provide self-calibrated token estimation... Maintain a parallel un-pruned transcript in RAM for export via `/save`."
     - *R3. Sandboxed Tool Suite and Anti-Fatigue Approval Boundary*: "Provide read-only workspace observation tools (`list_files`, `search`, `read_file`, `file_info`)... mutation tools (`replace_in_file`, `append_to_file`, `write_file`)... auto-approve new file creation but require interactive approval with a unified diff before modifying existing files. Mutations to `.git/` must be forbidden... `ask_model`... `run_command` with process group isolation, a hard timeout cap, closed stdin, and an interactive approval modal (`[y]`, `[N]`, `[e]`, `[a]` exact, `[p]` prefix), with a strict ban on auto-approving any command containing shell metacharacters."
     - *R4. Mantle Step Harness and Typed Result Sum Types*: "Orchestrate execution via Mantle's step runner, encapsulating all LLM interactions within a strict `Result(T) = Success(T) | Failure` sum-type boundary. Apply automatic exponential backoff with jitter on rate limits. Trigger a single format-correction retry turn upon receiving malformed payloads..."
     - *R5. Interactive Salamander REPL and Slash Command Router*: "terminal REPL powered by Salamander with live token streaming, spinner management, `<think>` block isolation, and ANSI markdown formatting. `Ctrl+C` during generation must immediately cancel execution and roll back the active turn without terminating the session. Support slash commands: `/clear`, `/cls`, `/drop`, `/save`, `/prompt [edit]`, `/review`, `/thinking`, `/model`, `/paste`, `/exit`."
     - *R6. Framework Integration Constraints*: "Link dependencies to local paths `../mantle` and `../salamander`."

2. **`/home/cam/repos/adjutant/nightmare/docs/DESIGN.md`** (Lines 1–410):
   - Canonical workspace hash algorithm: `slug = File.basename(@root).gsub(/[^a-zA-Z0-9_-]/, "_")`, `hash = Digest::SHA256.hexdigest(@root)[0..7]`, `workspace_id = "#{slug}-#{hash}"`.
   - Directive resolution precedence: CLI flag > `.nightmare/prompt.md` > XDG workspace `prompt.md` > XDG global `prompt.md` > Default general persona.
   - Context equation: $\text{Turn} = \langle \text{User Message},\, [\text{Assistant Tool Call} \leftrightarrow \text{Tool Result}]^{*},\, \text{Final Assistant Message} \rangle$.
   - In-turn shedding threshold: `token_hardmax * 0.85`, keeping last 2 verbatim, truncating consumed to first ~200 chars + `[... output truncated: was N bytes]`.
   - Token calibration formula: $\text{Divisor}_{\text{new}} = 0.8 \times \text{Divisor}_{\text{prev}} + 0.2 \times (\text{Raw Assembled Chars} / \text{usage.prompt_tokens})$.
   - Pinned files: live re-read on prompt assembly; budget cap 60% of `token_hardmax`; redundancy short-circuit in `read_file`.
   - Metacharacter ban set: `;&|` `` ` `` `$()` `>` `<` `\n`.
   - Subprocess execution: `Process.new(..., chdir: @root)`, `CI=1`, `GIT_TERMINAL_PROMPT=0`, stdin closed (`Process::Redirect::Close`), timeout hard cap 600s, `Process.kill(Signal::KILL, -pgid)`.
   - Startup banner box layout.

3. **`/home/cam/repos/adjutant/nightmare/docs/ARCHITECTURE.md`** (Lines 1–289):
   - Module hierarchy and namespace layout (`Nightmare::CLI`, `Nightmare::Workspace`, `Nightmare::Directives`, `Nightmare::Context`, `Nightmare::Transcript`, `Nightmare::Tools`, `Nightmare::Harness`, `Nightmare::UI`, `Nightmare::Commands`).
   - Data models: `Nightmare::Harness::StepErrorKind`, `Nightmare::Harness::Result(T)`, `Nightmare::Context::Turn`, `Nightmare::Context::ToolExchange`, `Nightmare::Context::PinnedFile`, `Nightmare::Workspace::Manifest`.
   - Data flow pipelines: boot, prompt assembly, in-turn tool shedding, approval boundary, and signal cancellation rollback.

4. **Framework Codebases**:
   - `mantle`: `Mantle::Step` operates on `messages : Array(Message)` and yields chunks; uses `StepResult(T, E)` and `StepError`.
   - `salamander`: `Salamander::ChatSession` state machine handles streaming tokens, isolates `<think>` / `<|think|>` blocks into `thinking_log`; `Salamander::UI` provides `stream_text`, spinner animation, and `MarkdownFormatter`.

## 2. Logic Chain
1. **Security & Workspace Containment**:
   - By resolving `File.realpath(Dir.current)` once at boot into `@root`, and requiring all path operations to satisfy `File.realpath(target).starts_with?(@root)`, directory traversal (`../`) and out-of-tree symlinks are deterministically prevented from reading or writing host system files outside the repository.
   - Forbidding `.git/` in all mutation tools (`write_file`, `replace_in_file`, `append_to_file`) protects version control metadata from bot corruption.
   - Barring shell metacharacters (`;&|` `` ` `` `$()` `>` `<` `\n`) from auto-approval closes command injection bypasses where an attacker or LLM chains commands (e.g., `git status; rm -rf /`).
2. **Context Stability & API Compliance**:
   - LLM tool-calling APIs reject orphaned tool results or un-paired tool calls. Grouping messages into atomic `Turn` units ensures that sliding window eviction purges entire turns, guaranteeing that `tool_calls` and matching `role: "tool"` messages are never split.
   - Shedding consumed tool outputs in the active turn while preserving the last 2 verbatim keeps the active working set available for subsequent reasoning while preventing mid-turn token blowout.
3. **User Agency & Ephemeral Workflow**:
   - Ephemeral in-memory context ensures zero repository pollution (no `.nightmare/` state files littered unless explicitly user-committed).
   - Parallel RAM un-pruned transcript preserves pristine tool exchanges for on-demand export via `/save [path]`.
   - `Ctrl+C` signal trapping kills subprocesses and aborts streams without crashing the REPL, rolling back the corrupted partial turn while restoring the user prompt for rapid refinement.

## 3. Caveats
- **Local Framework Modifications**: Per R6, minor backward-compatible enhancements to Mantle and Salamander are permitted if strictly necessary (e.g. allowing optional memory stores or adjusting hooks), but major refactoring is prohibited.
- **v2 Deferrals**: As explicitly defined in `DESIGN.md` §10, fast-model summarization (`/add --summary`), pre-approved scripts directories, and multi-agent swarm coordination are deferred to v2 and out of scope for v1.

## 4. Conclusion
The specification discovery and survey phase is complete. The full inventory has been compiled into `/home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1/specs.md`. It covers all 6 focus areas, includes 44 discovered features across 6 categories, 30 edge case scenarios, exact data models, algorithms, and 18 concrete acceptance criteria (AC-B1..B2, AC-S1..S5, AC-C1..C7, AC-U1..U4).

## 5. Verification Method
1. **Specification Document Inspection**:
   - Review `/home/cam/repos/adjutant/nightmare/.agents/spec_miner_survey_1/specs.md` to confirm all sections, algorithms, and tables are present and verbatim-accurate against the authoritative documentation.
2. **Cross-Reference Invalidation Checks**:
   - If any requirement in `specs.md` contradicts `ORIGINAL_REQUEST.md`, `DESIGN.md`, or `ARCHITECTURE.md`, verify line numbers cited in Section 1 of this report.
3. **Future Implementation Verification**:
   - Once implementation begins:
     - Run `shards build` in `/home/cam/repos/adjutant/nightmare` to verify zero compiler warnings.
     - Run `crystal spec` in `/home/cam/repos/adjutant/nightmare` to verify test suite passes.
