# Milestone 1: Workspace Anchoring & Central XDG Mapping
## Detailed Technical Design & Implementation Blueprint

**Author**: `explorer_m1_1`  
**Milestone**: M1 (F1.1, F1.2, F1.3, F1.4, F1.5, F1.7, F6.1)  
**Status**: Ready for Implementation  
**Target Repository**: `nightmare` (`/home/cam/repos/adjutant/nightmare`)  

---

## 1. Executive Summary & Architectural Invariants

Milestone 1 establishes the foundational isolation, containment, and state partitioning subsystem for NIGHTMARE. It guarantees:
1. **Immutable Workspace Root**: Anchors to `File.realpath(Dir.current)`. All read, mutation, and shell tool invocations are strictly contained within this boundary.
2. **Defensive Path Resolution**: Detects and rejects path traversal (`../`), sibling prefix collisions (`/repo_evil`), and out-of-tree symlinks using ancestor dereferencing, raising a typed `SecurityError`.
3. **Deterministic Partitioning**: Computes `<slug>-<hash>` (`File.basename` sanitized + 8-char SHA-256 digest of `@root`), guaranteeing repeatable, collision-free workspace isolation.
4. **Strict Zero-Repository-Litter**: All configuration (`workspace.json`, `prompt.md`, `allow`), logs (`llm_calls.jsonl`), and caches reside exclusively in central user XDG directories (`~/.config/nightmare/`, `~/.local/state/nightmare/`, `~/.cache/nightmare/`). Zero files are written into the target project repository.
5. **Auditability & Observability**: Renders a standardized 76-character Unicode startup banner on launch, maintains `workspace.json` metadata, and supports atomic 20 MB log rotation for `llm_calls.jsonl` with up to 3 historical generations.
6. **Local Shards Linkage**: Configures `shard.yml` to link local framework path dependencies `../mantle` and `../salamander` without version or path ambiguity.

---

## 2. Framework Dependency Configuration (F6.1)

### 2.1 Analysis & Discovery
NIGHTMARE links to local sibling frameworks `mantle` and `salamander` located in `../mantle` and `../salamander`.
- Inspection of `salamander/shard.yml` showed it declares `mantle` as `path: ../mantle`.
- Shards requires exact matching path representations; using relative path `../mantle` in `nightmare/shard.yml` prevents "ambiguous sources" errors during dependency resolution.

### 2.2 `shard.yml` Blueprint
File: `/home/cam/repos/adjutant/nightmare/shard.yml`
```yaml
name: nightmare
version: 0.1.0

authors:
  - ieve <ievemail@proton.me>

dependencies:
  mantle:
    path: ../mantle
  salamander:
    path: ../salamander

targets:
  nightmare:
    main: src/nightmare.cr

crystal: '>= 1.21.0'

license: MIT
```

### 2.3 Installation Command
```bash
shards install
```

---

## 3. Exception Modeling: `SecurityError`

### 3.1 Rationale
Crystal's standard library does not provide a built-in `SecurityError` (unlike Ruby). To satisfy `specs.md` §1.1 and acceptance criteria `AC-S1`/`AC-S2`, NIGHTMARE defines `SecurityError < Exception` at the top level and aliases it under `Nightmare::SecurityError`.

### 3.2 Code Blueprint
File: `src/nightmare/exceptions.cr`
```crystal
class SecurityError < Exception
end

module Nightmare
  alias SecurityError = ::SecurityError
end
```

---

## 4. `Nightmare::Workspace::Environment` (F1.1 - F1.5, F1.7)

### 4.1 Class Responsibilities & Data Contract
`Nightmare::Workspace::Environment` represents the immutable runtime anchoring of the REPL session:
```crystal
module Nightmare::Workspace
  class Environment
    getter root : String
    getter workspace_id : String
    getter xdg_config_home : String
    getter xdg_state_home : String
    getter xdg_cache_home : String
    getter config_dir : String
    getter state_dir : String
    getter cache_dir : String
    getter allowlist_path : String
    getter log_path : String
    getter manifest_path : String
    getter workspace_prompt_path : String
    getter global_prompt_path : String
    getter repo_prompt_path : String

    def self.resolve(
      current_dir : String = Dir.current,
      xdg_config_home : String? = nil,
      xdg_state_home : String? = nil,
      xdg_cache_home : String? = nil,
      ensure_dirs : Bool = true
    ) : Environment

    def sanitize_path(path : String) : String
    def inside_root?(path : String) : Bool
    def git_path?(path : String) : Bool
    def startup_banner : String
  end
end
```

### 4.2 Canonical Root Resolution (F1.1)
- **Resolution**:
  ```crystal
  @root = File.realpath(root_path)
  ```
- If `root_path` does not exist or is inaccessible, `File.realpath` raises `File::NotFoundError`, preventing execution with invalid working directories.
- Symlinked directories are immediately resolved to their real underlying path (e.g. `/var/tmp/symlink` $\rightarrow$ `/tmp/canonical`).

### 4.3 Deterministic Workspace ID Algorithm (F1.3)
To ensure identical projects in different directories do not collide, while retaining human readability:
1. **Slug Extraction & Sanitization**:
   - Extract directory basename: `raw_slug = File.basename(@root)`
   - Handle edge case of root filesystem (`/`) where basename is `"/"`: fallback to `"root"`.
   - Sanitize all non-alphanumeric, non-hyphen, non-underscore characters:
     ```crystal
     slug = raw_slug.gsub(/[^a-zA-Z0-9_-]/, "_")
     slug = "workspace" if slug.empty?
     ```
2. **Deterministic SHA-256 Hash**:
   - Compute SHA-256 digest of the canonical string `@root`:
     ```crystal
     hash = Digest::SHA256.hexdigest(@root)[0..7]
     ```
3. **Identifier Composition**:
   - Format: `workspace_id = "#{slug}-#{hash}"`
   - Example: `/home/cam/repos/adjutant` $\rightarrow$ `adjutant-8a4f21bc` (or actual SHA256 substring).
   - Regex validation: `^[a-zA-Z0-9_-]+-[0-9a-f]{8}$`.

### 4.4 Central XDG Base Directory Resolution (F1.4, F1.5)
Strictly adheres to the FreeDesktop XDG Base Directory Specification:
- **`$XDG_CONFIG_HOME`**:
  If `ENV["XDG_CONFIG_HOME"]?` is present and non-empty, use it. Otherwise default to `File.join(Path.home, ".config")`.
- **`$XDG_STATE_HOME`**:
  If `ENV["XDG_STATE_HOME"]?` is present and non-empty, use it. Otherwise default to `File.join(Path.home, ".local", "state")`.
- **`$XDG_CACHE_HOME`**:
  If `ENV["XDG_CACHE_HOME"]?` is present and non-empty, use it. Otherwise default to `File.join(Path.home, ".cache")`.
- **Test Inversion Parameter**:
  The constructor accepts optional `xdg_config_home`, `xdg_state_home`, and `xdg_cache_home` string parameters to allow unit tests to run against isolated temporary directories without altering developer system files.

#### Derived Workspace Hierarchy
- `config_dir = File.join(@xdg_config_home, "nightmare", "workspaces", @workspace_id)`
- `state_dir  = File.join(@xdg_state_home, "nightmare", "workspaces", @workspace_id)`
- `cache_dir  = File.join(@xdg_cache_home, "nightmare", "workspaces", @workspace_id)`
- `allowlist_path        = File.join(@config_dir, "allow")`
- `log_path              = File.join(@state_dir, "llm_calls.jsonl")`
- `manifest_path         = File.join(@config_dir, "workspace.json")`
- `workspace_prompt_path = File.join(@config_dir, "prompt.md")`
- `global_prompt_path    = File.join(@xdg_config_home, "nightmare", "prompt.md")`
- `repo_prompt_path      = File.join(@root, ".nightmare", "prompt.md")`

#### Directory Bootstrapping
When `ensure_dirs: true` is set (default in REPL boot):
- `Dir.mkdir_p(@config_dir)`
- `Dir.mkdir_p(@state_dir)`
- `Dir.mkdir_p(@cache_dir)`
- Zero directories or files are created in `@root`.

### 4.5 Path Sanitization & Containment Algorithm (F1.2)
A critical security challenge in path validation is verifying targets that **do not yet exist on disk** (e.g. creating `src/new_module/new_file.cr`), while preventing traversal through existing out-of-tree symlinks.

#### Resolution Algorithm (`resolve_contained_path`)
1. **Initial Expansion**:
   - If `path` is absolute: `expanded = File.expand_path(path)`
   - If `path` is relative: `expanded = File.expand_path(path, @root)`
2. **Ancestor Walk for Non-Existent Targets**:
   - Start from `expanded`.
   - While `!File.exists?(curr) && !File.symlink?(curr)`:
     - Record `File.basename(curr)` in a `remaining` queue.
     - Move `curr` to `File.dirname(curr)`.
     - Stop if `curr == File.dirname(curr)` (filesystem root).
3. **Canonical Ancestor Resolution**:
   - Call `real_ancestor = File.realpath(curr)`.
   - If `remaining` is empty: `resolved = real_ancestor`.
   - Else: `resolved = File.join(real_ancestor, File.join(remaining))`.
4. **Strict Root Containment Verification**:
   - Sibling prefix collision protection:
     ```crystal
     def path_inside_root?(path : String) : Bool
       path == @root || path.starts_with?(@root.ends_with?('/') ? @root : "#{@root}/")
     end
     ```
   - If `path_inside_root?(resolved)` is `false`:
     `raise SecurityError.new("Path traversal violation: target '#{path}' resolves outside root '#{@root}'")`
   - Return `resolved`.

#### Git Path Detection Helper
For integration with Milestone 3 mutation protection:
```crystal
def git_path?(path : String) : Bool
  sanitized = sanitize_path(path)
  rel = Path.new(sanitized).relative_to(@root).to_s
  rel == ".git" || rel.starts_with?(".git/")
rescue SecurityError | File::Error
  false
end
```

### 4.6 Startup Notification Banner Format (F1.7)
Format follows `DESIGN.md` §2 and `specs.md` §1.6:
- Standard width: 76 columns (or dynamic `[72, longest_line].max + 4` if paths are exceptionally long).
- Unicode box-drawing characters: `┌`, `┐`, `└`, `┘`, `─`, `│`.
- Paths display `~` in place of `$HOME` for central XDG locations.
- Config and State paths end with trailing slashes `/`.

```text
┌── NIGHTMARE ─────────────────────────────────────────────────────────────┐
│ Workspace : /home/cam/repos/adjutant                                     │
│ Config    : ~/.config/nightmare/workspaces/adjutant-8a4f21bc/            │
│ State/Logs: ~/.local/state/nightmare/workspaces/adjutant-8a4f21bc/       │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 5. `Nightmare::Workspace::Manifest` & `AuditLog` (F1.4, F1.5)

File: `src/nightmare/workspace/manifest.cr`

### 5.1 `struct Manifest`
Persisted in `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/workspace.json`.

```crystal
module Nightmare::Workspace
  struct Manifest
    include JSON::Serializable

    property id : String
    property canonical_path : String
    property created_at : Time
    property last_accessed : Time

    def initialize(@id : String, @canonical_path : String)
      @created_at = Time.utc
      @last_accessed = Time.utc
    end

    def self.load(path : String) : Manifest
      from_json(File.read(path))
    end

    def save(path : String) : Nil
      File.write(path, to_pretty_json)
    end

    def self.bootstrap(config_dir : String, id : String, canonical_path : String) : Manifest
      path = File.join(config_dir, "workspace.json")
      if File.exists?(path)
        manifest = begin
          load(path)
        rescue JSON::ParseException
          Manifest.new(id: id, canonical_path: canonical_path)
        end
        manifest.last_accessed = Time.utc
        manifest.save(path)
        manifest
      else
        Dir.mkdir_p(config_dir)
        manifest = Manifest.new(id: id, canonical_path: canonical_path)
        manifest.save(path)
        manifest
      end
    end
  end
end
```

### 5.2 `class AuditLog` (Safe Creation & 20MB Rotation)
Appends LLM exchanges to `$XDG_STATE_HOME/nightmare/workspaces/<workspace_id>/llm_calls.jsonl`.
- Default maximum file size: `20_971_520` bytes (20 MB).
- Default maximum generations: `3` (`llm_calls.jsonl.1`, `.2`, `.3`).
- Rotation procedure:
  1. If `llm_calls.jsonl.3` exists, remove it.
  2. If `llm_calls.jsonl.2` exists, rename to `.3`.
  3. If `llm_calls.jsonl.1` exists, rename to `.2`.
  4. Rename `llm_calls.jsonl` to `.1`.
  5. Create fresh `llm_calls.jsonl`.
- Disabled when initialized with `enabled: false` (from `--no-log` CLI flag).

```crystal
module Nightmare::Workspace
  class AuditLog
    MAX_SIZE = 20_971_520_i64 # 20 MB
    MAX_ROTATED = 3

    getter path : String
    getter? enabled : Bool
    getter max_size : Int64
    getter max_rotated : Int32

    def initialize(
      @path : String,
      @enabled : Bool = true,
      @max_size : Int64 = MAX_SIZE,
      @max_rotated : Int32 = MAX_ROTATED
    )
    end

    def log(entry : String) : Nil
      return unless @enabled

      dir = File.dirname(@path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)

      rotate_if_needed

      File.open(@path, mode: "a") do |file|
        file.puts(entry)
      end
    end

    def log(entry : Hash(String, JSON::Any) | JSON::Any | NamedTuple) : Nil
      log(entry.to_json)
    end

    def rotate_if_needed : Bool
      return false unless File.exists?(@path)
      return false if File.size(@path) < @max_size

      oldest = "#{@path}.#{@max_rotated}"
      File.delete(oldest) if File.exists?(oldest)

      (@max_rotated - 1).downto(1) do |i|
        src = "#{@path}.#{i}"
        dst = "#{@path}.#{i + 1}"
        File.rename(src, dst) if File.exists?(src)
      end

      File.rename(@path, "#{@path}.1")
      true
    end

    def rotated_files : Array(String)
      files = [] of String
      (1..@max_rotated).each do |i|
        candidate = "#{@path}.#{i}"
        files << candidate if File.exists?(candidate)
      end
      files
    end
  end
end
```

---

## 6. Complete Source Code Blueprint

### 6.1 `src/nightmare/exceptions.cr`
```crystal
class SecurityError < Exception
end

module Nightmare
  alias SecurityError = ::SecurityError
end
```

### 6.2 `src/nightmare/workspace/environment.cr`
```crystal
require "digest/sha256"
require "../exceptions"

module Nightmare::Workspace
  class Environment
    getter root : String
    getter workspace_id : String
    getter xdg_config_home : String
    getter xdg_state_home : String
    getter xdg_cache_home : String
    getter config_dir : String
    getter state_dir : String
    getter cache_dir : String
    getter allowlist_path : String
    getter log_path : String
    getter manifest_path : String
    getter workspace_prompt_path : String
    getter global_prompt_path : String
    getter repo_prompt_path : String

    def initialize(
      root_path : String,
      xdg_config_home : String? = nil,
      xdg_state_home : String? = nil,
      xdg_cache_home : String? = nil,
      ensure_dirs : Bool = true
    )
      @root = File.realpath(root_path)

      raw_slug = File.basename(@root)
      raw_slug = "root" if raw_slug == "/" || raw_slug.empty?
      slug = raw_slug.gsub(/[^a-zA-Z0-9_-]/, "_")
      slug = "workspace" if slug.empty?

      hash = Digest::SHA256.hexdigest(@root)[0..7]
      @workspace_id = "#{slug}-#{hash}"

      home = Path.home.to_s
      @xdg_config_home = resolve_xdg("XDG_CONFIG_HOME", xdg_config_home, File.join(home, ".config"))
      @xdg_state_home = resolve_xdg("XDG_STATE_HOME", xdg_state_home, File.join(home, ".local", "state"))
      @xdg_cache_home = resolve_xdg("XDG_CACHE_HOME", xdg_cache_home, File.join(home, ".cache"))

      @config_dir = File.join(@xdg_config_home, "nightmare", "workspaces", @workspace_id)
      @state_dir = File.join(@xdg_state_home, "nightmare", "workspaces", @workspace_id)
      @cache_dir = File.join(@xdg_cache_home, "nightmare", "workspaces", @workspace_id)

      @allowlist_path = File.join(@config_dir, "allow")
      @log_path = File.join(@state_dir, "llm_calls.jsonl")
      @manifest_path = File.join(@config_dir, "workspace.json")
      @workspace_prompt_path = File.join(@config_dir, "prompt.md")
      @global_prompt_path = File.join(@xdg_config_home, "nightmare", "prompt.md")
      @repo_prompt_path = File.join(@root, ".nightmare", "prompt.md")

      if ensure_dirs
        Dir.mkdir_p(@config_dir)
        Dir.mkdir_p(@state_dir)
        Dir.mkdir_p(@cache_dir)
      end
    end

    def self.resolve(
      current_dir : String = Dir.current,
      xdg_config_home : String? = nil,
      xdg_state_home : String? = nil,
      xdg_cache_home : String? = nil,
      ensure_dirs : Bool = true
    ) : Environment
      env = new(
        root_path: current_dir,
        xdg_config_home: xdg_config_home,
        xdg_state_home: xdg_state_home,
        xdg_cache_home: xdg_cache_home,
        ensure_dirs: ensure_dirs
      )
      if ensure_dirs
        Manifest.bootstrap(env.config_dir, env.workspace_id, env.root)
      end
      env
    end

    def sanitize_path(path : String) : String
      resolved = resolve_contained_path(path)
      unless path_inside_root?(resolved)
        raise SecurityError.new("Path traversal violation: target \"#{path}\" resolves outside root \"#{@root}\"")
      end
      resolved
    end

    def inside_root?(path : String) : Bool
      resolved = resolve_contained_path(path)
      path_inside_root?(resolved)
    rescue SecurityError | File::Error
      false
    end

    def git_path?(path : String) : Bool
      sanitized = sanitize_path(path)
      rel = Path.new(sanitized).relative_to(@root).to_s
      rel == ".git" || rel.starts_with?(".git/")
    rescue SecurityError | File::Error
      false
    end

    def startup_banner : String
      home = Path.home.to_s
      config_disp = @config_dir.starts_with?(home) ? "~" + @config_dir[home.size..] : @config_dir
      state_disp = @state_dir.starts_with?(home) ? "~" + @state_dir[home.size..] : @state_dir
      config_disp += "/" unless config_disp.ends_with?("/")
      state_disp += "/" unless state_disp.ends_with?("/")

      l1 = "Workspace : #{@root}"
      l2 = "Config    : #{config_disp}"
      l3 = "State/Logs: #{state_disp}"

      content_width = [72, [l1.size, l2.size, l3.size].max].max

      title = "── NIGHTMARE "
      top_dashes = content_width + 2 - title.size
      top = "┌#{title}#{"─" * top_dashes}┐"

      row1 = "│ #{l1.ljust(content_width)} │"
      row2 = "│ #{l2.ljust(content_width)} │"
      row3 = "│ #{l3.ljust(content_width)} │"
      bot = "└#{"─" * (content_width + 2)}┘"

      [top, row1, row2, row3, bot].join("\n")
    end

    private def resolve_contained_path(path : String) : String
      expanded = if Path.new(path).absolute?
        File.expand_path(path)
      else
        File.expand_path(path, @root)
      end

      curr = expanded
      remaining = [] of String
      while !File.exists?(curr) && !File.symlink?(curr)
        parent = File.dirname(curr)
        break if parent == curr
        remaining.unshift(File.basename(curr))
        curr = parent
      end

      real_ancestor = File.realpath(curr)
      if remaining.empty?
        real_ancestor
      else
        File.join(real_ancestor, File.join(remaining))
      end
    end

    private def path_inside_root?(path : String) : Bool
      path == @root || path.starts_with?(@root.ends_with?('/') ? @root : "#{@root}/")
    end

    private def resolve_xdg(env_var : String, param : String?, fallback : String) : String
      if param && !param.empty?
        param
      elsif (env = ENV[env_var]?) && !env.empty?
        env
      else
        fallback
      end
    end
  end
end
```

### 6.3 `src/nightmare/workspace/manifest.cr`
```crystal
require "json"

module Nightmare::Workspace
  struct Manifest
    include JSON::Serializable

    property id : String
    property canonical_path : String
    property created_at : Time
    property last_accessed : Time

    def initialize(@id : String, @canonical_path : String)
      @created_at = Time.utc
      @last_accessed = Time.utc
    end

    def self.load(path : String) : Manifest
      from_json(File.read(path))
    end

    def save(path : String) : Nil
      File.write(path, to_pretty_json)
    end

    def self.bootstrap(config_dir : String, id : String, canonical_path : String) : Manifest
      path = File.join(config_dir, "workspace.json")
      if File.exists?(path)
        manifest = begin
          load(path)
        rescue JSON::ParseException
          Manifest.new(id: id, canonical_path: canonical_path)
        end
        manifest.last_accessed = Time.utc
        manifest.save(path)
        manifest
      else
        Dir.mkdir_p(config_dir)
        manifest = Manifest.new(id: id, canonical_path: canonical_path)
        manifest.save(path)
        manifest
      end
    end
  end

  class AuditLog
    MAX_SIZE = 20_971_520_i64 # 20 MB
    MAX_ROTATED = 3

    getter path : String
    getter? enabled : Bool
    getter max_size : Int64
    getter max_rotated : Int32

    def initialize(
      @path : String,
      @enabled : Bool = true,
      @max_size : Int64 = MAX_SIZE,
      @max_rotated : Int32 = MAX_ROTATED
    )
    end

    def log(entry : String) : Nil
      return unless @enabled

      dir = File.dirname(@path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)

      rotate_if_needed

      File.open(@path, mode: "a") do |file|
        file.puts(entry)
      end
    end

    def log(entry : Hash(String, JSON::Any) | JSON::Any | NamedTuple) : Nil
      log(entry.to_json)
    end

    def rotate_if_needed : Bool
      return false unless File.exists?(@path)
      return false if File.size(@path) < @max_size

      oldest = "#{@path}.#{@max_rotated}"
      File.delete(oldest) if File.exists?(oldest)

      (@max_rotated - 1).downto(1) do |i|
        src = "#{@path}.#{i}"
        dst = "#{@path}.#{i + 1}"
        File.rename(src, dst) if File.exists?(src)
      end

      File.rename(@path, "#{@path}.1")
      true
    end

    def rotated_files : Array(String)
      files = [] of String
      (1..@max_rotated).each do |i|
        candidate = "#{@path}.#{i}"
        files << candidate if File.exists?(candidate)
      end
      files
    end
  end
end
```

### 6.4 `src/nightmare.cr` Entrypoint Integration
```crystal
require "./nightmare/exceptions"
require "./nightmare/workspace/environment"
require "./nightmare/workspace/manifest"

module Nightmare
  VERSION = "0.1.0"
end
```

---

## 7. Concrete Unit Test Blueprint: `spec/workspace_spec.cr`

File: `spec/workspace_spec.cr`

```crystal
require "./spec_helper"
require "file_utils"

describe Nightmare::Workspace::Environment do
  it "anchors immutably to canonical realpath of directory" do
    temp_dir = File.join(Dir.tempdir, "nightmare_spec_#{Random::Secure.hex(4)}")
    Dir.mkdir_p(temp_dir)
    canonical = File.realpath(temp_dir)

    sym_dir = File.join(Dir.tempdir, "nightmare_sym_#{Random::Secure.hex(4)}")
    File.symlink(canonical, sym_dir)

    begin
      env = Nightmare::Workspace::Environment.new(sym_dir, ensure_dirs: false)
      env.root.should eq(canonical)
    ensure
      FileUtils.rm_rf(sym_dir)
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "fails initialization if root path does not exist" do
    nonexistent = "/path/definitely/nonexistent_#{Random::Secure.hex(8)}"
    expect_raises(File::NotFoundError) do
      Nightmare::Workspace::Environment.new(nonexistent, ensure_dirs: false)
    end
  end

  it "generates deterministic workspace_id with sanitized slug and 8-char SHA256" do
    temp_dir = File.join(Dir.tempdir, "My Cool Project (v1.0)")
    Dir.mkdir_p(temp_dir)
    canonical = File.realpath(temp_dir)

    begin
      env = Nightmare::Workspace::Environment.new(temp_dir, ensure_dirs: false)
      expected_slug = "My_Cool_Project__v1_0_"
      expected_hash = Digest::SHA256.hexdigest(canonical)[0..7]

      env.workspace_id.should eq("#{expected_slug}-#{expected_hash}")
      (env.workspace_id =~ /^[a-zA-Z0-9_-]+-[0-9a-f]{8}$/).should_not be_nil

      # Idempotency
      env2 = Nightmare::Workspace::Environment.new(temp_dir, ensure_dirs: false)
      env2.workspace_id.should eq(env.workspace_id)
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "resolves central XDG paths correctly without littering target repo" do
    temp_root = File.join(Dir.tempdir, "repo_#{Random::Secure.hex(4)}")
    temp_xdg = File.join(Dir.tempdir, "xdg_#{Random::Secure.hex(4)}")
    Dir.mkdir_p(temp_root)
    Dir.mkdir_p(temp_xdg)

    cfg = File.join(temp_xdg, "config")
    st = File.join(temp_xdg, "state")
    ca = File.join(temp_xdg, "cache")

    begin
      env = Nightmare::Workspace::Environment.resolve(
        current_dir: temp_root,
        xdg_config_home: cfg,
        xdg_state_home: st,
        xdg_cache_home: ca,
        ensure_dirs: true
      )

      env.config_dir.should eq(File.join(cfg, "nightmare", "workspaces", env.workspace_id))
      env.state_dir.should eq(File.join(st, "nightmare", "workspaces", env.workspace_id))
      env.cache_dir.should eq(File.join(ca, "nightmare", "workspaces", env.workspace_id))
      env.allowlist_path.should eq(File.join(env.config_dir, "allow"))
      env.log_path.should eq(File.join(env.state_dir, "llm_calls.jsonl"))

      # Zero repo litter verification
      Dir.exists?(env.config_dir).should be_true
      Dir.exists?(env.state_dir).should be_true
      Dir.exists?(env.cache_dir).should be_true
      File.exists?(env.manifest_path).should be_true

      # Target repo must remain pristine
      Dir.children(temp_root).should be_empty
    ensure
      FileUtils.rm_rf(temp_root)
      FileUtils.rm_rf(temp_xdg)
    end
  end

  describe "Path Containment & Security Sanitization" do
    it "allows canonical relative and absolute paths inside root" do
      test_dir = File.join(Dir.tempdir, "sec_#{Random::Secure.hex(4)}")
      Dir.mkdir_p(test_dir)
      Dir.mkdir_p(File.join(test_dir, "src"))
      File.write(File.join(test_dir, "src", "app.cr"), "content")

      begin
        env = Nightmare::Workspace::Environment.new(test_dir, ensure_dirs: false)
        expected = File.join(env.root, "src", "app.cr")

        env.sanitize_path("src/app.cr").should eq(expected)
        env.sanitize_path("./src/../src/./app.cr").should eq(expected)
        env.sanitize_path(expected).should eq(expected)
        env.inside_root?("src/app.cr").should be_true
      ensure
        FileUtils.rm_rf(test_dir)
      end
    end

    it "allows non-existent targets inside root for new file creation" do
      test_dir = File.join(Dir.tempdir, "sec_#{Random::Secure.hex(4)}")
      Dir.mkdir_p(test_dir)

      begin
        env = Nightmare::Workspace::Environment.new(test_dir, ensure_dirs: false)
        target = env.sanitize_path("new_dir/sub_dir/new_file.cr")
        target.should eq(File.join(env.root, "new_dir", "sub_dir", "new_file.cr"))
        env.inside_root?("new_dir/sub_dir/new_file.cr").should be_true
      ensure
        FileUtils.rm_rf(test_dir)
      end
    end

    it "strictly rejects path traversal escaping root with SecurityError" do
      test_dir = File.join(Dir.tempdir, "sec_#{Random::Secure.hex(4)}")
      Dir.mkdir_p(test_dir)

      begin
        env = Nightmare::Workspace::Environment.new(test_dir, ensure_dirs: false)

        expect_raises(SecurityError) { env.sanitize_path("../outside.txt") }
        expect_raises(SecurityError) { env.sanitize_path("src/../../outside.txt") }
        expect_raises(SecurityError) { env.sanitize_path("/etc/passwd") }

        env.inside_root?("../outside.txt").should be_false
        env.inside_root?("/etc/shadow").should be_false
      ensure
        FileUtils.rm_rf(test_dir)
      end
    end

    it "rejects sibling prefix collision attacks" do
      parent_dir = File.join(Dir.tempdir, "prefix_#{Random::Secure.hex(4)}")
      root_dir = File.join(parent_dir, "nightmare")
      evil_dir = File.join(parent_dir, "nightmare_evil")
      Dir.mkdir_p(root_dir)
      Dir.mkdir_p(evil_dir)
      File.write(File.join(evil_dir, "secret.txt"), "stolen")

      begin
        env = Nightmare::Workspace::Environment.new(root_dir, ensure_dirs: false)

        expect_raises(SecurityError) do
          env.sanitize_path(File.join(evil_dir, "secret.txt"))
        end
        env.inside_root?(File.join(evil_dir, "secret.txt")).should be_false
      ensure
        FileUtils.rm_rf(parent_dir)
      end
    end

    it "allows internal symlinks pointing inside root" do
      test_dir = File.join(Dir.tempdir, "sym_#{Random::Secure.hex(4)}")
      Dir.mkdir_p(test_dir)
      src_dir = File.join(test_dir, "src")
      Dir.mkdir_p(src_dir)
      File.write(File.join(src_dir, "code.cr"), "puts 1")

      symlink_dir = File.join(test_dir, "link_src")
      File.symlink(src_dir, symlink_dir)

      begin
        env = Nightmare::Workspace::Environment.new(test_dir, ensure_dirs: false)
        sanitized = env.sanitize_path("link_src/code.cr")
        sanitized.should eq(File.join(env.root, "src", "code.cr"))
        env.inside_root?("link_src/code.cr").should be_true
      ensure
        FileUtils.rm_rf(test_dir)
      end
    end

    it "strictly rejects out-of-tree symlinks with SecurityError" do
      base_dir = File.join(Dir.tempdir, "sym_out_#{Random::Secure.hex(4)}")
      root_dir = File.join(base_dir, "root")
      outside_dir = File.join(base_dir, "outside")
      Dir.mkdir_p(root_dir)
      Dir.mkdir_p(outside_dir)
      File.write(File.join(outside_dir, "secret.txt"), "super_secret")

      symlink_outside = File.join(root_dir, "sym_outside")
      File.symlink(outside_dir, symlink_outside)

      begin
        env = Nightmare::Workspace::Environment.new(root_dir, ensure_dirs: false)

        expect_raises(SecurityError) { env.sanitize_path("sym_outside") }
        expect_raises(SecurityError) { env.sanitize_path("sym_outside/secret.txt") }
        expect_raises(SecurityError) { env.sanitize_path("sym_outside/new_file.txt") }

        env.inside_root?("sym_outside").should be_false
        env.inside_root?("sym_outside/secret.txt").should be_false
        env.inside_root?("sym_outside/new_file.txt").should be_false
      ensure
        FileUtils.rm_rf(base_dir)
      end
    end

    it "detects .git paths via git_path? helper" do
      test_dir = File.join(Dir.tempdir, "git_#{Random::Secure.hex(4)}")
      Dir.mkdir_p(test_dir)
      Dir.mkdir_p(File.join(test_dir, ".git"))

      begin
        env = Nightmare::Workspace::Environment.new(test_dir, ensure_dirs: false)
        env.git_path?(".git").should be_true
        env.git_path?(".git/config").should be_true
        env.git_path?("src/../.git/HEAD").should be_true
        env.git_path?(".gitignore").should be_false
        env.git_path?("git_util.cr").should be_false
      ensure
        FileUtils.rm_rf(test_dir)
      end
    end
  end

  describe "Startup Notification Banner" do
    it "renders bordered Unicode box banner matching exact specification" do
      test_dir = File.join(Dir.tempdir, "banner_#{Random::Secure.hex(4)}")
      Dir.mkdir_p(test_dir)

      begin
        env = Nightmare::Workspace::Environment.new(test_dir, ensure_dirs: false)
        banner = env.startup_banner

        banner.should contain("┌── NIGHTMARE ")
        banner.should contain("│ Workspace : #{env.root}")
        banner.should contain("│ Config    : ")
        banner.should contain("│ State/Logs: ")
        banner.should contain("└─")

        # Every line in the box has matching character width
        lines = banner.lines
        lines.size.should eq(5)
        lines.map(&.size).uniq.size.should eq(1)
      ensure
        FileUtils.rm_rf(test_dir)
      end
    end
  end
end

describe Nightmare::Workspace::Manifest do
  it "bootstraps and updates workspace.json metadata" do
    test_dir = File.join(Dir.tempdir, "manifest_#{Random::Secure.hex(4)}")
    Dir.mkdir_p(test_dir)

    begin
      m1 = Nightmare::Workspace::Manifest.bootstrap(test_dir, "test-12345678", "/path/to/repo")
      m1.id.should eq("test-12345678")
      m1.canonical_path.should eq("/path/to/repo")

      path = File.join(test_dir, "workspace.json")
      File.exists?(path).should be_true

      # Reloading updates last_accessed
      sleep 10.milliseconds
      m2 = Nightmare::Workspace::Manifest.bootstrap(test_dir, "test-12345678", "/path/to/repo")
      m2.last_accessed.should be >= m1.last_accessed
      m2.created_at.should eq(m1.created_at)
    ensure
      FileUtils.rm_rf(test_dir)
    end
  end
end

describe Nightmare::Workspace::AuditLog do
  it "appends entries and rotates automatically at threshold with 3 history files" do
    test_dir = File.join(Dir.tempdir, "audit_#{Random::Secure.hex(4)}")
    Dir.mkdir_p(test_dir)
    log_path = File.join(test_dir, "llm_calls.jsonl")

    begin
      # Max size 60 bytes, max 3 rotated files
      logger = Nightmare::Workspace::AuditLog.new(log_path, max_size: 60_i64, max_rotated: 3)

      6.times do |i|
        logger.log(%({"call":#{i},"payload":"#{"a" * 25}"}))
      end

      File.exists?(log_path).should be_true
      logger.rotated_files.size.should be <= 3

      File.exists?("#{log_path}.1").should be_true
      File.exists?("#{log_path}.2").should be_true
      File.exists?("#{log_path}.3").should be_true
      File.exists?("#{log_path}.4").should be_false
    ensure
      FileUtils.rm_rf(test_dir)
    end
  end

  it "does not write logs when disabled via --no-log" do
    test_dir = File.join(Dir.tempdir, "audit_dis_#{Random::Secure.hex(4)}")
    Dir.mkdir_p(test_dir)
    log_path = File.join(test_dir, "llm_calls.jsonl")

    begin
      logger = Nightmare::Workspace::AuditLog.new(log_path, enabled: false)
      logger.log(%({"test":"ignored"}))
      File.exists?(log_path).should be_false
    ensure
      FileUtils.rm_rf(test_dir)
    end
  end
end
```

---

## 8. Implementation Steps & Verification Plan

### 8.1 Implementation Order for M1 Implementer
1. **Configure `shard.yml`**:
   - Add `mantle: { path: ../mantle }` and `salamander: { path: ../salamander }`.
   - Run `shards install`.
2. **Implement `src/nightmare/exceptions.cr`**:
   - Declare `SecurityError < Exception` and `Nightmare::SecurityError`.
3. **Implement `src/nightmare/workspace/manifest.cr`**:
   - `struct Manifest` (with `JSON::Serializable`, `bootstrap`, `save`, `load`).
   - `class AuditLog` (with `log`, `rotate_if_needed`, `rotated_files`, `enabled` flag).
4. **Implement `src/nightmare/workspace/environment.cr`**:
   - `class Environment` (root anchoring, slug/hash, XDG resolution, path sanitization, `git_path?`, banner).
5. **Update `src/nightmare.cr`**:
   - Require exceptions, environment, manifest.
6. **Implement `spec/workspace_spec.cr`**:
   - Remove failing placeholder from `spec/nightmare_spec.cr`.
   - Run `crystal spec`.

### 8.2 Invalidation Conditions
- If `File.realpath(Dir.current)` is altered or made mutable.
- If path sanitization permits any relative `../` or external symlink without throwing `SecurityError`.
- If prefix attacks (`root + "_evil"`) succeed.
- If any file (`workspace.json`, `llm_calls.jsonl`, etc.) is written into `@root`.
- If `AuditLog` retains more than 3 rotated files or fails to rotate at threshold.
