---
ID: TKT-013
Title: Slash Command for Sidechannel LLM Turn (Dispatch Recipes)
Status: Open
Priority: Med
---

## 1. User Need
The user wants a way to quickly trigger specialized, "canned" subagent tasks without manually typing long, repetitive system prompts. This is useful for recurring tasks like security audits, code reviews, or design evaluations where a specific persona and output format are required.

## 2. Specification
- Implement a new slash command (e.g., `/delegate <role_name> <target_file>`).
- The command should look up a "role overlay" file in a configured directory (e.g., `~/.config/nightmare/roles/<role_name>.md`).
- The command should:
    1. Read the content of the target file.
    2. Prepend the instructions from the role overlay file.
    3. Execute a new, isolated LLM turn (a child subagent) with these instructions.
    4. The subagent should have its own tool-calling capabilities and depth (configurable).
    5. Append the resulting output from the subagent to the target file under a specific markdown header (e.					e.g., `## [Role Name] Analysis`).
- The system should support multiple roles defined by separate markdown files.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
    * Create a dummy role overlay file `test_role.md`.
    * Create a dummy target file `test_target.md`.
    * Run `/delegate test_role test_target.md`.
    * Verify that `test_target.md` is updated with the output of the subagent.
    * Verify that the subagent used the instructions from `test_role.md`.
* **Validation Plan:**
    * Use the command for a real-world task (e.g., a quick code review of an existing file) and ensure the output is useful and correctly formatted.

## Open Questions & Concurrency Concerns
* Where exactly should the roles directory be located? (User suggested `~/.config/nghtmare/roles/`).
* How to handle errors if the role file or target file does not exist?
* Should the subagent's depth and tool-calling iterations be globally configurable or per-role?

## 4. Revision History
* [2024-05-22]: Initial creation.
---
