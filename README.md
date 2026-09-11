# NIGHTMARE

**NIGHTMARE** is a standalone, human-in-the-loop developer REPL in Crystal for plain text file manipulation and shell task execution, delegating local inference to Ollama via the Mantle framework.

It provides a predictable, low-fatigue agentic workflow anchored strictly to your workspace with strong security invariants and zero repository litter.

---

## Features

- **Strict Workspace Anchoring**: Operates strictly within `Dir.current.realpath`. Path traversal (`../`) and out-of-tree symlinks are rejected with `SecurityError`. Writes to `.git/` are strictly forbidden.
- **Zero Repository Litter**: No config or cache files in your project directory. All configuration, transcripts, audit logs, and token calibration state live in centralized XDG user directories (`~/.config/nightmare/`, `~/.local/state/nightmare/`, `~/.cache/nightmare/`), partitioned by deterministic workspace IDs (`<slug>-<hash>`).
- **Anti-Fatigue Approval Boundary**:
  - Autonomous read-only tools (`list_files`, `search`, `read_file`, `file_info`).
  - Interactive unified diff modal (`[y/N/a]`) for modifying existing files; new file creation is auto-approved.
  - Interactive shell modal (`[y/N/e/a/p]`) with isolated process groups, output capping, termination ladders, and a strict ban on auto-approving commands with shell metacharacters.
- **Ephemeral Context Engine**: Atomic turn-unit sliding window that never orphans tool pairs. Predictive in-turn shedding compresses older consumed tool results while preserving the last 2 verbatim. Dynamic token estimation self-calibrates against provider feedback.
- **Interactive REPL & Slash Commands**: ANSI markdown streaming, `<think>` block isolation, cooperative `Ctrl+C` interruption and turn rollback, and comprehensive slash commands (`/help`, `/clear`, `/cls`, `/save`, `/prompt`, `/review`, `/thinking`, `/model`, `/paste`, `/exit`).

---

## Quickstart

### Prerequisites

- [Crystal](https://crystal-lang.org/) (>= 1.10)
- [Ollama](https://ollama.com/) running locally (`http://127.0.0.1:11434`) with a model installed (e.g. `qwen2.5-coder:7b`, `huihui_ai/Qwen3.8-abliterated:latest`, `gemma4:26b`, etc.)

### Build

```bash
shards build
```

The compiled binary will be placed at `bin/nightmare`.

### Run

```bash
# Launch in the current directory with default model
bin/nightmare

# Launch with a specific model
bin/nightmare -m huihui_ai/Qwen3.8-abliterated:latest

# Launch targeting a specific workspace directory
bin/nightmare /path/to/project

# Launch with a custom system prompt file
bin/nightmare -s /path/to/custom_prompt.md
```

---

## Documentation

For a detailed walkthrough of configuration, slash commands, approval workflows, token budgets, and troubleshooting, refer to [USERS_GUIDE.md](USERS_GUIDE.md).
