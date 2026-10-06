---
ID: TKT-031
Title: Context Overflow Classification and Large Tool Output Pruning (Qwen Missing User Query)
Status: Closed
Priority: High
---

## 1. User Need
When local agent models with restricted context budgets (such as Qwen 3.8 models running under back-end limits like `num_ctx 8192` to conserve KV cache memory) execute shell commands or file operations that produce voluminous responses, the total token count can exceed the server's context window.

Under Ollama, exceeding `num_ctx` triggers front-truncated FIFO message pruning, which discards the initial `user` role prompt. Because Qwen 3.8 models enforce a strict Jinja chat template requirement that at least one `user` message must exist in the conversation, Ollama fails with `HTTP 500: {"error":"no user query found in messages"}`.

Previously, this error was misclassified by Mantle as a generic unrecoverable `ClientFailure` rather than a `ContextOverflow`, bypassing Nightmare's emergency context shedding and recovery routines. As a result, the agent run terminated catastrophically rather than trimming context, shedding large outputs, and continuing. The user needs the harness to proactively prevent, properly classify, and automatically recover from this failure mode.

## 2. Specification

### 2.1 Incident Investigation & Assessment
* **Incident Workspace**: `/home/cam/.local/state/nightmare/workspaces/kasten-beed8f62`
* **Model Configuration**: `qac:latest` (`huihui_ai/Qwen3.8-abliterated:latest` with Ollama backend parameter `PARAMETER num_ctx 8192`).
* **Sequence of Events**:
  1. The user requested: `"Please list all files in all directories in cwd"`.
  2. The agent called `list_files`, which was adaptively capped to 40 entries / top-level summary per TKT-029.
  3. Attempting to satisfy the user's exhaustive listing request, the agent bypassed `list_files` by invoking `run_command` with `find . -type f -not -path './.git/*' | sort`.
  4. The tool returned 13,257 characters (~3,500+ tokens) in a single turn.
  5. The previous turn had already consumed 5,672 tokens (`prompt_eval_count: 5672`). Appending the 13 KB tool result inflated the prompt to 21,278 characters (~9,500–10,000+ tokens).
  6. Even with user-configured `token_hardmax: 8000` (and `shed_trigger_ratio: 0.85` yielding a trigger threshold of 6,800 tokens), in-turn shedding was ineffective:
     - `Mantle::Storage::Shedder.shed_active_turn!` only shed *consumed* tool results (those followed by a subsequent assistant message). The 13,257 character result from `find` was newly returned and *unconsumed*, exempting it from shedding.
     - Prior tool results in the active turn (exchanges 1–8) were already small (~15–240 characters) due to `list_files` folding, meaning shedding to `shed_keep_chars: 200` recovered zero tokens.
     - Exchange 9 was protected by `shed_keep_verbatim: 2`.
     - `prune_history!` only evicts completed historical turns, leaving the bloated active turn untouched.
     - Additionally, the user configuration had `tool_output_max_bytes: 65536` (64 KB), which allowed the 13 KB `find` output through without shell-level byte capping.
  7. Ollama received >8,192 tokens. Ollama performed front-truncation to fit `num_ctx 8192`, which pruned the original `user` prompt.
  8. Qwen 3.8's Jinja template raised an exception (`raise_exception('no user query found in messages')`), causing Ollama to respond with `HTTP 500: {"error":"no user query found in messages"}`.
  9. Mantle's `Mantle::Clients::APIError#context_overflow?` only checked for HTTP 400 and specific substrings (`context_length_exceeded`, `maximum context length`, `context window`, `too many tokens`). It categorized the 500 error as `StepError::ClientFailure`.
  10. `Nightmare::StepRunner` received `ClientFailure`. Despite the user having `context_overflow_retries: 1`, `context_overflow_error?` evaluated to false, bypassing `recover_from_context_overflow` and crashing the turn immediately.

### 2.2 Potential Root Causes Identified
1. **Ollama Front-Truncation Drops User Prompt**: Exceeding `num_ctx` causes Ollama to drop earlier messages FIFO-style, stripping out the single `user` message.
2. **Qwen 3.8 Chat Template Assertion**: Qwen 3.8 template enforces `{% if not messages | selectattr('role', 'equalto', 'user') | list %}{{ raise_exception('no user query found in messages') }}{% endif %}`.
3. **Mantle Error Classification Gap**: `Mantle::Clients::APIError#context_overflow?` expects HTTP 400 and does not match the HTTP 500 Qwen Jinja template exception.
4. **Nightmare Error Recovery Gap**: `Nightmare::StepRunner#context_overflow_error?` does not detect `"no user query found in messages"`, disarming `context_overflow_retries: 1` and preventing emergency shedding.
5. **In-Turn Shedding Blindspot for Unconsumed Tool Results**: `Mantle::Storage::Shedder.shed_active_turn!` exempts unconsumed tool results. Even when `token_hardmax: 8000` is configured, a single large unconsumed result (e.g. 13 KB) delivered at the end of a long turn is sent raw to the LLM.
6. **Tool Output Cap Elevation**: With `tool_output_max_bytes: 65536` (64 KB), shell outputs can single-handedly consume or blow past an 8,192 token context window before harness-level guards intervene.

### 2.3 Required Technical Changes

#### Mantle Upstream Changes:
* **API Error Classification**:
  * In `Mantle::Clients::APIError#context_overflow?`, recognize HTTP 500 errors containing `"no user query found in messages"` as context overflow conditions.
  * In `Mantle::Steps::Step#run`, map these errors to `StepError::ContextOverflow`.
* **Proactive In-Turn Shedding / Unconsumed Clamping**:
  * Update `Mantle::Storage::Shedder.shed_active_turn!` with `include_unconsumed : Bool = false`.
  * In `Mantle::Steps::ToolLoop#handle_iteration`, if `estimated > hardmax`, invoke `shed_active_turn!(include_unconsumed: true, keep_verbatim: 0)` to prevent dispatching an oversized payload.

#### Nightmare Harness Changes:
* **Error Detection & Recovery**:
  * In `Nightmare::Harness::StepRunner#context_overflow_error?` and `SubagentRunner#context_overflow_error?`, check for `result.error == Mantle::StepError::ContextOverflow` and `"no user query found in messages"`.
  * In `recover_from_context_overflow`, call `Context::Shedder.shed_active_turn!` with `include_unconsumed: true` and `keep_verbatim: 0`, aggressively shedding the turn to allow successful retry.
* **Tool Output Clamping in Shell**:
  * In `Nightmare::Tools::Shell#execute_process_group`, apply `Guard.cap_output(formatted, max_bytes: @tool_output_max_bytes)`.

## 3. Verification & Validation (V&V)

* **Verification Plan:**
  1. Unit specs in `mantle/spec/client_spec.cr` for `Mantle::Clients::APIError#context_overflow?` verifying that HTTP 500 with `no user query found in messages` returns true.
  2. Unit specs in `mantle/spec/mantle/storage/turn_and_shedder_spec.cr` verifying that `shed_active_turn!` with `include_unconsumed: true` successfully compresses unconsumed exchanges.
  3. Integration specs in `nightmare/spec/harness_spec.cr` and `nightmare/spec/plan/subagent_runner_spec.cr` simulating `API error 500: {"error":"no user query found in messages"}` and confirming emergency shedding and turn retries.
  4. Unit spec in `nightmare/spec/tools_spec.cr` verifying `Shell.run_command` output capping.
* **Verification Evidence:**
  * Mantle spec suite: `crystal spec` passing with 338 examples, 0 failures, 0 errors.
  * Nightmare spec suite: `crystal spec` passing with 329 examples, 0 failures, 0 errors.
* **Validation Plan:**
  1. Re-run an agent session against simulated context overflow with `no user query found in messages`.
  2. Confirm the harness catches the error, sheds active turn exchanges (including unconsumed outputs), and completes the retry without crashing.
* **Validation Evidence:**
  * Automated integration tests in `harness_spec.cr` and `subagent_runner_spec.cr` successfully validated that upon receiving `API error 500: {"error":"no user query found in messages"}`, the runner triggers `recover_from_context_overflow`, sheds the large tool exchange down to 50 characters, and successfully completes the turn on retry.

## Open Questions & Concurrency Concerns
* Model-aware configuration profiles: captured separately in TKT-033.

## 4. Revision History
* 2026-10-06: Initial ticket created with root cause investigation and assessment from kasten-beed8f62 incident.
* 2026-10-06: Implemented error classification in Mantle, unconsumed shedding support, StepRunner/SubagentRunner recovery, and Shell output capping. Verified with automated test suites in Mantle (338 specs) and Nightmare (329 specs). Moved to closed.
---
