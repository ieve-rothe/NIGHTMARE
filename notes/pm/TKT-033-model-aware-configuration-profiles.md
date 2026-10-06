---
ID: TKT-033
Title: Model-Aware Configuration Profiles
Status: Open
Priority: Med
---

## 1. User Need
Users frequently switch between different local model backends and architectures depending on their hardware environment, task requirements, and memory constraints. For instance, a user might use a large-capacity MoE model (such as `laguna-xs-2.1:latest` with a 32k+ token working window) for complex programming tasks, but switch to a bounded model (such as `qac:latest` capped at 8,192 tokens to prevent KV cache memory blowout) on constrained hardware or for lightweight operations.

Currently, Nightmare's operational configuration—including `token_hardmax`, `max_tokens`, `tool_output_max_bytes`, in-turn shedding thresholds, and sampling options—is flat and globally applied across all sessions in a workspace.

This creates an ergonomics and stability tradeoff:
1. If the user tunes settings conservatively for smaller models (e.g., `token_hardmax: 8000`, aggressive shedding), higher-capacity models are artificially throttled, resulting in premature context pruning and unnecessary eviction of conversational history.
2. If the user tunes settings for high-capacity models (e.g., `token_hardmax: 24000`, larger tool output budgets), smaller models exceed their context limits, suffer FIFO message truncation, or trigger fatal backend template exceptions.

The user needs the harness to support model-aware configuration profiles so that operational parameters automatically align with the active model without requiring manual edits to `settings.json` upon every model switch.

## 2. Specification

### 2.1 Problem Scope
* The configuration in `.nightmare/settings.json` is currently a single static object.
* Key parameters that depend heavily on model context and capability:
  * `token_hardmax` (context ceiling before history eviction)
  * `max_tokens` (completion `num_predict` budget)
  * `tool_output_max_bytes` (process supervisor output cap)
  * `shed_trigger_ratio`, `shed_keep_chars`, `shed_keep_verbatim`
  * `temperature`, `top_p`

### 2.2 Conceptual Approaches Under Consideration
1. **Explicit Model Profile Overrides in `settings.json`**:
   * Add an optional `profiles` or `models` section in `settings.json` keyed by model name or glob pattern:
     ```json
     {
       "token_hardmax": 12000,
       "models": {
         "qac:*": {
           "token_hardmax": 7500,
           "tool_output_max_bytes": 16384
         },
         "laguna-*": {
           "token_hardmax": 24000,
           "max_tokens": 6096,
           "tool_output_max_bytes": 65536
         }
       }
     }
     ```
   * When initializing the harness, the active `model` string is matched against model profile keys to overlay model-specific parameters on top of the base settings.

2. **Named Profiles via CLI / Slash Command**:
   * Define named configuration presets (e.g., `profiles: { "low-kv": {...}, "extended": {...} }`).
   * Allow selection via CLI flag `--profile low-kv` or runtime REPL command `/profile low-kv`.

3. **Automatic Inference-Time Discovery**:
   * Query backend model metadata (e.g., Ollama `/api/show`) to detect `context_length` and derive sensible defaults for `token_hardmax` (e.g. 75% of context window) and `max_tokens` when explicit overrides are not provided.

### 2.3 Proposed Resolution Hierarchy
When resolving effective settings for a session or turn:
1. Explicit CLI arguments / runtime flags (highest precedence).
2. Matching model-specific profile block in `.nightmare/settings.json`.
3. Global baseline values in `.nightmare/settings.json`.
4. Hardcoded defaults in `Nightmare::Config` (fallback).

## 3. Verification & Validation (V&V)

* **Verification Plan:**
  1. Unit tests in `nightmare/spec/settings_spec.cr` verifying that loading settings with a model tag merges matching profile overrides over base values.
  2. Spec tests verifying pattern matching (e.g., glob or prefix matching for tags like `qac:latest` vs `qac:*`).
  3. Spec tests verifying that unspecified properties retain baseline configuration values without regression.
* **Verification Evidence:**
  * To be populated upon implementation.
* **Validation Plan:**
  1. Configure two distinct model profiles in a test environment: one for `qac:latest` (`hardmax: 7500`) and one for `laguna-xs-2.1:latest` (`hardmax: 24000`).
  2. Launch Nightmare with `qac:latest` and verify via `/config` or debug logging that the 7,500 token limit is enforced.
  3. Launch Nightmare with `laguna-xs-2.1:latest` and verify that the 24,000 token limit is enforced without manual file edits.
* **Validation Evidence:**
  * To be populated upon implementation.

## Open Questions & Concurrency Concerns
* **Matching Granularity**: Should model matching support exact names, wildcards (`qwen*`), or regexes?
* **Subagent Model Independence**: If a parent agent running Laguna spawns a subagent configured to use a smaller model, how should settings inheritance work? (Subagent runner should independently resolve profiles for its assigned model).
* **Automatic vs. Declarative**: How much should be automatically derived from Ollama versus explicitly declared in configuration files? (Declarative JSON configuration is generally more predictable and reproducible across environments).

## 4. Revision History
* 2026-10-06: Initial ticket created capturing the core user need for model-aware profiles and setting the concept aside for design exploration.
---
