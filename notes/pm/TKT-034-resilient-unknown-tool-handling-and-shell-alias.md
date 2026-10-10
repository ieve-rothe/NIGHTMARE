---
ID: TKT-034
Title: Resilient Unknown Tool Handling in Mantle Step and Shell Tool Alias in Nightmare
Status: Resolved
Priority: High
---

## 1. User Need
When an LLM agent produces a tool call for an unknown, alternate, or hallucinated tool name (such as invoking `shell` when only `run_command` is advertised), users need the execution harness to handle the mismatch gracefully. The agent must receive an informative tool-result error message that lists the available tools, enabling it to self-correct in the subsequent iteration without losing session state or crashing. Furthermore, because local and smaller LLMs frequently invoke `shell` for shell execution, the tool registry must support known aliases so execution succeeds transparently.

## 2. Specification
1. **Resilient Unknown Tool Feedback in `Mantle::Step` (`mantle/src/mantle/steps/step.cr`)**:
   - When the LLM outputs a tool call whose name does not match any registered tool in `@tools` (and is not handled by `@tool_callback`):
     - Do not abort the step with a terminal `StepError::ToolExecutionFailure`.
     - Construct a tool error response JSON string: `{"error": "Unknown tool '<tool_name>'. Available tools: <tool_1>, <tool_2>, ..."}`. If `@tools` is empty, report `"No tools are currently available."`.
     - Append this error as a `Mantle::Message` with role `"tool"` and the corresponding `tool_call_id` to `working_messages`.
     - Continue the loop so the model can inspect the error and self-correct on the next iteration.
   - If a terminal tool execution failure must still be returned (e.g. fatal unhandled exception or unrecoverable error), ensure `error_message` is always populated rather than `nil`.

2. **Tool Alias Support in `Mantle::Tools::Tool` (`mantle/src/mantle/tools/tools.cr`)**:
   - Add property `aliases : Array(String) = [] of String` to `Mantle::Tools::Tool`.
   - In `Mantle::Step#run`, match tool calls against both primary name and aliases: `tool_def = @tools.find { |t| t.function.name == fn_name || t.aliases.includes?(fn_name) }`.
   - Ensure tools sent to the inference client (`client.execute`) only advertise the primary canonical function name, conserving prompt tokens and preventing model confusion from duplicate schema entries.

3. **Register `shell` Alias in Nightmare (`nightmare/src/nightmare/tools/registry.cr`)**:
   - Set `tool.aliases = ["shell"]` on the tool created by `build_run_command_tool` in both `build_tools` and `build_subagent_tools`.
   - Aligns the registry with `Nightmare::UI::TurnPresenter` (`turn_presenter.cr:275`), which already expects and renders `"shell"` alongside `"run_command"`.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - `mantle/spec/mantle/steps/step_spec.cr`:
    - Add unit spec verifying that calling an unknown tool does not crash with `ToolExecutionFailure`; instead, it appends a tool error message with available tools and allows the model to self-correct.
    - Add unit spec verifying that calling a tool via an alias defined in `tool.aliases` invokes the underlying tool handler successfully.
  - `nightmare/spec/tools_spec.cr`:
    - Verify that invoking `"shell"` executes through the `run_command` pipeline, respecting allowlists and process group isolation.
  - Run `crystal spec` in `mantle/` and `nightmare/`.
* **Verification Evidence:**
  - `mantle/spec/mantle/steps/step_spec.cr`: verified both unknown-tool self-correction and alias execution unit specs passed (19 examples, 0 failures).
  - `mantle`: full test suite passed cleanly (`crystal spec`: 340 examples, 0 failures, 0 errors, 0 pending).
  - `nightmare/spec/tools_spec.cr` and `nightmare/spec/harness_spec.cr`: verified tool alias configuration, alias dispatch, and unknown-tool recovery.
  - `nightmare`: full test suite passed cleanly (`crystal spec`: 332 examples, 0 failures, 0 errors, 0 pending).
* **Validation Plan:**
  - Replay / simulate the scenario from workspace `kasten-beed8f62` where an LLM calls `shell({"command": "head -n 50 tmp/evaluate_frontmatter.sh"})`: verify that the command executes or self-corrects without encountering `[Error: Mantle step error: ToolExecutionFailure]`.
* **Validation Evidence:**
  - `nightmare/spec/harness_spec.cr`: added integration tests verifying that calling `"shell"` routes directly to `run_command` in `StepRunner`, and unknown tool calls yield self-correction responses rather than terminal crashes.

## Open Questions & Concurrency Concerns
* Concurrency: `Mantle::Step` remains stateless with pure message arrays; adding aliases is purely additive on immutable tool configurations.
* Prompt Overhead: Aliases are resolved locally during tool dispatch and omitted from the client tool schemas, introducing zero additional token overhead in model context.

## 4. Revision History
* 2026-10-10: Created ticket following postmortem investigation of crash in `kasten-beed8f62`.
---
