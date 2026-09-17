# Settings Reference

NIGHTMARE uses a structured JSON configuration system. Settings are resolved using a cascading precedence model:

1. **Workspace Config:** `~/.config/nightmare/workspaces/<id>/config.json` (Overrides all, scoped to project)
2. **Global Config:** `~/.config/nightmare/config.json` (Base user settings)
3. **Defaults:** Hardcoded system fallbacks.

## Example Config

```json
{
  "model": "qwen2.5-coder:7b",
  "api_url": "http://127.0.0.1:11434/api/chat",
  "temperature": 0.2,
  "theme": "cyberpunk",
  "markdown": true,
  "logging": true
}
```

## Settings Matrix

### Model & API

| Setting | Type | Default | Description |
|---|---|---|---|
| `model` | String | `"qwen2.5-coder:7b"` | Name of the model to use for completion requests. |
| `api_url` | String | `"http://127.0.0.1:11434/api/chat"` | Endpoint for the LLM inference server. |
| `temperature` | Float64 | `0.2` | Sampling temperature for model output generation. |
| `top_p` | Float64 | `0.95` | Nucleus sampling probability threshold. |
| `max_tokens` | Int32 | `4096` | Maximum number of tokens to generate per request. |

### UI & Display

| Setting | Type | Default | Description |
|---|---|---|---|
| `markdown` | Bool | `true` | Enables rich markdown rendering in terminal outputs. |
| `logging` | Bool | `true` | Toggles detailed execution logging. |
| `theme` | String | `"cyberpunk"` | Color scheme for terminal UI and dashboard elements. |
| `max_dashboard_width` | Int32 | `105` | Maximum column width for UI rendering. |
| `file_card_threshold_screens` | Float64 | `1.5` | Screen height ratio before truncating files into summary cards. |
| `file_card_preview_lines` | Int32 | `8` | Number of preview lines to show in a minimized file card. |

### Context & Token Management

| Setting | Type | Default | Description |
|---|---|---|---|
| `token_hardmax` | Int32 | `12000` | Absolute limit for context window size before forced truncation. |
| `per_file_max_tokens` | Int32 | `10000` | Maximum tokens to embed from a single file read operation. |
| `pinned_budget_ratio` | Float64 | `0.60` | Fraction of context window reserved for system prompts and pinned facts. |
| `shed_trigger_ratio` | Float64 | `0.85` | Context utilization threshold that triggers history truncation. |
| `shed_keep_chars` | Int32 | `200` | Number of characters to retain from pruned conversation turns. |
| `shed_keep_verbatim` | Int32 | `2` | Number of recent conversation turns exempt from pruning. |
| `initial_divisor` | Float64 | `3.5` | Initial scaling factor for token estimation heuristics. |

### Tool Execution

| Setting | Type | Default | Description |
|---|---|---|---|
| `command_timeout_seconds` | Int32 | `60` | Timeout before sending a synchronous shell command to the background. |
| `max_command_timeout_seconds` | Int32 | `600` | Absolute maximum runtime for execution before hard termination. |
| `tool_output_max_bytes` | Int32 | `24576` | Truncation threshold for tool stdout/stderr buffers. |
| `bulk_data_patterns` | Array(String) | `["*.jsonl", "*.log", "*.trace", "*.ndjson"]` | Glob patterns identifying high-volume log and data files. |
| `bulk_data_max_lines` | Int32 | `50` | Line limit enforced when reading files matching bulk patterns. |

### Harness & Retry

| Setting | Type | Default | Description |
|---|---|---|---|
| `rate_limit_retries` | Int32 | `3` | Maximum attempts for recovering from HTTP 429 rate limits. |
| `format_retries` | Int32 | `1` | Maximum attempts to fix JSON schema or formatting violations. |
| `context_overflow_retries` | Int32 | `1` | Maximum attempts to recover when context window is breached. |

### Plan Orchestration

| Setting | Type | Default | Description |
|---|---|---|---|
| `max_iterations` | Int32 | `25` | Limit on consecutive autonomous tool-use turns per session. |
| `turn_soft_cap` | Int32 | `10` | Threshold for warning the user about prolonged execution loops. |
| `turn_spend_cap_tokens` | Int32 | `200000` | Limit of tokens consumed per task reasoning loop. |
| `loop_detect_threshold` | Int32 | `3` | Number of identical consecutive tool calls before aborting. |

<br>

[Previous: Observability](11-observability.md) | [Next: Troubleshooting](13-troubleshooting.md)
