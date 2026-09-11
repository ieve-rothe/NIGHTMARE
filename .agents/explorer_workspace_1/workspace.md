# Nightmare Workspace Investigation Report

**Date**: 2026-09-11
**Investigator**: explorer_workspace_1 (Archetype: Explorer)
**Repository Target**: `/home/cam/repos/adjutant/nightmare`
**Original Parent / Orchestrator**: `3ad3ad0f-7c04-4b8b-8435-1ed5dba552db` (`.agents/orchestrator_1`)

---

## 1. Executive Summary

The `nightmare` repository is in an early scaffolding state, freshly generated via `crystal init app nightmare` with added design documentation. The repository compiles cleanly with `shards build`, but the default test suite currently fails because `spec/nightmare_spec.cr` contains the default scaffold placeholder assertion (`false.should eq(true)`). 

No external or sibling dependencies (`mantle`, `salamander`) are declared in `shard.yml`. The system environment provides working Crystal 1.21.0 and Shards 0.19.1 tooling, requiring `BypassSandbox: true` due to local sandbox socket unavailability. Sibling repositories `../mantle` and `../salamander` are present and accessible at the expected relative paths.

---

## 2. Directory Layout & File Inventory

### 2.1 File Tree
```
/home/cam/repos/adjutant/nightmare/
├── .agents/                        # Agent workspace directory (untracked)
│   ├── ORIGINAL_REQUEST.md         # Authoritative user requirements
│   ├── orchestrator_1/             # Parent orchestrator workspace
│   └── explorer_workspace_1/       # Current explorer workspace
├── docs/
│   ├── ARCHITECTURE.md             # System architecture & specification (11,268 bytes, untracked)
│   └── DESIGN.md                   # Concept of Operations & UX spec (27,321 bytes, tracked)
├── spec/
│   ├── nightmare_spec.cr           # Default placeholder spec (122 bytes)
│   └── spec_helper.cr              # Spec helper requiring spec & ../src/nightmare (42 bytes)
├── src/
│   └── nightmare.cr                # Entry point module Nightmare with VERSION = "0.1.0" (115 bytes)
├── .editorconfig                   # Standard 2-space indentation config (150 bytes)
├── .gitignore                      # Git ignore rules (50 bytes)
├── LICENSE                         # MIT License (1,082 bytes)
├── README.md                       # Scaffolded placeholder README (596 bytes)
└── shard.yml                       # Shards specification (157 bytes)
```

Generated / ignored build artifacts (after build execution):
- `bin/nightmare` (gitignored, binary executable)
- `lib/` (gitignored, empty directory)

### 2.2 Key File Contents

#### `shard.yml`
```yaml
name: nightmare
version: 0.1.0

authors:
  - ieve <ievemail@proton.me>

targets:
  nightmare:
    main: src/nightmare.cr

crystal: '>= 1.21.0'

license: MIT
```
*Observation*: No `dependencies` block is defined. Neither `../mantle` nor `../salamander` is referenced yet.

#### `src/nightmare.cr`
```crystal
# TODO: Write documentation for `Nightmare`
module Nightmare
  VERSION = "0.1.0"

  # TODO: Put your code here
end
```

#### `spec/spec_helper.cr`
```crystal
require "spec"
require "../src/nightmare"
```

#### `spec/nightmare_spec.cr`
```crystal
require "./spec_helper"

describe Nightmare do
  # TODO: Write tests

  it "works" do
    false.should eq(true)
  end
end
```

#### `.gitignore`
```
/docs/*
!/docs/*.md
/lib/
/bin/
/.shards/
*.dwarf
```

---

## 3. Toolchain & Environment Verification

| Tool | Command | Version / Output | Status |
|---|---|---|---|
| **Crystal Compiler** | `crystal -v` | `Crystal 1.21.0 (2026-07-23)`<br>`LLVM: 22.1.8`<br>`Default target: x86_64-pc-linux-gnu` | **Working** |
| **Shards Package Manager** | `shards --version` | `Shards 0.19.1 (2026-02-02)` | **Working** |
| **Sandbox Execution** | Default sandbox | Socket connection reset (`read unix @->@: recvmsg: connection reset by peer`) | **Requires BypassSandbox: true** |
| **Build** | `shards build` | Successfully compiles `bin/nightmare` | **Clean build** |
| **Test Runner** | `crystal spec` | 1 example, 1 failure (`false.should eq(true)`) | **Expected initial failure** |

*Tooling Note*: In Shards, running `shards -v` runs verbose dependency resolution and emits `shard.lock`. To print version without side effects, `shards --version` must be used.

---

## 4. Git Repository State

- **Branch**: `main`
- **Remotes**: None (`git remote -v` returns empty)
- **Commit History**:
  - `3bf744ac56a31e66d7d52e1a6f02cfcd364e8e8f` (HEAD -> main): `Initial commit: scaffold Nightmare app and design doc`
- **Submodules**: None (`git submodule status` returns empty)
- **Working Tree Status**:
  - Tracked changes: Clean (no modified files)
  - Untracked paths:
    - `.agents/`
    - `docs/ARCHITECTURE.md`

---

## 5. Dependency & Framework Analysis

### 5.1 Sibling Repositories

The project requirements specify linking to local sibling frameworks `../mantle` and `../salamander`.

1. **`../mantle`**:
   - Location: `/home/cam/repos/adjutant/mantle` (confirmed present)
   - Shard info: `name: mantle`, `version: 1.1.0`, `crystal: '>= 1.18.2'`
   - Test suite: Passed (303 examples, 0 failures, 0 errors, 0 pending). Working tree is clean.
   - Provides step runner (`Mantle::Step`), LLM client interfaces (`Mantle::Message`, `Mantle::Clients::ToolCall`), memory stores, and provider backends.

2. **`../salamander`**:
   - Location: `/home/cam/repos/adjutant/salamander` (confirmed present)
   - Shard info: `name: salamander`, `version: 0.2.0`, `crystal: '>= 1.18.2'`
   - Test suite: Passed (20 examples, 0 failures, 0 errors, 0 pending). Working tree is clean.
   - Already demonstrates path dependency pattern in its own `shard.yml`:
     ```yaml
     dependencies:
       mantle:
         path: ../mantle
       tts_kokoro:
         path: ../tts_kokoro
     ```
   - Provides terminal formatting, raw mode handling, streaming controls, and REPL components.

### 5.2 Required `shard.yml` Configuration for Nightmare
To satisfy requirement R6, `nightmare/shard.yml` must be configured with:
```yaml
dependencies:
  mantle:
    path: ../mantle
  salamander:
    path: ../salamander
```

---

## 6. Architecture & Design Alignment

The specifications in `docs/ARCHITECTURE.md` and `docs/DESIGN.md` outline a comprehensive architecture:

1. **Workspace Anchoring (`Nightmare::Workspace`)**: Canonical `Dir.current` realpath anchoring, deterministic XDG slug-hash path resolution (`~/.config/nightmare/...`, `~/.local/state/nightmare/...`), launch notification banner.
2. **System Directives (`Nightmare::Directives`)**: Strict 5-tier resolution order (CLI flag > repo `.nightmare/` > central workspace > central global > default persona) and in-memory editor buffer (`/prompt edit`).
3. **Context Engine (`Nightmare::Context`)**:
   - `SlidingStore`: In-memory turn-unit FIFO context store (never orphan tool pairs, never evict active user prompt).
   - `Shedder`: In-turn and historical tool output compressor (keeps last 2 tool outputs verbatim).
   - `TokenEstimator`: Self-calibrating character/token ratios updated via provider usage.
   - `PinnedFiles`: Re-reads pinned working files directly from disk on prompt assembly.
4. **Transcript Exporter (`Nightmare::Transcript`)**: Un-truncated parallel transcript in RAM exported cleanly via `/save`.
5. **Tool Suite (`Nightmare::Tools`)**:
   - Read-only tools (`list_files`, `search`, `read_file`, `file_info`): Auto-approved, `.git/` excluded.
   - Mutation tools (`replace_in_file`, `append_to_file`, `write_file`): Diff modal required on modifications; `.git/` modifications rejected.
   - Shell tool (`run_command`): Interactive approval `[y]`, `[N]`, `[e]`, `[a]`, `[p]`; auto-approval banned on metacharacters; process group isolation with closed stdin and timeout.
   - Model delegation (`ask_model`): Stateless remote LLM invocation.
6. **Mantle Step Harness (`Nightmare::Harness`)**:
   - Strict `Result(T) = Success(T) | Failure` sum-type boundary.
   - Exponential backoff with jitter on rate limits; single-turn schema format correction retry.
7. **Salamander REPL & Commands (`Nightmare::UI`, `Nightmare::Commands`)**:
   - Live token streaming, `<think>` isolation, terminal spinner.
   - `Ctrl+C` rolls back active turn without process exit.
   - Slash commands: `/clear`, `/cls`, `/drop`, `/save`, `/prompt [edit]`, `/review`, `/thinking`, `/model`, `/paste`, `/exit`.

---

## 7. Multi-Repository Workspace Compliance

As established in `/home/cam/repos/adjutant/AGENTS.md`:
1. `Cwd` must always be explicitly set when running commands (e.g. `Cwd: "/home/cam/repos/adjutant/nightmare"`).
2. Never join commands with `&&`, `;`, `||`, or pipes.
3. Use prefix-approvable command shapes (`git status`, `git diff`, `crystal spec`, `shards build`).
4. Note that `BypassSandbox: true` must be specified for execution in this environment.
