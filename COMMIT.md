# Nightmare — Commit & Versioning Guide

> This file extends the workspace-level [COMMIT.md](../COMMIT.md).
> Read that first for general conventions. This file covers Nightmare-specific details.

## Project Identity

- **Type:** Crystal application (CLI agent harness)
- **License:** AGPL-3.0
- **Current version:** See `shard.yml`

## Version File Locations

When bumping the version, update **all three** of these files in the same commit:

| File | Field | Example |
|:---|:---|:---|
| `shard.yml` | `version:` | `version: 0.4.0` |
| `src/nightmare.cr` | `VERSION =` (line 34) | `VERSION = "0.4.0"` |
| `spec/nightmare_spec.cr` | `VERSION.should eq` (line 5) | `Nightmare::VERSION.should eq("0.4.0")` |

All three MUST match. Forgetting one will cause either a runtime mismatch or a
spec failure.

## Common Scopes

Use these scopes in commit messages where applicable:

| Scope | Covers |
|:---|:---|
| `harness` | StepRunner, turn loop, subagent orchestration |
| `tools` | Tool registry, tool middleware, individual tools |
| `ui` | Terminal UI, approval modals, response cards, HUD |
| `context` | Context engine, shedding, calibration, guards |
| `security` | Sandbox, path validation, injection prevention |
| `repl` | REPL loop, slash commands, multiline entry |
| `plan` | Plan orchestration, deterministic gates |
| `integration` | Integration test workflows |
| `pm` | Project management ticket bookkeeping |

## What Counts as Public API

Nightmare is an application, not a library — but it still has versioned
surfaces that affect users and downstream consumers:

- **Slash commands** (`/recover`, `/skill`, etc.) — adding one is MINOR,
  removing or renaming one is MAJOR
- **CLI flags** (`--no-logs`, `-v`, etc.) — same as above
- **Tool schemas** (the JSON tool definitions sent to the LLM) — changing
  parameter names, types, or removing tools is MAJOR
- **Config file format** (`config.json` keys) — removing or renaming keys is MAJOR
- **State file schemas** (`schema_version` in plan/run state) — changing
  serialization format is MAJOR (bump the internal schema_version too)

Internal classes, private methods, and prompt text are not versioned surfaces.

## Pre-1.0 Note

Nightmare is pre-1.0. The `0.x` prefix signals that the API is still
stabilizing, but SemVer semantics still apply: features bump the minor
(`0.4.0`), fixes bump the patch (`0.3.6`). When the core interfaces feel
stable, bump to `1.0.0`.
