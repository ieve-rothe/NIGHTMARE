---
ID: TKT-014
Title: Integrate Tavily Search Service as a Web Search Tool in Mantle
Status: Closed
Priority: Med
---

## 1. User Need
The agent needs the ability to perform real-time web searches to retrieve up-to-date information from the internet, as its internal knowledge is limited to its training data and the provided context.

## 2. Specification
Implement a new `WebSearch` tool in MANTLE using the Tavily API.

### Technical Requirements:
* **API Integration:**
    * Endpoint: `POST https://api.tavily.com/search`
    * Authentication: Bearer Token via `Authorization` header (`Authorization: Bearer <TAVILY_API_KEY>`) and `api_key` payload attribute.
    * Request Body: JSON containing `query`, `search_depth` (optional), and `max_results` (optional).
    * Response Parsing: Extract `query`, `answer` (if available), and `results` (array of `url`, `content`, `title`).
* **Implementation Details:**
    * Create `mantle/src/mantle/tools/builtin/web_search.cr`.
    * Register the new tool in `mantle/src/mantle/tools/builtin.cr`.
    * Use `HTTP::Client` with HTTPS (`URI.parse("https://api.tavily.com")`) and `JSON` from the Crystal standard library.
    * Support configuration of `TAVILY_API_KEY` via environment variables.
* **Tool Interface:**
    * Provide `WebSearch.create : Mantle::Tools::Tool` (parameterless) and `WebSearch.create(_sandbox : FileSystemSandbox) : Tool` for backwards compatibility with sandbox tool aggregations.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
    * Unit test for `WebSearch` definition, parameter validation, schema serialization, and missing API key error handling in `mantle/spec/builtin_tools_spec.cr`.
    * Verify tool registration in `Mantle::Tools::Builtin.all(sandbox)`.
* **Verification Evidence:**
    * `crystal spec` in `mantle`: 300 examples, 0 failures, 0 errors.
    * `shards build` in `mantle`: Clean compile.
* **Validation Plan:**
    * Execute tool invocation with missing arguments and ensure graceful error JSON return.
* **Validation Evidence:**
    * Verified schema validation and environment variable presence checks in `builtin_tools_spec.cr`.

## 4. Revision History
* 2026-09-25: Implemented and closed with full spec suite coverage and HTTPS fixes.
* 2025-05-22: Initial ticket creation.
---
