---
ID: TKT-041
Title: Inline Image Downscaling and Compression via Mantle::Support::Image
Status: Resolved
Priority: High
---

## 1. User Need & Initial Investigation

### 1.1 User Need
Operators capturing or attaching 4K (3840×2160) screenshots in Nightmare easily produce raw PNG files up to 4+ MB (~5.3+ MB once base64-encoded). Sending full-resolution uncompressed screenshots directly to vision-language models introduces unnecessary wire/memory/log overhead and inflates vision token counts and prompt evaluation latency without improving visual comprehension.

### 1.2 Initial Investigation Findings
1. **How Vision Encoders Process 4K Screenshots:**
   - **Fixed-resolution models** (e.g., Gemma 3, LLaVA) resize inputs internally to a fixed square (such as `896×896` or `336×336`), immediately discarding excess 4K pixels.
   - **Dynamic-resolution / tiled models** (e.g., Qwen2.5-VL, Qwen3-VL, Llama 3.2 Vision) split high-resolution images into `14×14` or `28×28` patches. An un-clamped 3840×2160 image can explode into **3,000–4,500+ vision tokens**, exceeding `Mantle::Storage::Shedder::IMAGE_TOKEN_ESTIMATE` (`1,000` tokens) and consuming a large fraction of the `12,000` token context budget and prefill compute.
   - **Legibility Sweet Spot:** Bounding the longest edge to **`1920px` (1080p)** preserves full legibility for small terminal and UI text while reducing pixel count by 4× (from 8.3M pixels to ≤2.07M pixels).
2. **Wire, Memory, and Decoder Compatibility (PNG vs. JPEG vs. WebP):**
   - `wl-paste` and screenshot tools default to `image/png`. A 4 MB 4K PNG becomes ~5.3 MB of base64 JSON in every tool-loop request until shed.
   - Downscaling to `<= 1920×1920` and encoding as JPEG (`quality: 85`) reduces a 4 MB 4K screenshot to **~150–350 KB** (a 10–20× reduction) with negligible perceptual impact after vision-encoder RGB tensor normalization.
   - **Why JPEG over WebP:** While Go's `golang.org/x/image/webp` can decode WebP, native C/C++ inference backends (`llama.cpp` via `stb_image.h`) natively support JPEG and PNG out of the box without external `libwebp` linkage. Outputting `jpeg:-` (with alpha flattened onto white via `-background white -alpha remove -alpha off`) guarantees universal compatibility across Ollama and OpenAI-compatible vision endpoints.
3. **In-Memory Pipeline Execution:**
   - ImageMagick (`magick` or legacy `convert`) supports streaming `stdin -> stdout` (`-` to `jpeg:-`) with the `>` shrink-only geometry flag (`"1920x1920>"`), avoiding temporary files on disk and never upscaling smaller images.

---

## 2. Specification & Design Selection

### 2.1 `Mantle::Support::Image` (`mantle/src/mantle/support/image.cr`)
Create a shared upstream support module in `Mantle::Support::Image` providing:
- **Constants:**
  - `SUPPORTED_EXTENSIONS = Set{".png", ".jpg", ".jpeg", ".webp", ".gif"}`
  - `DEFAULT_MAX_DIMENSION = 1920`
  - `DEFAULT_QUALITY = 85`
  - `DEFAULT_OPTIMIZE_THRESHOLD_BYTES = 65_536` (64 KB — skips subprocess invocation for tiny icons and synthetic unit test fixtures)
  - `DEFAULT_MAX_BYTES = 10_485_760_i64` (10 MB)
- **Format & MIME Detection:**
  - `mime_for_path(path : String) : String?`: Extension-based MIME lookup.
  - `detect_mime(bytes : Bytes, path_hint : String? = nil) : String?`: Magic-byte inspection (`PNG`, `JPEG`, `GIF87a`/`GIF89a`, `RIFF`/`WEBP`) with `path_hint` fallback.
  - `image_path?(path : String) : Bool`: Checks whether path extension is in `SUPPORTED_EXTENSIONS`.
- **In-Memory `magick` Optimization (`optimize` & `encode_base64`):**
  - `magick_executable : String?`: Resolves `magick` or `convert` via `Process.find_executable` (with an overridable class property `custom_magick_executable : String?` for deterministic spec testing of missing/custom binaries).
  - `optimize(bytes : Bytes, mime : String, max_dimension : Int32 = DEFAULT_MAX_DIMENSION, quality : Int32 = DEFAULT_QUALITY, min_bytes : Int32 = DEFAULT_OPTIMIZE_THRESHOLD_BYTES) : Tuple(Bytes, String)`:
    - Returns `{bytes, mime}` unchanged if:
      - `mime == "image/gif"` (preserves animated GIFs),
      - `bytes.size < min_bytes`, or
      - No ImageMagick executable is available.
    - Executes `magick` (or `convert`) with `input: IO::Memory.new(bytes)`, `output: out_io`, `error: err_io`, and arguments:
      `["-", "-background", "white", "-alpha", "remove", "-alpha", "off", "-resize", "#{max_dimension}x#{max_dimension}>", "-quality", quality.to_s, "jpeg:-"]`
    - If `status.success? && out_io.size > 0 && out_io.size < bytes.size`, returns `{out_io.to_slice, "image/jpeg"}`; otherwise falls back to `{bytes, mime}`.
  - `encode_base64(...) : Tuple(String, String, Int64)`: Runs `optimize` and returns `{Base64.strict_encode(opt_bytes), opt_mime, opt_bytes.size.to_i64}`.

### 2.2 Integration in Mantle & Nightmare
1. **Mantle Builtin `ReadFile` (`mantle/src/mantle/tools/builtin/read_file.cr`):**
   - Detect image files via `Mantle::Support::Image.mime_for_path(absolute_path)` (and magic bytes), enforce `DEFAULT_MAX_BYTES`, optimize via `Mantle::Support::Image.encode_base64`, and return the structured `"image_loaded"` JSON payload expected by `Mantle::Step#run`.
2. **Nightmare `UI::Clipboard` (`nightmare/src/nightmare/ui/clipboard.cr`):**
   - Delegate `detect_mime` to `Mantle::Support::Image.detect_mime`.
   - Route `load_file`, `capture_image`, `capture_wayland_image`, and `capture_x11_image` through `Mantle::Support::Image.optimize` so pasted 4K screenshots and `@image.png` attachments are automatically downscaled and compressed before staging into `PendingImage`.
3. **Nightmare `Tools::ReadOnly#read_file` (`nightmare/src/nightmare/tools/read_only.cr`):**
   - Delegate `ReadOnly.image_mime_for_path` to `Mantle::Support::Image.mime_for_path`.
   - Optimize loaded image bytes via `Mantle::Support::Image.optimize` before base64 encoding in `read_file`, returning the optimized `mime`, `size_bytes`, and `images: [b64]`.

---

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Add unit specs in `mantle/spec/support/image_spec.cr` testing:
    - Magic-byte and extension MIME detection.
    - In-memory downscaling and JPEG compression of a large (>64 KB, e.g. 2560×1440 or 3840×2160) PNG into a much smaller `image/jpeg` payload with dimensions bounded by `max_dimension`.
    - Preservation of small images (`< min_bytes`) and `image/gif`.
    - Graceful fallback to original `{bytes, mime}` when `magick` is unavailable or fails on malformed bytes.
    - `Mantle::Tools::Builtin::ReadFile` loading and optimizing image files.
  - Add unit specs in `nightmare/spec/` verifying `Nightmare::UI::Clipboard` and `Nightmare::Tools::ReadOnly#read_file` automatically compress oversized PNGs while keeping existing small-fixture specs passing.
  - Run full `crystal spec` suites in both `mantle` and `nightmare`.
* **Verification Evidence:**
  - `mantle`: `crystal spec mantle/spec` passed (`352 examples, 0 failures, 0 errors, 0 pending` in 4.19s), including `mantle/spec/mantle/support/image_spec.cr` (`5 examples, 0 failures` in 289.72ms) and `mantle/spec/builtin_tools_spec.cr` verifying MIME sniffing, small/GIF preservation, fallback when `magick` is disabled or input is malformed, and in-memory downscaling + JPEG compression of multi-megabyte high-resolution PNGs.
  - `nightmare`: `CRYSTAL_PATH=nightmare/lib:/usr/lib/crystal crystal spec nightmare/spec` passed (`392 examples, 0 failures, 0 errors, 0 pending` in 11.47s), verifying automatic downscaling and JPEG compression in `Nightmare::Tools::ReadOnly#read_file` and `Nightmare::UI::Clipboard.load_file` alongside all existing multimodal specs.
* **Validation Plan:**
  - Verify that a multi-megabyte 4K PNG image loaded via `Clipboard.load_file` or `ReadOnly#read_file` is compressed to a compact JPEG (hundreds of KB) with dimensions `<= 1920x1920`.
* **Validation Evidence:**
  - Verified in `mantle/spec/mantle/support/image_spec.cr` and `nightmare/spec/tools_spec.cr` that uncompressed high-resolution PNG images (>7 MB) are downscaled in-memory via `magick` stdin/stdout to `<= max_dimension` and compressed to `image/jpeg` (<50 KB), while `identify` confirms the resulting dimensions match the aspect-preserved bounding box.

## Open Questions & Concurrency Concerns
* Process execution uses `IO::Memory` buffers for `stdin`, `stdout`, and `stderr`. Since `Process.run` streams `input` in Crystal's standard library, no temporary files or disk locks are required.

## 4. Revision History
* 2026-11-14: Created ticket documenting 4K screenshot investigation, vision model token/resolution trade-offs, design selection for `Mantle::Support::Image`, and integration plan across `mantle` and `nightmare`.
* 2026-11-14: Implemented `Mantle::Support::Image` (`mantle/src/mantle/support/image.cr`), wired it into `Mantle::Tools::Builtin::ReadFile`, `Nightmare::UI::Clipboard`, and `Nightmare::Tools::ReadOnly#read_file`, verified full spec suites in `mantle` (352 examples) and `nightmare` (392 examples), and marked ticket `Resolved`.
---
