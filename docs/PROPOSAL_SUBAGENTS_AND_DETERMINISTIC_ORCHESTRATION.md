# Programmatic Orchestration with Deterministic Gates & Subagent Execution

**Status:** Proposed (Revised - Second Pass)  
**Author:** Antigravity / Nightmare Team  
**Date:** 2026-09-11  
**Target:** `nightmare` and `mantle`  
**Related Tickets:** [TKT-004](../notes/pm/TKT-004-subagent-plan-orchestration.md)

---

## 1. Executive Summary & Hardware Reality

### 1.1 The Operational Bottleneck
When running local inference on sub-frontier models (e.g. ~24B–32B parameter models such as Mistral Small / Devstral 24B or Qwen 2.5 Coder 32B on workstation GPUs), the true constraint is **planning competence, long-horizon decomposition, and instruction-following degradation under delayed feedback**.

Stacking multiple tiers of LLM agents (Root $\rightarrow$ LLM Orchestrator $\rightarrow$ LLM Workers) compounds this weakness:
1. **Compounded Lossy Compression:** Every tier compresses state into prose.
2. **Hallucinated Completions:** A small LLM middle-manager has no ground-truth access; it accepts a subagent's prose summary at face value and falsely reports completion.
3. **Plan-Freezing:** Decomposing a complex refactor into a static sequence without a dynamic replanning protocol guarantees that early wrong assumptions cascade into wasted compute.

### 1.2 The Core Thesis
We replace the LLM orchestrator agent with a **programmatic orchestrator workflow**—a deterministic state machine in Crystal—that sequences single-tier (Depth 1) leaf workers, gates every transition on machine-verifiable signals (compiler exit codes, test set differences, non-empty diffs), and manages Git checkpointing and clean rollbacks.

**Core Invariant:** *The gate is the sole authority.* No plan item transition is ever determined by model-asserted prose or model-reported status. Ground-truth diffs and deterministic verification gates exclusively decide whether an item passes, fails, or retries.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               PROGRAMMATIC ORCHESTRATOR WORKFLOW (Crystal State Machine)               │
│                                                                                        │
│   Declarative Plan (Intent)                 Durable Run State (XDG)                    │
│   ┌───────────────────────────┐             ┌──────────────────────────┐               │
│   │ plan.yaml / plan.json     │             │ runs/<run_id>.json       │               │
│   │ - DAG dependencies       │             │ - Per-item attempt state │               │
│   │ - Files targeted          │             │ - Git base/result SHAs   │               │
│   │ - Verification contracts  │             │ - Ground-truth telemetry │               │
│   └─────────────┬─────────────┘             └────────────┬─────────────┘               │
│                 │                                        ▲                             │
│                 ▼                                        │                             │
│        1. Select ready item (DAG)                        │ 5. Record verified result   │
│                 │                                        │    or rollback worktree     │
│                 ▼                                        │                             │
│        2. Check Git Baseline & Managed Worktree          │                             │
│                 │                                        │                             │
│                 ▼                                        │                             │
│        3. Dispatch Leaf Worker (Depth = 1)               │                             │
│           - Scoped tools (Mantle::Step)                  │                             │
│           - Tool layer synthesizes touched files/cmds    │                             │
│                 │                                        │                             │
│                 ▼                                        │                             │
│        4. Deterministic Gate Evaluation ─────────────────┘                             │
│           - Monotonic test set & differential baseline                                 │
│           - Verification command / transaction group                                   │
│           - Diff & error thrash detection                                              │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Architecture & Data Contracts

### 2.1 Separation of Intent vs. Execution State

To maintain Nightmare's **Zero Repository Litter** tenet while enabling team collaboration and rerunability, we strictly decouple declarative intent from ephemeral run state:

1. **Declarative Plan (`plan.yaml` or `plan.json`):**
   - Human-authored or frontier-drafted, reviewable, diffable, opt-in committable to repo root or loaded from `$XDG_CONFIG_HOME`.
   - Defines goals, item DAG dependencies, target files/globs, and verification contracts.
   - May declare an optional `base_ref` (e.g. `"main"`), but never hardcodes a transient `base_sha`.
2. **Durable Run State (`runs/<run_id>.json`):**
   - Stored in `$XDG_STATE_HOME/nightmare/workspaces/<workspace_id>/runs/<run_id>.json`.
   - Records execution attempts, captured `base_sha`, item result SHAs, error histories, and ground-truth telemetry. Never committed to repo.
   - Locked via `flock` to prevent concurrent execution races.

#### Declarative Plan Schema (`plan.json` / `plan.yaml`):
```json
{
  "$schema": "https://nightmare.dev/schemas/plan-v1.json",
  "schema_version": "1.0.0",
  "id": "refactor-cli-args",
  "goal": "Refactor CLI argument parsing to support --headless flag and config override",
  "base_ref": "main",
  "setup_command": ["shards", "install"],
  "baseline_verification": {
    "command": ["crystal", "spec", "--junit_output", "build/spec_reports"],
    "parser": "junit",
    "expected_known_failures": ["CLI > legacy flag parsing"]
  },
  "max_run_duration_seconds": 14400,
  "max_total_tokens": 500000,
  "items": [
    {
      "id": "item-1",
      "title": "Map OptionParser structure in cli.cr",
      "profile_id": "researcher",
      "depends_on": [],
      "files_targeted": ["src/nightmare/cli.cr", "src/nightmare/commands/**"],
      "verification": {
        "kind": "none"
      }
    },
    {
      "id": "item-2",
      "title": "Add headless configuration option to Environment",
      "profile_id": "code_modifier",
      "depends_on": ["item-1"],
      "group_id": "cli-headless-txn",
      "files_targeted": ["src/nightmare/workspace/environment.cr"],
      "verification": {
        "kind": "compile",
        "command": ["crystal", "build", "--no-codegen", "src/nightmare.cr"]
      },
      "max_attempts": 3
    },
    {
      "id": "item-3",
      "title": "Wire --headless flag to CLI and add unit tests",
      "profile_id": "code_modifier",
      "depends_on": ["item-2"],
      "group_id": "cli-headless-txn",
      "files_targeted": ["src/nightmare/cli.cr", "spec/cli_spec.cr"],
      "verification": {
        "kind": "command",
        "command": ["crystal", "spec", "--junit_output", "build/spec_reports"],
        "parser": "junit",
        "expect": "no_new_failures",
        "allows_test_removal": false
      },
      "max_attempts": 3
    }
  ]
}
```

#### Durable Run State Schema (`runs/<run_id>.json`):
```json
{
  "run_id": "run-20260911-201500",
  "plan_id": "refactor-cli-args",
  "plan_schema_version": "1.0.0",
  "started_at": "2026-09-11T20:15:00Z",
  "updated_at": "2026-09-11T20:18:22Z",
  "status": "running",
  "base_sha": "a1b2c3d4e5f67890",
  "worktree_path": "/home/cam/.local/state/nightmare/workspaces/ws-abc/worktree",
  "baseline": {
    "total_tests": 124,
    "known_failing_tests": ["CLI > legacy flag parsing"]
  },
  "items": {
    "item-1": {
      "status": "completed",
      "attempts": 1,
      "base_sha": "a1b2c3d4e5f67890",
      "result_sha": "b2c3d4e5f6789012",
      "started_at": "2026-09-11T20:15:05Z",
      "finished_at": "2026-09-11T20:16:10Z",
      "tokens_used": 1420,
      "worker_self_reported_status": "completed",
      "summary": "OptionParser logic mapped to src/nightmare/commands/router.cr",
      "files_touched": [],
      "tool_calls_count": 4,
      "shell_commands": [],
      "proposed_items": [],
      "proposed_targets": []
    },
    "item-2": {
      "status": "in_progress",
      "attempts": 1,
      "base_sha": "b2c3d4e5f6789012",
      "result_sha": null,
      "started_at": "2026-09-11T20:16:15Z",
      "finished_at": null,
      "tokens_used": 3100,
      "worker_self_reported_status": "completed",
      "error_history": [
        "src/nightmare/cli.cr:40: undefined method 'headless?' for Nightmare::Workspace::Environment"
      ],
      "attempt_signatures": ["e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
    }
  },
  "groups": {
    "cli-headless-txn": {
      "status": "in_progress",
      "attempts": 1,
      "max_attempts": 2,
      "base_sha": "b2c3d4e5f6789012",
      "result_sha": null
    }
  }
}
```

---

## 3. Subagent Contract & Ground-Truth Telemetry

### 3.1 Subagent API Contracts
We restore the explicit data structures for subagent execution:

```crystal
module Nightmare::Harness
  enum SubagentStatus
    Completed
    Failed
    BudgetExhausted
    BlockedOnApproval
    Refused
  end

  record SubagentBudget,
    max_iterations : Int32 = 12,
    max_tokens : Int32 = 60_000,
    max_wall_clock_seconds : Int32 = 1800

  record ExecutedCommand,
    cmd : Array(String),
    exit_code : Int32,
    duration_ms : Int64

  record SubagentResult,
    status : SubagentStatus,
    summary : String,
    files_touched : Array(String),
    tool_calls_count : Int32,
    shell_commands : Array(ExecutedCommand),
    unresolved : Array(String),
    proposed_items : Array(NamedTuple(title: String, files_targeted: Array(String))),
    proposed_targets : Array(String),
    iterations : Int32,
    tokens_used : Int32
```

### 3.2 Synthesis at the Tool Layer (Zero Model Self-Reporting)
The subagent's prose completion is parsed solely for `summary`, `unresolved[]`, `proposed_items[]`, and `proposed_targets[]`. All factual telemetry is synthesized directly by the tool execution supervisor:
- **`files_touched`**: Captured by `Tools::Mutation` when `write_file` or `replace_in_file` mutates a file.
- **`shell_commands`**: Captured by `Tools::Shell` with exact argv, exit code, and millisecond duration.
- **`tool_calls_count`**: Maintained by the dispatcher.

### 3.3 Shedding Immunity
In Nightmare, active turn contexts undergo in-turn shedding and FIFO eviction. Subagent execution outputs are **immune to context shedding**:
- Upon subagent completion, the `SubagentResult` is written immediately to `$XDG_STATE_HOME/.../runs/<run_id>.json`.
- The parent orchestrator never keeps full multi-kilobyte subagent transcripts in memory; it references items by ID and loads telemetry on demand.

### 3.4 Target File Enforcement & Escape Valve
`files_targeted` supports globs (e.g. `src/nightmare/commands/**`) and new file creation.
- **Normalization Guard:** Prior to evaluating glob matches, all target paths are canonicalized via `File.expand_path` (or `File.realpath` for existing ancestors) relative to the workspace root. Relative paths containing `..` or leading slashes cannot bypass glob boundaries (e.g. `src/../spec/foo.cr` resolves cleanly to `spec/foo.cr` before matching `src/**`).
- If a worker attempts to touch a file outside `files_targeted`:
  - If the path matches the broader session `CapabilityGrant`: the write is **permitted**, logged, and appended to `proposed_targets[]`.
  - If the path violates the `CapabilityGrant`: the write is **refused immediately** with `[Refused: <path> is outside granted capability allowlist]`, and the item completes with `BlockedOnApproval`.

---

## 4. Git Worktree Isolation, Checkpoints & Rollback

### 4.1 Dedicated Worktree Environment
To protect the developer's primary working tree:
1. **Isolated Worktree Location:**
   The orchestrator provisions a dedicated git worktree under `$XDG_STATE_HOME/nightmare/workspaces/<workspace_id>/worktree`.
2. **Setup Command & Isolated Compiler Cache:**
   - Runs `setup_command` (e.g. `["shards", "install"]`) immediately upon worktree creation. If setup fails, the run aborts immediately.
   - **Isolated Crystal Cache:** To eliminate AST cache contention and lock fighting with concurrent manual builds in the primary checkout, all worktree executions export `CRYSTAL_CACHE_DIR=$XDG_STATE_HOME/nightmare/workspaces/<workspace_id>/cache`. No symlinks into `~/.cache/crystal`.
3. **Safety Assertion on `git clean`:**
   `git clean -fd` is asserted to execute *only* when cwd is verified to be the managed worktree, never the user's primary checkout.

### 4.2 Git Transaction Semantics
- **Clean Baseline Check:** At run start, HEAD is recorded as `base_sha`.
- **Pre-Attempt Hard Rollback:** Before each attempt, the worktree is restored to the item's `base_sha`:
  `git reset --hard <base_sha>` and `git clean -fd`.
  *Attempt 2 never inherits half-applied, broken edits from Attempt 1.*
- **Failure Patch Archival:** Before running `git reset --hard` on a failed attempt, the dirty diff is archived to `$XDG_STATE_HOME/.../runs/<run_id>/failures/<item_id>-attempt-<N>.patch` for post-mortem analysis.
- **Item Commit:** When an item passes its verification gate, changes are committed:
  `git commit -m "nightmare(plan): [#{item.id}] #{item.title}"`.
  The new commit hash becomes `result_sha`.

### 4.3 Transaction Groups (`group_id`)
When multi-step refactors require intermediate broken states:
- Group items declare a common `group_id` (e.g. `cli-headless-txn`).
- Per-item verification runs lightweight checks (`kind: compile` or `kind: diff_nonempty`).
- The primary regression suite runs at the **group boundary** after all items in the group succeed.
- If the group gate fails:
  1. The entire worktree rolls back to the group's `base_sha`.
  2. The group's `attempts` counter increments.
  3. If $\text{group\_attempts} \le 2$, group items re-run in sequence with the group failure injected into their context.
  4. If group retries are exhausted, the group and its items are parked as `PlanItemStatus::NeedsReview`.

---

## 5. Granular Verification & Anti-Tampering Gates

### 5.1 Test-Set Monotonicity (Anti-Tampering Rail)
Local models frequently satisfy gates by deleting or commenting out failing tests.
1. **Baseline Identity Capture:**
   During pre-flight baseline execution, the orchestrator parses the **complete set of all test descriptions** using machine-readable test outputs (e.g. JUnit XML or TAP via a pluggable `VerificationParser` interface).
2. **Monotonicity Enforcement:**
   During gate evaluation, if any previously existing test description disappears:
   - If the item declares `allows_test_removal: true`: permitted.
   - Otherwise: **hard gate failure** (`[Gate Failure: 2 tests were deleted or renamed without authorization]`).
3. **Author vs. Grader Separation:**
   The plan linter checks whether an item targets both an implementation file and its spec file while using `expect: "no_new_failures"`. The linter warns and suggests splitting into:
   - Step A: Author failing spec (`expect: "new_failure_present"`).
   - Step B: Implement fix (`files_targeted` strictly excludes spec file; `expect: "no_new_failures"`).

### 5.2 Description-Path Baseline Identities (No File:Line Keys)
Tests are identified strictly by nested descriptive paths:
`"Nightmare::CLI > --headless flag > disables terminal spinner"`
Line numbers (`spec/cli_spec.cr:45`) are never used as keys, ensuring that edits and line shifts in target files do not invalidate baseline failure mappings.

### 5.3 Differential Gating Formula
$$\text{New Failures} = \text{Current Failures} \setminus \text{Baseline Known Failures}$$
If $\text{New Failures} = \emptyset$ and test set is monotonic, the gate **passes**.

---

## 6. Authoritative State Machine & Graph Scheduling

### 6.1 The Gate is the Sole Authority
The model's self-reported status (`SubagentStatus`) is demoted to advisory telemetry. The transition is determined strictly by ground truth:

```crystal
enum PlanItemStatus
  Pending
  Running
  Completed
  Failed
  Blocked
  Skipped
  NeedsReview
end
```

```
if diff.empty?
  -> Item marked Failed (no work product; skips gate)
else
  run verification gate
  if gate passed:
    -> Item marked Completed (commit git result_sha)
  else:
    archive patch -> rollback to base_sha
    if attempts < max_attempts and not thrashed:
      -> retry item
    else:
      -> Item marked Failed
```

*Exception:* If the runner returns `BlockedOnApproval`, the item is marked `Blocked` immediately (without running the gate or burning retries), because retrying without operator approval is futile.

### 6.2 Thrash Detection
Before executing Attempt $N+1$, the orchestrator computes:
$$\text{Signature} = \text{SHA256}(\text{diff} \parallel \text{"\0"} \parallel \text{normalize}(\text{error}))$$
`normalize(error)` strips ANSI escapes, execution durations, memory addresses, and absolute path prefixes, and sorts multi-line compiler errors.
- If $\text{Signature}$ matches any previous attempt for this item, execution aborts immediately with `PlanItemStatus::Failed` to prevent looping compute burn. Two consecutive empty-diff attempts trip this immediately.

### 6.3 DAG Dependency & Failure Propagation
- **Topological Walker:** Evaluates items whose `depends_on` entries are all `Completed`.
- **Transitive Failure:** If an item ends `Failed`, all transitive downstream dependents are marked `PlanItemStatus::Skipped`.
- **Blocked Propagation:** If an item ends `Blocked`, downstream dependents transition to `PlanItemStatus::Blocked`. Independent subgraphs continue execution.
- **Terminal Run Status:**
  - `Completed`: All items `Completed`.
  - `Partial`: Some items `Completed`, others `Blocked` or `NeedsReview`.
  - `Failed`: Critical path item `Failed` and dependencies `Skipped`.

---

## 7. Security Threat Model & Scoped Tool Allowlisting

### 7.1 Realistic Threat Model
Capability grants are **guardrails against model mistake and runaway execution**, not a hardened sandbox against arbitrary malicious code execution. Running test suites (`crystal spec`) allows arbitrary subprocess execution. Untrusted codebases require OS-level containerization (e.g. bubblewrap/Docker), which is out of scope for v1.

### 7.2 Tool & Subcommand Allowlisting
- **No Direct Git Mutations by Subagents:** Subagents have zero access to git write tools. Subagents cannot run `git commit`, `git checkout`, `git restore`, `git apply`, or `git push`. The orchestrator exclusively owns git commits and resets.
- **Read-Only Subcommands:** `run_command` allows only inspection subcommands: `git status`, `git diff`, `git rev-parse`, `git log`.
- **Disabled Git Hooks:** All orchestrator git commands run with `-c core.hooksPath=/dev/null`.
- **Compiler Restrictions:** Disallow `crystal eval` and `crystal run`. Allow only `crystal spec` and `crystal build`.
- **Argv Only:** Commands are tokenized into argv arrays. Shell metacharacters (`;`, `&`, `|`, `` ` ``, `$`, `>`, `<`) are rejected.

---

## 8. Hardware Pacing, GPU Thermal Rails & Global Budgets

### 8.1 Pacing Defaults & Thermal Rail
- `inter_item_pacing_seconds`: 3.0s (allows GPU power states to downclock to idle, dissipating VRM heat).
- `inter_turn_pacing_seconds`: 0.5s.
- **Thermal Tripwire & Polling Decoupling:** Queries `nvidia-smi` / `rocm-smi` / sysfs. To avoid process fork overhead, thermal queries are decoupled from the 0.5s micro-turn loop and throttled to run **strictly at item boundaries** or at a maximum frequency of once every 20 seconds. If GPU $> 80^\circ\text{C}$, execution pauses until temp drops $< 70^\circ\text{C}$.
- **Modes:** `/mode sprint` (0s), `/mode pace [sec]` (default 3s), `/mode step` (interactive Enter confirmation).

### 8.2 Global Run Ceilings
- `max_run_duration_seconds`: 14,400s (4 hours).
- `max_total_tokens`: 500,000 tokens.
- On ceiling trip: cleanly park all in-flight work, write the morning-after report, and exit without corrupting git state.

---

## 9. Evaluation Framework & Benchmark Harness (WP0)

To validate the architecture against empirical local-model baselines:
- **Suite:** 3 golden tasks (CLI option refactor, error reporting bugfix, parser unit test expansion).
- **Protocol:** $n \ge 5$ runs per task on local Mistral Small / Devstral 24B and Qwen 2.5 Coder 32B.
- **Target Thresholds:**
  - $\ge 70\%$ item completion without human intervention.
  - $\le 5\%$ false-green rate (verified by human diff inspection against §5.1 anti-tampering).
  - $0$ unhandled worktree corruptions across all runs.

---

## 10. Vertical-Slice Milestone Roadmap (WBS)

### Milestone 0: Evaluation Harness & Benchmarks (WP0)
- Curate 3 golden benchmark repositories and tasks.
- Build automated scoring script recording completion rate, false-green rate, and token spend.

### Milestone 1: Thesis Validation & Core State Machine (WP1)
- Implement `Nightmare::Plan` and `Nightmare::PlanRun` data models.
- Implement file locking (`flock`) on run state.
- Implement dedicated worktree provisioning with `setup_command` and shared cache.
- Implement Git checkpointing, failed diff archival, and pre-attempt rollback.
- Implement JUnit/TAP baseline parser, test-set monotonicity check, and differential gating.
- Run 3-item plan using a stubbed runner to verify zero-hallucination state transitions.

### Milestone 2: Generalized Subagent Runner & Tool Telemetry (WP2)
- Remove `args["depth"]` from `Mantle::Subagents::Runner`; enforce runtime depth tracking.
- Build `Nightmare::Harness::SubagentRunner` with tool-layer ground-truth telemetry synthesis (`files_touched`, `shell_commands`).
- Implement `files_targeted` glob validation and `proposed_targets[]` auto-acceptance.
- Implement diff and normalized error thrash detection.

### Milestone 3: Profiles, Capability Grants & Pacing (WP3)
- Extend `Mantle::Subagents::Profile` with client bindings (`model_name`, `api_url`).
- Implement `CapabilityGrant` evaluation and `BlockedOnApproval` park semantics.
- Implement cadence pacing delays and GPU thermal rail monitoring.

### Milestone 4: Plan Linter, Replanning & REPL Reporting (WP4)
- Implement plan linter (DAG cycle checks, author/grader spec separation warnings).
- Implement `proposed_items` review queue.
- Implement `/plan` slash command family and `/plan report` morning-after summary.
