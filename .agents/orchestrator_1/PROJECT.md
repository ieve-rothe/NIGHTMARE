# Project: NIGHTMARE REPL

## Architecture
NIGHTMARE is structured as a decoupled, modular Crystal application linking local frameworks `mantle` and `salamander`.

```
                    ┌─────────────────────────┐
                    │      Nightmare::CLI     │
                    │   (REPL / Slash Router) │
                    └────────────┬────────────┘
                                 │
           ┌─────────────────────┼─────────────────────┐
           ▼                     ▼                     ▼
┌────────────────────┐ ┌────────────────────┐ ┌────────────────────┐
│Nightmare::Workspace│ │ Nightmare::Context │ │  Nightmare::Tools  │
│  - Realpath Root   │ │  - Atomic Turns    │ │  - Read-Only Obs.  │
│  - Central XDG     │ │  - In-Turn Shedding│ │  - Safe Mutations  │
│  - Directives Res. │ │  - Token Estimator │ │  - Subprocess Exec │
│  - Zero Repo Litter│ │  - RAM Transcript  │ │  - Approval Modal  │
└────────────────────┘ └─────────┬──────────┘ └─────────┬──────────┘
                                 │                      │
                                 ▼                      ▼
                    ┌─────────────────────────────────────────┐
                    │            Nightmare::Harness           │
                    │       - Result(T) Sum Type Boundary     │
                    │       - Mantle::Step Orchestrator       │
                    │       - Backoff & Format Recovery       │
                    └────────────────────┬────────────────────┘
                                         │
                                         ▼
                    ┌─────────────────────────────────────────┐
                    │              Nightmare::UI              │
                    │       - Salamander Token Streaming      │
                    │       - <think> Tag Isolation           │
                    │       - ANSI Markdown & Spinners        │
                    │       - Signal Trapping (Ctrl+C)        │
                    └─────────────────────────────────────────┘
```

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | F1.1 Canonical Root Anchor | Immutably bind `@root = File.realpath(Dir.current)`, enforce containment | M1 | R1 |
| 2 | F1.2 Path Traversal & Symlink Check | Reject `../` traversals and external symlinks with SecurityError | M1 | R1 |
| 3 | F1.3 Deterministic Workspace ID | Compute `<slug>-<hash>` (basename sanitized + SHA256 8 hex chars) | M1 | R1 |
| 4 | F1.4 Central XDG Hierarchy | Map configs/state/cache to central XDG partitioned by workspace ID | M1 | R1 |
| 5 | F1.5 Zero Repo Litter | Ensure no logs or configs are written inside the target repo | M1 | R1 |
| 6 | F1.6 Directives Precedence | Resolve CLI > repo override > workspace > global > default persona | M1 | R1 |
| 7 | F1.7 Startup Box Banner | Display bordered banner with root, config path, and state path | M1 | R1 |
| 8 | F1.8 In-Memory Directive Edit | `/prompt edit` mutates memory directive only; disk remains untouched | M1 | R1 |
| 9 | F2.1 Ephemeral Context Store | Store turns purely in RAM; no disk persistence of sessions | M2 | R2 |
| 10 | F2.2 Atomic Turn Units | Turn = User Message + Tool Exchanges + Assistant Message | M2 | R2 |
| 11 | F2.3 Atomic Turn Pruning | Evict whole turns; never orphan tool call/result pairs or active turn | M2 | R2 |
| 12 | F2.4 In-Turn Tool Shedding | Compress older tool outputs at 85% limit, keep last 2 verbatim | M2 | R2 |
| 13 | F2.5 Token Calibrator | Self-calibrating token estimator using 0.8/0.2 smoothed provider usage | M2 | R2 |
| 14 | F2.6 RAM Transcript & /save | Parallel unpruned transcript preserved in RAM for `/save` export | M2 | R2 |
| 15 | F2.7 Pinned Files | Budget-capped (60%) live-reread pinned files with redundancy short-circuit | M2 | R2 |
| 16 | F3.1 Read-Only Obs Tools | `list_files`, `search`, `read_file`, `file_info` autonomous execution | M3 | R3 |
| 17 | F3.2 Safe Mutation Tools | `write_file`, `replace_in_file`, `append_to_file` with unified diffs | M3 | R3 |
| 18 | F3.3 Auto-Approve New Files | Mutation tools auto-approve new files; require prompt for existing | M3 | R3 |
| 19 | F3.4 Strict .git/ Protection | Mutation tools unconditionally reject any write targeting `.git/` | M3 | R3 |
| 20 | F3.5 Remote Model Delegation | `ask_model` tool for stateless sub-queries | M3 | R3 |
| 21 | F3.6 Subprocess Isolation | `run_command` with pgid isolation, closed stdin, CI=1, timeout cap 600s | M3 | R3 |
| 22 | F3.7 Command Approval Modal | Interactive approval modal (`[y]`, `[N]`, `[e]`, `[a]`, `[p]`) | M3 | R3 |
| 23 | F3.8 Shell Metacharacter Ban | Strict ban on auto-approving commands containing shell metacharacters | M3 | R3 |
| 24 | F4.1 Result Sum Types | Define `Result(T) = Success(T) | Failure` with typed error models | M4 | R4 |
| 25 | F4.2 Mantle Step Harness | Wrap `Mantle::Step` with clean message feeding and error mapping | M4 | R4 |
| 26 | F4.3 Rate Limit Backoff | Exponential backoff with jitter on `RateLimited` errors | M4 | R4 |
| 27 | F4.4 Format Correction Retry | Single format-correction retry turn on malformed payloads | M4 | R4 |
| 28 | F5.1 Token Streaming | Live streaming output through `Salamander::ChatSession` | M5 | R5 |
| 29 | F5.2 Thinking Tag Isolation | Parse and isolate `<think>` blocks into internal thinking log | M5 | R5 |
| 30 | F5.3 Braille Spinner | Spin while processing LLM turns (`Salamander::UI#spin_while`) | M5 | R5 |
| 31 | F5.4 ANSI Markdown Rendering | Render assistant responses with `Salamander::UI::MarkdownFormatter` | M5 | R5 |
| 32 | F5.5 Signal Handling (Ctrl+C) | Trap `SIGINT`: abort step, kill subprocess, rollback active turn | M5 | R5 |
| 33 | F5.6 Slash Command Router | Implement `/clear`, `/cls`, `/drop`, `/save`, `/prompt`, etc. | M5 | R5 |
| 34 | F6.1 Shards Linkage | Configure `shard.yml` with path dependencies for local frameworks | M1 | R6 |
| 35 | F6.2 Zero Warning Compilation| Clean `shards build` with 0 warnings or errors | M6 | AC |
| 36 | F6.3 100% Spec Pass | Complete test coverage passing across all modules | M6 | AC |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Workspace Anchoring & Central XDG | F1.1-F1.8, F6.1: Shards linking, Root anchor, path safety, XDG layout, directives | none | DONE |
| M2 | Ephemeral Context & Pruning Engine | F2.1-F2.7: Atomic turns, sliding window pruning, in-turn shedding, calibrator | M1 | PLANNED |
| M3 | Sandboxed Tool Suite & Approval | F3.1-F3.8: Read-only, mutation, diffs, approval modal, metacharacter ban | M1 | PLANNED |
| M4 | Mantle Step Harness & Sum Types | F4.1-F4.4: Result(T) sum types, Mantle step integration, retries, backoff | M2, M3 | PLANNED |
| M5 | Salamander REPL, UI & Signals | F5.1-F5.6: REPL loop, streaming, thinking isolation, slash commands, Ctrl+C | M1-M4 | PLANNED |
| M6 | Final Milestone: E2E Verification & Adversarial Coverage Hardening | F6.2, F6.3: Pass 100% E2E test suite (Tiers 1-4) + Tier 5 adversarial hardening | M1-M5, E2E | PLANNED |

## Interface Contracts

### Nightmare::Workspace ↔ Nightmare::Directives
```crystal
module Nightmare::Workspace
  class Environment
    getter root : String
    getter workspace_id : String
    getter config_dir : String
    getter state_dir : String
    getter cache_dir : String
    getter allowlist_path : String
    getter log_path : String

    def self.resolve(current_dir : String = Dir.current) : Environment
    def sanitize_path(path : String) : String # raises SecurityError on traversal
    def inside_root?(path : String) : Bool
    def startup_banner : String
  end
end

module Nightmare::Directives
  class Resolver
    def self.resolve(env : Workspace::Environment, cli_override : String? = nil) : String
  end
end
```

### Nightmare::Context ↔ Nightmare::Harness
```crystal
module Nightmare::Context
  class SlidingStore
    getter turns : Array(Turn)
    getter token_calibrator : TokenCalibrator

    def initialize(@token_hardmax : Int32 = 100_000)
    def add_user_message(text : String) : Turn
    def record_tool_exchange(call_id : String, name : String, args : Hash(String, JSON::Any), output : String) : Nil
    def record_assistant_message(text : String) : Nil
    def rollback_active_turn : Turn?
    def prune_sliding_window : Nil
    def shed_in_turn_tools : Nil
    def assemble_mantle_messages(system_directive : String) : Array(Mantle::Message)
  end

  class Transcript
    def self.record(turn : Turn) : Nil
    def self.save_to(path : String) : Int32 # exports unpruned transcript
  end
end
```

### Nightmare::Tools ↔ Nightmare::Harness
```crystal
module Nightmare::Tools
  abstract class BaseTool
    abstract def name : String
    abstract def description : String
    abstract def schema : Mantle::Tools::FunctionDefinition
    abstract def execute(args : Hash(String, JSON::Any), context : ExecutionContext) : ToolResult
  end

  class Registry
    def self.default_suite(env : Workspace::Environment, approval_boundary : ApprovalBoundary) : Array(BaseTool)
    def self.to_mantle_tools(tools : Array(BaseTool)) : Array(Mantle::Tools::Tool)
  end

  class ApprovalBoundary
    def evaluate(tool : BaseTool, args : Hash(String, JSON::Any)) : ApprovalDecision
    def metacharacters?(cmd : String) : Bool
  end
end
```

### Nightmare::Harness ↔ Nightmare::UI
```crystal
module Nightmare::Harness
  struct Success(T)
    getter value : T
    def initialize(@value : T); end
  end

  struct Failure
    getter kind : StepErrorKind
    getter message : String
    def initialize(@kind : StepErrorKind, @message : String); end
  end

  alias Result(T) = Success(T) | Failure

  class StepRunner
    def execute_turn(messages : Array(Mantle::Message), &block : String -> Nil) : Result(String)
  end
end
```

## Code Layout
```
nightmare/
├── shard.yml
├── src/
│   ├── nightmare.cr                    # Entry point & CLI option parser
│   └── nightmare/
│       ├── workspace/
│       │   ├── environment.cr          # Canonical root, slug/hash, XDG paths
│       │   └── manifest.cr             # Workspace JSON manifest & logging
│       ├── directives/
│       │   └── resolver.cr             # Hierarchy resolution & in-memory prompt
│       ├── context/
│       │   ├── models.cr               # Turn, ToolExchange, PinnedFile
│       │   ├── calibrator.cr           # 0.8/0.2 token estimator
│       │   ├── sliding_store.cr        # Sliding window & in-turn tool shedding
│       │   └── transcript.cr           # Pristine RAM transcript & /save export
│       ├── tools/
│       │   ├── base.cr                 # BaseTool, ExecutionContext, ToolResult
│       │   ├── approval.cr             # Approval boundary & metacharacter filter
│       │   ├── observation.cr          # list_files, search, read_file, file_info
│       │   ├── mutation.cr             # write_file, replace_in_file, append_to_file
│       │   ├── model.cr                # ask_model delegation
│       │   ├── shell.cr                # run_command with pgid isolation & timeout
│       │   └── registry.cr             # Adapter to Mantle::Tools::Tool
│       ├── harness/
│       │   ├── result.cr               # Success(T) | Failure sum types
│       │   ├── errors.cr               # StepErrorKind
│       │   └── runner.cr               # Mantle::Step runner, retries, backoff
│       ├── ui/
│       │   ├── terminal.cr             # Formatting, dimensions, colors
│       │   ├── spinner.cr              # Salamander spinner integration
│       │   └── signals.cr              # Ctrl+C signal trapping & turn rollback
│       └── commands/
│           └── router.cr               # Slash command dispatch (/clear, /save, etc.)
└── spec/
    ├── spec_helper.cr
    ├── workspace_spec.cr
    ├── directives_spec.cr
    ├── context_spec.cr
    ├── tools_spec.cr
    ├── harness_spec.cr
    ├── ui_spec.cr
    └── e2e/
        ├── test_runner.cr
        ├── tier1_feature_spec.cr
        ├── tier2_boundary_spec.cr
        ├── tier3_combination_spec.cr
        └── tier4_workload_spec.cr
```
