---
ID: TKT-001
Title: Rename Directives Terminology to System Prompt Across Codebase
Status: Closed
Priority: Med
---

## 1. User Need
Developers and users working with `nightmare` find the term "Directives" idiosyncratic and confusing compared to standard LLM ecosystem conventions. Replacing "Directives" with "System Prompt" (or "System Instructions") establishes clear, canonical naming across documentation, code modules, CLI options, and internal APIs.

## 2. Specification
1. Refactor module namespace and file structure:
   - Rename `src/nightmare/directives/` to `src/nightmare/system_prompt/`.
   - Rename `Nightmare::Directives` module to `Nightmare::SystemPrompt`.
   - Update `DirectiveBuffer` to `SystemPromptBuffer`.
2. Update references in core runtime and context store:
   - `SlidingStore#assemble_messages(system_prompt: ...)` parameter.
   - `StepRunner#run_turn(system_prompt: ...)` parameter.
   - Error messages, logs, and comments referring to system directives.
3. Update unit and empirical specs:
   - Rename `spec/directives_spec.cr` to `spec/system_prompt_spec.cr`.
   - Rename `spec/empirical_directives_spec.cr` to `spec/empirical_system_prompt_spec.cr`.
   - Update all spec descriptions and assertions.
4. Align documentation:
   - Update `docs/DESIGN.md`, `docs/ARCHITECTURE.md`, `docs/ARCHITECTURE_R3.md`, `UPDATE_ARCHITECTURE.md`, `USERS_GUIDE.md`, and `AGENTS.md` to reference system prompts.
5. CLI & REPL alignment:
   - Verify `-s` / `--system` flag and `/prompt` command consistency.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Run full test suite: `crystal spec`
  - Ensure zero regressions in unit specs: `crystal spec spec/system_prompt_spec.cr spec/empirical_system_prompt_spec.cr spec/shedder_and_store_spec.cr`
  - Verify clean compilation of `bin/nightmare`.
* **Verification Evidence:**
  - `crystal spec spec/system_prompt_spec.cr spec/empirical_system_prompt_spec.cr spec/shedder_and_store_spec.cr`: 43 examples, 0 failures, 0 errors, 0 pending (80.77ms).
  - Full test suite `crystal spec`: 222 examples, 0 failures, 0 errors, 0 pending (14.0s).
  - `shards build`: Successfully compiled `bin/nightmare`.
* **Validation Plan:**
  - Verify that running `nightmare --help` and `/prompt` in the REPL uses consistent, standard terminology.
* **Validation Evidence:**
  - Ran `bin/nightmare --help`, verified `-s PATH, --system=PATH` description and all help texts.
  - REPL `/prompt` and in-memory edit tested and confirmed working with RAM mutation without on-disk side effects.
  - Per operator direction ("No backwards compatibility, just break things!"), a clean cut was performed with zero backward compatibility aliases.

## Open Questions & Concurrency Concerns
* Decide whether to alias `Nightmare::Directives` temporarily for backwards compatibility if external modules rely on it, or perform a clean cut.
  - *Resolution*: Operator directed a clean cut with no backwards compatibility. All references migrated cleanly.
* Confirm exact convention: `system_prompt` vs `system_instruction`.
  - *Resolution*: `system_prompt` selected across all code, options, and APIs.

## 4. Revision History
* 2026-09-11: Ticket created based on user request to standardize directives naming.
* 2026-09-11: Clean-cut refactor executed across codebase, specs renamed and verified (222/222 passing), binary compiled, ticket closed.
---
