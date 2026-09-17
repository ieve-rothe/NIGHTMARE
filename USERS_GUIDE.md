# NIGHTMARE User's Guide

A comprehensive operational guide to **NIGHTMARE**, a standalone developer REPL for plain text file manipulation and shell task execution powered by local LLMs via Ollama and Mantle.

---

## Table of Contents

1. [Overview & Philosophy](#1-overview--philosophy)
2. [Prerequisites & Installation](#2-prerequisites--installation)
3. [Workspace Anchoring & Centralized XDG Storage](#3-workspace-anchoring--centralized-xdg-storage)
4. [Configuration Hierarchy](#4-configuration-hierarchy)
5. [Tool Suite & The Approval Boundary](#5-tool-suite--the-approval-boundary)
6. [Context Engine & Token Management](#6-context-engine--token-management)
7. [Slash Commands Reference](#7-slash-commands-reference)
8. [Signal Handling & Cooperative Interruption](#8-signal-handling--cooperative-interruption)
9. [Observability & Audit Logging](#9-observability--audit-logging)
10. [Troubleshooting & FAQs](#10-troubleshooting--faqs)

---

## 1. Overview & Philosophy

NIGHTMARE is designed around four core tenets:

1. **Zero Repository Litter**: Project source trees must remain clean. Config files, token caches, transcripts, and audit logs are stored strictly in central user XDG locations partitioned by workspace identity.
2. **Strict Workspace Containment**: The agent cannot access or modify files outside `Dir.current.realpath`. Path traversal attempts (`../`) and symlinks pointing outside the workspace are rejected immediately with a `SecurityError`. Modifying `.git/` is prohibited.
3. **Anti-Fatigue Human-in-the-Loop Boundaries**:
   - Safe observation tools run autonomously without prompting.
   - Modifying existing files requires approval via an interactive unified diff modal (`[y/N/a]`). Creating new files is auto-approved.
   - Shell commands prompt for approval (`[y/N/e/a/p]`) with process group isolation and strict bans on auto-approving shell metacharacters.
4. **Deterministic Harness with Typed Boundaries**: Execution is driven by Mantle's step runner, wrapping all stochastic LLM responses into typed `StepOutcome` sum types, with built-in loop detection, exponential rate-limit backoff, and format-correction retries.

---

## 2. Prerequisites & Installation

### Prerequisites

- **Crystal**: Version 1.10.0 or later.
- **Ollama**: Running locally at `http://127.0.0.1:11434`. Ensure at least one model is pulled, for example:
  ```bash
  ollama pull huihui_ai/Qwen3.8-abliterated:latest
  # or
  ollama pull qwen2.5-coder:7b
  ```

### Building NIGHTMARE

From the root of the repository:

```bash
shards build
```

The compiled binary will be placed at `bin/nightmare`.

---

## 3. Workspace Anchoring & Centralized XDG Storage

When you launch `bin/nightmare`, it resolves `Dir.current` to its real filesystem path and computes a deterministic workspace ID of the form:

```
<slug>-<hash>
```

For example, `/home/cam/repos/adjutant/nightmare` becomes `nightmare-b97495a0`.

### The Startup Banner

On launch, NIGHTMARE prints a clear banner identifying the workspace and its associated central state directories:

```
┌── NIGHTMARE ─────────────────────────────────────────────────────────────┐
│ Workspace : /home/cam/repos/adjutant/nightmare                           │
│ Config    : ~/.config/nightmare/workspaces/nightmare-b97495a0/           │
│ State/Logs: ~/.local/state/nightmare/workspaces/nightmare-b97495a0/      │
└──────────────────────────────────────────────────────────────────────────┘
> 
```

### Filesystem Layout

| Directory / File | Path | Purpose |
| :--- | :--- | :--- |
| **Global Config** | `~/.config/nightmare/` | Global fallback settings (`config.json`, `prompt.md`) |
| **Workspace Config** | `~/.config/nightmare/workspaces/<id>/` | Workspace-specific config (`config.json`, `prompt.md`, `allow`, `workspace.json`) |
| **Workspace State** | `~/.local/state/nightmare/workspaces/<id>/` | Central audit log (`llm_calls.jsonl`) and active transcript (`transcript.md`) |
| **Workspace Cache** | `~/.cache/nightmare/workspaces/<id>/` | Dynamic token calibration state (`calibrator.json`) |

---

## 4. Configuration Hierarchy

NIGHTMARE resolves configuration and system prompts using strict precedence rules.

### Model Selection

The active model is determined in the following order of precedence:

1. **CLI Flag**: `-m MODEL` or `--model=MODEL`
2. **Workspace Config**: `"model"` key in `~/.config/nightmare/workspaces/<id>/config.json`
3. **Global Config**: `"model"` key in `~/.config/nightmare/config.json`
4. **Default**: `Config::DEFAULT_MODEL` (`qwen2.5-coder:7b`)

You can also change the model dynamically inside the REPL using `/model <name>`.

### API Endpoint (Ollama / Mantle)

The API URL is determined in the following order:

1. **Environment Variables**: `MANTLE_API_URL` or `OLLAMA_API_URL`
2. **Workspace Config**: `"api_url"` key in `~/.config/nightmare/workspaces/<id>/config.json`
3. **Global Config**: `"api_url"` key in `~/.config/nightmare/config.json`
4. **Default**: `http://127.0.0.1:11434/api/chat`

#### Example `config.json`

Place this in `~/.config/nightmare/config.json` for global defaults, or in a workspace config directory for per-project settings:

```json
{
  "model": "huihui_ai/Qwen3.8-abliterated:latest",
  "api_url": "http://127.0.0.1:11434/api/chat"
}
```

### System Prompt Resolution

System prompts are resolved in the following strict order:

1. **CLI Flag**: `-s PATH` or `--system=PATH`
2. **Repository Override**: `<workspace_root>/.nightmare/prompt.md`
3. **Workspace Prompt**: `~/.config/nightmare/workspaces/<id>/prompt.md`
4. **Global Prompt**: `~/.config/nightmare/prompt.md`
5. **Default General Persona**: Built-in concise, factual execution agent persona.

---

## 5. Tool Suite & The Approval Boundary

NIGHTMARE equips the model with a carefully partitioned tool suite designed to maximize autonomy on read operations while giving the operator full control over mutations and command execution.

### Autonomous Read-Only Tools

These tools run automatically without human intervention:

- **`list_files(glob)`**: Lists matching files relative to the workspace root. Automatically excludes `.git/`.
- **`search(pattern, glob)`**: Searches text contents across files using regex or literal patterns. Excludes `.git/`.
- **`read_file(path, offset, limit)`**: Reads file contents line-by-line with 1-indexed line numbers.
- **`file_info(path)`**: Reports file metadata (size, permissions, line count, modified time).

### Mutation Tools & Diff Modals

- **`write_file(path, content)`**: Writes or overwrites a file.
- **`replace_in_file(path, target, replacement)`**: Replaces targeted substrings.
- **`append_to_file(path, content)`**: Appends content to an existing file.

#### The Diff Approval Modal

When the agent creates a **new file**, the mutation is **auto-approved**.

When the agent attempts to **modify an existing file**, NIGHTMARE displays a colorized unified diff and presents an approval modal:

```
Approvals: [y] Approve once  [N] Reject  [a] Allow all file edits this session
Choice [y/N/a]:
```

- **`y`**: Approves the modification.
- **`N` (or Enter)**: Rejects the modification and returns an error message to the model.
- **`a`**: Approves the modification and enables session-wide auto-approval for subsequent file mutations.

> [!NOTE]
> Writes targeting `.git/` are strictly forbidden and cannot be approved.

### Shell Execution (`run_command`)

The `run_command` tool executes arbitrary shell tasks within the workspace.

#### Shell Protections

1. **Process Group Isolation**: Commands run inside an isolated process group (`setsid -w /bin/bash -c ...`).
2. **Closed Stdin**: Commands cannot block waiting for keyboard input (`Process::Redirect::Close`).
3. **Hard Output Capping**: Output is capped at 300 lines and 64 KB to prevent buffer exhaustion and pipe deadlocks.
4. **Termination Ladder**: On timeout or cancellation, NIGHTMARE sends `SIGTERM`, waits a grace period (2 seconds), and escalates to `SIGKILL` if the process group remains alive.

#### The Command Approval Modal

```
Command: git status
Cwd:     /path/to/workspace
Timeout: 30s
Approvals: [y] once (don't save)  [N] reject  [e] edit  [a] save exact  [p] save prefix
Approve command? [y/N/e/a/p]:
```

- **`y`**: Executes the command once without saving to the allowlist.
- **`N` (or Enter)**: Rejects the command.
- **`e`**: Allows inline operator editing of the command, followed by re-confirmation in the approval modal before execution.
- **`a`**: Saves the exact command string to the allowlist (auto-approved in future).
- **`p`**: Saves the command prefix to the allowlist (e.g. `git status` allows future `git status ...`).
- **`?`**: Displays detailed help explaining each option and reprompts.

> [!IMPORTANT]
> **Metacharacter Ban**: Commands containing shell metacharacters (`;`, `&&`, `||`, `|`, `` ` ``, `$()`, `>`, `<`) **cannot** be auto-approved via `[a]` or `[p]`. They will always trigger an interactive prompt to protect against command injection.

### Subagent Delegation (`spawn_subagent`)

- **`spawn_subagent(task, files_targeted)`**: Delegates an autonomous sub-task to an isolated subagent runner equipped with its own multi-step tool execution loop (reading files, searching, editing files, running commands). The subagent executes within target file bounds, strictly blocks recursive subagent calls and git mutation commands, and returns a concise summary of results without polluting the primary REPL turn context.

---

## 6. Context Engine & Token Management

NIGHTMARE implements an ephemeral, turn-unit sliding window designed to stay strictly within token budgets.

### Atomic Turn Units

A conversation turn consists of:
- A user message.
- Optional assistant tool calls and corresponding tool response pairs.
- A final assistant response.

Pruning always operates on whole turn units; tool call and tool result messages are never separated or orphaned. The active turn's user message is strictly protected from pruning.

### In-Turn Shedding

During complex turns with many sequential tool calls, context size can spike before the turn completes. When estimated tokens exceed the shed threshold (85% of hardmax), NIGHTMARE sheds older consumed tool results:
- **Last 2 Verbatim**: The most recent 2 consumed tool exchanges are preserved verbatim.
- **Shed Markers**: Earlier tool results in the turn are truncated to 200 characters with a summary notice (`[... output truncated: was <N> bytes]`).
- **Pristine Transcript**: The in-memory transcript retains un-truncated tool results for pristine export via `/save`.

### Token Calibration

Token counts are estimated using character-to-token divisors self-calibrated from Ollama's `prompt_eval_count` responses. Calibration parameters are persisted in `~/.cache/nightmare/workspaces/<id>/calibrator.json` across sessions.

---

## 7. Slash Commands Reference

NIGHTMARE provides operators with immediate command controls:

| Command | Description |
| :--- | :--- |
| **`/help`** | Displays the slash command quick reference table. |
| **`/clear`** | Clears the screen and active conversation history from memory (pinned files remain). |
| **`/cls`** | Clears the ANSI terminal screen. |
| **`/add <path>`** | Pins a workspace file into persistent system context. |
| **`/drop [path]`** | Unpins a specified file, or all files if no path is given (alias: `/rm`). |
| **`/save [path]`** | Exports the pristine, un-truncated in-memory transcript to a Markdown file. |
| **`/prompt`** | Displays the current in-memory system prompt. |
| **`/prompt edit`** | Edits the in-memory system prompt for the current session. |
| **`/review`** | Displays the assembled prompt, pinned files, turn history, and token budget. |
| **`/thinking`** | Displays the model's `<think>` chain-of-thought tokens from the last turn. |
| **`/model [name]`** | Displays the active model, or switches to a new model immediately. |
| **`/paste`** | Enters multi-line input paste mode; submit with `/end` or an empty line. |
| **`/exit`** | Exits the NIGHTMARE session (alias: `/quit` or EOF `Ctrl+D`). |

---

## 8. Signal Handling & Cooperative Interruption

### During LLM Generation or Tool Execution (`Ctrl+C`)

Pressing `Ctrl+C` while the model is generating or while a tool is executing:
1. Cooperatively cancels the Mantle step execution.
2. Immediately terminates any active child process group (`SIGTERM` -> `SIGKILL`).
3. Rolls back the active turn from context so that partial outputs do not pollute history.
4. Preserves the session and returns to the prompt `> `.

If files were written or commands were executed before the interruption occurred, NIGHTMARE notes the modified side effects upon the next turn:
```
[Previous turn was interrupted after modifying: src/app.cr]
```

### At the Empty Prompt (`Ctrl+C`)

- A single `Ctrl+C` at an empty prompt prints:
  ```
  (Press Ctrl+C again to exit, or type /exit)
  ```
- Pressing `Ctrl+C` a second time within 1.5 seconds cleanly exits the REPL.

---

## 9. Observability & Audit Logging

### Audit Log (`llm_calls.jsonl`)

Every call to the LLM is recorded in:
```
~/.local/state/nightmare/workspaces/<workspace-id>/llm_calls.jsonl
```

Each line contains a JSON object:
```json
{
  "timestamp": "2026-09-11T22:41:24Z",
  "model": "huihui_ai/Qwen3.8-abliterated:latest",
  "prompt": "Inspect src/nightmare.cr",
  "completion": "I have inspected the file...",
  "latency_ms": 1420,
  "error": null
}
```

If an LLM call fails, the exact error reason (e.g. HTTP 404, context length exceeded, rate limit) is captured in the `"error"` field.

#### Automatic Log Rotation
The audit log automatically rotates when it reaches 20 MB, keeping up to 3 rotated archives (`llm_calls.jsonl.1`, `llm_calls.jsonl.2`, `llm_calls.jsonl.3`).

### Disabling Logs & Ghost Mode (`--no-logs`)

To prevent any data exfiltration of confidential repository code, queries, or model outputs to disk, run with `--no-logs`:

```bash
bin/nightmare --no-logs
```

When `--no-logs` is active, NIGHTMARE enters zero-footprint ghost mode:
- **No LLM call logs**: `llm_calls.jsonl` is not written or created.
- **No disk transcripts**: The incremental transcript is not written to `transcript.md` (retained in RAM only; `/save [path]` can still export on explicit command).
- **No XDG footprint**: Does not create or update `workspace.json`, auto-bootstrapped `config.json`, or `calibrator.json` under `.config`, `.local/state`, or `.cache`.

### Permanent Log Disabling (System Configuration)

You can turn off logging permanently across all sessions by setting `"logging": false` in your global configuration (`~/.config/nightmare/config.json`) or workspace configuration (`~/.config/nightmare/workspaces/<workspace-id>/config.json`):

```json
{
  "logging": false
}
```

*Default Stance:* Logging is enabled by default to ensure observability, session diagnostics, and crash-safe transcripts, unless explicitly disabled by configuration or the `--no-logs` flag.

---

## 10. Troubleshooting & FAQs

### Q: `[Error: Mantle step error: ClientFailure - Error 404: {"error":"model '...' not found"}]`
**Cause**: The requested model is not downloaded in Ollama.  
**Resolution**:
1. Run `ollama list` to see installed models.
2. Pull the model using `ollama pull <model-name>`.
3. Or switch models in NIGHTMARE via `/model <model-name>` or `-m <model-name>`.

### Q: `Fatal Security Violation: Path traversal violation`
**Cause**: An operation attempted to reference a file outside the workspace root (e.g. `../../etc/passwd` or an external symlink).  
**Resolution**: NIGHTMARE strictly confines all operations to the workspace root. Keep all target files within the project repository.

### Q: `Connection refused - connect(2) for "127.0.0.1:11434"`
**Cause**: Ollama is not running.  
**Resolution**: Start the Ollama daemon:
```bash
ollama serve
```

### Q: How do I permanently change my default model?
**Resolution**: Create or edit `~/.config/nightmare/config.json`:
```json
{
  "model": "huihui_ai/Qwen3.8-abliterated:latest"
}
```
