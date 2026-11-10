---
ID: TKT-038
Title: Live Harness Tool Availability, Cascade Quotas, and Session Token Caps
Status: Resolved
Priority: High
---

## 1. User Need
During interactive sessions in Nightmare, operators need fine-grained, live governance over the agent's harness tool capabilities and token consumption without terminating or restarting the REPL session.

Currently:
1. **Static Tool Availability**: The harness tools (`list_files`, `search`, `read_file`, `file_info`, `write_file`, `replace_in_file`, `append_to_file`, `run_command`, `spawn_subagent`, `web_search`) are constructed once at startup in `REPL#initialize` and statically passed into `StepRunner`. There is no mechanism to disable, enable, or constrain tools live during an active session (e.g., locking an agent into read-only mode during an architecture review, or preventing expensive subagent spawning or external web searches).
2. **Missing Tool Quotas & The Fallback Sidechannel Problem ("Sneak-Around")**:
   - Operators cannot set quotas on tool usage (e.g. allowing at most 5 file reads before the read capability is stripped).
   - Crucially, if an agent is denied `read_file` (or exhausts its read quota), modern LLMs immediately seek fallback sidechannels—specifically invoking `run_command` (shell/bash) to run `cat`, `head`, `tail`, `sed`, `less`, or `python` to inspect files.
   - Without linked or cascading tool revocation (e.g., revoking `read_file` must simultaneously revoke `run_command` or restrict shell file reading), single-tool restrictions are ineffective against agent circumvention.
3. **No Session-Level Token Budget**: While Nightmare supports a per-turn token spend cap (`turn_spend_cap_tokens`) and a sliding-window context limit (`token_hardmax`), there is no session-wide token budget. An operator running multiple turns or letting an autonomous loop run cannot define a hard cap on total session tokens (eval + prompt) to prevent runaway costs or model drift.
4. **Lack of Live Visibility**: Operators have no slash command to inspect active tool availability, call counts, quota limits, or cumulative session token metrics.

Operators need intuitive slash commands to configure tool availability live, enforce tool usage quotas with cascade sidechannel revocation, set session-wide token caps, and inspect resource governance in real time.

---

## 2. Specification

### 2.1 Tool Policy Architecture (`src/nightmare/tools/policy.cr`)
Introduce a dedicated `Nightmare::Tools::Policy` manager held by `REPL` and accessible via `Commands::Router` and `StepRunner`:

```crystal
module Nightmare::Tools
  enum QuotaScope
    Turn
    Session
  end

  struct Quota
    property limit : Int32
    property used : Int32 = 0
    property scope : QuotaScope
    property cascade_revocations : Set(String) = Set(String).new

    def initialize(@limit : Int32, @scope : QuotaScope = QuotaScope::Turn, cascade : Array(String) = [] of String)
      @cascade_revocations = cascade.to_set
    end

    def remaining : Int32
      {@limit - @used, 0}.max
    end

    def exhausted? : Bool
      @used >= @limit
    end
  end

  class Policy
    getter disabled_tools : Set(String) = Set(String).new
    getter quotas : Hash(String, Quota) = Hash(String, Quota).new
    getter turn_calls : Hash(String, Int32) = Hash(String, Int32).new(0)
    getter session_calls : Hash(String, Int32) = Hash(String, Int32).new(0)

    # Tool groups / aliases for ergonomics
    GROUPS = {
      "read"     => Set{"read_file", "search", "list_files", "file_info"},
      "write"    => Set{"write_file", "replace_in_file", "append_to_file"},
      "mutation" => Set{"write_file", "replace_in_file", "append_to_file"},
      "shell"    => Set{"run_command"},
      "subagent" => Set{"spawn_subagent"},
      "web"      => Set{"web_search"},
    }

    # Checks if a tool can currently execute
    def allowed?(tool_name : String) : Tuple(Bool, String?)

    # Records an execution, increments counters, and checks quota
    # If quota exhausts, automatically adds cascade revocations to disabled_tools
    def record_call(tool_name : String) : Tuple(Bool, String?)

    # Turn lifecycle reset
    def reset_turn : Nil
  end
end
```

#### Key Capabilities:
- **Direct Disabling/Enabling**: Individual tools (or groups like `write`, `shell`, `subagent`) can be toggled on/off at any time.
- **Quota Tracking with Cascade Revocation**:
  When a tool with an active quota breaches its limit:
  1. The tool itself is marked as disabled for the remainder of its scope (turn or session).
  2. Any configured `cascade_revocations` are immediately triggered (e.g., reaching `read_file` quota automatically revokes `run_command` to block shell fallback reading).
  3. The active tool call is refused with a structured, model-readable error message:
     `"[ToolQuotaExceeded: 'read_file' quota of 5 reached. 'read_file' and linked tool 'run_command' have been disabled.]"`
- **Presets / Profiles**:
  - `read-only`: Disables all mutation tools and `run_command`.
  - `locked-down`: Disables `run_command`, `spawn_subagent`, and `web_search`.
  - `no-shell`: Disables `run_command` only.
  - `default`: Restores all registered tools and resets quotas.

### 2.2 Dynamic Schema Presentation in StepRunner (`src/nightmare/harness/step_runner.cr`)
- Modify `StepRunner` to filter tools dynamically on each turn and each iteration:
  ```crystal
  active_tools = @all_tools.reject { |t| @policy.disabled?(t.function.name) }
  ```
- **Schema-Level Suppression**: Disabled tools are omitted from the LLM client schema payload entirely so the model is not prompted with unavailable tools.
- **In-Turn Fallback Interception**: If an agent hallucinations-invokes a disabled tool mid-turn, `Mantle::Step` or `ToolPolicyMiddleware` intercepts the invocation and returns an informative refusal without crashing.

### 2.3 Session Token Budgeting and Hardmax Context Override (`src/nightmare/context/session_budget.cr` & `Mantle::Storage::SlidingStore`)
In addition to cumulative session token tracking, operators need the ability to configure a live **session override for the token hardmax** (sliding context window cap).
- **Session Token Hardmax Override**:
  - `SlidingStore#hardmax` is upgraded from `getter` to `property`.
  - Via `/tokens hardmax <N>` (or `/tokens max <N>`), the operator can set a session override for the context hardmax (e.g. from 12,000 to 7,000).
  - **Next-Turn Dynamic Pruning**:
    If current context tokens exceed the new session hardmax (e.g., context is currently 8,000 tokens and the hardmax is reduced to 7,000), `SlidingStore#prune_to_hardmax!` runs at the start of the next turn prior to message assembly. It invokes `Shedder.prune_history!` to shed older tool exchanges and FIFO-evict older completed turns until estimated tokens fit strictly beneath the session hardmax.
  - `/tokens hardmax default` (or `reset`): Restores the workspace's configured `token_hardmax`.

```crystal
module Mantle::Storage
  class SlidingStore
    property hardmax : Int32

    # Prunes historical turns until total estimated tokens fall within @hardmax
    def prune_to_hardmax!(calibrator : TokenEstimator, system_prompt : String? = nil, pinned_block : String? = nil, skill_block : String? = nil) : Int32
      estimated = total_estimated_tokens(calibrator, system_prompt, pinned_block, skill_block)
      if estimated > @hardmax
        Shedder.prune_history!(@history, estimated, @hardmax, calibrator: calibrator)
      else
        estimated
      end
    end
  end
end
```

Introduce `Nightmare::Context::SessionBudget` managed in `REPL`:

```crystal
module Nightmare::Context
  class SessionBudget
    getter session_prompt_tokens : Int64 = 0_i64
    getter session_eval_tokens : Int64 = 0_i64
    property session_token_cap : Int64? = nil
    property warning_threshold_percent : Int32 = 80
    getter? warning_emitted : Bool = false

    def total_tokens : Int64
      @session_prompt_tokens + @session_eval_tokens
    end

    def remaining_tokens : Int64?
      if cap = @session_token_cap
        {cap - total_tokens, 0_i64}.max
      end
    end

    def cap_exceeded? : Bool
      if cap = @session_token_cap
        total_tokens >= cap
      else
        false
      end
    end

    def record_turn(prompt_tokens : Int32?, eval_tokens : Int32?) : Nil
    def reset : Nil
  end
end
```

#### Enforcement:
1. **Pre-Turn Gate**: Before executing a turn in `REPL#execute_turn`, if `session_budget.cap_exceeded?`, Nightmare halts and alerts the user:
   `"⚠️ Session token cap reached (Total: #{total} / Cap: #{cap}). Increase cap with /tokens cap <limit> or reset with /tokens reset."`
2. **Context Pruning Gate**: In `REPL#execute_turn`, before calling `step_runner.run_turn`, invokes `@store.prune_to_hardmax!(@calibrator, ...)` to ensure context conforms to any live `hardmax` override.
3. **In-Turn Iteration Tripwire**: In `ToolLoop#handle_iteration`, if cumulative session tokens breach `session_token_cap`, raises `SessionSpendCapExceededException`, terminating the tool loop cleanly.
4. **Proactive Warnings**: At 80% and 90% consumption of the session cap, output a non-blocking advisory banner before model turns.

---

### 2.4 User Interface Approaches & Generated Options

We evaluated three UI paradigms for slash command ergonomics:

#### Option A: Dedicated Domain Commands (`/tools` and `/tokens`) — [RECOMMENDED]
Separates tool governance from token accounting into two high-signal, self-documenting commands that match existing CLI conventions (`/model`, `/theme`, `/plan`).

##### 1. Tool Governance (`/tools`)
* `/tools` or `/tools status`:
  Renders a visual dashboard of all 10 tools, their current state, call counts, quotas, and cascade links:
  ```text
  === Tool Governance & Availability ===
  Preset: custom (workspace default: full)

  Tool                 Status     Turn Calls   Session Calls   Quota / Cascade Link
  ──────────────────────────────────────────────────────────────────────────────────
  read_file            ENABLED    3            12              Max 5/turn → Cascade: run_command
  run_command          ENABLED    1            4               Linked to read_file
  list_files           ENABLED    2            8               -
  search               ENABLED    0            2               -
  file_info            ENABLED    0            1               -
  write_file           ENABLED    0            1               -
  replace_in_file      ENABLED    1            3               -
  append_to_file       ENABLED    0            0               -
  spawn_subagent       DISABLED   0            0               Disabled by user
  web_search           DISABLED   0            0               Disabled by user
  ```
* `/tools off <tool... | group...>` (or `/tools disable`):
  - Example: `/tools off spawn_subagent web_search`
  - Example: `/tools off shell`
  - Example: `/tools off mutation`
* `/tools on <tool... | group...>` (or `/tools enable`):
  - Example: `/tools on run_command`
* `/tools limit <tool> <N> [--scope turn|session] [--cascade <other_tool>]`:
  - Configures an automatic quota and optional fallback cascade.
  - Example: `/tools limit read_file 5 --cascade run_command`
  - Example: `/tools limit spawn_subagent 2 --scope session`
* `/tools preset <read-only | locked-down | no-shell | default>`:
  - Quickly activates curated security stances.
* `/tools reset`:
  - Re-enables all tools, clears quotas and cascade links, and resets turn/session tool call counts.

##### 2. Session Token Budgeting and Hardmax (`/tokens` or `/budget`)
* `/tokens` or `/tokens status`:
  Displays comprehensive token metrics, context estimation divisor, current hardmax, and session budget progress:
  ```text
  === Session Token Budget & Context Window ===
  Active Context Tokens:  5,420 / 7,000 (Session Hardmax Override)
  Configured Default:    12,000 tokens
  Calibrator Divisor:    3.42 chars/token

  Prompt Tokens (In):     34,120
  Eval Tokens (Out):       8,450
  Total Session Tokens:   42,570 / 100,000 (42.6%)
  Session Progress:      [████████████░░░░░░░░░░░░░░░░] 57,430 remaining
  Turn Spend Cap:        200,000 tokens (per-turn)
  ```
* `/tokens hardmax <amount | default>` (alias `/tokens max`):
  - Sets a live session override for the context window hardmax (e.g. `/tokens hardmax 7000`, `/tokens hardmax 7k`).
  - Next turn automatically prunes older historical turns via `Shedder.prune_history!` if current tokens exceed the new hardmax.
  - `/tokens hardmax default` restores the configured setting.
* `/tokens cap <amount | off>`:
  - Sets or disables the cumulative session-wide token cap (e.g., `/tokens cap 50k`, `/tokens cap off`).
* `/tokens reset`:
  - Resets session token accumulators to zero for a fresh monitoring window.
* `/tokens warn <percent>`:
  - Sets warning threshold (default 80%).

---

#### Option B: Unified Policy & Governance Command (`/policy` or `/guard`)
Combines tool availability, cascade policies, and token budgeting under a single unified security umbrella.

* Syntax:
  - `/guard status`: Renders a combined panel with both tool availability and token budget.
  - `/guard tools disable <tools...>`
  - `/guard tools limit read_file 5 --then-disable run_command`
  - `/guard tokens cap 50k`
  - `/guard preset read-only`
  - `/guard reset [tools | tokens | all]`
* **Pros**: Single command to learn; unified security mental model.
* **Cons**: Command invocations become more verbose (`/guard tools limit ...` vs `/tools limit ...`).

---

#### Option C: Declarative Rule DSL (`/rule` or `/constrain`)
Allows operators to write concise rule statements mimicking a firewall or policy engine:

* Syntax:
  - `/rule allow all except web_search, spawn_subagent`
  - `/rule on read_file > 5 -> revoke read_file, run_command`
  - `/rule session_tokens <= 50000`
  - `/rule list`
  - `/rule reset`
* **Pros**: Highly expressive; natural phrasing for conditional actions ("when X exceeds Y then revoke Z").
* **Cons**: Requires custom parser logic; less immediate discoverability via shell autocomplete.

---

## 3. Verification & Validation (V&V)

### Verification Plan
1. **Unit Tests for `Nightmare::Tools::Policy` (`spec/tools/policy_spec.cr`)**:
   - Verify disabling and enabling tools by individual name and by group (`read`, `mutation`, `shell`, `subagent`).
   - Verify per-turn and per-session tool call counting.
   - Verify that when a quota is breached, `record_call` marks the tool as exhausted and immediately disables configured cascade tools (`read_file` -> `run_command`).
   - Verify reset behavior across turns (per-turn quotas reset; session quotas persist).
2. **Unit Tests for `Nightmare::Context::SessionBudget` (`spec/context/session_budget_spec.cr`)**:
   - Verify accumulator math across multiple turns with prompt and eval tokens.
   - Verify human string parsing (`50k`, `100k`, `1m`, `off`).
   - Verify `cap_exceeded?` and warning threshold trip logic.
3. **Unit Tests for Router Slash Commands (`spec/commands/router_spec.cr`)**:
   - Verify `/tools` status table output.
   - Verify `/tools off`, `/tools on`, `/tools limit --cascade`, `/tools preset`, and `/tools reset`.
   - Verify `/tokens` status display, `/tokens cap 50k`, `/tokens cap off`, and `/tokens reset`.
4. **Integration Tests (`spec/harness/tool_policy_integration_spec.cr`)**:
   - Verify that disabled tools are excluded from the tool schema sent to `Mantle::Step`.
   - Verify cascade enforcement: simulate an LLM turn where `read_file` is called until quota trips, and verify that the subsequent attempt to run `run_command` (e.g. `cat file`) is refused by the harness.
   - Verify that breaching session token cap halts step execution and emits proper user-facing guidance.
5. **Full Test Suite Execution**:
   - Run `crystal spec` to ensure no regressions in existing harness specs.

### Verification Evidence
* `mantle`:
  - `spec/mantle/storage/turn_and_shedder_spec.cr`: verified dynamic mutable `hardmax` property on `SlidingStore` and `prune_to_hardmax!` pruning historical turns (7 examples, 0 failures).
  - Full suite: `crystal spec` passing cleanly (342 examples, 0 failures, 0 errors, 0 pending).
* `nightmare`:
  - `spec/tools/policy_spec.cr`: verified tool disabling/enabling by name and group alias, quota tracking, automatic cascade revocation of linked tools (`read_file` -> `run_command`), turn resets, and preset switching (7 examples, 0 failures).
  - `spec/harness_spec.cr`: verified `ToolMiddleware::PolicyEnforcer` and `StepRunner` dynamic tool filtering refusing calls upon quota exhaustion and rejecting bash circumvention (15 examples, 0 failures).
  - `spec/commands/router_spec.cr`: verified `/tools` dashboard, `/tools off`, `/tools on`, `/tools limit --cascade`, `/tools preset`, `/tools reset`, `/tokens status`, `/tokens hardmax <N>` with context pruning, and `/tokens hardmax default` (32 examples, 0 failures).
  - `spec/shedder_and_store_spec.cr`: verified dynamic mutation of `hardmax` on `SlidingStore` and automatic context pruning of historical turns via `prune_to_hardmax!` (8 examples, 0 failures).
  - `spec/cli_spec.cr`: verified terminal UI input driving interactive slash commands (`/tools`, `/tokens`, presets, quotas, and `/exit`) using `Nightmare::CLI.execute` with injected `IO::Memory` `stdin`/`stdout` according to `spec/GUIDANCE.md` §1 (11 examples, 0 failures).
  - Full suite: `crystal spec` passing cleanly (375 examples, 0 failures, 0 errors, 0 pending).

### Validation Plan
1. **Interactive REPL Scenario - Read Limit & Shell Fallback Cascade**:
   - Launch `nightmare`.
   - Run `/tools limit read_file 2 --cascade run_command`.
   - Issue prompt asking the agent to read 5 different files in the codebase.
   - Validate that after 2 reads, `read_file` and `run_command` are automatically disabled, and the agent's attempt to use `cat` or `head` via `run_command` is rejected.
2. **Interactive REPL Scenario - Session Token Cap**:
   - Run `/tokens cap 10k`.
   - Perform turns until total tokens reach 10k.
   - Validate that the warning banner appears at 80%, and subsequent turns are gated with the cap notice.
3. **Interactive REPL Scenario - Preset Switching**:
   - Run `/tools preset read-only`.
   - Ask the agent to modify a file. Validate that mutation tools are omitted from the prompt schema and no edits occur.

### Validation Evidence
* Direct Terminal UI execution via `Nightmare::CLI.execute(args, stdin: in_io, stdout: out_io, stderr: err_io)`:
  - Injected interactive command stream:
    ```text
    /tools status
    /tools limit read_file 3 session
    /tools off run_command
    /tokens hardmax 9500
    /tokens status
    /tools status
    /tools preset read-only
    /tokens hardmax default
    /tools reset
    /exit
    ```
  - Result: Returned exit code `0`. Rendered full interactive dashboard, successfully confirmed quota configuration, confirmed tool disabling, updated session token hardmax override, verified contextual table rendering with colorized badges, switched presets, reset policies, and gracefully terminated the REPL loop without subprocesses or `exit` crashes.

---

## Open Questions & Concurrency Concerns
1. **Subagent Policy Inheritance**:
   - Should subagents spawned via `spawn_subagent` inherit the parent's current tool policy and share the session token budget?
   - *Recommendation*: Yes. Subagents should inherit the parent's active disabled tool set and their token consumption must contribute to the parent's session budget to prevent subagent bypasses.
2. **Granular Shell Command Filtering vs. Complete Shell Revocation**:
   - When `read_file` is revoked, should we completely revoke `run_command`, or dynamically inject a blocklist of read utilities (`cat`, `head`, `tail`, `sed`, `less`, `more`, `awk`, `grep`) into `Tools::Guard`?
   - *Recommendation*: Support complete revocation of `run_command` by default for guaranteed safety, while allowing power users to specify selective cascade policies if desired.
3. **Persistence of Session Policies**:
   - Should `/tools` and `/tokens` settings be strictly ephemeral to the current REPL session, or persistable across sessions in `.nightmare/settings.json`?
   - *Recommendation*: Ephemeral by default (scoped to the live session), with an optional `--save` flag to write presets or default limits into workspace settings.

---

## 4. Revision History
* 2026-10-26: Initial ticket created documenting User Need, Technical Specification, UI approaches (Options A, B, and C), and Verification & Validation plan.
* 2026-10-26: Clarified token hardmax session override via `/tokens hardmax <N>` and next-turn dynamic historical context pruning via `SlidingStore#prune_to_hardmax!`.
* 2026-10-26: Implemented `Nightmare::Tools::Policy`, `ToolMiddleware::PolicyEnforcer`, StepRunner dynamic filtering, `SlidingStore#prune_to_hardmax!`, `/tools` and `/tokens` slash commands. All specs passing (373 examples in Nightmare, 342 examples in Mantle). Status updated to Resolved.
---
