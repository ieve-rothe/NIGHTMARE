---
ID: TKT-002
Title: KV Cache Capacity and Utilization Metrics (Tokens and Memory)
Status: Open
Priority: Med
---

## 1. User Need
Developers and operators tuning `nightmare` workloads need visibility into KV cache allocation versus actual utilization (in terms of token count and memory consumption). Without this observability, it is difficult to determine whether KV cache memory is over-provisioned (wasting VRAM/system memory that could be freed or allocated elsewhere) or near exhaustion (risking context truncation or OOMs for a given workload).

## 2. Specification
1. **Metrics Collection:**
   - Query or calculate configured KV cache limits:
     - Maximum token capacity reserved / configured for KV cache (e.g., context window size `n_ctx` / slot capacity).
     - Estimated or reported memory allocation for KV cache (bytes / MB / GB based on context size, precision, layers, architecture).
   - Track active / current KV cache usage during sessions or per-turn:
     - Active token occupancy in the cache (prompt + generated tokens currently retained).
     - Approximate or reported memory footprint of active KV cache tokens.
   - Calculate utilization percentages:
     - Token utilization (`active_tokens / max_tokens * 100%`).
     - Memory utilization (`used_memory / allocated_memory * 100%`).
2. **Reporting & Exposure Interfaces:**
   - Expose metrics in the REPL (e.g., via `/status`, `/context`, `/stats`, or a dedicated `/kv` command).
   - Optionally log KV cache utilization stats in verbose/debug logs or per-turn audit transcripts.
   - Provide human-readable summary output (e.g., `KV Cache: 4,096 / 16,384 tokens (25.0%) | ~512 MB / 2,048 MB (25.0%)`).
3. **Backend Integration:**
   - Integrate with `salamander` / underlying engine metrics or inference API if supported, or calculate deterministic estimates from model context parameters and layer configurations.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Unit specs: Test calculation functions for KV cache token and memory estimations across standard configurations and quantization types.
  - Integration specs: Verify that REPL command and/or status output correctly reflects cache state as tokens accumulate in context turns.
  - Test suite run: `crystal spec`
* **Verification Evidence:**
  - *Pending execution.*
* **Validation Plan:**
  - Run an interactive session or simulated workload, inspect the KV metrics output, and verify that token and memory usage values align with actual context load.
  - Verify that the metrics allow an operator to evaluate whether to increase or decrease reserved KV cache memory for a specific workload.
* **Validation Evidence:**
  - *Pending execution.*

## Open Questions & Concurrency Concerns
* Does `salamander` (or the underlying engine like `llama.cpp`) expose exact runtime KV cache slot and memory metrics via API, or should `nightmare` estimate based on context length, layer count, head dimension, and data type?
* How should multi-sequence or speculative decoding (if applicable) factor into KV cache reservation reporting?
* Preferred UX display format: integrated into an existing command (e.g., `/stats` or prompt summary) vs. a dedicated `/kv` command.

## 4. Revision History
* 2026-09-11: Ticket created from user feature request.
---
