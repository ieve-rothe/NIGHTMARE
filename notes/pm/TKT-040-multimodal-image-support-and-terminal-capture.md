---
ID: TKT-040
Title: End-to-End Multimodal Image Support, Agent Image Inspection, and Terminal Clipboard Capture
Status: Resolved
Priority: High
---

## 1. User Need & Concept of Operations (CONOPS)

### 1.1 User Need
Operators running Nightmare with vision-capable local models on Ollama need first-class multimodal image support across both human-to-agent input and autonomous agent workspace inspection. Currently, `Mantle::Message` only carries text and tool metadata, `Nightmare::REPL` only reads cooked text lines via `@stdin.gets`, and `ReadOnly#read_file` treats all files as UTF-8 text lines.

### 1.2 Concept of Operations (CONOPS)
The multimodal workflow operates across three integrated flows:

1. **Flow A — Direct Terminal Clipboard Paste (`Ctrl+V` / `/clip`):**
   - The operator copies a screenshot or image to the system clipboard (Wayland `wl-paste` or X11 `xclip`/`xsel`).
   - In the Nightmare REPL prompt, pressing `Ctrl+V` (in raw-mode line editing) or invoking `/clip` (or `/img`) inspects clipboard MIME targets (`image/png`, `image/jpeg`, `image/webp`).
   - When an image is detected on the clipboard, Nightmare captures the binary payload, stages it in the current turn's `pending_images` queue, and immediately acknowledges capture in the terminal UI with an inline badge (e.g., `[Image #1: 1280×720 PNG, 184 KB]`).
   - When the operator submits their prompt text, Nightmare attaches the base64-encoded image(s) to the outgoing `user` `Mantle::Message` sent to Ollama's `/api/chat` endpoint.

2. **Flow B — File Path Attachment & Drag-and-Drop (`@path/to/img.png` & Bracketed Paste):**
   - The operator drags an image file into the terminal window (triggering bracketed paste `\e[200~...\e[201~`) or references `@path/to/image.png` inline in their prompt.
   - Nightmare resolves the path through `Tools::Guard#resolve_read`, validates the image format/magic bytes, strips or links the token in the prompt, displays `[Image #1: image.png]`, and attaches the base64 payload to the user turn.

3. **Flow C — Autonomous Agent Image Inspection (`read_file` on Image Files):**
   - During a tool loop, the agent invokes `read_file(path: "mockup.png")` to inspect a UI screenshot, diagram, or asset in the workspace.
   - `ReadOnly#read_file` detects binary image formats (`.png`, `.jpg`, `.jpeg`, `.webp`, `.gif`), bypasses line-numbered UTF-8 text pagination, validates file size caps, and returns structured metadata (`{"status": "image_loaded", "path": "mockup.png", "mime": "image/png", "bytes": 124500}`) for the `role: "tool"` message while staging the base64 image payload.
   - Immediately after the `role: "tool"` response(s) are appended, `Mantle::Step#run` injects a synthetic `role: "user"` message carrying `images: [base64]` (`"[Attached image from read_file('mockup.png')]"`), allowing the vision model to see the image on the very next inference iteration while preserving strict tool-call pairing invariants.
   - `TurnPresenter` renders a compact visual file badge (`🖼 mockup.png · 121.6 KB`) instead of a line-numbered code preview card.

---

## 2. Specification & Main Design Planning Points

### 2.1 Mantle Wire Protocol & Message Model (`mantle/src/mantle/clients/message.cr`)
- Extend `Mantle::Message` with an optional `images` field for Ollama `/api/chat` compatibility (raw base64 strings without `data:` URI prefixes):
  ```crystal
  @[JSON::Field(emit_null: false)]
  property images : Array(String)?
  ```
- Update `Mantle::Message#initialize` to accept `@images : Array(String)? = nil`.
- **Struct Rebuild Preservation:** Ensure any code that reconstructs a user `Mantle::Message` preserves `images`:
  - In `Mantle::Storage::SlidingStore#start_turn` (`mantle/src/mantle/storage/sliding_store.cr`), when prepending `[Previous turn was interrupted after modifying: ...]`, forward `images: msg.images`.

### 2.2 Token Calibration Isolation, Budgeting & Historical Image Shedding (`mantle/src/mantle/storage/` & `steps/tool_loop.cr`)
- **Calibrator Isolation:** `TokenEstimator#calibrate!` (`mantle/src/mantle/storage/token_estimator.cr`) computes `assembled_chars / prompt_eval_count` to calibrate the text chars-per-token divisor. Base64 image strings MUST NOT be included in `assembled_chars` passed to `calibrate!`, or a single 1 MB image (~1.33M base64 chars vs ~1,000 vision tokens) would corrupt `@divisor` to `10.0` (the clamp ceiling).
- **Fixed Per-Image Token Heuristic:** When estimating context tokens against `hardmax` in `SlidingStore#total_estimated_tokens` and `ToolLoop#handle_iteration`, add a configurable heuristic (e.g., `IMAGE_TOKEN_ESTIMATE = 1_000` tokens per attached image) on top of text token estimates when `last_prompt_tokens` is not yet available.
- **Historical Image Shedding (`Mantle::Storage::Shedder`):**
  - Base64 images retained in `@store.history` across turns quickly saturate both memory and vision context budgets.
  - Extend `Shedder.prune_history!` (and optionally a post-turn history compaction policy) to strip `images` arrays from older completed turns first (setting `msg.images = nil` and appending `"\n[... attached image shed from history]"` to `msg.content`, subtracting `IMAGE_TOKEN_ESTIMATE` per shed image) before evicting entire historical turns.

### 2.3 Observability & Log Redaction (`mantle/src/mantle/clients/logging_client.cr` & `nightmare/src/nightmare/transcript.cr`)
- **`LoggingClient` JSONL Redaction:** `LoggingClient#log_receipt` writes `prompt` and `raw_request` to `llm_calls.jsonl` on every iteration of a tool loop. To prevent multi-megabyte JSONL bloat:
  - Sanitize `prompt` and `raw_request` copies prior to serialization in `log_receipt` by replacing each base64 string in `images` with a compact digest descriptor: `"<base64_image: #{bytesize}b sha256:#{Digest::SHA256.hexdigest(b64)[0, 12]}>"`.
- **`Nightmare::Transcript` Formatting:** In `Transcript#format_message_markdown` (`nightmare/src/nightmare/transcript.cr`), if `msg.images` is present and non-empty, render an attachment summary line (`*Attached images: #{imgs.size}*`) rather than dumping raw base64 into `transcript.md`.

### 2.4 Agent Image Inspection & The Ollama `role: "tool"` Constraint (`nightmare/src/nightmare/tools/read_only.cr` & `mantle/src/mantle/steps/step.cr`)
- **Why Synthetic `role: "user"` Injection is Required:**
  - Across Ollama's `/api/chat` templates and runner implementations, `images` attached to `role: "tool"` messages are frequently ignored or rejected by model templates, whereas `images` on `role: "user"` messages are universally supported by Ollama vision models.
  - Furthermore, `Mantle::Storage::Turn#well_formed?` (`mantle/src/mantle/storage/turn.cr:112-150`) strictly requires every assistant `tool_call` ID to be paired with a matching `role: "tool"` message before any subsequent `role: "user"` message appears (`when "user"; return false unless open_calls.empty?`).
- **Dual-Message Tool Image Protocol:**
  1. **Detection in `ReadOnly#read_file`:**
     - Check file extension (`.png`, `.jpg`, `.jpeg`, `.webp`, `.gif`) and/or magic header bytes after `@guard.resolve_read(path)` and `File.exists?(full_path)`.
     - Enforce a maximum image file size limit (e.g. `max_image_bytes = 10 * 1024 * 1024`, configurable in `Settings`).
     - Read binary bytes and encode via `Base64.strict_encode(File.read(full_path))`.
     - Return a structured JSON payload or `Mantle::Tools::ToolResult` carrying both the text metadata for the `tool` message (`{"status": "image_loaded", "path": rel_path, "mime": mime_type, "size_bytes": file_bytes}`) and the base64 image attachment.
  2. **Synthetic User Message in `Mantle::Step#run` (`mantle/src/mantle/steps/step.cr`):**
     - After the `tool_calls.each` loop finishes appending all `role: "tool"` messages to `working_messages` (satisfying `open_calls.empty?`), if any tool execution in that batch produced image attachments, append a synthetic user message:
       ```crystal
       working_messages << Mantle::Message.new(
         role: "user",
         content: "[System: Loaded image(s) from #{loaded_paths.join(", ")} for visual inspection]",
         images: batch_images
       )
       ```
  3. **Active Turn Synchronization in `ToolLoop#sync_active_messages` (`mantle/src/mantle/steps/tool_loop.cr`):**
     - Update `sync_active_messages` (lines 170-189) to include a `when "user"` branch (for index `i > 0`) that appends mid-turn synthetic user messages to `active.messages` so `Turn` state and `SlidingStore` history stay synchronized with `working_messages`.
  4. **Dashboard Presentation (`nightmare/src/nightmare/ui/turn_presenter.cr`):**
     - Update `TurnPresenter#present_tool_result` for `read_file` so image metadata results record a concise `OpenedFile` entry (e.g., `read_range: "image"`, preview `"🖼 Image loaded (#{mime}, #{size_bytes} bytes)"`) without attempting line-numbered source code slicing.

### 2.5 Terminal Image Paste & User Attachment UX (`salamander` & `nightmare/src/nightmare/`)
- **Clipboard Helper (`Nightmare::UI::Clipboard` or `Salamander::Clipboard`):**
  - Auto-detect display server / clipboard utilities:
    - Wayland (`ENV["WAYLAND_DISPLAY"]?`): `wl-paste --list-types` to check for `image/png`, `image/jpeg`, `image/webp`; fetch bytes via `wl-paste --type <mime>`.
    - X11 (`ENV["DISPLAY"]?`): `xclip -selection clipboard -t TARGETS -o` to check for `image/png`, `image/jpeg`; fetch bytes via `xclip -selection clipboard -t <mime> -o`.
  - Optionally downscale oversized images (e.g. >1568px dimension) if `magick`/`ffmpeg` is available or enforce a safe byte threshold.
- **Immediate Slash Commands & Inline `@path` References (`Commands::Router` & `REPL`):**
  - `/clip` (alias `/img`): Captures an image from the OS clipboard (or loads `/img <path>`), stages it in `@pending_images` on `REPL`/`Router`, and prints:
    `↳ Captured [Image #1: clipboard PNG, 184 KB] (will be sent with your next message)`
  - `/clip clear` / `/img clear`: Clears staged pending images.
  - Inline `@path/to/file.png` in user prompts: Detect `@<token>` tokens matching valid workspace/readable image files, attach them to the user `Mantle::Message#images`, and display attachment confirmation.
  - Prompt indicator (`Nightmare::UI::Prompt.render`): When `pending_images` is non-empty, display `[🖼 ×N]` badge in the prompt header so the operator always sees pending visual attachments.
- **Raw-Mode Terminal Input & `Ctrl+V` Capture (`Salamander` / `Nightmare::UI`):**
  - Upgrade the interactive TTY prompt reader from cooked `@stdin.gets` to a raw-mode line reader (`STDIN.raw`) with Bracketed Paste Mode (`\e[?2004h` / `\e[?2004l`) when `stdin.tty?` is true (preserving `@stdin.gets` fallback for non-TTY pipes and `IO::Memory` specs):
    - Pressing `Ctrl+V` (`0x16`) checks the clipboard for `image/*` first; if present, stages the image into `pending_images` and renders `[Image #N]` inline in the prompt without needing a slash command; otherwise falls back to pasting clipboard `text/plain`.
    - Bracketed paste of a file path pointing to an existing image file (e.g. drag-and-drop from file manager) automatically stages the image and inserts `[Image #N: basename.png]`.

---

## 3. Implementation Plan (Phased Execution)

### Phase 1: Mantle Core Wire Protocol, Token Accounting, Shedding & Log Redaction
1. **`mantle/src/mantle/clients/message.cr`**:
   - Add `@[JSON::Field(emit_null: false)] property images : Array(String)? = nil` to `Mantle::Message`.
2. **`mantle/src/mantle/storage/sliding_store.cr` & `turn.cr`**:
   - Preserve `images` when `SlidingStore#start_turn` prepends side-effect interruption notes.
   - Add `IMAGE_TOKEN_ESTIMATE = 1_000` constant and account for attached images in `SlidingStore#total_estimated_tokens`.
3. **`mantle/src/mantle/storage/shedder.cr` & `mantle/src/mantle/steps/tool_loop.cr`**:
   - Keep `TokenEstimator#calibrate!` strictly text-based (`chars` from `m.content` only).
   - Include image token estimates in `ToolLoop#handle_iteration` threshold checks.
   - Update `Shedder.prune_history!` to shed `images` from historical turns before evicting full turns.
4. **`mantle/src/mantle/clients/logging_client.cr` & `nightmare/src/nightmare/transcript.cr`**:
   - Redact `images` base64 strings in `LoggingClient#log_receipt` (`prompt` and `raw_request`) to `<base64_image: ...>`.
   - Render image attachment count in `Transcript#format_message_markdown`.
5. **Phase 1 Specs**:
   - Add unit specs in `mantle/spec/` and `nightmare/spec/` covering `Message` JSON serialization with `images`, `SlidingStore` preservation, `Shedder` image pruning, and `LoggingClient` base64 redaction.

### Phase 2: Agent Image Inspection via `read_file` & Synthetic User Injection
1. **`mantle/src/mantle/tools/tools.cr` & `mantle/src/mantle/steps/step.cr`**:
   - Introduce a mechanism for tool executions to attach images (e.g., `Tool#last_images` or a thread/fiber-local / callback or structured envelope detected by `Step#run`) without breaking existing `Proc(Hash(String, JSON::Any), String)` tool handlers.
   - In `Mantle::Step#run`, after all `role: "tool"` messages for a turn iteration are appended to `working_messages`, append the synthetic `role: "user"` message containing any images loaded during that tool batch.
2. **`mantle/src/mantle/steps/tool_loop.cr`**:
   - Update `ToolLoop#sync_active_messages` to sync mid-turn `role: "user"` messages (`i >= active.messages.size`) into `active.messages`.
3. **`nightmare/src/nightmare/tools/read_only.cr` & `registry.cr`**:
   - Update `ReadOnly#read_file` to detect `.png`, `.jpg`, `.jpeg`, `.webp`, and `.gif` files, validate against `max_image_bytes`, base64-encode the file, and return clean JSON metadata + staged image payload.
   - Update `read_file` tool description in `Registry#build_read_file_tool` and `prompts/NIGHTMARE_AGENT_PROMPT.md` to note image file support.
4. **`nightmare/src/nightmare/ui/turn_presenter.cr`**:
   - Handle image `read_file` tool outputs cleanly in `TurnPresenter#present_tool_result`.
5. **Phase 2 Specs**:
   - Add unit and integration specs in `mantle/spec/` and `nightmare/spec/` verifying `read_file` on a PNG fixture produces a valid `tool` message followed by a synthetic `user` message with `images: [b64]`, satisfies `Turn#well_formed?`, and renders in `TurnPresenter`.

### Phase 3: User-Side Clipboard Capture (`/clip`, `@image.png`, and Raw-Mode `Ctrl+V` / Bracketed Paste)
1. **`nightmare/src/nightmare/ui/clipboard.cr` (new)**:
   - Implement clipboard image detection and reading for Wayland (`wl-paste`) and X11 (`xclip`/`xsel`) with MIME sniffing and PNG/JPEG magic-byte validation.
2. **`nightmare/src/nightmare/commands/router.cr`, `ui/prompt.cr`, & `repl.cr`**:
   - Add `pending_images` staging to `Router` / `REPL`.
   - Implement `/clip` / `/img` (`capture`, `<path>`, `list`, `clear`) slash commands and `@path/to/img.png` inline extraction in `REPL#execute_turn`.
   - Render `[🖼 ×N]` indicator in `UI::Prompt.render` when images are staged.
3. **Raw-Mode Line Input with `Ctrl+V` & Bracketed Paste (`salamander` / `nightmare/src/nightmare/ui/`)**:
   - Implement raw-mode TTY input reader supporting standard line editing, bracketed paste (`\e[200~...\e[201~`) file-path image auto-attachment, and `Ctrl+V` (`0x16`) clipboard image capture with live `[Image #N]` prompt acknowledgment, while retaining `@stdin.gets` fallback for non-TTY / spec `IO::Memory` streams.
4. **Phase 3 Specs**:
   - Add specs in `nightmare/spec/commands/router_spec.cr`, `nightmare/spec/ui/prompt_spec.cr`, and `nightmare/spec/cli_spec.cr` verifying `/clip`, `/img <path>`, `@image.png` attachment, prompt badge rendering, and outgoing `Mantle::Message#images` payloads.

---

## 4. Verification & Validation (V&V)

* **Verification Plan:**
  - `mantle`: Run `crystal spec` in `/home/cam/repos/adjutant/mantle` verifying `Mantle::Message` `images` serialization, `Step#run` synthetic user message injection after tool calls, `Turn#well_formed?` compliance, `ToolLoop#sync_active_messages` mid-turn user message syncing, `Shedder` image pruning, and `LoggingClient` base64 redaction.
  - `nightmare`: Run `crystal spec` in `/home/cam/repos/adjutant/nightmare` verifying `ReadOnly#read_file` binary image loading, `TurnPresenter` image badge rendering, `/clip` and `/img` router commands, `@file.png` attachment in `REPL`, and `Transcript` markdown formatting.
* **Verification Evidence:**
  - `mantle`: `crystal spec /home/cam/repos/adjutant/mantle/spec` passed (`346 examples, 0 failures, 0 errors, 0 pending` in 3.95s), covering `Mantle::Message` `images` JSON serialization/omission (`mantle/spec/client_spec.cr`), `LoggingClient` base64 redaction in `prompt` & `raw_request` (`mantle/spec/clients/logging_client_spec.cr`), `SlidingStore#start_turn` image preservation & `Shedder.prune_history!` historical image shedding (`mantle/spec/mantle/storage/turn_and_shedder_spec.cr`), and `Step#run` synthetic user message injection + `ToolLoop` `Turn#well_formed?` sync & `TokenEstimator` calibration isolation (`mantle/spec/mantle/steps/step_spec.cr`).
  - `nightmare`: `CRYSTAL_PATH=/home/cam/repos/adjutant/nightmare/lib:/usr/lib/crystal crystal spec /home/cam/repos/adjutant/nightmare/spec` passed (`391 examples, 0 failures, 0 errors, 0 pending` in 11.19s), and `crystal spec --order=random` passed (`391 examples, 0 failures, 0 errors, 0 pending`, seed `82240`, in 5.14s), covering `ReadOnly#read_file` PNG/JPEG `"image_loaded"` JSON and `MAX_IMAGE_BYTES` enforcement (`nightmare/spec/tools_spec.cr`), `TurnPresenter` `[READ: IMAGE]` rendering (`nightmare/spec/ui/turn_presenter_spec.cr`), `Prompt.render` `[🖼 ×N]` header badge (`nightmare/spec/ui/prompt_spec.cr`), `/clip` and `/img` router staging (`nightmare/spec/commands/router_spec.cr`), `Transcript` markdown image counts (`nightmare/spec/transcript_spec.cr`), and `Clipboard.extract_inline_images` / `InputReader` raw `Ctrl+V` & bracketed paste / `Nightmare::CLI.execute` interactive staging (`nightmare/spec/cli_spec.cr`).
* **Validation Plan:**
  - Launch `nightmare` against a vision-capable Ollama model:
    1. Copy a screenshot to clipboard, press `Ctrl+V` (or run `/clip`), verify `[Image #1]` acknowledgment appears in the terminal, and ask `"What is shown in this screenshot?"`.
    2. Ask the agent `"Inspect any PNG file in the workspace and describe it"`, verifying the agent calls `read_file` on the PNG, receives the image in context without UTF-8 errors, and accurately describes the visual content.
    3. Verify `llm_calls.jsonl` and `transcript.md` contain redacted image summaries rather than raw megabyte base64 strings.
* **Validation Evidence:**
  - Automated end-to-end simulation passed in specs using `StepMockClient`, `Nightmare::UI::Clipboard.test_image_provider`, `InputReader.read_line(..., simulate_raw: true)`, and `Nightmare::CLI.execute` with `IO::Memory`, confirming bracketed paste file capture (catching and fixing a `String::Builder#to_s` multi-call bug in `InputReader`), `Ctrl+V` clipboard badge emission, `@path` inline extraction, and log/transcript base64 redaction.
  - Live Ollama `/api/chat` vision model inference and host Wayland/X11 clipboard (`wl-paste` / `xclip` / `xsel`) interactive runs await manual verification in a live graphical terminal session.

## Open Questions & Concurrency Concerns
* **Max Image Resolution / Pre-Resize:** Large 4K screenshots can consume significant vision tokens and Ollama evaluation time. We should enforce a sensible file size cap (e.g., 10 MB) initially and optionally support transparent downscaling (e.g., max 1568px edge) if ImageMagick/`ffmpeg` is present on `PATH`.
* **Non-Vision Model Graceful Degradation:** If the active Ollama model does not support vision and returns an HTTP 400 error from `/api/chat`, `StepRunner` should surface a clear error message indicating the current model does not support image inputs.

## 5. Revision History
* 2026-11-13: Initial ticket created documenting CONOPS, architectural design points, and 3-phase implementation plan across `mantle`, `nightmare`, and `salamander`.
* 2026-11-13: Implemented Phases 1–3 across `mantle` and `nightmare` (`Ctrl+V` clipboard capture, bracketed paste file auto-attach, `/clip` & `/img` commands, `@image` inline extraction, and `read_file` visual inspection via synthetic user message injection), fixed `InputReader` bracketed-paste buffer accumulation bug, verified `mantle` (`346` examples) and `nightmare` (`391` examples, including `--order=random`) spec suites passing, and marked ticket `Resolved`.
---
