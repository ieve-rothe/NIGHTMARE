---
ID: TKT-016
Title: Integrate WebSearch Tool into Nightmare Registry
Status: Closed
Priority: Med
---

## 1. User Need & Scope
- **Target Repository:** `nightmare`
- **Scope Description:** Integrate the `WebSearch` tool from the `Mantle` library into the `Nightmare::Tools::Registry` so that both the main agent and subagents can perform real-time web searches using the Tavily API.

## 2. Specification & Implementation Plan
### Analysis Summary
- **Tool Source**: `mantle/src/mantle/tools/builtin/web_search.cr` provides `Mantle::Tools::Builtin::WebSearch`.
- **Resolution**: Rather than duplicating HTTP client code inside `Registry`, `Mantle::Tools::Builtin::WebSearch.create` was made parameterless (independent of `FileSystemSandbox`). `Nightmare::Tools::Registry` simply delegates via `build_web_search_tool`.

### Implementation Steps
1. **Registry Integration**:
   - Added `build_web_search_tool` in `nightmare/src/nightmare/tools/registry.cr`:
     ```crystal
     private def build_web_search_tool : Mantle::Tools::Tool
       Mantle::Tools::Builtin::WebSearch.create
     end
     ```
   - Added `build_web_search_tool` to `build_tools` (primary agent).
   - Added `build_web_search_tool` to `build_subagent_tools` (subagents).

## 3. Verification & Validation (V&V)
- **Verification Plan:**
    1. **Compile Check**: Run `shards build` to ensure clean compilation.
    2. **Unit Tests**: Add tests in `spec/tools_spec.cr` verifying presence of `web_search` in both `build_tools` and `build_subagent_tools`, and testing error responses when required parameters or API keys are missing.
- **Verification Evidence:**
    - `crystal spec`: 257 examples, 0 failures, 0 errors.
    - `shards build`: Built `nightmare` binary cleanly.
- **Validation Plan:**
    - Verify schema serialization and execution error handling through `Registry#build_tools`.
- **Validation Evidence:**
    - Specs in `spec/tools_spec.cr` confirmed parameter and API key validation.

## 4. Outcome & Integration
- **Status:** Closed
- **Summary:** WebSearch tool integrated into `Nightmare::Tools::Registry` for primary and subagent loops, backed by `Mantle::Tools::Builtin::WebSearch`.
---
