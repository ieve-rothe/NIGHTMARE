---
ID: TKT-001
Title: Rename Directives Terminology to System Prompt Across Codebase
Status: Open
Priority: Med
---

## 1. User Need
Developers and users working with `nightmare` find the term "Directives" idiosyncratic and confusing compared to standard LLM ecosystem conventions. Replacing "Directives" with "System Prompt" (or "System Instructions") establishes clear, canonical naming across documentation, code modules, CLI options, and internal APIs.

## 2. Specification
1. Refactor module namespace and file structure:
   - Rename `src/nightmare/directives/` to `src/nightmare/system_prompt/` (or similar agreed-upon path).
   - Rename `Nightmare::Directives` module to `Nightmare::SystemPrompt`.
   - Update `DirectiveBuffer` to `SystemPromptBuffer` (or `PromptBuffer`).
2. Update references in core runtime and context store:
   - `SlidingStore#assemble_messages(directive: ...)` parameters to `system_prompt: ...`.
   - Error messages, logs, and comments referring to system directives.
3. Update unit and empirical specs:
   - Rename `spec/directives_spec.cr` and `spec/empirical_directives_spec.cr`.
   - Update all spec descriptions and assertions.
4. Align documentation:
   - Update `docs/DESIGN.md`, `docs/ARCHITECTURE.md`, `docs/ARCHITECTURE_R3.md`, and `AGENTS.md` to reference system prompts/instructions.
5. CLI & REPL alignment:
   - Verify `-s` / `--system` flag and `/prompt` command consistency.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Run full test suite: `crystal spec`
  - Ensure zero regressions in unit specs: `crystal spec spec/system_prompt_spec.cr spec/empirical_system_prompt_spec.cr`
  - Verify clean compilation of `bin/nightmare`.
* **Verification Evidence:**
  - *Pending execution.*
* **Validation Plan:**
  - Verify that running `nightmare --help` and `/prompt` in the REPL uses consistent, standard terminology.
* **Validation Evidence:**
  - *Pending execution.*

## Open Questions & Concurrency Concerns
* Decide whether to alias `Nightmare::Directives` temporarily for backwards compatibility if external modules rely on it, or perform a clean cut.
* Confirm exact convention: `system_prompt` vs `system_instruction`.

## 4. Revision History
* 2026-09-11: Ticket created based on user request to standardize directives naming.
---
