# NIGHTMARE User's Guide

A workspace-anchored AI agent harness with a deterministic plan orchestrator, powered by local LLMs via Ollama and Mantle.

---

## Guide Chapters

| # | Chapter | Summary |
|---|---------|---------|
| 1 | [Quickstart](docs/guide/01-quickstart.md) | Prerequisites, build, first run |
| 2 | [Workspace & Storage](docs/guide/02-workspace-and-storage.md) | Workspace anchoring, XDG layout, zero litter |
| 3 | [Configuration](docs/guide/03-configuration.md) | Config hierarchy, model selection, system prompts, themes |
| 4 | [Tools](docs/guide/04-tools.md) | Read-only, mutation, shell, and subagent tools |
| 5 | [Approval Boundary](docs/guide/05-approval-boundary.md) | Diff modals, command modals, allowlist, security |
| 6 | [Context Engine](docs/guide/06-context-engine.md) | Turn management, token calibration, shedding, spend caps |
| 7 | [Execution Pipeline](docs/guide/07-execution-pipeline.md) | Multi-tier loop hierarchy, middleware, retry/recovery |
| 8 | [Plan Orchestrator](docs/guide/08-plan-orchestrator.md) | Autonomous multi-item plans, worktrees, verification gates |
| 9 | [Commands](docs/guide/09-commands.md) | Slash command reference |
| 10 | [Signals & Interruption](docs/guide/10-signals-and-interruption.md) | Ctrl+C handling, turn rollback, side-effect tracking |
| 11 | [Observability](docs/guide/11-observability.md) | Audit logging, ghost mode, transcripts |
| 12 | [Settings Reference](docs/guide/12-settings-reference.md) | Complete config.json field reference |
| 13 | [Troubleshooting](docs/guide/13-troubleshooting.md) | Common errors and FAQs |

---

## Quick Reference

```bash
# Build
shards build

# Launch (current directory, default model)
bin/nightmare

# Launch with specific model
bin/nightmare -m qwen2.5-coder:7b

# Launch targeting a workspace
bin/nightmare /path/to/project

# Launch in ghost mode (zero disk footprint)
bin/nightmare --no-logs
```

## Core Tenets

1. **Zero Repository Litter** — Config, logs, and caches live in XDG directories, never in your project tree.
2. **Strict Workspace Containment** — All operations confined to workspace root. Path traversal and `.git/` writes are blocked.
3. **Anti-Fatigue Approval Boundary** — Reads are autonomous. Mutations show diffs. Shell commands prompt for approval.
4. **Deterministic Execution Harness** — Typed outcomes, loop detection, self-healing retries, and context overflow recovery.
