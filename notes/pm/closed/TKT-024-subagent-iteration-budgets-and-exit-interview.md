---
ID: TKT-024
Title: Subagent Iteration Budgets and Automated Exit Interview / Telemetry Post-Mortem
Status: Closed
Priority: High
---

## 1. User Need
Subagents currently inherit the root agent's `max_iterations` setting (default 25 turns). When a subagent performs open-ended search or analysis, it frequently exhausts its entire turn budget reading files without producing a final deliverable. When this happens (`StepError::MaxIterationsReached`), `SubagentRunner` returns an unhelpful generic error (`[Subagent error: MaxIterationsReached]`). The calling root agent receives none of the subagent's findings, decisions, or inspected file paths, causing the root agent to redundantly repeat the exact same file exploration.

The user requires:
1. **Configurable Iterations**: Allow `max_iterations` to be configured independently between the root agent (e.g. 25 turns) and subagents (e.g. 15 turns or custom dynamic budgets passed via `spawn_subagent`).
2. **Subagent Exit Interview**: When a subagent runs out of turns or trips a loop circuit breaker, conduct an exit interview with the subagent model to summarize what was discovered, which files were examined, where it got stuck, and recommendations for the parent agent.
3. **Deterministic Telemetry Fallback**: If the exit interview LLM call fails, the context overflows, or the feature is disabled, return a deterministic telemetry post-mortem listing inspected files, touched files, commands executed, last action, and last thought.

## 2. Specification & Implementation Plan

### 2.1 Configuration & Settings
- Added `Nightmare::Config::SUBAGENT_MAX_ITERATIONS = 15` and `Nightmare::Config::SUBAGENT_EXIT_INTERVIEW = true`.
- Added `subagent_max_iterations : Int32` and `subagent_exit_interview : Bool` properties to `Nightmare::Settings`.
- Updated schema bootstrap and auto-patching to seamlessly migrate existing configuration files without data loss.

### 2.2 Tool Delegation Schema
- Updated `build_spawn_subagent_tool` in `Nightmare::Tools::Registry` to declare `budget_iterations` parameter in schema properties and forward dynamic limits to `SubagentRunner#run_subagent`.

### 2.3 Subagent Runner & Exit Interview Pipeline
- In `SubagentRunner#run_subagent` and `SubagentRunner#dispatch`:
  - Default subagent iteration limits to `@environment.settings.subagent_max_iterations`, honoring explicit `budget_iterations` overrides.
  - Track executed tool calls, arguments, and return values in `executed_tool_results`.
  - When `Mantle::Step` terminates with `MaxIterationsReached`, `ERR_DEGENERATE_LOOP`, or other harness halts:
    - Synchronize final iteration messages and executed tool results into `store.active_turn`.
    - Seal open tool calls with synthetic responses (`Execution halted before tool response: <reason>`) to ensure API schema validity.
    - If `subagent_exit_interview` is enabled and error permits LLM interaction (`MaxIterationsReached` / loop trips):
      - Run emergency shedding via `Context::Shedder` if context approaches hardmax.
      - Prompt subagent model with a single-turn supervisor intervention (`tools: nil`) for discoveries, actions, blockers, and recommendations.
      - Return structured summary containing header, telemetry, and subagent exit report.
    - If LLM call fails or is bypassed: return deterministic telemetry post-mortem with inspected files, commands run, last action, and last thought.
  - Maintain cooperative user cancellation (`CancelledException`) propagation.

## 3. Verification & Validation (V&V)

* **Verification Plan:**
  - Add unit specs in `spec/settings_spec.cr` verifying defaults, bootstrapping, and auto-patching of `subagent_max_iterations` and `subagent_exit_interview`.
  - Add unit specs in `spec/tools_spec.cr` verifying `spawn_subagent` accepts and forwards `budget_iterations`.
  - Add unit specs in `spec/plan/subagent_runner_spec.cr` verifying:
    - Dynamic `budget_iterations` enforcement.
    - Exit interview generation on `MaxIterationsReached`.
    - Deterministic telemetry fallback on LLM failure or disabled setting.
    - Sealing of open tool calls.
    - Dispatch integration in plan items.
  - Run full test suite `crystal spec`.

* **Verification Evidence:**
  - `crystal spec spec/settings_spec.cr`: 8 examples, 0 failures, 0 errors, 0 pending.
  - `crystal spec spec/tools_spec.cr`: 31 examples, 0 failures, 0 errors, 0 pending.
  - `crystal spec spec/plan/subagent_runner_spec.cr`: 18 examples, 0 failures, 0 errors, 0 pending.
  - Full suite `crystal spec`: 296 examples, 0 failures, 0 errors, 0 pending.

## 4. Revision History
* 2026-09-27: Implemented configurable subagent iterations and two-tier exit interview / deterministic telemetry post-mortem. Verified with full test suite; closed ticket.
