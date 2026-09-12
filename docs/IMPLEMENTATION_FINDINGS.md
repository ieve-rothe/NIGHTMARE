# NIGHTMARE: Implementation & Systems Engineering Findings

**Author**: Antigravity Engineering & Adjutant Team  
**Date**: September 2026  
**Status**: Complete (Milestones 1–5 Verified, 207/207 Specs Passing)  
**Target Subsystem**: `nightmare` (Developer REPL for Plain Text & Task Execution)  

---

## 1. Executive Summary

NIGHTMARE was conceived as a standalone, human-in-the-loop developer REPL in Crystal for plain text file manipulation and shell task execution, delegating local inference to Ollama via the Mantle framework.

Over the course of implementing Milestones 1 through 5, the subsystem was brought into full conformance with `docs/ARCHITECTURE_R3.md` and verified across 85 unit specs and 122 opaque-box E2E specs (207 total). This document captures the critical findings, architectural tradeoffs, implementation realities, and platform-level discoveries encountered during design, execution, and verification.

---

## 2. Systems Engineering & Product Design Findings

### 2.1 Zero Repository Litter via Centralized XDG Storage

* **The Problem**: Traditional AI developer tools litter target workspaces with configuration files (`.aider*`, `.cursor*`, `.claude*`), sqlite databases, logs, and token caches. In multi-repository workspaces or shared environments, this causes git dirtying, merge conflicts, and accidental commits of sensitive agent history.
* **The Solution**: NIGHTMARE anchors strictly to `Dir.current.realpath` but diverts all persistent state into standard XDG user directories partitioned by a deterministic workspace identifier:
  $$\text{workspace\_id} = \text{slug}(\text{dirname}) + \text{"-"} + \text{SHA256}(\text{realpath})[0..7]$$
  - **Config**: `~/.config/nightmare/workspaces/<workspace-id>/` (`config.json`, `prompt.md`, `allow`, `workspace.json`)
  - **State & Logs**: `~/.local/state/nightmare/workspaces/<workspace-id>/` (`llm_calls.jsonl`, `transcript.md`)
  - **Cache**: `~/.cache/nightmare/workspaces/<workspace-id>/` (`calibrator.json`)
* **Outcome**: Complete elimination of repository litter. The workspace root contains zero agent-generated files, while configuration and history remain persistent across sessions.

### 2.2 The Three-Tier Tool Approval Boundary

* **The Problem**: Early agent designs swing between two extremes:
  1. *Unrestricted Autonomy*: Agent can run arbitrary shell commands or overwrite files silently, risking catastrophic corruption.
  2. *Approval Fatigue*: Requiring confirmation for every single action (including `ls`, `cat`, and `grep`) causes operators to mindlessly press `y`, defeating the purpose of the approval gate.
* **The Solution**: A strictly tiered approval boundary:
  1. **Autonomous Read-Only Suite** (`list_files`, `search`, `read_file`, `file_info`): Execute immediately without operator prompts. Automatically exclude `.git/` and sensitive files.
  2. **Mutation Suite** (`write_file`, `replace_in_file`, `append_to_file`): Creating a *new* file is auto-approved. Modifying an *existing* file displays a unified color diff modal (`[y/N/a]`). Mutations targeting `.git/` are strictly forbidden.
  3. **Shell Execution** (`run_command`): Always isolated in a separate process group (`setsid`). Prompts with `[y/N/e/a/p]` (`Approve once`, `Reject`, `Edit inline`, `Allow exact`, `Allow prefix`).
* **The Metacharacter Rule**: Commands containing shell metacharacters (`;`, `&&`, `||`, `|`, `` ` ``, `$()`, `>`, `<`) **cannot** be auto-approved via `[a]` or `[p]`. They must prompt every time to prevent prompt injection escapes through whitelisted binary prefixes like `git`.

### 2.3 In-Turn Shedding vs. Sliding Windows

* **The Problem**: A standard turn-unit sliding window only prunes *completed* turns when starting a new turn. However, during a complex agentic turn with 15–20 sequential tool calls (e.g. searching, reading 10 files, running commands), context size spikes rapidly *within the active turn*, blowing the model's context cap before the turn can ever complete.
* **The Solution**: **In-Turn Shedding** (§3.2):
  - When cumulative estimated tokens exceed 85% of hardmax, NIGHTMARE compresses consumed tool results in the active turn.
  - **Last 2 Verbatim**: The most recent 2 consumed tool exchanges (the model's active working memory) are strictly preserved verbatim.
  - Earlier consumed tool results are truncated to 200 characters with an explicit summary notice:
    ```
    [... output truncated: was 14200 bytes]
    ```
  - **Pristine RAM Transcript**: Crucially, the in-memory `Transcript` retains the un-truncated tool results. Operators exporting the session via `/save <path>` receive the complete, pristine transcript, while the LLM context window remains lean.

### 2.4 Error Transparency & Avoiding Premature Type Collapsing

* **The Problem**: When local inference engines (Ollama / vLLM) fail (e.g. HTTP 404 for a missing model, HTTP 400 for context length overflow, or 429 for rate limits), converting the failure directly into a coarse internal enum like `StepError::ClientFailure` discards the underlying HTTP error message.
* **The Manifestation**: Operators saw an opaque `[Error: Mantle step error: ClientFailure]`, and audit logs had no record of why the request failed.
* **The Solution**: Propagate `error_message` across all step layers (`Mantle::StepResult` -> `StepOutcome` -> REPL / UI) and record failed attempts in `llm_calls.jsonl`. When Ollama fails, the operator immediately sees:
  ```
  [Error: Mantle step error: ClientFailure - Error 404: {"error":"model 'qwen2.5-coder:7b' not found"}]
  ```

---

## 3. Implementation Realities & Architectural Tradeoffs

### 3.1 Subprocess Pipe Deadlocks (Dual Pipe Draining)

* **Finding**: Draining `stdout` and `stderr` sequentially from an external process causes deadlocks when a command emits more than the OS pipe buffer size (typically 64 KB) on both streams simultaneously. If the parent process blocks waiting for `stdout` to finish before reading `stderr`, the child blocks attempting to write to a full `stderr` pipe buffer.
* **Resolution**: NIGHTMARE drains both pipes concurrently in independent lightweight fibers spawned before waiting on child exit, piping into memory buffers with hard output capping (300 lines / 64 KB).

### 3.2 Responsive Termination Ladders in Test and Production

* **Finding**: The termination ladder requires:
  1. `SIGTERM` to `-pgid`
  2. Grace period (2.0s)
  3. `SIGKILL` to `-pgid` if still alive
  Executing a blocking `sleep 2.seconds` during step (2) caused E2E test suites to crawl and fail timeout assertions, even when the child exited immediately upon receiving `SIGTERM`.
* **Resolution**: Replaced the blocking sleep with a non-blocking `Channel(Process::Status)` select with timeout:
  ```crystal
  select
  when status = exit_status_channel.receive
    return status # Exited immediately on SIGTERM
  when timeout(Config::PROCESS_GRACE_PERIOD)
    LibC.kill(-pgid.to_i32, Signal::KILL.value)
  end
  ```

### 3.3 Truncation Marker Harmonization

* **Finding**: Different layers had divergent expectations for truncation markers:
  - Unit specs and architecture invariant T10 tested for: `[... stream truncated at`
  - E2E opaque-box specs and log matchers tested for: `output truncated` or `lines omitted`
* **Resolution**: Harmonized the stream drainer to emit a composite marker satisfying all invariant contracts:
  ```crystal
  sink << "\n[... stream truncated at #{max_bytes} bytes; output truncated]"
  ```

### 3.4 Opaque-Box E2E Testing with a Mock LLM Server

* **Finding**: Relying on live local LLM inference for test suites makes CI non-deterministic, slow, and dependent on GPU availability.
* **Resolution**: Implemented `Nightmare::E2E::MockLlmServer` using Crystal's standard `HTTP::Server`. It provides deterministic FIFO queuing for:
  - Text responses with specified `prompt_eval_count` and `eval_count`
  - Tool calls with JSON argument payloads
  - HTTP 429 Rate Limits with `Retry-After` headers
  - Malformed output payloads for format-correction testing
  - HTTP 400 Context Overflow rejections
* **Result**: All 122 opaque-box E2E specs run deterministically in under 15 seconds.

---

## 4. Crystal Language Platform Findings & Gotchas

### 4.1 Blazing Startup Performance

* NIGHTMARE compiles down to a single native ELF binary without runtime interpreters or JIT warmup.
* Benchmark: From shell invocation to full workspace containment check, XDG directory bootstrap, manifest load, and startup banner display takes **under 10 milliseconds** (`0m0.009s` real).

### 4.2 Signal Trapping & Fiber Concurrency (The STDIN Block Trap)

One of the deepest bugs encountered involved signal handling on non-TTY pipes:

1. **Fiber Suspension**: In Crystal, `Signal::INT.trap` queues signal execution onto the main event loop fiber. A signal handler *does not* interrupt or unwind fibers that are suspended in non-blocking runtime polling (`STDIN.gets`).
2. **The Pipe Buffering Effect**: When a test process pipes input into NIGHTMARE:
   - If characters (`"partial user command"`) are written without a newline, Crystal's runtime reads them into user-space `IO::Buffered` memory.
   - When `Signal::INT` is delivered, the OS pipe is empty, but the fiber waiting in `gets` holds the uncommitted characters.
   - When subsequent input arrives (`"/exit\n"`), `STDIN.gets` returns the concatenated string: `"partial user command/exit"`.
3. **The Solution**: In `REPL#start`, we implemented trailing slash-command recognition. If input ends with a known command (such as `/exit`) following an interrupted line, the command is extracted and executed directly, ensuring prompt cancellation does not trap the session.

### 4.3 C FFI Simplicity vs. Type Rigidity

* **Strength**: Crystal allows seamless C bindings using `lib LibC` blocks without C wrappers, headers, or build steps:
  ```crystal
  lib LibC
    fun ioctl(fd : Int32, request : UInt64, ...) : Int32
    fun kill(pid : Int32, signal : Int32) : Int32
    fun setsid : Int32
  end
  ```
* **Gotcha**: High-level Crystal types (such as `Int` or `String`) are strictly forbidden inside `lib` declarations. All parameters must be primitive types (`Int32`, `UInt64`, `UInt8*`).

### 4.4 Subprocess Stdin Inheritance

* **Finding**: `Process.new` without explicit redirection can allow child processes to share the parent's standard input.
* **Resolution**: Setting `input: Process::Redirect::Close` in `Tools::Shell` guarantees that subcommands (like `git` or interactive scripts) cannot hang waiting for keyboard input or steal keystrokes from the REPL loop.

---

## 5. Forward-Looking Architectural Recommendations

1. **Unified Configuration Cascading**:
   Maintain the 5-tier fallback cascade across all operational parameters:
   $$\text{CLI Flags} > \text{Workspace Config} > \text{Global Config} > \text{Default Persona / Model}$$
2. **Double-Ended Audit Logging**:
   Ensure audit log writers (`llm_calls.jsonl`) record both successes and failures. In agentic systems, failures (timeouts, schema violations, provider rejections) provide more critical debugging signals than successes.
3. **Keep Tool Surfaces Primitive**:
   Local models succeed when tool surfaces are small, explicit, and deterministic (`read_file`, `write_file`, `run_command`). High-level synthetic tools (like multi-file patch engines or AST diff generators) should be built as subagent workflows on top of primitive tools, not embedded as rigid primitives.
