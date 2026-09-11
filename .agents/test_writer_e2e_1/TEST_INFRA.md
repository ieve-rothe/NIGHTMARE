# NIGHTMARE: Opaque-Box E2E Test Infrastructure & Requirements-Driven Test Suites (Tiers 1–4)

## 1. Executive Summary & Architecture Overview

The **NIGHTMARE End-to-End (E2E) Test Suite** provides an authoritative, opaque-box verification framework for the standalone Crystal developer REPL. Operating strictly from the external boundary, tests treat the compiled `bin/nightmare` binary as an opaque executable, driving execution through CLI arguments, environment variables, simulated terminal IO (stdin/stdout/stderr), POSIX signals (`SIGINT`), and filesystem interactions.

### 1.1 Core Architecture Diagram

```text
┌──────────────────────────────────────────────────────────────────────────────────┐
│                             NIGHTMARE E2E TEST RUNNER                            │
├────────────────────────┬─────────────────────────┬───────────────────────────────┤
│  WorkspaceSandbox      │  MockLlmServer          │  ProcessSession               │
│  - @root Dir.current   │  - Ephemeral HTTP Port  │  - Non-blocking IO pipes      │
│  - Isolated XDG Dirs   │  - Ollama API Emulation │  - POSIX Signal Dispatch      │
│  - Zero Repo Litter    │  - Streaming / Chunks   │  - Line / Token Streaming     │
│  - .git/ Sandbox       │  - Tool Call Generator  │  - Hard Timeout Supervisor    │
│  - Outside Symlinks    │  - 429 Rate Limit Mock  │  - Exit Status Capture        │
└───────────┬────────────┴────────────┬────────────┴───────────────┬───────────────┘
            │                         │                            │
            ▼                         ▼                            ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                         OPAQUE EXECUTABLE (bin/nightmare)                        │
│                                                                                  │
│   ARGV / CLI Flags ──> [ Workspace Resolution & Canonical Root Anchor ]          │
│                                │                                                 │
│   MANTLE_API_URL  ───> [ Mantle Step Harness & Typed Result Sum Types ]          │
│                                │                                                 │
│   Stdin / Term IO  ───> [ Salamander REPL, Slash Commands, Approval Modals ]     │
│                                │                                                 │
│   Filesystem IO    ───> [ Sandboxed Tools: list, read, search, write, replace ]  │
│                                │                                                 │
│   XDG Output       ───> [ Central Config, State Manifest, Rotating Audit Logs ]  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Core Invariants Under Verification

1. **Workspace Anchoring & Path Containment**: `@root` is canonicalized once via `File.realpath(Dir.current)`. All read/write operations outside `@root`, including `../` path traversal and external symlinks, raise security errors.
2. **Zero Repository Litter**: No configuration, cache, temporary files, or audit logs are created within `@root`. All persistent state lives in central XDG user directories partitioned by `<slug>-<hash>`.
3. **Strict `.git/` Protection**: Any mutation tool (`write_file`, `replace_in_file`, `append_to_file`) targeting `.git/` or subpaths is unconditionally rejected.
4. **Strict Shell Metacharacter Auto-Approval Ban**: Commands containing `;`, `&`, `|`, `` ` ``, `$()`, `>`, `<`, or `\n` can **never** be auto-approved, regardless of allowlists, and always force the interactive approval modal.
5. **Context Engine & In-Turn Shedding**: Turn units are atomic and never orphaned. When active turn tokens hit 85% of budget, older consumed tool outputs are truncated to 200 characters + stub while preserving the last 2 tool outputs verbatim.
6. **Parallel Pristine Transcript**: Truncation in the conversational sliding window does not affect the un-truncated in-memory RAM transcript exported via `/save`.
7. **Signal Interruption Resilience**: `Ctrl+C` (`SIGINT`) during execution kills the subprocess group (`-pgid`), rolls back the in-flight turn, preserves prompt text, and keeps the REPL session alive.

---

## 2. Compilation, Build & Execution Guide

### 2.1 Compiling the Application Binary

To compile the `nightmare` binary:

```bash
cd /home/cam/repos/adjutant/nightmare
shards build nightmare
# Or directly via Crystal:
crystal build src/nightmare.cr -o bin/nightmare --no-debug
```

### 2.2 Running the E2E Test Suite

The test suite is written using Crystal's standard `spec` library and executed via `crystal spec`.

| Command | Target Scope |
| :--- | :--- |
| `crystal spec` | Runs all unit, integration, and E2E specs in the repository |
| `crystal spec spec/e2e/test_runner_spec.cr` | Verifies the E2E test runner infrastructure itself (sandboxing, mock HTTP server, process IO) |
| `crystal spec spec/e2e/tier1_feature_spec.cr` | Executes Tier 1: Core Feature Coverage (45 executable examples) |
| `crystal spec spec/e2e/tier2_boundary_spec.cr` | Executes Tier 2: Boundary & Corner Cases (40 executable examples) |
| `crystal spec spec/e2e/tier3_combination_spec.cr` | Executes Tier 3: Cross-Feature Combinations (10 executable examples) |
| `crystal spec spec/e2e/tier4_workload_spec.cr` | Executes Tier 4: Real-World Workloads & Scenarios (6 executable examples) |
| `crystal spec spec/e2e/` | Runs all E2E test tiers in one pass (108 total examples) |

### 2.3 Progressive Testability

- When `bin/nightmare` is not yet compiled or is the initial empty scaffold, the runner calls `Nightmare::E2E.require_binary!`, marking pending features without failing the test runner.
- The test harness itself (`spec/e2e/test_runner_spec.cr`) runs and passes 100% without dependencies on the application binary.
- Once milestones M1 through M5 are implemented, tests transition automatically from pending to active verification.

---

## 3. Tier 1: Comprehensive Feature Coverage (Tiers 1–44)

Every inventoried feature from `PROJECT.md` and `specs.md` is covered by at least 5 distinct test cases.

### Category A: Workspace & Anchoring (Features 1–6)

#### Feature 1: Canonical Root Anchor (`@root = File.realpath(Dir.current)`)
- **TC-T1-F01-01 (Current Directory Realpath)**:
  - *Input*: Launch `bin/nightmare` in a fresh temporary directory `/tmp/test_ws_xyz`.
  - *Oracle*: `DESIGN.md` §1; `specs.md` §1.1.
  - *Procedure*: Spawn process, send `/exit`.
  - *Assertion*: Banner output contains canonical `/tmp/test_ws_xyz`; exit code 0.
- **TC-T1-F01-02 (Symlinked Working Directory Resolution)**:
  - *Input*: Create symlink `/tmp/link_ws -> /tmp/real_ws`. Launch from `/tmp/link_ws`.
  - *Oracle*: `specs.md` Edge Case 1.
  - *Procedure*: Spawn process in `/tmp/link_ws`, send `/exit`.
  - *Assertion*: Banner displays `/tmp/real_ws` as canonical workspace root.
- **TC-T1-F01-03 (Containment Invariant Enforcement)**:
  - *Input*: Tool call `read_file(path: "src/app.cr")` inside root.
  - *Oracle*: `specs.md` §1.1.
  - *Procedure*: Run read_file tool on existing file.
  - *Assertion*: Read succeeds; zero security errors raised.
- **TC-T1-F01-04 (Nested Subdirectory Containment)**:
  - *Input*: Tool call targeting `nested/deep/sub/file.cr`.
  - *Oracle*: `specs.md` §1.1.
  - *Procedure*: Ensure file exists, invoke tool.
  - *Assertion*: File resolved cleanly within `@root`.
- **TC-T1-F01-05 (Root Anchor Immutability Across Turns)**:
  - *Input*: Execute 5 successive turns with `/help`, `/clear`, `/cls`.
  - *Oracle*: `specs.md` §1.1.
  - *Procedure*: Verify root anchor remains unchanged after multiple commands.
  - *Assertion*: Root path remains strictly identical across entire session.

#### Feature 2: Deterministic Workspace ID (`<slug>-<hash>`)
- **TC-T1-F02-01 (Basename Slug Sanitization)**:
  - *Input*: Workspace directory name `My Project.v1+alpha`.
  - *Oracle*: `slug = File.basename(@root).gsub(/[^a-zA-Z0-9_-]/, "_")` (`specs.md` §1.2).
  - *Assertion*: Slug equals `My_Project_v1_alpha`.
- **TC-T1-F02-02 (SHA-256 8-Character Hash)**:
  - *Input*: Canonical path `/home/cam/repos/adjutant`.
  - *Oracle*: `Digest::SHA256.hexdigest(path)[0..7]` (`specs.md` §1.2).
  - *Assertion*: Generated hash matches computed 8 hex characters.
- **TC-T1-F02-03 (XDG Workspace Config Subfolder Creation)**:
  - *Input*: Launch NIGHTMARE with isolated `XDG_CONFIG_HOME`.
  - *Oracle*: `specs.md` §1.3.
  - *Assertion*: Directory `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/` exists.
- **TC-T1-F02-04 (Workspace JSON Manifest Generation)**:
  - *Input*: First launch in clean workspace.
  - *Oracle*: `specs.md` §1.3 (`workspace.json` schema).
  - *Assertion*: `workspace.json` contains `id`, `canonical_path`, `created_at`, `last_accessed`.
- **TC-T1-F02-05 (Manifest Idempotence & Timestamp Update)**:
  - *Input*: Relaunch in existing workspace after 1 second.
  - *Oracle*: `specs.md` §1.3.
  - *Assertion*: `id` and `created_at` preserved; `last_accessed` updated.

#### Feature 3: Central XDG Storage Resolution
- **TC-T1-F03-01 (Config Path Resolution)**:
  - *Input*: Launch with custom `XDG_CONFIG_HOME`.
  - *Oracle*: `specs.md` §1.3.
  - *Assertion*: Configuration stored in `$XDG_CONFIG_HOME/nightmare/config.json`.
- **TC-T1-F03-02 (State & Log Isolation)**:
  - *Input*: Launch with custom `XDG_STATE_HOME`.
  - *Oracle*: `specs.md` §1.3.
  - *Assertion*: State logs written to `$XDG_STATE_HOME/nightmare/workspaces/<id>/llm_calls.jsonl`.
- **TC-T1-F03-03 (Cache Path Resolution)**:
  - *Input*: Launch with custom `XDG_CACHE_HOME`.
  - *Oracle*: `specs.md` §1.3.
  - *Assertion*: Directory `$XDG_CACHE_HOME/nightmare/workspaces/<id>/` initialized.
- **TC-T1-F03-04 (Zero Repo Litter Invariant)**:
  - *Input*: Execute multiple turns creating files and executing commands.
  - *Oracle*: `specs.md` §1.3 zero repository litter invariant.
  - *Assertion*: `assert_zero_repo_litter!` passes; zero nightmare configs/logs in `@root`.
- **TC-T1-F03-05 (--no-log Flag Audit Suppression)**:
  - *Input*: Launch with `--no-log`.
  - *Oracle*: `specs.md` §1.3.
  - *Assertion*: `llm_calls.jsonl` is not created in `$XDG_STATE_HOME`.

#### Feature 4: Startup Notification Banner
- **TC-T1-F04-01 (Box Border Header)**:
  - *Input*: Launch `bin/nightmare`.
  - *Oracle*: `specs.md` §1.6 banner template.
  - *Assertion*: STDOUT starts with `┌── NIGHTMARE ───`.
- **TC-T1-F04-02 (Workspace Root Row)**:
  - *Input*: Launch in `/tmp/test_ws`.
  - *Oracle*: `specs.md` §1.6.
  - *Assertion*: Line contains `│ Workspace : /tmp/test_ws`.
- **TC-T1-F04-03 (Config Path Row)**:
  - *Input*: Launch with specific XDG config.
  - *Oracle*: `specs.md` §1.6.
  - *Assertion*: Line contains `│ Config    : ~/.config/nightmare/workspaces/<id>/`.
- **TC-T1-F04-04 (State/Logs Path Row)**:
  - *Input*: Launch with specific XDG state.
  - *Oracle*: `specs.md` §1.6.
  - *Assertion*: Line contains `│ State/Logs: ~/.local/state/nightmare/workspaces/<id>/`.
- **TC-T1-F04-05 (Bottom Border Line)**:
  - *Input*: Launch `bin/nightmare`.
  - *Oracle*: `specs.md` §1.6.
  - *Assertion*: Banner terminates with `└───────┘`.

#### Feature 5: System Directives Precedence
- **TC-T1-F05-01 (Default Persona Fallback)**:
  - *Input*: Launch with zero prompt files or CLI flags.
  - *Oracle*: `specs.md` §1.4 tier 5.
  - *Assertion*: `/prompt` output matches default persona text verbatim.
- **TC-T1-F05-02 (Global XDG Prompt Override)**:
  - *Input*: Place prompt in `$XDG_CONFIG_HOME/nightmare/prompt.md`.
  - *Oracle*: `specs.md` §1.4 tier 4.
  - *Assertion*: `/prompt` displays global XDG prompt.
- **TC-T1-F05-03 (Workspace XDG Prompt Override)**:
  - *Input*: Place prompt in `$XDG_CONFIG_HOME/nightmare/workspaces/<id>/prompt.md`.
  - *Oracle*: `specs.md` §1.4 tier 3.
  - *Assertion*: `/prompt` displays workspace XDG prompt over global prompt.
- **TC-T1-F05-04 (Committed Repository Prompt Override)**:
  - *Input*: Commit `.nightmare/prompt.md` in `@root`.
  - *Oracle*: `specs.md` §1.4 tier 2.
  - *Assertion*: `/prompt` displays repository prompt over central XDG prompt.
- **TC-T1-F05-05 (CLI Flag Absolute Precedence)**:
  - *Input*: Pass `-s custom.md` when `.nightmare/prompt.md` exists.
  - *Oracle*: `specs.md` §1.4 tier 1.
  - *Assertion*: `/prompt` displays content of `custom.md`.

#### Feature 6: In-Memory Directive Edit (`/prompt edit`)
- **TC-T1-F06-01 (Editor Launch on Temp File)**:
  - *Input*: Run `/prompt edit` with `EDITOR=touch`.
  - *Oracle*: `specs.md` §1.5.
  - *Assertion*: Modifies active directive in RAM.
- **TC-T1-F06-02 (Zero Disk Modification)**:
  - *Input*: Edit prompt loaded from `.nightmare/prompt.md`.
  - *Oracle*: `specs.md` §1.5 zero disk modification guarantee.
  - *Assertion*: `.nightmare/prompt.md` on disk remains identical byte-for-byte.
- **TC-T1-F06-03 (Updated Directive Display via /prompt)**:
  - *Input*: Execute `/prompt edit`, update to "NEW PROMPT", then run `/prompt`.
  - *Oracle*: `specs.md` §1.5.
  - *Assertion*: `/prompt` displays "NEW PROMPT".
- **TC-T1-F06-04 (Prompt Reflection in LLM Turn Assembly)**:
  - *Input*: Edit prompt in RAM, dispatch turn, run `/review`.
  - *Oracle*: `specs.md` §1.5, §2.2.
  - *Assertion*: Prompt assembly reflects the in-memory edited prompt.
- **TC-T1-F06-05 (Revert on Editor Error Exit)**:
  - *Input*: Run `/prompt edit` with `EDITOR=false` (exit 1).
  - *Oracle*: `specs.md` §1.5 error recovery.
  - *Assertion*: Prior in-memory directive is preserved without corruption.

---

### Category B: Context & Memory (Features 7–14)

#### Feature 7: Atomic Turn Units
- **TC-T1-F07-01 (Turn Record Structure)**:
  - *Input*: User message + tool call + tool result + assistant message.
  - *Oracle*: `specs.md` §2.1 `Turn` model.
  - *Assertion*: Encapsulated into single `Turn` object; `complete?` is true.
- **TC-T1-F07-02 (Multi-Step Tool Exchanges in Single Turn)**:
  - *Input*: Turn with 3 sequential tool calls.
  - *Oracle*: `specs.md` §2.1.
  - *Assertion*: `turn.tool_exchanges.size == 3`.
- **TC-T1-F07-03 (Turn Atomicity During Assembly)**:
  - *Input*: Inspect assembled messages via `/review`.
  - *Oracle*: `specs.md` §2.2.
  - *Assertion*: Tool call and tool result are consecutive; no role mismatch.
- **TC-T1-F07-04 (Never Split Turn Invariant)**:
  - *Input*: Trigger context pruning with completed multi-tool turn.
  - *Oracle*: `specs.md` §2.1 atomicity invariant.
  - *Assertion*: Entire turn is either retained or evicted; no orphaned tool calls.
- **TC-T1-F07-05 (Active Turn In-Flight Isolation)**:
  - *Input*: Query context while tool execution is in-flight.
  - *Oracle*: `specs.md` §2.1.
  - *Assertion*: Current turn is marked incomplete until assistant message commits.

#### Feature 8: Sliding Window Turn Pruning
- **TC-T1-F08-01 (Soft Turn Cap Eviction)**:
  - *Input*: Complete 11 turns with turn cap set to 10.
  - *Oracle*: `specs.md` §2.3 rule 2.
  - *Assertion*: Turn 1 evicted; Turns 2–11 retained.
- **TC-T1-F08-02 (Protected Active Turn User Prompt)**:
  - *Input*: Fill context to `token_hardmax`.
  - *Oracle*: `specs.md` §2.3 rule 1.
  - *Assertion*: Active turn's user prompt is never evicted.
- **TC-T1-F08-03 (Phase 1 Historical Result Shedding)**:
  - *Input*: Tokens exceed `token_hardmax`.
  - *Oracle*: `specs.md` §2.3 rule 3 (Phase 1).
  - *Assertion*: Historical tool results >200 chars are truncated with stub.
- **TC-T1-F08-04 (Phase 2 Whole Turn Eviction)**:
  - *Input*: Tokens still exceed `token_hardmax` after Phase 1 shedding.
  - *Oracle*: `specs.md` §2.3 rule 3 (Phase 2).
  - *Assertion*: Oldest completed turn unit evicted completely.
- **TC-T1-F08-05 (Protected System Directive & Pinned Files)**:
  - *Input*: Exceed `token_hardmax` repeatedly.
  - *Oracle*: `specs.md` §2.3 rule 1.
  - *Assertion*: System directive and pinned files remain permanently in context.

#### Feature 9: In-Turn Tool Shedding (Active Turn Defense)
- **TC-T1-F09-01 (Trigger at 85% Hardmax)**:
  - *Input*: Active turn tool results exceed `token_hardmax * 0.85`.
  - *Oracle*: `specs.md` §2.4 algorithm.
  - *Assertion*: In-turn shedding triggers.
- **TC-T1-F09-02 (Preserve Last 2 Verbatim)**:
  - *Input*: Active turn contains 4 tool exchanges.
  - *Oracle*: `specs.md` §2.4 rule 3.
  - *Assertion*: Tools 3 and 4 retained verbatim without truncation.
- **TC-T1-F09-03 (Truncate Prior Consumed Results)**:
  - *Input*: 4 tool exchanges in active turn.
  - *Oracle*: `specs.md` §2.4 rule 4.
  - *Assertion*: Tools 1 and 2 truncated to first 200 chars + `[... output truncated: was N bytes]`.
- **TC-T1-F09-04 (User Input Untouched)**:
  - *Input*: Active turn shedding occurs on long user prompt.
  - *Oracle*: `specs.md` §2.4 rule 5.
  - *Assertion*: User prompt text remains 100% untouched.
- **TC-T1-F09-05 (No Shedding When <=2 Tool Results)**:
  - *Input*: Active turn contains 2 tool results.
  - *Oracle*: `specs.md` §2.4 rule 3.
  - *Assertion*: Neither tool result is truncated.

#### Feature 10: Self-Calibrating Token Estimator
- **TC-T1-F10-01 (Boot Default Divisor 3.5)**:
  - *Input*: Launch NIGHTMARE; inspect initial token estimate.
  - *Oracle*: `specs.md` §2.5.
  - *Assertion*: Divisor initializes to 3.5 characters per token.
- **TC-T1-F10-02 (Exponential Moving Average Update)**:
  - *Input*: Provider reports `usage.prompt_tokens = 200` for 1000 characters.
  - *Oracle*: `Divisor_new = 0.8 * 3.5 + 0.2 * (1000 / 200) = 2.8 + 1.0 = 3.8` (`specs.md` §2.5).
  - *Assertion*: Calibrated divisor updates to 3.8.
- **TC-T1-F10-03 (Smoothing Resistance to Outliers)**:
  - *Input*: Sudden single turn with 1 char/token feedback.
  - *Oracle*: `specs.md` §2.5 (0.8/0.2 weight).
  - *Assertion*: Divisor adjusts smoothly by 20%, avoiding erratic oscillations.
- **TC-T1-F10-04 (UI Meter Tilde Representation)**:
  - *Input*: View context meter in REPL header.
  - *Oracle*: `specs.md` §2.5.
  - *Assertion*: Output shows tilde: `Working Memory: ~N / M tokens`.
- **TC-T1-F10-05 (Feedback from Ollama prompt_eval_count)**:
  - *Input*: Ollama response payload containing `prompt_eval_count`.
  - *Oracle*: `specs.md` §2.5.
  - *Assertion*: Extracted and fed into calibration feedback loop.

#### Feature 11: Pinned Files (`/add`)
- **TC-T1-F11-01 (Basic Pinning via /add)**:
  - *Input*: `/add src/app.cr`.
  - *Oracle*: `specs.md` §2.6.
  - *Assertion*: Pinned block appears in `/review` with `=== PINNED FILE: src/app.cr ===`.
- **TC-T1-F11-02 (Line Slicing Range --lines)**:
  - *Input*: `/add src/app.cr --lines 10-20`.
  - *Oracle*: `specs.md` §2.6 line slicing.
  - *Assertion*: Only lines 10 to 20 of `src/app.cr` are injected into context.
- **TC-T1-F11-03 (Live Re-read from Disk)**:
  - *Input*: Pin `src/app.cr`, modify on disk externally, run `/review`.
  - *Oracle*: `specs.md` §2.6 live re-read.
  - *Assertion*: Next turn reflects modified disk content immediately without re-adding.
- **TC-T1-F11-04 (60% Budget Protection Cap)**:
  - *Input*: `/add` a file whose estimated tokens exceed 60% of `token_hardmax`.
  - *Oracle*: `specs.md` §2.6 budget protection limit.
  - *Assertion*: Command rejected with error: `File exceeds 60% of context budget limit`.
- **TC-T1-F11-05 (Prompt Caching Invalidation Awareness)**:
  - *Input*: Modify pinned file.
  - *Oracle*: `specs.md` §2.6 cache awareness.
  - *Assertion*: Pinned block sits above turn history, ensuring correctness.

#### Feature 12: Pinned File Redundancy Short-Circuit
- **TC-T1-F12-01 (read_file Short-Circuit Notice)**:
  - *Input*: File `src/app.cr` is pinned. Agent calls `read_file("src/app.cr")`.
  - *Oracle*: `specs.md` §2.6 redundancy short-circuit.
  - *Assertion*: Tool returns notice without reading file body: `[Notice: Path 'src/app.cr' is already pinned...]`.
- **TC-T1-F12-02 (Zero Token Redundancy)**:
  - *Input*: Measure tool result size for short-circuited call.
  - *Oracle*: `specs.md` §2.6.
  - *Assertion*: Result payload is minimal (~80 bytes), avoiding token duplication.
- **TC-T1-F12-03 (Normalized Path Match)**:
  - *Input*: Pinned as `./src/app.cr`; read as `src/app.cr`.
  - *Oracle*: `specs.md` §2.6.
  - *Assertion*: Realpath normalization correctly identifies match and short-circuits.
- **TC-T1-F12-04 (Non-Pinned File Unaffected)**:
  - *Input*: Call `read_file("src/other.cr")` when `src/app.cr` is pinned.
  - *Oracle*: `specs.md` §2.6.
  - *Assertion*: `src/other.cr` reads normally.
- **TC-T1-F12-05 (Short-Circuit Lifted After /drop)**:
  - *Input*: `/drop src/app.cr`, then agent calls `read_file("src/app.cr")`.
  - *Oracle*: `specs.md` §2.6.
  - *Assertion*: File content is read normally into turn history.

#### Feature 13: Unpinning Files (`/drop`)
- **TC-T1-F13-01 (Specific File Drop)**:
  - *Input*: `/drop src/app.cr`.
  - *Oracle*: `specs.md` §2.6, §5.5.
  - *Assertion*: `src/app.cr` removed from pinned set; confirmation emitted.
- **TC-T1-F13-02 (Drop All Pinned Files)**:
  - *Input*: `/drop` with no arguments.
  - *Oracle*: `specs.md` §5.5 table.
  - *Assertion*: All pinned files cleared from context.
- **TC-T1-F13-03 (Non-Pinned File Notice)**:
  - *Input*: `/drop unpinned.cr`.
  - *Oracle*: `specs.md` §8 table.
  - *Assertion*: Notifies user that file was not in pinned set.
- **TC-T1-F13-04 (Prompt Assembly Cleared)**:
  - *Input*: `/drop` then `/review`.
  - *Oracle*: `specs.md` §2.2.
  - *Assertion*: Pinned files block absent from assembled prompt.
- **TC-T1-F13-05 (Subsequent Turn Execution)**:
  - *Input*: Dispatch turn after `/drop`.
  - *Oracle*: `specs.md` §2.2.
  - *Assertion*: Dispatches cleanly without pinned context.

#### Feature 14: Pristine RAM Transcript & `/save`
- **TC-T1-F14-01 (Un-pruned History Preservation)**:
  - *Input*: Generate 5 turns with shedding, then run `/save`.
  - *Oracle*: `specs.md` §2.7.
  - *Assertion*: Saved Markdown contains full, un-truncated tool call arguments and outputs.
- **TC-T1-F14-02 (Default Timestamped Filename)**:
  - *Input*: Run `/save` without arguments.
  - *Oracle*: `specs.md` §2.7 (`transcript_<timestamp>.md`).
  - *Assertion*: Creates file matching `transcript_\d{8}_\d{6}\.md`.
- **TC-T1-F14-03 (Custom Output Destination)**:
  - *Input*: `/save exported_session.md`.
  - *Oracle*: `specs.md` §2.7.
  - *Assertion*: Written to specified filename.
- **TC-T1-F14-04 (GitHub Flavored Markdown Formatting)**:
  - *Input*: Inspect saved file content.
  - *Oracle*: `specs.md` §2.7 GFM format.
  - *Assertion*: User messages formatted as `### User`, assistant as `### Assistant`, tools in code blocks.
- **TC-T1-F14-05 (RAM Evaporation on Exit)**:
  - *Input*: Terminate REPL via `/exit` without `/save`.
  - *Oracle*: `specs.md` §2.7 ephemeral lifecycle.
  - *Assertion*: Ephemeral memory evaporates; zero transcript files written to disk.

---

### Category C: Sandboxed Tool Suite (Features 15–26)

#### Feature 15: `list_files`
- **TC-T1-F15-01 (Directory Traversal Listing)**:
  - *Input*: `list_files(directory: ".")`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Returns array of relative file paths in `@root`.
- **TC-T1-F15-02 (Subdirectory Scoped Listing)**:
  - *Input*: `list_files(directory: "src")`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Returns files strictly within `src/`.
- **TC-T1-F15-03 (Automatic .git/ Exclusion)**:
  - *Input*: Repository with `.git/HEAD`, `.git/config`. Run `list_files(".")`.
  - *Oracle*: `specs.md` §3.1, §3.2.
  - *Assertion*: Output contains zero `.git/` entries.
- **TC-T1-F15-04 (Sensitive Patterns Exclusion)**:
  - *Input*: Directory containing `.env.local`, `id_rsa`, `app.cr`. Run `list_files(".")`.
  - *Oracle*: `specs.md` §3.1 sensitive ignore list.
  - *Assertion*: `.env.local` and `id_rsa` excluded; `app.cr` listed.
- **TC-T1-F15-05 (Autonomous Execution Zero Modals)**:
  - *Input*: Invoke `list_files`.
  - *Oracle*: `specs.md` §3.2 autonomous execution.
  - *Assertion*: Executes immediately without prompting user for approval.

#### Feature 16: `search`
- **TC-T1-F16-01 (Exact Keyword Search)**:
  - *Input*: `search(pattern: "class Order")`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Returns file path and matching line number.
- **TC-T1-F16-02 (Regex Search)**:
  - *Input*: `search(pattern: "def\\s+[a-z_]+\\(.*\\)")`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Returns matching method signatures across files.
- **TC-T1-F16-03 (Glob Filter Constraint)**:
  - *Input*: `search(pattern: "test", glob: "*.spec.cr")`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Limits search to files matching glob pattern.
- **TC-T1-F16-04 (Max Matches Ceiling)**:
  - *Input*: `search(pattern: "e", max_matches: 10)`.
  - *Oracle*: `specs.md` §3.2 `max_matches` cap.
  - *Assertion*: Result contains at most 10 matches.
- **TC-T1-F16-05 (Automatic Secret File Exclusion)**:
  - *Input*: Keyword exists inside `.env` and `config.cr`. Run `search`.
  - *Oracle*: `specs.md` §3.1.
  - *Assertion*: Match in `.env` is omitted; match in `config.cr` is returned.

#### Feature 17: `read_file`
- **TC-T1-F17-01 (Full File Read)**:
  - *Input*: `read_file(path: "src/main.cr")`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Returns complete file contents.
- **TC-T1-F17-02 (1-Indexed Line Slice)**:
  - *Input*: `read_file(path: "lines.txt", offset: 10, limit: 5)`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Returns exactly lines 10 through 14.
- **TC-T1-F17-03 (Sensitive File Rejection)**:
  - *Input*: `read_file(path: ".env")`.
  - *Oracle*: `specs.md` §3.1.
  - *Assertion*: Returns security error: access to sensitive file rejected.
- **TC-T1-F17-04 (Non-Existent File Handling)**:
  - *Input*: `read_file(path: "missing.txt")`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Returns descriptive file not found error.
- **TC-T1-F17-05 (Zero Approval Autonomous Execution)**:
  - *Input*: Invoke `read_file`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Runs autonomously without interactive prompt.

#### Feature 18: `file_info`
- **TC-T1-F18-01 (Size in Bytes Inspection)**:
  - *Input*: `file_info(path: "100_bytes.bin")`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Returns size: 100.
- **TC-T1-F18-02 (Line Count Inspection)**:
  - *Input*: `file_info(path: "25_lines.txt")`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Returns line count: 25.
- **TC-T1-F18-03 (Permissions Inspection)**:
  - *Input*: File with permissions 0o755. Run `file_info`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Returns octal / human-readable permissions string.
- **TC-T1-F18-04 (Modification Time Inspection)**:
  - *Input*: `file_info(path: "src/app.cr")`.
  - *Oracle*: `specs.md` §3.2.
  - *Assertion*: Returns ISO-8601 modification timestamp.
- **TC-T1-F18-05 (Zero File Modification)**:
  - *Input*: Inspect file metadata with `file_info`.
  - *Oracle*: `specs.md` §3.2 read-only observation.
  - *Assertion*: File content and mtime on disk remain unchanged.

#### Feature 19: `write_file`
- **TC-T1-F19-01 (Auto-Approve New File)**:
  - *Input*: `write_file(path: "brand_new.txt", content: "hello")`. Target does not exist.
  - *Oracle*: `specs.md` §3.3 rule 1.
  - *Assertion*: Created autonomously without prompting user; file on disk has "hello".
- **TC-T1-F19-02 (Overwrite Existing Displays Diff Modal)**:
  - *Input*: `write_file(path: "existing.txt", content: "new")`. Target exists.
  - *Oracle*: `specs.md` §3.3 rule 1 overwrite modal.
  - *Assertion*: Emits unified diff modal: `--- existing.txt`, `+++ existing.txt (proposed)`.
- **TC-T1-F19-03 (User Approval [y] Overwrites)**:
  - *Input*: Overwrite prompt; user inputs `y`.
  - *Oracle*: `specs.md` §3.3.
  - *Assertion*: File on disk updated to "new"; tool result confirms overwrite.
- **TC-T1-F19-04 (User Rejection [N] Preserves Original)**:
  - *Input*: Overwrite prompt; user inputs `N`.
  - *Oracle*: `specs.md` §3.3 rejection semantics.
  - *Assertion*: File on disk untouched; returns `[Execution rejected by user]`.
- **TC-T1-F19-05 (Parent Directory Creation)**:
  - *Input*: `write_file(path: "deep/dir/new.txt", content: "data")`.
  - *Oracle*: `specs.md` §3.3.
  - *Assertion*: Creates intermediate directories `deep/dir/` automatically.

#### Feature 20: `replace_in_file`
- **TC-T1-F20-01 (Unique Substring Replacement)**:
  - *Input*: File has `timeout = 30`. `replace_in_file(target: "timeout = 30", replacement: "timeout = 60")`.
  - *Oracle*: `specs.md` §3.3 rule 2.
  - *Assertion*: Displays diff modal; on `y`, file contains `timeout = 60`.
- **TC-T1-F20-02 (Zero Matches Error)**:
  - *Input*: `target` string does not exist in file.
  - *Oracle*: `specs.md` Edge Case 8.
  - *Assertion*: Fails with `Target substring not found in file`.
- **TC-T1-F20-03 (Ambiguous >1 Matches Error)**:
  - *Input*: `target` appears twice in file.
  - *Oracle*: `specs.md` Edge Case 7.
  - *Assertion*: Fails with `Target substring matches 2 instances; must match exactly 1`.
- **TC-T1-F20-04 (Unified Diff Rendering)**:
  - *Input*: Proposed replacement.
  - *Oracle*: `specs.md` §3.3.
  - *Assertion*: Modal displays `-` old line and `+` new line with line numbers.
- **TC-T1-F20-05 (Rejection Preserves File)**:
  - *Input*: User enters `N` at replacement modal.
  - *Oracle*: `specs.md` §3.3.
  - *Assertion*: Original file content preserved exactly.

#### Feature 21: `append_to_file`
- **TC-T1-F21-01 (Append to Existing File)**:
  - *Input*: `append_to_file(path: "log.txt", content: "new entry\n")`.
  - *Oracle*: `specs.md` §3.3 rule 3.
  - *Assertion*: Displays append modal; on `y`, lines appended to end of file.
- **TC-T1-F21-02 (Append to Non-Existent File)**:
  - *Input*: `append_to_file` targeting non-existent path.
  - *Oracle*: `specs.md` §3.3.
  - *Assertion*: Fails with error: target file does not exist (use `write_file`).
- **TC-T1-F21-03 (Modal Display of Appended Lines)**:
  - *Input*: Append 3 lines.
  - *Oracle*: `specs.md` §3.3.
  - *Assertion*: Modal shows preview of lines being appended.
- **TC-T1-F21-04 (Rejection Preserves File)**:
  - *Input*: User rejects with `N`.
  - *Oracle*: `specs.md` §3.3.
  - *Assertion*: File remains unaltered; returns rejection message.
- **TC-T1-F21-05 (Git Protection Invariant)**:
  - *Input*: `append_to_file(path: ".git/info/exclude", content: "foo")`.
  - *Oracle*: `specs.md` §3.1.
  - *Assertion*: Rejects write targeting `.git/`.

#### Feature 22: Remote Model Delegation (`ask_model`)
- **TC-T1-F22-01 (Stateless Remote Inference)**:
  - *Input*: `ask_model(prompt: "Summarize this diff")`.
  - *Oracle*: `specs.md` §3.4.
  - *Assertion*: Calls model in isolation without carrying REPL conversation history.
- **TC-T1-F22-02 (Context Files Injection)**:
  - *Input*: `ask_model(prompt: "Explain", context_files: ["src/types.cr"])`.
  - *Oracle*: `specs.md` §3.4.
  - *Assertion*: Content of `src/types.cr` read live and prepended to prompt.
- **TC-T1-F22-03 (Model Override Parameter)**:
  - *Input*: `ask_model(prompt: "hi", model: "fast-summarizer")`.
  - *Oracle*: `specs.md` §3.4.
  - *Assertion*: Dispatches call to requested model alias.
- **TC-T1-F22-04 (Encapsulation into Tool Message)**:
  - *Input*: Remote model returns completion text.
  - *Oracle*: `specs.md` §3.4.
  - *Assertion*: Output returned as tool result string in active turn.
- **TC-T1-F22-05 (Remote Error Handling via Result Sum Type)**:
  - *Input*: Remote endpoint returns HTTP 500.
  - *Oracle*: `specs.md` §3.4, §7.
  - *Assertion*: Error captured and returned as `Result(String)` tool failure message.

#### Feature 23: Subprocess Execution (`run_command`)
- **TC-T1-F23-01 (Working Directory Confined to @root)**:
  - *Input*: `run_command(command: "pwd")`.
  - *Oracle*: `specs.md` §3.5 guardrail 1 (`chdir: @root`).
  - *Assertion*: Output equals `@root`.
- **TC-T1-F23-02 (Dedicated Process Group Isolation)**:
  - *Input*: `run_command(command: "echo $$")`.
  - *Oracle*: `specs.md` §3.5 guardrail 2 (`pgid`).
  - *Assertion*: Process runs in distinct process group.
- **TC-T1-F23-03 (Closed Stdin /dev/null)**:
  - *Input*: `run_command(command: "cat")`.
  - *Oracle*: `specs.md` §3.5 guardrail 4 (`stdin: /dev/null`).
  - *Assertion*: Receives EOF immediately and exits with code 0.
- **TC-T1-F23-04 (Environment Sanitization CI=1, GIT_TERMINAL_PROMPT=0)**:
  - *Input*: `run_command(command: "env")`.
  - *Oracle*: `specs.md` §3.5 guardrail 5.
  - *Assertion*: Output contains `CI=1` and `GIT_TERMINAL_PROMPT=0`.
- **TC-T1-F23-05 (Output Truncation 50 KB / 300 Lines)**:
  - *Input*: `run_command(command: "seq 1 1000")`.
  - *Oracle*: `specs.md` §3.5 guardrail 6.
  - *Assertion*: Output truncated with `[... output truncated: N lines omitted ...]`.

#### Feature 24: Shell Metacharacter Ban
- **TC-T1-F24-01 (Semicolon ; Forces Modal)**:
  - *Input*: `git status; rm -rf /`.
  - *Oracle*: `specs.md` §3.5 strict auto-approval ban.
  - *Assertion*: Auto-approval barred; forces interactive approval modal.
- **TC-T1-F24-02 (Pipe | Forces Modal)**:
  - *Input*: `cat file | grep text`.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Forces approval modal.
- **TC-T1-F24-03 (Command Substitution $() and Backticks Forces Modal)**:
  - *Input*: `echo $(whoami)` or `echo `id``.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Forces approval modal.
- **TC-T1-F24-04 (Redirection > and < Forces Modal)**:
  - *Input*: `echo a > file.txt`.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Forces approval modal.
- **TC-T1-F24-05 (Newline \n Injection Forces Modal)**:
  - *Input*: `git status\necho evil`.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Forces approval modal.

#### Feature 25: Anti-Fatigue Shell Modal Options
- **TC-T1-F25-01 ([y] Execute Once)**:
  - *Input*: User inputs `y`.
  - *Oracle*: `specs.md` §3.5 modal options.
  - *Assertion*: Command executes; output returned to agent.
- **TC-T1-F25-02 ([N] Reject Execution)**:
  - *Input*: User inputs `N`.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Execution blocked; returns `[Execution rejected by user]`.
- **TC-T1-F25-03 ([e] Inline Edit Execution)**:
  - *Input*: User selects `e`, modifies `ls -la` to `ls -l`.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Executes edited command; tool result notes `[Executed command after user edit: ls -l]`.
- **TC-T1-F25-04 ([a] Exact Match Session Allowlist)**:
  - *Input*: User selects `a` on `git status`.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Subsequent `git status` executes without prompting.
- **TC-T1-F25-05 ([p] Prefix Allowlist)**:
  - *Input*: User selects `p` on `git diff HEAD~1`.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Subsequent `git diff HEAD~2` executes without prompting.

#### Feature 26: Workspace Allowlist Persistence
- **TC-T1-F26-01 (Path Location in Central XDG)**:
  - *Input*: Save allowlist pattern.
  - *Oracle*: `specs.md` §3.5 ($XDG_CONFIG_HOME/nightmare/workspaces/<id>/allow).
  - *Assertion*: Saved to central XDG config path.
- **TC-T1-F26-02 (Regex Anchoring Invariant)**:
  - *Input*: Pattern added to allowlist.
  - *Oracle*: `specs.md` §3.5 regex format.
  - *Assertion*: Pattern is anchored with `^` and `$`.
- **TC-T1-F26-03 (Zero Repo Litter)**:
  - *Input*: Update allowlist.
  - *Oracle*: `specs.md` §1.3.
  - *Assertion*: No allowlist file created in workspace repo.
- **TC-T1-F26-04 (Persistence Across Sessions)**:
  - *Input*: Terminate and relaunch NIGHTMARE.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Pre-existing allowlist patterns loaded and active in new session.
- **TC-T1-F26-05 (Metacharacter Invalidation of Allowlist)**:
  - *Input*: Allowlist contains `^git.*$`. Run `git status; rm -rf /`.
  - *Oracle*: `specs.md` §3.5 metacharacter ban rule.
  - *Assertion*: Rule is ignored; modal is forced due to semicolon.

---

### Category D: Mantle Harness & Result Types (Features 27–31)

#### Feature 27: Mantle Step Runner Wrapper
- **TC-T1-F27-01 (Immutable Message Duplication)**:
  - *Input*: Dispatch turn with historical messages.
  - *Oracle*: `specs.md` §4.1 graph isolation (`working_messages = messages.dup`).
  - *Assertion*: Input array is never modified in-place.
- **TC-T1-F27-02 (Status Lifecycle Transitions)**:
  - *Input*: Dispatch LLM turn.
  - *Oracle*: `specs.md` §4.1 status hooks.
  - *Assertion*: Transitions `:evaluating` -> `:thinking` -> `:tool_loop` -> `:idle`.
- **TC-T1-F27-03 (Multi-Turn Step Execution)**:
  - *Input*: Agent calls 3 tools sequentially.
  - *Oracle*: `specs.md` §4.1.
  - *Assertion*: Step runner manages loop until final response.
- **TC-T1-F27-04 (Token Usage Extraction)**:
  - *Input*: Provider returns usage metrics.
  - *Oracle*: `specs.md` §4.1.
  - *Assertion*: Usage metrics extracted and dispatched to token calibrator.
- **TC-T1-F27-05 (Clean Step Teardown)**:
  - *Input*: Step completes.
  - *Oracle*: `specs.md` §4.1.
  - *Assertion*: Step runner resources and sockets closed cleanly.

#### Feature 28: Strongly-Typed `Result(T)` Sum Types
- **TC-T1-F28-01 (Success(T) Return on Clean Execution)**:
  - *Input*: Successful LLM turn without errors.
  - *Oracle*: `specs.md` §4.2 `Success(T)` sum type.
  - *Assertion*: Returns `Success(String)` containing value, thinking, and iteration count.
- **TC-T1-F28-02 (Failure Return on Step Error)**:
  - *Input*: Turn encountering unrecoverable client error.
  - *Oracle*: `specs.md` §4.2 `Failure` sum type.
  - *Assertion*: Returns `Failure` encapsulating `StepError`.
- **TC-T1-F28-03 (StepErrorKind Enumeration Coverage)**:
  - *Input*: Exhaustive check of `StepErrorKind` values.
  - *Oracle*: `specs.md` §4.2 (`MaxIterationsReached`, `RateLimited`, `ClientFailure`, `MalformedPayload`, `ExecutionTimeout`).
  - *Assertion*: All error kinds are strongly typed enum members.
- **TC-T1-F28-04 (Thinking Block Encapsulation)**:
  - *Input*: Model emits thinking tokens before error or success.
  - *Oracle*: `specs.md` §4.2.
  - *Assertion*: Both `Success` and `Failure` retain `thinking : String?`.
- **TC-T1-F28-05 (Iterations Count Encapsulation)**:
  - *Input*: Multi-tool turn completing in 4 iterations.
  - *Oracle*: `specs.md` §4.2.
  - *Assertion*: `result.iterations == 4`.

#### Feature 29: Rate Limit Exponential Backoff with Jitter
- **TC-T1-F29-01 (429 Rate Limit Detection)**:
  - *Input*: HTTP 429 response from provider.
  - *Oracle*: `specs.md` §4.3.
  - *Assertion*: Caught by harness as `StepErrorKind::RateLimited`.
- **TC-T1-F29-02 (Exponential Delay Calculation)**:
  - *Input*: First, second, third retry attempts.
  - *Oracle*: `Delay = random(0, base_delay * 2^attempt)` (`specs.md` §4.3).
  - *Assertion*: Sleep intervals scale exponentially with full jitter.
- **TC-T1-F29-03 (Max 3 Retry Attempts)**:
  - *Input*: Provider returns 429 continuously.
  - *Oracle*: `specs.md` §4.3.
  - *Assertion*: Retries exactly 3 times before returning `Failure(RateLimited)`.
- **TC-T1-F29-04 (Recovery on Intermediate Retry)**:
  - *Input*: Attempt 1 returns 429; Attempt 2 returns HTTP 200.
  - *Oracle*: `specs.md` §4.3.
  - *Assertion*: Recovers smoothly and returns `Success(T)`.
- **TC-T1-F29-05 (Retry-After Header Honor)**:
  - *Input*: Response contains `Retry-After: 2`.
  - *Oracle*: `specs.md` §4.3.
  - *Assertion*: Minimum delay honors header duration.

#### Feature 30: Single Format-Correction Retry Turn
- **TC-T1-F30-01 (Malformed JSON Detection)**:
  - *Input*: Model emits invalid JSON for tool arguments: `{ invalid: }`.
  - *Oracle*: `specs.md` §4.4.
  - *Assertion*: Harness catches schema parse failure.
- **TC-T1-F30-02 (Single Automatic Retry Turn Injection)**:
  - *Input*: Malformed payload received.
  - *Oracle*: `specs.md` §4.4.
  - *Assertion*: Injects correction prompt: `"Previous response could not be parsed: <error>. Output strictly valid JSON."`.
- **TC-T1-F30-03 (Recovery on Format Retry)**:
  - *Input*: Model returns valid JSON on retry attempt.
  - *Oracle*: `specs.md` §4.4.
  - *Assertion*: Tool call executes successfully.
- **TC-T1-F30-04 (Failure Surfacing on Second Malformed Payload)**:
  - *Input*: Model returns malformed JSON on retry attempt as well.
  - *Oracle*: `specs.md` §4.4.
  - *Assertion*: Returns typed `Failure(StepError(MalformedPayload))`; no infinite retry loop.
- **TC-T1-F30-05 (Context Consistency on Format Retry)**:
  - *Input*: Inspect context after format correction.
  - *Oracle*: `specs.md` §4.4.
  - *Assertion*: Malformed attempt and correction reminder recorded cleanly.

#### Feature 31: Bounded Iterations Limit
- **TC-T1-F31-01 (Default Max Iteration Cap 15)**:
  - *Input*: Tool loop executes 15 consecutive iterations.
  - *Oracle*: `specs.md` §4.5.
  - *Assertion*: Halts cleanly at iteration 15.
- **TC-T1-F31-02 (Committed Tool State Preservation)**:
  - *Input*: Files modified on iterations 1..14 before cap is reached.
  - *Oracle*: `specs.md` §4.5.
  - *Assertion*: File modifications on disk are preserved; not rolled back.
- **TC-T1-F31-03 (User Notice Emission)**:
  - *Input*: Iteration cap reached.
  - *Oracle*: `specs.md` §4.5 notice message.
  - *Assertion*: Emits notice: `[Notice] Execution reached iteration limit (15). Workspace modifications preserved...`.
- **TC-T1-F31-04 (REPL Session Continuity)**:
  - *Input*: Iteration cap reached.
  - *Oracle*: `specs.md` §4.5.
  - *Assertion*: REPL remains active; user can enter next prompt or `/replay`.
- **TC-T1-F31-05 (Configurable Iteration Limit Flag)**:
  - *Input*: Launch with `--max-iterations 5`.
  - *Oracle*: `specs.md` §4.5.
  - *Assertion*: Halts cleanly at iteration 5.

---

### Category E: UI, Streaming & Slash Commands (Features 32–43)

#### Feature 32: Live Token Streaming
- **TC-T1-F32-01 (Salamander stream_text Output)**:
  - *Input*: Incoming SSE token stream.
  - *Oracle*: `specs.md` §5.1.
  - *Assertion*: Tokens printed to STDOUT as they arrive.
- **TC-T1-F32-02 (Word Boundary Preservation)**:
  - *Input*: Multi-chunk streaming.
  - *Oracle*: `specs.md` §5.1.
  - *Assertion*: Words are assembled without dropped characters or spurious spaces.
- **TC-T1-F32-03 (Flushing on Newline)**:
  - *Input*: Stream emits newline token `\n`.
  - *Oracle*: `specs.md` §5.1.
  - *Assertion*: Output buffer flushed immediately to terminal.
- **TC-T1-F32-04 (ANSI Color Escape Passthrough)**:
  - *Input*: Formatted response stream.
  - *Oracle*: `specs.md` §5.1.
  - *Assertion*: ANSI formatting sequences rendered correctly.
- **TC-T1-F32-05 (Zero Spurious Linebreaks)**:
  - *Input*: Long streamed paragraph.
  - *Oracle*: `specs.md` §5.1.
  - *Assertion*: Renders with natural terminal wrapping.

#### Feature 33: Spinner Management
- **TC-T1-F33-01 (Spinner Activation on :evaluating)**:
  - *Input*: Turn starts evaluating.
  - *Oracle*: `specs.md` §5.1.
  - *Assertion*: Animated Braille spinner starts in terminal.
- **TC-T1-F33-02 (Clean Teardown on First Visible Token)**:
  - *Input*: First visible content token arrives (:responding).
  - *Oracle*: `specs.md` §5.1 teardown rule.
  - *Assertion*: Spinner torn down (`clear_line`), zero leftover spinner glyphs on screen.
- **TC-T1-F33-03 (Spinner Restart on Subsequent Tool Calling)**:
  - *Input*: Agent initiates tool execution.
  - *Oracle*: `specs.md` §5.1.
  - *Assertion*: Spinner restarts indicating active tool execution.
- **TC-T1-F33-04 (Clean Teardown on Error)**:
  - *Input*: Step encounters error while spinner is active.
  - *Oracle*: `specs.md` §5.1.
  - *Assertion*: Spinner stops cleanly; error printed on clean line.
- **TC-T1-F33-05 (CI/Dumb Terminal Graceful Degradation)**:
  - *Input*: `TERM=dumb` or `CI=1`.
  - *Oracle*: `specs.md` §5.1.
  - *Assertion*: Braille animations suppressed; clean static text emitted.

#### Feature 34: `<think>` Tag Isolation
- **TC-T1-F34-01 (Real-Time Tag Detection)**:
  - *Input*: Model emits `<think>analyzing code</think>Hello`.
  - *Oracle*: `specs.md` §5.2.
  - *Assertion*: `<think>` opening and closing tags detected by state machine.
- **TC-T1-F34-02 (Thinking Content Hidden from STDOUT)**:
  - *Input*: Stream contains thinking tokens.
  - *Oracle*: `specs.md` §5.2.
  - *Assertion*: "analyzing code" is not printed to visible terminal STDOUT.
- **TC-T1-F34-03 (Thinking Accumulation in RAM)**:
  - *Input*: Stream completes.
  - *Oracle*: `specs.md` §5.2.
  - *Assertion*: Reasoning accumulated in `thinking_log` buffer.
- **TC-T1-F34-04 (Inspection via /thinking)**:
  - *Input*: Run `/thinking`.
  - *Oracle*: `specs.md` §5.2.
  - *Assertion*: Displays "analyzing code".
- **TC-T1-F34-05 (Alternative <|think|> Tag Support)**:
  - *Input*: Model emits `<|think|>reasoning<|/think|>Answer`.
  - *Oracle*: `specs.md` §5.2.
  - *Assertion*: Pipe-style thinking tags also isolated.

#### Feature 35: ANSI Markdown Formatting
- **TC-T1-F35-01 (Code Blocks Protected from Span Formatting)**:
  - *Input*: Code block containing `*foo*` and `_bar_`.
  - *Oracle*: `specs.md` §5.3.
  - *Assertion*: Asterisks and underscores in code blocks remain verbatim; not styled as italics.
- **TC-T1-F35-02 (Code Block Background Styling)**:
  - *Input*: ```crystal ... ```.
  - *Oracle*: `specs.md` §5.3.
  - *Assertion*: Styled with dark gray background `\e[48;5;236m`.
- **TC-T1-F35-03 (Header Bold Cyan Formatting)**:
  - *Input*: `# Header Title`.
  - *Oracle*: `specs.md` §5.3.
  - *Assertion*: Styled with bold cyan `\e[1;36m`.
- **TC-T1-F35-04 (Bold and Italic Styling)**:
  - *Input*: `**bold** and *italic*`.
  - *Oracle*: `specs.md` §5.3.
  - *Assertion*: Bold styled with `\e[1;97m`, italic with `\e[3m`.
- **TC-T1-F35-05 (Style Stack Restoration)**:
  - *Input*: Bold span inside header: `# Header with **bold** word`.
  - *Oracle*: `specs.md` §5.3 style stack restoration.
  - *Assertion*: Exiting bold word restores cyan header style, not default reset `\e[0m`.

#### Feature 36: `Ctrl+C` Turn Rollback
- **TC-T1-F36-01 (Interrupt During LLM Generation)**:
  - *Input*: Send `SIGINT` while streaming.
  - *Oracle*: `specs.md` §5.4.
  - *Assertion*: Stream aborted immediately; REPL session survives.
- **TC-T1-F36-02 (Interrupt During Subprocess Execution)**:
  - *Input*: Send `SIGINT` while `run_command` is active.
  - *Oracle*: `specs.md` §5.4.
  - *Assertion*: `SIGKILL` sent to `-pgid`; child processes killed.
- **TC-T1-F36-03 (Active Turn Purge from Context)**:
  - *Input*: Inspect `/review` after `Ctrl+C`.
  - *Oracle*: `specs.md` §5.4 rule 3.
  - *Assertion*: Partial turn purged; no orphaned `tool_calls` remain.
- **TC-T1-F36-04 (Prompt Line Restoration)**:
  - *Input*: Press `Ctrl+C`.
  - *Oracle*: `specs.md` §5.4 rule 5.
  - *Assertion*: Original user prompt text restored to input line for editing.
- **TC-T1-F36-05 (Double Ctrl+C at Empty Prompt Exits)**:
  - *Input*: Press `Ctrl+C` twice rapidly at empty prompt.
  - *Oracle*: `specs.md` §5.4 session termination.
  - *Assertion*: REPL exits cleanly with code 0.

#### Feature 37: `/clear` Command
- **TC-T1-F37-01 (Conversation Window Wipe)**:
  - *Input*: Run `/clear`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Conversational history cleared; `/review` shows empty history.
- **TC-T1-F37-02 (Pinned Files Preserved)**:
  - *Input*: Pin file, run `/clear`, run `/review`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Pinned files remain intact in context.
- **TC-T1-F37-03 (Active Directive Preserved)**:
  - *Input*: Run `/clear`, run `/prompt`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Active system prompt remains unchanged.
- **TC-T1-F37-04 (Confirmation Notice)**:
  - *Input*: Run `/clear`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Prints confirmation that context was cleared.
- **TC-T1-F37-05 (RAM Transcript Independence)**:
  - *Input*: Run `/clear`, then `/save`.
  - *Oracle*: `specs.md` §2.7.
  - *Assertion*: Pristine transcript retains pre-clear turns.

#### Feature 38: `/cls` Command
- **TC-T1-F38-01 (Screen Clear Escape Sequence)**:
  - *Input*: Run `/cls`.
  - *Oracle*: `specs.md` §5.5 (`\e[2J\e[H`).
  - *Assertion*: Emits terminal clear and cursor home escape sequence.
- **TC-T1-F38-02 (Context Untouched)**:
  - *Input*: Run `/cls`, run `/review`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Conversational memory remains 100% intact.
- **TC-T1-F38-03 (Prompt Reprompted)**:
  - *Input*: Run `/cls`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Input prompt reappears at top of screen.
- **TC-T1-F38-04 (Zero Disk Activity)**:
  - *Input*: Run `/cls`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: No filesystem operations triggered.
- **TC-T1-F38-05 (Aliased to Clear Screen Shortcut)**:
  - *Input*: Run `/cls`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Behaves equivalently to terminal `Ctrl+L`.

#### Feature 39: `/review` Command
- **TC-T1-F39-01 (Complete Prompt Assembly Display)**:
  - *Input*: Run `/review`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Prints exact assembled payload prepared for LLM dispatch.
- **TC-T1-F39-02 (System Directive Display)**:
  - *Input*: Run `/review`.
  - *Oracle*: `specs.md` §2.2.
  - *Assertion*: Shows system directive block.
- **TC-T1-F39-03 (Pinned Files Block Display)**:
  - *Input*: Pin file, run `/review`.
  - *Oracle*: `specs.md` §2.2.
  - *Assertion*: Shows pinned files block with live content.
- **TC-T1-F39-04 (Truncated Tool Stub Display)**:
  - *Input*: Trigger shedding, run `/review`.
  - *Oracle*: `specs.md` §2.3, §2.4.
  - *Assertion*: Displays truncated tool results with stub.
- **TC-T1-F39-05 (Zero Stochastic Side-Effects)**:
  - *Input*: Run `/review`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Purely read-only inspection; no LLM call or turn advance.

#### Feature 40: `/thinking` Command
- **TC-T1-F40-01 (Reasoning Log Display)**:
  - *Input*: Run `/thinking` after turn with `<think>` tags.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Prints reasoning block verbatim.
- **TC-T1-F40-02 (Notice When No Thinking Occurred)**:
  - *Input*: Run `/thinking` after turn without `<think>` tags.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Prints notice: `No thinking reasoning recorded for the last turn`.
- **TC-T1-F40-03 (Formatted Display)**:
  - *Input*: View `/thinking` output.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Rendered with distinct reasoning styling (italic / dark gray).
- **TC-T1-F40-04 (Updated Each Turn)**:
  - *Input*: Execute second turn with new thinking tokens.
  - *Oracle*: `specs.md` §5.2.
  - *Assertion*: `/thinking` displays the new turn's reasoning block.
- **TC-T1-F40-05 (Pristine Transcript Parity)**:
  - *Input*: Compare `/thinking` with `/save` export.
  - *Oracle*: `specs.md` §2.7.
  - *Assertion*: Thinking blocks included in exported transcript.

#### Feature 41: `/model` Command
- **TC-T1-F41-01 (Display Active Model)**:
  - *Input*: Run `/model` with no args.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Prints active model name, provider, and parameters.
- **TC-T1-F41-02 (Switch Active Model)**:
  - *Input*: `/model qwen2.5-coder:32b`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Switches active model configuration for current session.
- **TC-T1-F41-03 (Confirmation Emission)**:
  - *Input*: Switch model.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Prints confirmation: `Active model switched to...`.
- **TC-T1-F41-04 (Subsequent Turn Dispatched to New Model)**:
  - *Input*: Switch model, dispatch turn.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: HTTP request payload `model` field matches new model.
- **TC-T1-F41-05 (Unknown Model Error Handling)**:
  - *Input*: `/model invalid_model_alias`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Emits error notice if alias cannot be resolved.

#### Feature 42: `/paste` Multi-Line Input Mode
- **TC-T1-F42-01 (Enter Paste Mode via /paste)**:
  - *Input*: `/paste`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Enters accumulation mode with prompt indicator (e.g. `... `).
- **TC-T1-F42-02 (Enter Paste Mode via Triple Quotes """ )**:
  - *Input*: Type `"""`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Enters multi-line mode automatically.
- **TC-T1-F42-03 (Terminate via /end)**:
  - *Input*: Multi-line text followed by `/end`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Accumulation terminates; single combined prompt dispatched.
- **TC-T1-F42-04 (Terminate via Closing Triple Quotes """ )**:
  - *Input*: Multi-line text followed by `"""`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Multi-line block closes and dispatches.
- **TC-T1-F42-05 (Internal Newline Preservation)**:
  - *Input*: Paste 10 lines with indentation.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Indentation and newlines preserved verbatim in prompt.

#### Feature 43: `/exit` Command
- **TC-T1-F43-01 (Clean Process Exit Code 0)**:
  - *Input*: Run `/exit`.
  - *Oracle*: `specs.md` §5.5.
  - *Assertion*: Process exits with code 0.
- **TC-T1-F43-02 (Terminal Mode Restoration)**:
  - *Input*: Run `/exit`.
  - *Oracle*: `specs.md` §5.5 raw mode cleanup.
  - *Assertion*: Terminal cooked mode and cursor visibility restored.
- **TC-T1-F43-03 (Ephemeral Context Evaporation)**:
  - *Input*: Exit REPL; check memory.
  - *Oracle*: `specs.md` §1.3, §2.7.
  - *Assertion*: In-memory sliding window and RAM transcript evaporate.
- **TC-T1-F43-04 (XDG Manifest last_accessed Update)**:
  - *Input*: Check `workspace.json` after exit.
  - *Oracle*: `specs.md` §1.3.
  - *Assertion*: `last_accessed` timestamp updated in central XDG.
- **TC-T1-F43-05 (Zero Hanging Subprocesses)**:
  - *Input*: Exit REPL.
  - *Oracle*: `specs.md` §3.5 process group cleanup.
  - *Assertion*: No orphaned child processes left running.

---

### Category F: Persistence & Logging (Feature 44)

#### Feature 44: Audit Log Rotation
- **TC-T1-F44-01 (JSONL Format Verification)**:
  - *Input*: Execute 2 LLM turns.
  - *Oracle*: `specs.md` §1.3 (`llm_calls.jsonl`).
  - *Assertion*: File contains valid JSON on each line with `timestamp`, `model`, `prompt`, `response`.
- **TC-T1-F44-02 (Central State Directory Placement)**:
  - *Input*: Check log file path.
  - *Oracle*: `specs.md` §1.3 (`$XDG_STATE_HOME/nightmare/workspaces/<id>/llm_calls.jsonl`).
  - *Assertion*: Located strictly in central state directory.
- **TC-T1-F44-03 (Rotation at 20 MB)**:
  - *Input*: Append data to `llm_calls.jsonl` exceeding 20 MB; dispatch turn.
  - *Oracle*: `specs.md` §1.3 rotation rule.
  - *Assertion*: Rotated to `llm_calls.jsonl.1`; active log reset.
- **TC-T1-F44-04 (Retention of Up to 3 Rotated Files)**:
  - *Input*: Trigger 4 successive rotations.
  - *Oracle*: `specs.md` §1.3 retention cap.
  - *Assertion*: Files `llm_calls.jsonl`, `.1`, `.2`, `.3` exist; older `.4` purged.
- **TC-T1-F44-05 (Suppression with --no-log)**:
  - *Input*: Run with `--no-log`.
  - *Oracle*: `specs.md` §1.3.
  - *Assertion*: Zero log writes executed.

---

## 4. Tier 2: Boundary & Corner Cases

At least 5 test cases per specified boundary condition.

### Boundary 1: Path Traversal (`../`) Invariant
- **TC-T2-PT-01 (Relative Escaping to System Root)**:
  - *Input*: `read_file(path: "../../../etc/passwd")`.
  - *Oracle*: `specs.md` §1.1, Edge Case 2.
  - *Assertion*: Raises `SecurityError`; execution rejected; zero bytes read.
- **TC-T2-PT-02 (Write Traversal Outside Root)**:
  - *Input*: `write_file(path: "../escaped.txt", content: "data")`.
  - *Oracle*: `specs.md` §1.1.
  - *Assertion*: Raises `SecurityError`; file not created.
- **TC-T2-PT-03 (Absolute Path Outside Root)**:
  - *Input*: `read_file(path: "/etc/hosts")`.
  - *Oracle*: `specs.md` §1.1.
  - *Assertion*: Raises `SecurityError`; execution blocked.
- **TC-T2-PT-04 (Nested Subdirectory Path Traversal)**:
  - *Input*: `read_file(path: "src/nested/../../../../etc/shadow")`.
  - *Oracle*: `specs.md` §1.1.
  - *Assertion*: Dereferenced path resolves outside `@root`; raises `SecurityError`.
- **TC-T2-PT-05 (Internal Redundant Navigation Permitted)**:
  - *Input*: `read_file(path: "./src/sub/../sub/app.cr")`.
  - *Oracle*: `specs.md` §1.1.
  - *Assertion*: Resolves cleanly inside `@root`; file read succeeds.

### Boundary 2: Outside Symlink Dereferencing
- **TC-T2-SL-01 (Symlink to External File /etc/hosts)**:
  - *Input*: Symlink `link_hosts -> /etc/hosts` in workspace. Call `read_file("link_hosts")`.
  - *Oracle*: `specs.md` §1.1, Edge Case 3.
  - *Assertion*: Dereferenced via `File.realpath`; detected outside `@root`; raises `SecurityError`.
- **TC-T2-SL-02 (Writing Through External Symlink)**:
  - *Input*: Symlink `link_target -> /tmp/external`. Call `write_file("link_target", "data")`.
  - *Oracle*: `specs.md` §1.1, §3.1.
  - *Assertion*: Rejected with `SecurityError`; external file untouched.
- **TC-T2-SL-03 (Directory Symlink to Parent)**:
  - *Input*: Symlink `up -> ..`. Call `list_files("up")`.
  - *Oracle*: `specs.md` §1.1.
  - *Assertion*: Rejected with `SecurityError`.
- **TC-T2-SL-04 (Internal Symlinks Permitted)**:
  - *Input*: Symlink `link_app -> src/app.cr` inside repo. Call `read_file("link_app")`.
  - *Oracle*: `specs.md` §1.1.
  - *Assertion*: Resolves within `@root`; read succeeds.
- **TC-T2-SL-05 (Dangling / Broken Symlink Handling)**:
  - *Input*: Symlink pointing to missing file. Call `file_info("dangling_link")`.
  - *Oracle*: `specs.md` §1.1.
  - *Assertion*: Returns clean file not found error; does not crash process.

### Boundary 3: Strict `.git/` Protection
- **TC-T2-GIT-01 (write_file targeting .git/config)**:
  - *Input*: `write_file(path: ".git/config", content: "[evil]")`.
  - *Oracle*: `specs.md` §3.1, Edge Case 4.
  - *Assertion*: Unconditionally rejected; original `.git/config` preserved.
- **TC-T2-GIT-02 (write_file targeting .git/hooks/pre-commit)**:
  - *Input*: `write_file(path: ".git/hooks/pre-commit", content: "evil")`.
  - *Oracle*: `specs.md` §3.1.
  - *Assertion*: Rejected; hook not created.
- **TC-T2-GIT-03 (replace_in_file in .git/HEAD)**:
  - *Input*: `replace_in_file(path: ".git/HEAD", target: "main", replacement: "evil")`.
  - *Oracle*: `specs.md` §3.1.
  - *Assertion*: Rejected; `.git/HEAD` untouched.
- **TC-T2-GIT-04 (append_to_file in .git/info/exclude)**:
  - *Input*: `append_to_file(path: ".git/info/exclude", content: "data")`.
  - *Oracle*: `specs.md` §3.1.
  - *Assertion*: Rejected; `.git/info/exclude` untouched.
- **TC-T2-GIT-05 (Relative Path Trickery targeting .git/)**:
  - *Input*: `write_file(path: "src/../../.git/config", content: "data")`.
  - *Oracle*: `specs.md` §3.1.
  - *Assertion*: Canonical path detected inside `.git/`; write rejected.

### Boundary 4: Shell Metacharacter Auto-Approval Ban
- **TC-T2-MC-01 (Semicolon ; Command Injection)**:
  - *Input*: `git status; rm -rf /`.
  - *Oracle*: `specs.md` §3.5 strict metacharacter ban, Edge Case 9.
  - *Assertion*: Auto-approval barred; forces modal.
- **TC-T2-MC-02 (Pipeline | Command)**:
  - *Input*: `cat file | grep pattern`.
  - *Oracle*: `specs.md` §3.5, Edge Case 10.
  - *Assertion*: Forces modal.
- **TC-T2-MC-03 (Command Substitution $())**:
  - *Input*: `echo $(whoami)`.
  - *Oracle*: `specs.md` §3.5, Edge Case 11.
  - *Assertion*: Forces modal.
- **TC-T2-MC-04 (Redirection Operators > and <)**:
  - *Input*: `echo foo > out.txt`.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Forces modal.
- **TC-T2-MC-05 (Embedded Newline \n Injection)**:
  - *Input*: `git status\nls -la`.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Forces modal.

### Boundary 5: Closed Stdin (`/dev/null`)
- **TC-T2-IN-01 (Interactive Shell 'read' Returns EOF)**:
  - *Input*: `run_command(command: "read var; echo EOF_REACHED")`.
  - *Oracle*: `specs.md` §3.5 guardrail 4, Edge Case 14.
  - *Assertion*: Returns EOF immediately without blocking; prints `EOF_REACHED`.
- **TC-T2-IN-02 (Interactive Sudo Prompt Fails Immediately)**:
  - *Input*: `run_command(command: "cat -")`.
  - *Oracle*: `specs.md` §3.5 guardrail 4.
  - *Assertion*: Exits immediately with EOF; zero hanging.
- **TC-T2-IN-03 (Environment Injections CI=1, GIT_TERMINAL_PROMPT=0)**:
  - *Input*: `run_command(command: "echo CI=$CI GIT=$GIT_TERMINAL_PROMPT")`.
  - *Oracle*: `specs.md` §3.5 guardrail 5.
  - *Assertion*: Prints `CI=1 GIT=0`.
- **TC-T2-IN-04 (Closed Stdin Protects REPL Keystrokes)**:
  - *Input*: Subprocess runs while user types next command.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Subprocess cannot steal keystrokes from parent REPL stdin.
- **TC-T2-IN-05 (REPL Termination on Closed Stdin / EOF)**:
  - *Input*: Close REPL stdin (pipe close or Ctrl+D).
  - *Oracle*: `specs.md` §5.4.
  - *Assertion*: REPL exits cleanly with code 0.

### Boundary 6: Subprocess Timeout Cap & Process Group Termination
- **TC-T2-TO-01 (Timeout Supervisor Process Group Kill)**:
  - *Input*: `run_command(command: "sleep 60", timeout: 1)`.
  - *Oracle*: `specs.md` §3.5 guardrail 3, Edge Case 13.
  - *Assertion*: Fired at 1s; sends `SIGKILL` to `-pgid`; returns timeout notice.
- **TC-T2-TO-02 (Nested Child Process Tree Kill)**:
  - *Input*: `run_command(command: "sh -c 'sleep 100'", timeout: 1)`.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Entire subprocess tree (`sh` and `sleep`) terminated.
- **TC-T2-TO-03 (Hard Cap Clamping at 600s)**:
  - *Input*: `run_command(command: "echo ok", timeout: 9999)`.
  - *Oracle*: `specs.md` §3.5 (capped at hard maximum 600s).
  - *Assertion*: Modal and execution clamp timeout to 600s.
- **TC-T2-TO-04 (Infinite Loop CPU Burner Containment)**:
  - *Input*: `run_command(command: "while true; do :; done", timeout: 1)`.
  - *Oracle*: `specs.md` §3.5.
  - *Assertion*: Loop killed at 1s without leaking background CPU threads.
- **TC-T2-TO-05 (Excessive Stdout Output Truncation)**:
  - *Input*: `run_command(command: "cat 5mb_file.log")`.
  - *Oracle*: `specs.md` §3.5 guardrail 6, Edge Case 15.
  - *Assertion*: Truncated at 50 KB / 300 lines with omission banner.

### Boundary 7: In-Turn Shedding (Active Turn Defense)
- **TC-T2-SH-01 (Preserve Exactly Last 2 Verbatim)**:
  - *Input*: Active turn invokes 6 tools; tokens exceed 85% cap.
  - *Oracle*: `specs.md` §2.4, Edge Case 18.
  - *Assertion*: Tools 5 and 6 retained verbatim in context.
- **TC-T2-SH-02 (Truncate Prior Consumed Results to 200 Chars + Stub)**:
  - *Input*: Active turn with 6 tools exceeding 85% cap.
  - *Oracle*: `specs.md` §2.4.
  - *Assertion*: Tools 1 through 4 truncated to 200 chars + stub.
- **TC-T2-SH-03 (Strict User Prompt Protection)**:
  - *Input*: Large user prompt in active turn.
  - *Oracle*: `specs.md` §2.4.
  - *Assertion*: User prompt retains 100% of characters.
- **TC-T2-SH-04 (Zero Truncation When Turn Has <=2 Tools)**:
  - *Input*: Turn with 2 large tools.
  - *Oracle*: `specs.md` §2.4.
  - *Assertion*: Zero truncation applied.
- **TC-T2-SH-05 (Pristine Transcript Unaffected by In-Turn Shedding)**:
  - *Input*: Trigger in-turn shedding; export via `/save`.
  - *Oracle*: `specs.md` §2.7, Edge Case 17.
  - *Assertion*: Saved Markdown contains complete, un-truncated tool results.

### Boundary 8: `Ctrl+C` Signal Interception & Turn Rollback
- **TC-T2-SIG-01 (Stream Cancellation on Ctrl+C)**:
  - *Input*: Send `SIGINT` while LLM is generating text.
  - *Oracle*: `specs.md` §5.4, Edge Case 23.
  - *Assertion*: HTTP stream aborted; REPL prompt restored.
- **TC-T2-SIG-02 (Tool Subprocess Kill on Ctrl+C)**:
  - *Input*: Send `SIGINT` during `run_command`.
  - *Oracle*: `specs.md` §5.4, Edge Case 24.
  - *Assertion*: Subprocess process group killed via `SIGKILL`.
- **TC-T2-SIG-03 (Turn Rollback Invariant)**:
  - *Input*: Interrupt active turn mid-step.
  - *Oracle*: `specs.md` §5.4.
  - *Assertion*: Active turn purged from `SlidingStore`; zero orphaned tool pairs.
- **TC-T2-SIG-04 (User Input Text Preserved to Prompt Line)**:
  - *Input*: Interrupt active turn.
  - *Oracle*: `specs.md` §5.4.
  - *Assertion*: User's input prompt text restored for re-editing.
- **TC-T2-SIG-05 (Single Ctrl+C at Prompt Keeps Session Alive)**:
  - *Input*: Send single `SIGINT` at empty prompt.
  - *Oracle*: `specs.md` §5.4, Edge Case 25.
  - *Assertion*: REPL remains active; does not terminate.

---

## 5. Tier 3: Cross-Feature Combinations (Pairwise Coverage)

### 5.1 Pairwise Coverage Matrix

| Feature Area A | Feature Area B | Interaction Scenario | Key Invariant |
| :--- | :--- | :--- | :--- |
| **Pinned Files** | `read_file` Tool | Agent calls `read_file` on pinned path | Short-circuits with zero-token notice |
| **In-Turn Shedding** | Pristine Transcript | Active turn tool results compressed | `/save` exports un-truncated transcript |
| **Shell Metacharacters** | Allowlist Persistence | Command matches regex allowlist but has `;` | Metacharacter ban forces modal |
| **/prompt edit** | Directives Precedence | In-memory edit of committed prompt | Updates RAM directive; disk untouched |
| **Rate Limit Backoff** | Format Correction | Step gets 429 then malformed JSON | Exponential backoff then format retry |
| **Timeout Supervisor** | Process Group Kill | Subprocess times out then next run | Session survives; next tool executes |
| **Turn Pruning** | `/clear` Command | Pruning evicts history; user clears | Pinned files survive; history resets |
| **`<think>` Isolation** | Live Token Stream | Output has `<think>` reasoning block | Stream hides thoughts; `/thinking` shows |
| **Outside Symlinks** | `list_files` & Secrets | Directory has symlinks and `.env` | Both outside link and `.env` filtered |
| **Pinned Files Budget** | `/drop` Command | File exceeds 60% budget limit | Rejected; user drops and re-adds smaller |

### 5.2 Detailed Combination Test Specifications

- **TC-T3-CB-01 ([Pinned Files x read_file x Live Re-read])**:
  - *Procedure*: User pins `src/shared.cr` with `/add`. Agent invokes `read_file("src/shared.cr")` -> receives zero-token pinned notice. Developer modifies `src/shared.cr` on disk. User runs `/review`.
  - *Assertion*: `/review` reflects disk modification immediately.
- **TC-T3-CB-02 ([In-Turn Shedding x /save Pristine Transcript])**:
  - *Procedure*: Turn executes 4 tools exceeding 85% cap. `/review` verifies tools 1 and 2 are truncated with stubs. User runs `/save transcript.md`.
  - *Assertion*: `transcript.md` contains full un-truncated outputs of tools 1 and 2.
- **TC-T3-CB-03 ([Shell Metacharacters x Allowlist Persistence])**:
  - *Procedure*: Central allowlist contains `^git status.*$`. Agent invokes `git status` -> auto-approves. Agent invokes `git status; whoami` -> forced modal appears.
  - *Assertion*: Metacharacter ban overrides allowlist.
- **TC-T3-CB-04 ([/prompt edit In-Memory x Directives Precedence])**:
  - *Procedure*: `.nightmare/prompt.md` exists on disk. User runs `/prompt edit`, modifies prompt, runs `/prompt`.
  - *Assertion*: `/prompt` shows new text; `.nightmare/prompt.md` on disk is byte-for-byte unchanged.
- **TC-T3-CB-05 ([Rate Limit Backoff x Format-Correction Retry])**:
  - *Procedure*: Mock LLM returns HTTP 429 on call 1 (triggering backoff), then malformed JSON on call 2 (triggering format retry turn), then valid response on call 3.
  - *Assertion*: Harness completes turn successfully returning `Success(String)`.
- **TC-T3-CB-06 ([Timeout PGID Termination x Subsequent Tool Run])**:
  - *Procedure*: Agent runs `sleep 60` with 1s timeout -> PGID killed. Agent immediately runs `echo 'SURVIVED'`.
  - *Assertion*: Session survives; second command outputs `SURVIVED`.
- **TC-T3-CB-07 ([Turn Pruning x /clear x /review])**:
  - *Procedure*: Multiple turns executed, file pinned. User runs `/clear`, then `/review`.
  - *Assertion*: History is empty; pinned file block is intact.
- **TC-T3-CB-08 ([<think> Tag Isolation x Live Streaming x /thinking])**:
  - *Procedure*: Stream emits `<think>REASONING</think>VISIBLE`.
  - *Assertion*: Only `VISIBLE` printed during streaming; `/thinking` displays `REASONING`.
- **TC-T3-CB-09 ([Outside Symlinks x list_files x Sensitive Patterns])**:
  - *Procedure*: Directory contains `.env.production` and symlink pointing to `/etc`. Agent runs `list_files`.
  - *Assertion*: Neither the sensitive `.env` nor external targets are listed.
- **TC-T3-CB-10 ([Pinned Files Budget Cap x /drop Recovery])**:
  - *Procedure*: User adds 300 KB file (exceeding 60% cap) -> rejected. User adds small file -> succeeds. User runs `/drop`.
  - *Assertion*: Small file dropped cleanly; budget reclaimed.

---

## 6. Tier 4: Real-World Developer Workloads

Comprehensive end-to-end user scenarios simulating developer workflows.

### Workload 1: Initial Code Exploration & System Survey
- **Test ID**: `TC-T4-WL-01`
- **Scenario**: Developer launches NIGHTMARE in a new repository. Agent lists workspace files, inspects module structure via `file_info`, searches for entry point methods with `search`, and returns summary.
- **Assertions**:
  - Startup banner emitted cleanly.
  - Autonomous read tools execute with zero modal fatigue.
  - `assert_zero_repo_litter!` verifies zero config/log files written in project.

### Workload 2: Test-Driven Bug Fix & Refactoring Loop
- **Test ID**: `TC-T4-WL-02`
- **Scenario**: Developer pins failing spec with `/add spec/calc_spec.cr`. Agent executes `run_command("crystal spec")` (user approves `[y]`), discovers failure, proposes `replace_in_file` fix (modal displays unified diff, user approves `[y]`), then reruns `crystal spec` (user approves `[y]`).
- **Assertions**:
  - Overwrite diff modal presents unified diff before writing.
  - File on disk updated only after approval.
  - Spec passes on rerun; agent reports completion.

### Workload 3: Large Output In-Turn Shedding & Context Defense
- **Test ID**: `TC-T4-WL-03`
- **Scenario**: Agent analyzes 6 large log files in a single turn. As total tokens approach 85% of budget, in-turn shedding compresses older tool outputs. Developer runs `/save audit_session.md` to export the session.
- **Assertions**:
  - Active turn does not blow up context budget.
  - Last 2 tool outputs retained verbatim in memory.
  - Exported `audit_session.md` contains 100% of all log data un-truncated.

### Workload 4: Command Approval Anti-Fatigue & Allowlist Lifecycle
- **Test ID**: `TC-T4-WL-04`
- **Scenario**: Agent runs `git log -n 1` -> user selects `[p]` (prefix allow). Agent subsequently runs `git log --oneline` -> auto-approved without modal. Agent then runs `git log; rm -rf /` -> metacharacter ban forces approval modal. User rejects `[N]`.
- **Assertions**:
  - Prefix rule added to allowlist in central XDG.
  - Clean prefix commands execute autonomously.
  - Metacharacter injection cannot bypass approval boundary.

### Workload 5: Interrupted Execution & Session Resilience
- **Test ID**: `TC-T4-WL-05`
- **Scenario**: Agent runs a slow command (`sleep 60`). Developer presses `Ctrl+C`. Process group is killed, active turn is rolled back from context, and prompt is restored. Developer inputs new instruction; agent proceeds normally.
- **Assertions**:
  - Process group terminated cleanly.
  - No orphaned tool calls left in context store.
  - REPL session remains active and responsive.

### Workload 6: Self-Calibrating Token Accounting with Provider Feedback
- **Test ID**: `TC-T4-WL-06`
- **Scenario**: Model inference returns `usage.prompt_tokens` feedback. Estimator dynamically adjusts character-to-token divisor using exponential moving average (0.8/0.2 weight).
- **Assertions**:
  - Divisor updates based on actual feedback.
  - Context meter reflects calibrated estimation with `~` symbol.
  - Subsequent turn pruning thresholds adapt accurately.

---

## 7. Artifact Index

| File Path | Description |
| :--- | :--- |
| `spec/e2e/test_runner.cr` | Opaque-box E2E test infrastructure (WorkspaceSandbox, MockLlmServer, ProcessSession) |
| `spec/e2e/test_runner_spec.cr` | Executable verification specs for the test runner infrastructure itself (7 passing tests) |
| `spec/e2e/tier1_feature_spec.cr` | Executable E2E specs covering Tier 1 core features (45 examples) |
| `spec/e2e/tier2_boundary_spec.cr` | Executable E2E specs covering Tier 2 boundary cases (40 examples) |
| `spec/e2e/tier3_combination_spec.cr` | Executable E2E specs covering Tier 3 cross-feature combinations (10 examples) |
| `spec/e2e/tier4_workload_spec.cr` | Executable E2E specs covering Tier 4 developer workloads (6 examples) |
| `TEST_INFRA.md` | Authoritative requirements-driven test architecture & exhaustive specifications |
