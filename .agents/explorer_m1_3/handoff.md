# Milestone 1 Handoff Report: Shard Linkage, Workspace Layout & Directives Plan

**Author**: `explorer_m1_3`  
**Recipient**: `orchestrator_1` (Conv ID: `3ad3ad0f-7c04-4b8b-8435-1ed5dba552db`)  
**Scope**: Milestone 1 - Shard Linkage, Layout & Worker Implementation Plan (F1.1 - F1.8, F6.1)  
**Deliverable**: `/home/cam/repos/adjutant/nightmare/.agents/explorer_m1_3/m1_plan.md`

---

## 1. Observation

1. **Compiler Environment**:
   - Executed `crystal --version` in `/home/cam/repos/adjutant/nightmare`:
     ```text
     Crystal 1.21.0 (2026-07-23)
     LLVM: 22.1.8
     Default target: x86_64-pc-linux-gnu
     ```
   - Executed `shards --version` in `/home/cam/repos/adjutant/nightmare`:
     ```text
     Shards 0.19.1 (2026-02-02)
     ```
2. **Current Repository State**:
   - `nightmare/shard.yml` (lines 1-14) contains `targets: nightmare: main: src/nightmare.cr`, `crystal: '>= 1.21.0'`, but currently lacks a `dependencies:` block.
   - `nightmare/src/nightmare.cr` (lines 1-7) contains only a stub `module Nightmare; VERSION = "0.1.0"; end`.
   - `nightmare/spec/spec_helper.cr` (lines 1-3) contains `require "spec"` and `require "../src/nightmare"`.
   - `nightmare/spec/nightmare_spec.cr` (lines 1-10) contains a failing test assertion:
     ```crystal
     it "works" do
       false.should eq(true)
     end
     ```
3. **Local Framework Dependencies**:
   - `/home/cam/repos/adjutant/salamander/shard.yml` (lines 7-11) declares:
     ```yaml
     dependencies:
       mantle:
         path: ../mantle
       tts_kokoro:
         path: ../tts_kokoro
     ```
   - Executed `crystal spec` in `/home/cam/repos/adjutant/salamander`:
     `20 examples, 0 failures, 0 errors, 0 pending`.
   - Executed `crystal spec` in `/home/cam/repos/adjutant/mantle`:
     `303 examples, 0 failures, 0 errors, 0 pending`.
   - Executed `crystal build --no-codegen src/salamander.cr` in `salamander`:
     Clean exit 0 with zero warnings and zero errors.
   - Executed `crystal build --no-codegen src/mantle.cr` in `mantle`:
     Clean exit 0 with zero warnings and zero errors.
4. **Top-Level Spec Macro Guard**:
   - Tested Crystal macro constant detection:
     - Standalone: `{{ @top_level.has_constant?("Spec") }}` evaluates to `false`.
     - Spec execution (`require "spec"` first): `{{ @top_level.has_constant?("Spec") }}` evaluates to `true`.
   - Validated that `{% if !@top_level.has_constant?("Spec") %}` prevents CLI entrypoint execution when running `crystal spec`.
5. **Path Boundary Prefix Trap**:
   - Tested `target.starts_with?(root)` when `root = "/tmp/repo"` and `target = "/tmp/repo_evil"`.
   - Result: `target.starts_with?(root)` returns `true` (false positive vulnerability).
   - Validated boundary guard `target == root || target.starts_with?(root.ends_with?('/') ? root : "#{root}/")`, which evaluates to `false`.

---

## 2. Logic Chain

1. **Dependency Formulation**:
   - Observation 3 shows `salamander` depends on `mantle` and `tts_kokoro` via relative paths `../mantle` and `../tts_kokoro`.
   - Because `nightmare` resides in `/home/cam/repos/adjutant/nightmare`, its relative path to siblings is identically `../mantle`, `../salamander`, and `../tts_kokoro`.
   - Declaring all three path dependencies in `shard.yml` ensures offline hermetic installation without attempting any git network lookups during `shards install`.
2. **Build and Spec Compatibility**:
   - Observation 3 demonstrates that both `mantle` and `salamander` compile cleanly without warnings under Crystal 1.21.0.
   - Therefore, linking them into `nightmare` will satisfy Acceptance Criterion AC-B1 (`shards build` succeeds cleanly with zero compiler warnings or errors).
3. **Spec Runner Isolation**:
   - Observation 2 shows `spec_helper.cr` requires `../src/nightmare`.
   - Without guarding top-level code in `src/nightmare.cr`, `OptionParser` in the CLI entry point would attempt to parse spec runner arguments, causing crashes during `crystal spec`.
   - Observation 4 proves that wrapping CLI execution in `{% if !@top_level.has_constant?("Spec") %}` allows `src/nightmare.cr` to act as both the compiled binary entry point and a safely importable library for unit specs.
4. **Security Enclosure**:
   - Observation 5 establishes that naive substring prefix matching is vulnerable to path confusion attacks.
   - Applying the strict boundary delimiter check in `Environment#inside_root?` ensures full adherence to AC-S1, AC-S2, and F1.2.
5. **Zero Repo Litter & Directives Resolution**:
   - Partitioning all metadata into `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/` and `$XDG_STATE_HOME/nightmare/workspaces/<workspace_id>/` ensures no files are written into `@root` (F1.5).
   - Implementing `Directives::Resolver` with 5 prioritized branches (CLI flag > repo file > workspace config > global config > default persona) fulfills F1.6.
   - Providing `DirectiveBuffer` with tempfile spawning fulfills F1.8 (in-memory mutation leaving disk untouched).

---

## 3. Caveats

1. **External Sibling Repositories**:
   - This plan assumes `../mantle`, `../salamander`, and `../tts_kokoro` remain present at `/home/cam/repos/adjutant/`. They are local sibling repositories and must not be deleted or moved.
2. **Interactive Editor in CI/Headless Environments**:
   - Testing `DirectiveBuffer#edit!` in automated test suites requires passing an explicit editor command (e.g. `sed -i ...` or `true`) or setting `ENV["EDITOR"] = "true"`, as standard terminal editors like `nano` or `vim` block waiting for interactive TTY input.
3. **Subsequent Milestones Scope**:
   - Context engine (`SlidingStore`), Tools suite, Mantle step runner harness, and Salamander REPL loop belong to Milestones 2-5 and are purposefully omitted from Milestone 1 source files, leaving clean extension points.

---

## 4. Conclusion

Milestone 1 is fully specified, verified against the local compiler environment, and ready for worker implementation. The detailed blueprint in `m1_plan.md` provides:
- Complete file contents for `shard.yml`, `src/nightmare.cr`, `src/nightmare/workspace/manifest.cr`, `src/nightmare/workspace/environment.cr`, `src/nightmare/directives/resolver.cr`, and the spec files.
- An exact 11-step execution sequence for the worker.
- Verified test helpers and passing criteria.

The worker can execute the plan directly with zero ambiguity.

---

## 5. Verification Method

To independently verify the implementation:

1. **Verify Shards Installation**:
   ```bash
   # In /home/cam/repos/adjutant/nightmare (BypassSandbox: true)
   shards install
   shards check
   ```
   *Expected*: Zero errors, symlinks created in `lib/`, dependencies satisfied.

2. **Run All Unit Tests**:
   ```bash
   # In /home/cam/repos/adjutant/nightmare (BypassSandbox: true)
   crystal spec
   ```
   *Expected*: All tests pass (0 failures, 0 errors, 0 pending) across `nightmare_spec.cr`, `workspace_spec.cr`, and `directives_spec.cr`.

3. **Verify Clean Build**:
   ```bash
   # In /home/cam/repos/adjutant/nightmare (BypassSandbox: true)
   shards build
   ```
   *Expected*: Clean exit code 0 with zero warnings, binary created at `bin/nightmare`.

4. **Verify CLI Smoke Test**:
   ```bash
   ./bin/nightmare --version
   ./bin/nightmare --help
   ```
   *Expected*: Outputs version `0.1.0` and usage instructions cleanly.
