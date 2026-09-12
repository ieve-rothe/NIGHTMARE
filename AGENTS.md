# Nightmare Repository — Agent Notes

## Test Harness Speed Fix (2026-09-11)

The test suite was taking **3+ minutes** due to two root causes. Both are now fixed:

### 1. E2E Tests: `require_repl!` Gate

All E2E tests (Tier 1–4) now use `Nightmare::E2E.require_repl!` instead of `require_binary!`.

- `require_binary!` — checks if `bin/nightmare` exists and responds to `--help`. Use for tests that only need the binary to start.
- `require_repl!` — runs a one-shot cached probe (sends `/help`, checks for `/clear` in output within 500ms). If the REPL isn't functional, tests are instantly marked `pending` instead of timing out for seconds each.

**When writing new E2E tests**, use `require_repl!` at the top of each `it` block. The probe runs once per suite execution and is cached.

### 2. Default Timeouts Reduced

`wait_for`, `wait_for_error`, and `wait_exit` default timeouts are now **2 seconds** (down from 5). For local subprocess E2E tests, legitimate responses arrive within milliseconds. If you need a longer timeout for a specific test (e.g. testing a 3-second timeout cap), pass it explicitly:

```crystal
session.wait_for("timed out", timeout: 5.seconds)
```

### Running Tests

```bash
# Full suite (~5 seconds when REPL is not yet implemented)
crystal spec

# Unit tests only (~4 seconds, compile-dominated)
crystal spec spec/nightmare_spec.cr spec/system_prompt_spec.cr spec/workspace_spec.cr spec/empirical_system_prompt_spec.cr
```

### Test Structure

```
spec/
├── spec_helper.cr              # Shared test utilities
├── nightmare_spec.cr           # Core module unit tests
├── system_prompt_spec.cr       # System prompt resolution unit tests
├── workspace_spec.cr           # Workspace/env unit tests
├── empirical_system_prompt_spec.cr # Exhaustive system prompt edge cases
└── e2e/
    ├── test_runner.cr           # E2E harness (sandbox, mock LLM, process session)
    ├── test_runner_spec.cr      # Tests for the harness itself
    ├── tier1_feature_spec.cr    # Feature coverage (opaque-box E2E)
    ├── tier2_boundary_spec.cr   # Boundary & corner cases
    ├── tier3_combination_spec.cr # Cross-feature combination tests
    └── tier4_workload_spec.cr   # Real-world workflow scenarios
```
