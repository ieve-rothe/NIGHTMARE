# Project Plan: NIGHTMARE REPL

## Objective
Implement NIGHTMARE, a standalone, human-in-the-loop developer REPL in Crystal for general-purpose text and task execution based on docs/DESIGN.md, docs/ARCHITECTURE.md, ORIGINAL_REQUEST.md, linking local frameworks ../mantle and ../salamander.

## Execution Phases

### Phase 0: Survey & Requirements Mining
- Spawn 3 parallel survey explorers / spec miners:
  1. `spec_miner_1`: Exhaustive extraction of requirements from `docs/DESIGN.md`, `docs/ARCHITECTURE.md`, and `ORIGINAL_REQUEST.md`.
  2. `explorer_mantle_salamander`: Deep-dive analysis of local frameworks `../mantle` and `../salamander` (APIs, step runner, sum types, streaming, terminal UI, signal handling).
  3. `explorer_workspace`: Audit current `nightmare` repo status (shard.yml, current files, directory structure, build/spec readiness).
- Aggregate findings into `PROJECT.md` (§ Architecture, § Feature Inventory, § Code Layout, § Milestones, § Interface Contracts).

### Phase 1: Dual-Track Decomposition
- **Track A: E2E Testing Track**
  - Establish opaque-box requirement-driven testing harness and runner.
  - Author test suites across Tiers 1-4 (Feature coverage, Boundary/Corner, Cross-Feature Pairwise, Real-world Scenarios).
  - Publish `TEST_READY.md`.
- **Track B: Implementation Track**
  - Milestone 1: Core Architecture, Workspace Anchoring & Central XDG Mapping (R1).
  - Milestone 2: Ephemeral Context Engine, Turn-Unit Pruning & In-Turn Shedding (R2).
  - Milestone 3: Sandboxed Tool Suite & Anti-Fatigue Approval Boundary (R3).
  - Milestone 4: Mantle Step Harness & Typed Result Sum Types (R4).
  - Milestone 5: Interactive Salamander REPL, Token Streaming, Signal Handling & Slash Commands (R5).

### Phase 2: Track Execution & Gating
- Iterate through each milestone via Explorer -> Worker -> Reviewer -> Challenger -> Forensic Auditor cycle.
- Enforce zero tolerance for shortcuts, hardcoded mocks, or cheating.

### Phase 3: Final E2E Milestone & Coverage Hardening
- Phase 3A: Pass 100% of E2E test suite (Tiers 1-4) with zero warnings and zero failures.
- Phase 3B: Adversarial coverage hardening (Tier 5) with Challenger stress testing.

### Phase 4: Final Verification & Handover
- Verify all acceptance criteria:
  - `shards build` clean with 0 warnings/errors.
  - `crystal spec` passing 100%.
  - Path traversal and security boundaries verified.
  - Context pruning and tool shedding verified.
  - UI/Signal handling and prompt editing verified.
- Compile final verification report for parent.
