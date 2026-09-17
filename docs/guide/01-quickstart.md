# Quickstart

NIGHTMARE is a locally-hosted, agentic developer REPL that operates directly on your filesystem. This guide covers building the binary from source, launching your first session, and configuring basic runtime parameters.

## Prerequisites

Ensure your system meets the minimum requirements before building.

| Requirement | Version/Notes |
|---|---|
| Crystal | `>= 1.21.0` |
| Ollama | Running locally |

> [!NOTE]
> NIGHTMARE defaults to the `qwen2.5-coder:7b` model. Ensure you have pulled it via `ollama run qwen2.5-coder:7b` or specify an alternate model at launch.

## Building NIGHTMARE

Compile the binary using shards. This produces an executable in the `bin/` directory.

```bash
# From the project root
shards build

# Verify the build
./bin/nightmare --version
```

## First Run Examples

Launch NIGHTMARE by providing a target directory or using the current working directory. The target directory becomes the root of the workspace.

```bash
# Launch in current directory
./bin/nightmare

# Launch with a specific workspace path
./bin/nightmare ~/projects/my-app

# Launch with a specific model
./bin/nightmare -m llama3.2

# Launch with a custom system prompt
./bin/nightmare -s ~/prompts/code_review.md
```

## The Startup Banner

Upon launch, NIGHTMARE displays a banner summarizing the workspace boundaries and storage locations.

```text
┌── NIGHTMARE ────────────────────────────────────────────────────────┐
│ Workspace : /home/cam/projects/my-app                               │
│ Config    : ~/.config/nightmare/workspaces/my-app-a1b2c3d4/         │
│ State/Logs: ~/.local/state/nightmare/workspaces/my-app-a1b2c3d4/    │
└─────────────────────────────────────────────────────────────────────┘
```

| Field | Description |
|---|---|
| **Workspace** | The canonical root path of the session. The agent cannot read or write outside this boundary. |
| **Config** | Location of workspace-specific configurations (e.g., allowlists, saved prompts). |
| **State/Logs** | Location of runtime state and logs (e.g., `llm_calls.jsonl`). |

In `--no-logs` mode, disk configuration and state/log folders are not created or persisted. The banner reflects zero-persistence ghost mode:

```text
┌── NIGHTMARE ────────────────────────────────────────────────────────┐
│ Workspace : /home/cam/projects/my-app                               │
│ Mode      : --no-logs (nothing is persisted)                        │
└─────────────────────────────────────────────────────────────────────┘
```

## CLI Flags Reference

Use command-line flags to override default behaviors for the current session.

| Flag | Argument | Description |
|---|---|---|
| `-s, --system` | `PATH` | Path to custom system prompt file (overrides all defaults) |
| `-m, --model` | `MODEL` | Select model provider or alias (default: `qwen2.5-coder:7b`) |
| `--no-logs, --no-log` | | Disable LLM interaction logging and run in zero-footprint ghost mode |
| `--markdown` | | Enable ANSI markdown formatting in terminal (default) |
| `--no-markdown` | | Disable ANSI markdown formatting in terminal |
| `-v, --version` | | Show NIGHTMARE version |
| `-h, --help` | | Show help and command-line usage information |

---
**Next:** [Workspace & Storage](02-workspace-and-storage.md)
