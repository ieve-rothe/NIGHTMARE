---
ID: TKT-021
Title: Cooperative Cancellation and Session Recovery during Approval Prompts
Status: Closed
Priority: High
---

## 1. User Need
When an interactive operator is in the middle of a REPL session and the agent presents an interactive approval modal (such as a unified diff for file mutation or confirmation for shell command execution), the operator may recognize that the agent is on the wrong track and wish to abort the turn immediately by pressing `Ctrl+C`.

The operator needs a single `Ctrl+C` at any approval prompt to promptly cancel the active turn, discard the proposed diff or unexecuted command without modifying the workspace, and return control cleanly to the REPL prompt with the session history intact. The operator must not be left hanging indefinitely on an unresponsive prompt, nor forced to use emergency double `Ctrl+C` process termination that loses the entire session.

## 2. Problem & Investigation Results

### 2.1 Observed Symptom
During an active turn where the agent proposed a file mutation (`append_to_file`), the user reached the line-mode approval prompt:
```
Approve append to ellie_journal.md? [y/N/a]: n^C
[Interrupt received; cancelling active turn...]
^C
[Interrupt received; cancelling active turn...]
```
The REPL hung at this point. Pressing `Ctrl+C` repeatedly printed `[Interrupt received; cancelling active turn...]` but did not return to the REPL prompt (`> `). Pressing `Ctrl+C` twice in rapid succession triggered the emergency force exit (`exit(130)` introduced in TKT-018), terminating the harness process and discarding the session entirely.

### 2.2 Root Cause Analysis
1. **Uninterrupted STDIN Wait in `Approval#approve_diff` and `approve_command`:**
   Both `Approval#approve_diff` and `Approval#approve_command` rely directly on `raw = @input.gets`. In Crystal's cooperative runtime on Linux, STDIN reading fiber waits for an event from the event loop (epoll / libevent). When the operator hits `Ctrl+C`, the kernel delivers `SIGINT` to the process group. The early trap in `Cancellation#handle_sigint` executes on a signal fiber, sets `@tool_loop.cancelled = true`, and outputs `[Interrupt received; cancelling active turn...]`. However, POSIX signal delivery does not inject an event or synthetic newline into STDIN's file descriptor. As a result, the reading fiber remains suspended indefinitely inside `raw = @input.gets`.
2. **Buffer Bleed of Partially Typed Input:**
   If the operator types characters (e.g. `n`) before pressing `Ctrl+C` (`n^C`), those characters linger in the terminal/IO buffers because `handle_sigint` only invokes `flush_stdin` when `@busy == false`.
3. **Cancellation Propagation across Tool Execution:**
   When an approval prompt is interrupted, the prompt must immediately raise `Nightmare::Harness::CancelledException`. `Mantle::Step` and `StepRunner` already have hooks to catch `CancelledException` (or step failure with "Turn cancelled by user interrupt"), roll back the turn context in `SlidingStore#rollback_turn`, and display `[Turn cancelled by user interrupt]`, but because the approval modal never returned or raised, this pipeline was never reached.

## 3. Specification & Implementation Plan

### 3.1 Non-Blocking Polling with Cancellation Checks in `UI::Approval`
1. **POSIX Polling and Terminal Queue Flushing:**
   - Define `LibC::PollFd`, `LibC.poll`, and `LibC.tcflush(..., LibC::TCIFLUSH)` in `UI::Approval`.
   - Update `flush_input` to execute `tcflush` on `IO::FileDescriptor` to discard unread kernel line buffers.
2. **Configurable Cancellation Callback:**
   - Add `property cancellation_check : Proc(Bool)? = nil` to `UI::Approval`, defaulting to `Nightmare::UI::Cancellation.cancelled?`.
3. **Interruptible Interactive Input (`gets_interactive`):**
   - Implement `private def gets_interactive : String?`:
     - Checks `cancelled?` before reading. If true, flushes input and raises `Harness::CancelledException.new("Turn cancelled by user interrupt")`.
     - When `@input` is an `IO::FileDescriptor`, polls `poll(..., timeout: 50ms)` in a loop with `Fiber.yield` between intervals.
     - If `cancelled?` becomes true during the poll loop, flushes input and immediately raises `Harness::CancelledException`.
     - When data is ready or `@input` is a non-file IO (e.g. `IO::Memory` in specs), performs `@input.gets`.
4. **Approval Prompts Integration:**
   - Replace direct `@input.gets` calls in `approve_diff`, `approve_command`, and the inline command edit prompt (`when "e"`) with `gets_interactive`.

### 3.2 Terminal Input Flushing on Busy Cancellation in `UI::Cancellation`
1. Update `Cancellation#handle_sigint` to invoke `flush_stdin` when `@busy == true` before printing the cancellation banner, discarding any pre-typed characters (e.g., `n` from `n^C`).
2. Add `LibC.tcflush` to `Cancellation#flush_stdin` to flush kernel terminal queues.

## 4. Verification & Validation (V&V)

* **Verification Plan:**
  - Create `spec/ui/approval_cancellation_spec.cr` verifying:
    - `approve_diff` raises `Harness::CancelledException` immediately when `cancellation_check` is true.
    - `approve_command` raises `Harness::CancelledException` immediately when `cancellation_check` is true.
    - `approve_diff` unblocks within 100ms and raises `CancelledException` when cancelled asynchronously during a simulated blocking prompt.
    - Unapproved mutations do not write to disk when cancelled.
  - Run full test suite: `crystal spec` in `nightmare`.

* **Verification Evidence:**
  - `spec/ui/approval_cancellation_spec.cr` passing (5 examples, 0 failures):
    - Verified `approve_diff` immediately raises `CancelledException` when cancelled.
    - Verified `approve_command` immediately raises `CancelledException` when cancelled.
    - Verified asynchronous cancellation unblocks within ~100ms during blocking pipe read in `approve_diff`.
    - Verified asynchronous cancellation unblocks within ~100ms in `approve_command`.
    - Verified pending file mutation (`append_to_file`) leaves disk completely unmodified.
  - `spec/ui/approval_spec.cr` passing (16 examples, 0 failures).
  - `spec/tools_spec.cr` passing (30 examples, 0 failures).
  - `spec/integration/workflows_spec.cr` passing (13 examples, 0 failures).

* **Validation Plan:**
  - Simulate interactive session approval interruption: invoke `approve_diff`, send `SIGINT`, confirm `[Interrupt received; cancelling active turn...]` and clean return to REPL without process hang or needing double Ctrl+C.

* **Validation Evidence:**
  - Validated cooperative unblocking on STDIN/pipe descriptors using 50ms `LibC.poll` loop and `tcflush`. Interruption terminates prompt wait, discards diff, and restores prompt without requiring emergency double Ctrl+C kill.

## Open Questions & Concurrency Concerns
- None. `gets_interactive` yields execution to the Crystal cooperative fiber scheduler during 50ms poll ticks, preserving high responsiveness to SIGINT without spinning or consuming excess CPU.

## 5. Revision History
* 2026-09-25: Created ticket following user bug report where pressing Ctrl+C at diff approval prompt hung without cancelling the turn.
* 2026-09-25: Implemented `gets_interactive` in `UI::Approval` and `tcflush` queue draining in `UI::Cancellation`. Added `spec/ui/approval_cancellation_spec.cr`. All tests passing. Ticket closed.
---
