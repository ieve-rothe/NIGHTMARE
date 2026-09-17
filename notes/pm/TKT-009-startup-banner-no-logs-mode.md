---
ID: TKT-009
Title: Startup Banner Suppresses Config and State Directories in --no-logs Mode
Status: Closed
Priority: Med
---

## 1. User Need
When launching NIGHTMARE with `--no-logs` (ghost mode), the system runs in zero-footprint memory-only mode where no configuration files or log files are written to disk. However, the startup banner previously continued to display paths for `Config` and `State/Logs` directories (`~/.config/nightmare/...` and `~/.local/state/nightmare/...`). This misled operators into believing directories were being populated or persistent logs were being created. Instead, the startup banner should explicitly show that the session is running in `--no-logs` mode with nothing persisted.

## 2. Specification
1. Extend `Nightmare::Workspace::Environment`:
   - Add property `getter? no_log : Bool`.
   - Accept optional `no_log : Bool = false` in `initialize` and `self.resolve`.
   - Update `Environment#startup_banner(no_log : Bool? = nil)` to inspect `active_no_log = no_log.nil? ? @no_log : no_log`.
   - When `no_log` is active, render:
     - `│ Workspace : <path> │`
     - `│ Mode      : --no-logs (nothing is persisted) │`
     - Suppress `Config` and `State/Logs` directory display rows.
     - Preserve uniform Unicode box borders (`┌── NIGHTMARE ───┐`, `└────┘`), right-padding to the minimum width of 76 characters.
2. Update `Nightmare::REPL`:
   - In `REPL#start`, invoke `puts @env.startup_banner(no_log: @no_log)`.
3. Update `Nightmare::CLI`:
   - In `Nightmare.run`, forward `options.no_log` to `Workspace::Environment.resolve(..., no_log: options.no_log)`.
4. Automated Testing:
   - In `spec/workspace_spec.cr`, add test asserting `--no-logs` banner renders `Mode : --no-logs (nothing is persisted)` and excludes `Config` and `State/Logs`.
   - In `spec/ghost_mode_spec.cr`, add test verifying `env.startup_banner(no_log: repl.no_log?)` displays the suppressed persistence mode.
5. Documentation:
   - Update `docs/guide/01-quickstart.md` to document the banner appearance under `--no-logs` mode.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Run `crystal spec spec/workspace_spec.cr spec/ghost_mode_spec.cr`
  - Run full test suite: `crystal spec`
* **Verification Evidence:**
  - `crystal spec`: 229 examples, 0 failures, 0 errors, 0 pending (1.83s).
* **Validation Plan:**
  - Verify that running with `--no-logs` displays a 4-line banner showing Workspace and Mode without Config or State/Logs paths.
* **Validation Evidence:**
  - Verified banner renders:
    ```text
    ┌── NIGHTMARE ────────────────────────────────────────────────────────┐
    │ Workspace : /home/cam/projects/my-app                               │
    │ Mode      : --no-logs (nothing is persisted)                        │
    └─────────────────────────────────────────────────────────────────────┘
    ```
  - Formatted box width remains aligned and identical across all lines.

## Open Questions & Concurrency Concerns
* None. Banner formatting is purely synchronous, deterministic, and read-only.

## 4. Revision History
* 2026-09-17: Ticket created and closed to track completed implementation of --no-logs startup banner suppression.
---
