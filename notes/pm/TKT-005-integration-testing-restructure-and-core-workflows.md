---
ID: TKT-005
Title: Restructure Integration Testing Suite and Implement Human-Readable Core Workflows
Status: In-Progress
Priority: High
---

## 1. User Need

As a developer undertaking a major refactoring of the NIGHTMARE codebase, I need a trustworthy, human-readable, and fast test suite. 

Currently, the existing test suite was authored almost entirely by autonomous codebots. While the unit tests are solid, the 122 end-to-end (E2E) specs are filled with deceptive "bot finagling"—including zero-assertion tests, tautologies testing the test runner itself, and hollow paper-tiger tests that only type `/exit`. Furthermore, tests are wrapped in an escape hatch (`require_repl!`) that silently converts failures into `pending!` when the binary fails to run.

I need the legacy E2E tests quarantined so they do not slow down or pollute daily development runs, and I need a lean, comprehensible integration test suite composed of genuine developer workflows that assert actual state and disk changes.

---

## 2. Specification

### 2.1 Problem Analysis & Audit Findings

An exhaustive audit of `/home/cam/repos/adjutant/nightmare/spec` revealed a stark dichotomy between the unit suite (Trust Score: **8.5/10**) and the E2E suite (Trust Score: **2.0/10**):

1. **Unit & In-Process Tests (`spec/*_spec.cr`)**:
   - Genuinely test the 19 core architectural invariants (`T1` through `T19` from `docs/ARCHITECTURE_R3.md §9`).
   - `spec/guard_spec.cr`: Hard adversarial path traversal fuzzing (`../`, `/etc/passwd`, sibling directory `root-evil`, out-of-tree symlinks, protected `.git` and `.nightmare` paths).
   - `spec/shedder_and_store_spec.cr`: Rigorously verifies struct write-back mechanics (`T3`), in-turn shedding preserving the last 2 tool outputs verbatim (`T4`), and byte-identical history immutability (`T2`).
   - `spec/harness_spec.cr`: Accurately tests loop detection (`T16`), cancellation rollback (`T12`), and 429 rate limit backoff.

2. **Legacy E2E Suite (`spec/e2e/tier*.cr`)**:
   - **Tautological Tests**: E.g., `tier1_feature_spec.cr:68-82` (`TC-T1-F02-01`) purports to test deterministic workspace ID generation, but never spawns Nightmare; it asserts against `sandbox.workspace_id` calculated purely inside `test_runner.cr`.
   - **Hollow / Paper-Tiger Tests**: E.g., `tier1_feature_spec.cr:42-51` (`TC-T1-F01-04`) claims to test subfolder navigation containment by writing a file with Crystal `File.write`, starting Nightmare, typing `/exit`, and asserting Crystal's written file still exists.
   - **Zero-Assertion Tests**: At least 12 tests across Tiers 1 and 2 execute complex interactions (such as user rejection with `[N]` in `TC-T1-F08-02`, inline edits with `[e]` in `TC-T1-F08-03`, prefix allowlist additions with `[p]` in `TC-T1-F08-05`, or `Ctrl+C` prompt restores in `TC-T2-SIG-03`) without a single `.should` assertion.
   - **Cosmetic Assertions**: E.g., `tier4_workload_spec.cr:156-173` (`TC-T4-WL-06`) tests token calibration by typing `/review` and checking if stdout contains `"tokens"`, never verifying if the divisor actually updated.
   - **Silent Skip Escape Hatch**: `test_runner.cr`'s `require_repl!` marks all 122 tests `pending!` if `bin/nightmare` does not respond to `/help` within 500ms, hiding complete binary breakage behind a green CI run.

3. **Metadata Obfuscation**:
   - Tests were named using an unreadable combinatorial matrix notation:
     `TC-T3-CB-01: [Pinned Files x read_file x Live Disk Re-read]`
   - `TC`: Test Case
   - `T1`–`T4`: Artificial tier taxonomy (Feature, Boundary, Combination, Workload)
   - `[A x B x C]`: Cartesian product notation from pairwise testing theory.
   - `Opaque-Box`: Jargon for black-box stdin/stdout subprocess pipe testing.

---

### 2.2 New Architectural Paradigm for Testing

The project will transition to a clear, two-tier model:

1. **Unit & Invariant Suite (`spec/*_spec.cr`)**:
   - Fast, in-memory, deterministic.
   - Uses `FakeClient < Mantle::Clients::Client` for scripted LLM responses with 0 network calls and 0 process spawns.
   - Runs in <3 seconds and serves as the primary TDD refactoring guardrail.

2. **Integration & Workflow Suite (`spec/integration/`)**:
   - Reuses the robust plumbing from `test_runner.cr` (`WorkspaceSandbox` for XDG isolation, `MockLlmServer` for HTTP-level `/api/chat` mocking, `ProcessSession` for subprocess pipe streaming).
   - Removes `require_repl!` silent skips; tests must fail explicitly when the binary is broken.
   - Focuses exclusively on **11 high-value, end-to-end developer workflows** described in human language with strict assertions on file mutations, exit statuses, and terminal output.

---

### 2.3 Comprehensive Core Integration Workflows (The 11 Scenarios)

The following 11 developer scenarios represent the authoritative integration contract to be implemented in `spec/integration/`:

1. **Workflow 1: Codebase Survey & Zero Repository Litter** *(Inspo: TC-T4-WL-01)*
   - *Flow*: REPL boots in a clean repo. Agent executes read-only tools (`list_files`, `file_info`, `search`) to inspect the project.
   - *Verification*: Tools execute autonomously without approval modals. Agent answers survey question. Workspace directory contains **zero** agent files, config, or logs. Centralized XDG paths house state.

2. **Workflow 2: File Mutation with Unified Diff Approval Modal** *(Inspo: TC-T1-F07-02, TC-T4-WL-02)*
   - *Flow*: Agent proposes modifying existing code via `replace_in_file`.
   - *Verification*: REPL suspends and renders unified color diff modal.
     - Submitting `N` (Reject): Target file remains byte-identical; agent receives rejection message and plans alternative.
     - Submitting `y` (Approve): Target file updates on disk with exact replacement.

3. **Workflow 3: Shell Execution, Allowlisting & Metacharacter Anti-Injection** *(Inspo: TC-T2-MC-01, TC-T4-WL-04)*
   - *Flow*: Agent proposes running shell commands.
   - *Verification*:
     - Approving with `p` adds binary prefix to workspace `allow` file.
     - Subsequent benign prefix calls (e.g. `git status -s`) run autonomously without prompt.
     - Commands containing shell metacharacters (`;`, `&&`, `||`, `|`, `$()`, backticks, redirects) **unconditionally force the modal** despite matching an allowlist prefix.

4. **Workflow 4: Hard Subprocess Timeout & Process Group Reap** *(Inspo: TC-T2-TO-01, TC-T2-TO-02)*
   - *Flow*: Agent executes a runaway command (e.g., `sleep 60` or nested shell subprocesses) with a short timeout.
   - *Verification*: Execution terminates via process group `SIGKILL` at the deadline. No orphaned child or grandchild processes remain. REPL reports timeout notice and remains responsive for subsequent commands.

5. **Workflow 5: Pinned Working Set & Live Disk Re-Read** *(Inspo: TC-T3-CB-01, TC-T3-CB-10)*
   - *Flow*: Operator pins a file using `/add src/app.cr`. Agent later calls `read_file` on `src/app.cr`. Operator then modifies `src/app.cr` externally on disk.
   - *Verification*: Agent's `read_file` immediately short-circuits with an `"already pinned"` notice. Prompt re-assembly (`/review`) reflects the external disk modification without needing to unpin and re-add.

6. **Workflow 6: Interactive Turn Interruption & Context Rollback on Ctrl+C** *(Inspo: TC-T2-SIG-01, TC-T4-WL-05)*
   - *Flow*: Operator sends `SIGINT` (Ctrl+C) while the agent is streaming an answer or running a multi-step tool loop.
   - *Verification*: In-flight generation aborts immediately. Uncommitted active turn is rolled back cleanly from RAM context without leaving orphaned tool call messages. REPL session remains alive and accepts the next instruction cleanly.

7. **Workflow 7: In-Turn Context Shedding vs. Pristine Transcript Export** *(Inspo: TC-T2-SH-05, TC-T3-CB-02)*
   - *Flow*: A complex multi-step turn produces extensive tool output exceeding context limits. Operator then executes `/save full_transcript.md`.
   - *Verification*: Within the active context window, consumed tool outputs are compressed to 200 characters with `[... output truncated: was ...]`, preserving only the last 2 verbatim. The exported Markdown transcript contains the **untruncated original output** preserved in pristine RAM.

8. **Workflow 8: System Prompt Precedence Hierarchy** *(Inspo: TC-T1-F05)*
   - *Flow*: Multiple prompt sources exist simultaneously (global XDG, workspace XDG, committed `.nightmare/prompt.md`, and `--prompt` CLI flag).
   - *Verification*: Resolution strictly adheres to precedence: CLI flag > repo override > workspace config > global config > default persona.

9. **Workflow 9: Tool Call Loop Detection & Breaker** *(Inspo: T16, TC-T3-CB-05)*
   - *Flow*: Model gets stuck in a hallucination loop, issuing identical `(tool, args)` 3 consecutive times.
   - *Verification*: `LoopDetector` intercepts the 3rd invocation without executing it, returning a forced failure message directing the model to change strategy.

10. **Workflow 10: Multi-Line Paste & Input Handling** *(Inspo: TC-T2-IN-03, TC-T2-IN-04)*
    - *Flow*: User submits multiline input via `/paste` or triple-quote `"""` blocks containing newlines and code blocks.
    - *Verification*: REPL buffers input without triggering premature execution on newlines until closing delimiter or blank line is provided.

11. **Workflow 11: Ghost Mode & Anti-Exfiltration Guarantee** *(Inspo: R7, ghost_mode_spec.cr)*
    - *Flow*: Nightmare started with `--no-logs`.
    - *Verification*: Operates purely in RAM. Writes 0 files to target workspace, and creates no files or directories in `$XDG_CONFIG_HOME`, `$XDG_STATE_HOME`, or `$XDG_CACHE_HOME`. All traces evaporate on exit.

---

## 3. Verification & Validation (V&V)

### 3.1 Verification Plan
1. **Quarantine Execution**:
   - Relocate `spec/e2e/tier*.cr` and `spec/e2e/test_runner_spec.cr` into `legacy_e2e/`.
   - Verify `crystal spec` runs only in-memory unit tests in <3 seconds without executing quarantined files.
2. **Infrastructure Extraction**:
   - Extract `WorkspaceSandbox`, `MockLlmServer`, and `ProcessSession` into `spec/support/integration_harness.cr`.
   - Remove `require_repl!` escape hatch so failures are loud.
3. **Workflow Incremental Implementation**:
   - Implement Phase 1 workflows (Workflows 1 & 2: Survey/Zero-Litter and Diff Approval Modal) in `spec/integration/workflows_spec.cr`.
   - Run `crystal spec spec/integration/workflows_spec.cr` and verify clean execution with full assertions.
   - Progressively implement Workflows 3 through 11 as the major refactor proceeds.

### 3.2 Verification Evidence
- **Phase 1 Complete (Commit `2c64d0f`)**:
  - `legacy_e2e/`: Quarantined all 122 legacy specs (`tier1_feature_spec.cr`, `tier2_boundary_spec.cr`, `tier3_combination_spec.cr`, `tier4_workload_spec.cr`, `test_runner_spec.cr`, `test_runner.cr`).
  - `spec/e2e/`: Completely removed from active spec tree.
  - `spec/support/integration_harness.cr`: Extracted reusable `WorkspaceSandbox`, `MockLlmServer`, and `ProcessSession` with strict failure reporting (eliminated silent `pending!` escape hatch).
  - `spec/integration/workflows_spec.cr`: Implemented Workflow 1 (Survey & Zero-Litter) and Workflow 2 (Mutation with Unified Diff Modal - approve and reject branches) with real assertions.
  - Test Execution Verification:
    ```bash
    $ crystal spec spec/integration/workflows_spec.cr
    Finished in 133.26 milliseconds
    3 examples, 0 failures, 0 errors, 0 pending

    $ crystal spec
    Finished in 1.86 seconds
    204 examples, 0 failures, 0 errors, 0 pending
    ```

### 3.3 Validation Plan
- Developer confirms the test suite runs quickly and predictably during local refactoring.
- Developer can easily read and diagnose any failure in `spec/integration/workflows_spec.cr` without translating metadata tags.

---

## 4. Remaining Open Work Items

### Phase 1: Quarantine & Foundation (Complete)
- [x] Quarantine legacy E2E suite to `legacy_e2e/` and eliminate `spec/e2e/`
- [x] Extract clean integration harness to `spec/support/integration_harness.cr` with loud failure reporting
- [x] Implement Workflow 1: Codebase Survey & Zero Repository Litter in `spec/integration/workflows_spec.cr`
- [x] Implement Workflow 2: File Mutation with Unified Diff Approval Modal (`[y]` and `[N]`)

### Phase 2: Core REPL & Execution Workflows (Open)
- [ ] Implement Workflow 3: Shell Execution, Allowlisting & Metacharacter Anti-Injection Boundary
- [ ] Implement Workflow 4: Hard Subprocess Timeout & Process Group Reap (kill runaway PGID, no zombie grandchildren)
- [ ] Implement Workflow 5: Pinned Working Set & Live Disk Re-Read (`/add` short-circuiting & prompt re-assembly on disk change)
- [ ] Implement Workflow 6: Interactive Turn Interruption & Context Rollback on `Ctrl+C` (`Signal::INT` clean abort)

### Phase 3: Advanced Subsystem Workflows (Open)
- [ ] Implement Workflow 7: In-Turn Context Shedding vs. Pristine Transcript Export (`/save` exports un-truncated RAM transcript)
- [ ] Implement Workflow 8: System Prompt Precedence Hierarchy (CLI flag > repo override > workspace config > global config > default persona)
- [ ] Implement Workflow 9: Tool Call Loop Detection & Breaker (interception after 3 identical calls)
- [ ] Implement Workflow 10: Multi-Line Paste & Input Handling (`/paste` and triple-quote blocks)
- [ ] Implement Workflow 11: Ghost Mode & Anti-Exfiltration Guarantee (`--no-logs` zero-disk-footprint validation)

### Phase 4: CI & Final Hardening (Open)
- [ ] Add integration suite target to project CI script / workflow
- [ ] Benchmark full test suite execution time under continuous refactoring (<5s goal)

---

## Open Questions & Concurrency Concerns
- **Subprocess Timing**: `ProcessSession` in `spec/support/` must use bounded poll intervals (10-25ms) and default 2-second timeouts to keep integration tests fast while preventing flakiness on CI.
- **PTY vs Pipes**: `ProcessSession` uses piped IO. Terminal-specific escape sequences (like ANSI cursor positioning) should be tested via unit tests on `Salamander::Terminal` rather than brittle pipe scraping in E2E.

---

## 5. Revision History
* 2026-09-17: Created ticket capturing problem analysis, skeptic audit findings, quarantine strategy, and full specification for the 11 core human-readable workflows.
* 2026-09-17: Phase 1 completed (quarantine legacy suite, extract harness, seed Workflows 1 & 2, verified full suite passing in 1.86s). Status set to `In-Progress`. Added Remaining Open Work Items checklist.
