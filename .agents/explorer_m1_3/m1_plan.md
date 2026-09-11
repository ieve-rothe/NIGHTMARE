# Milestone 1: Shard Linkage, Workspace Layout & Directives Worker Implementation Plan

**Author**: `explorer_m1_3`  
**Target Milestone**: Milestone 1 (F1.1 - F1.8, F6.1)  
**Parent Orchestrator**: `orchestrator_1` (Conv ID: `3ad3ad0f-7c04-4b8b-8435-1ed5dba552db`)  
**Target Repository**: `/home/cam/repos/adjutant/nightmare`  
**Compiler Environment**: Crystal 1.21.0, Shards 0.19.1 on `x86_64-pc-linux-gnu`  
**Execution Constraint**: All `run_command` invocations MUST specify `BypassSandbox: true`. Multi-repo workspace rules apply: no `cd`, set `Cwd` directly, no shell command chaining (`&&`, `;`, `|`).

---

## 1. Executive Summary & Milestone Scope

Milestone 1 establishes the foundational infrastructure for NIGHTMARE:
1. **F6.1 Dependency Linkage**: Linking local sibling frameworks (`mantle`, `salamander`, and `tts_kokoro`) via relative path dependencies in `shard.yml` with clean `shards install` and zero compiler warnings on `shards build`.
2. **F1.1 Canonical Root Resolution**: Immutably binding the workspace to `File.realpath(Dir.current)` and enforcing strict workspace containment.
3. **F1.2 Path Traversal & Symlink Protection**: Detecting and rejecting `../` traversal escapes and external symlinks with typed `Nightmare::SecurityError`.
4. **F1.3 Deterministic Workspace ID**: Deriving `<slug>-<hash>` from the sanitized basename and the first 8 hex characters of the SHA-256 digest of `@root`.
5. **F1.4 Central XDG Hierarchy**: Partitioning all persistent configuration, state logs, and caches strictly under `$XDG_CONFIG_HOME`, `$XDG_STATE_HOME`, and `$XDG_CACHE_HOME` (`workspaces/<workspace_id>/`).
6. **F1.5 Zero Repository Litter**: Guaranteeing that no configuration, manifest, cache, or log file is ever written into the target workspace repository.
7. **F1.6 Directives Resolution Precedence**: Resolving system prompts across a strict 5-tier hierarchy (CLI flag > repo file > workspace config > global config > default persona).
8. **F1.7 Startup Notification Banner**: Emitting a formatted box-drawing banner displaying the canonical root, config path, and state path.
9. **F1.8 In-Memory Directive Mutation**: Providing an in-memory directive buffer (`DirectiveBuffer`) that enables `/prompt edit` to mutate the active prompt in RAM without touching underlying files on disk.

---

## 2. File Structure & Deliverables Matrix

The worker will create or modify the following files in `/home/cam/repos/adjutant/nightmare`:

| File Path | Role | Description |
| :--- | :--- | :--- |
| `shard.yml` | Config | Adds `dependencies:` for `mantle`, `salamander`, `tts_kokoro`. |
| `src/nightmare.cr` | Source / Entrypoint | Root namespace, `VERSION`, `SecurityError`, CLI option parser with `{% if !@top_level.has_constant?("Spec") %}` macro guard. |
| `src/nightmare/workspace/manifest.cr` | Source | `Nightmare::Workspace::Manifest` struct with JSON serialization, `load_or_create`, `touch`, `save`. |
| `src/nightmare/workspace/environment.cr` | Source | `Nightmare::Workspace::Environment` class: root anchor, slug-hash ID, XDG paths, path sanitization, traversal defense, startup banner. |
| `src/nightmare/directives/resolver.cr` | Source | `Nightmare::Directives::Resolver` class (5-tier resolution) and `DirectiveBuffer` (in-memory editor). |
| `spec/spec_helper.cr` | Spec Harness | Spec helper with `with_temp_dir` and `with_env` isolation helpers. |
| `spec/nightmare_spec.cr` | Spec | Fixes default failing test to assert `Nightmare::VERSION == "0.1.0"`. |
| `spec/workspace_spec.cr` | Spec | Comprehensive specs for root anchoring, path traversal, symlink resolution, workspace ID, XDG layout, and banner. |
| `spec/directives_spec.cr` | Spec | Comprehensive specs for all 5 directive precedence tiers, CLI override, and in-memory mutation. |

---

## 3. Detailed Component Specifications & Code Templates

### 3.1 `shard.yml` (F6.1)

Update `shard.yml` to include path dependencies. All three dependencies (`mantle`, `salamander`, `tts_kokoro`) exist as immediate siblings in `/home/cam/repos/adjutant/`:

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
  tts_kokoro:
    path: ../tts_kokoro

targets:
  nightmare:
    main: src/nightmare.cr

crystal: '>= 1.21.0'

license: MIT
```

**Worker Action**:
1. Overwrite `shard.yml` with the configuration above.
2. Run `shards install` with `BypassSandbox: true` and `Cwd: /home/cam/repos/adjutant/nightmare`.
3. Verify symlinks are generated in `lib/`:
   - `lib/mantle -> ../mantle`
   - `lib/salamander -> ../salamander`
   - `lib/tts_kokoro -> ../tts_kokoro`
4. Run `shards check` to confirm dependencies are satisfied.

---

### 3.2 `src/nightmare/workspace/manifest.cr` (F1.4)

Implements the JSON serialization model for `workspace.json` stored in `$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/workspace.json`.

```crystal
require "json"
require "time"

module Nightmare::Workspace
  struct Manifest
    include JSON::Serializable

    property id : String
    property canonical_path : String
    property created_at : Time
    property last_accessed : Time

    def initialize(
      @id : String,
      @canonical_path : String,
      @created_at : Time = Time.utc,
      @last_accessed : Time = Time.utc
    )
    end

    # Updates the last accessed timestamp to the current UTC time
    def touch : Nil
      @last_accessed = Time.utc
    end

    # Loads an existing workspace manifest or initializes a new one
    def self.load_or_create(path : String, id : String, canonical_path : String) : Manifest
      if File.exists?(path)
        begin
          manifest = from_json(File.read(path))
          manifest.touch
          manifest.save(path)
          manifest
        rescue JSON::ParseException
          manifest = new(id, canonical_path)
          manifest.save(path)
          manifest
        end
      else
        manifest = new(id, canonical_path)
        manifest.save(path)
        manifest
      end
    end

    # Persists the manifest as formatted JSON
    def save(path : String) : Nil
      File.write(path, to_pretty_json)
    end
  end
end
```

---

### 3.3 `src/nightmare/workspace/environment.cr` (F1.1 - F1.5, F1.7)

Implements canonical root resolution, deterministic slug-hash workspace identification, central XDG mapping, zero repo litter guarantees, path traversal & symlink security checks, and startup banner rendering.

**Security Alert — Path Boundary Prefix Check**:
A naive check `path.starts_with?(@root)` is vulnerable to prefix confusion (e.g. `@root = "/tmp/repo"`, `path = "/tmp/repo_attack"`). The check must verify that `path == @root || path.starts_with?("#{@root}/")` (or handled when `@root == "/"`).

```crystal
require "digest/sha256"
require "file_utils"
require "path"
require "./manifest"

module Nightmare::Workspace
  class Environment
    getter root : String
    getter workspace_id : String
    getter config_dir : String
    getter state_dir : String
    getter cache_dir : String
    getter allowlist_path : String
    getter log_path : String
    getter manifest_path : String
    getter workspace_prompt_path : String
    getter repo_prompt_path : String
    getter global_prompt_path : String
    getter manifest : Manifest

    def initialize(
      @root : String,
      @workspace_id : String,
      @config_dir : String,
      @state_dir : String,
      @cache_dir : String,
      @allowlist_path : String,
      @log_path : String,
      @manifest_path : String,
      @workspace_prompt_path : String,
      @repo_prompt_path : String,
      @global_prompt_path : String,
      @manifest : Manifest
    )
    end

    # Resolves and bootstraps the workspace environment for a given directory
    def self.resolve(current_dir : String = Dir.current) : Environment
      # F1.1: Canonical Root Anchor
      unless Dir.exists?(current_dir) || File.exists?(current_dir)
        raise ArgumentError.new("Workspace directory does not exist: #{current_dir}")
      end
      root = File.realpath(current_dir)

      # F1.3: Deterministic Workspace ID (<slug>-<hash>)
      raw_slug = File.basename(root).gsub(/[^a-zA-Z0-9_-]/, "_")
      slug = (raw_slug.empty? || raw_slug == "_") ? "root" : raw_slug
      hash = Digest::SHA256.hexdigest(root)[0..7]
      workspace_id = "#{slug}-#{hash}"

      # F1.4: Central XDG Base Directory Resolution
      xdg_config_home = ENV["XDG_CONFIG_HOME"]?.presence || File.join(Path.home, ".config")
      xdg_state_home = ENV["XDG_STATE_HOME"]?.presence || File.join(Path.home, ".local", "state")
      xdg_cache_home = ENV["XDG_CACHE_HOME"]?.presence || File.join(Path.home, ".cache")

      config_dir = File.join(xdg_config_home, "nightmare", "workspaces", workspace_id)
      state_dir = File.join(xdg_state_home, "nightmare", "workspaces", workspace_id)
      cache_dir = File.join(xdg_cache_home, "nightmare", "workspaces", workspace_id)
      global_config_dir = File.join(xdg_config_home, "nightmare")

      # Bootstrap central directories (Zero repo litter - F1.5)
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(state_dir)
      FileUtils.mkdir_p(cache_dir)

      manifest_path = File.join(config_dir, "workspace.json")
      allowlist_path = File.join(config_dir, "allow")
      log_path = File.join(state_dir, "llm_calls.jsonl")
      workspace_prompt_path = File.join(config_dir, "prompt.md")
      repo_prompt_path = File.join(root, ".nightmare", "prompt.md")
      global_prompt_path = File.join(global_config_dir, "prompt.md")

      # Bootstrap workspace.json manifest
      manifest = Manifest.load_or_create(manifest_path, workspace_id, root)

      new(
        root: root,
        workspace_id: workspace_id,
        config_dir: config_dir,
        state_dir: state_dir,
        cache_dir: cache_dir,
        allowlist_path: allowlist_path,
        log_path: log_path,
        manifest_path: manifest_path,
        workspace_prompt_path: workspace_prompt_path,
        repo_prompt_path: repo_prompt_path,
        global_prompt_path: global_prompt_path,
        manifest: manifest
      )
    end

    # Checks whether a canonical path is strictly inside or equal to the workspace root.
    # Prevents prefix spoofing (e.g. /tmp/repo vs /tmp/repo_attack).
    def inside_root?(path : String) : Bool
      prefix = @root.ends_with?('/') ? @root : "#{@root}/"
      path == @root || path.starts_with?(prefix)
    end

    # Validates and sanitizes a path. Resolves symlinks and ensures containment.
    # Raises Nightmare::SecurityError if path escapes root.
    def sanitize_path(path : String) : String
      target = Path[path].absolute? ? File.expand_path(path) : File.expand_path(path, @root)

      resolved = if File.exists?(target)
        File.realpath(target)
      else
        # For non-existent files (e.g. new files created by tools),
        # walk up ancestors to resolve symlinks in the existing parent hierarchy
        curr = target
        tail_parts = [] of String
        while !File.exists?(curr) && curr != "/" && curr != "."
          tail_parts.unshift(File.basename(curr))
          curr = File.dirname(curr)
        end
        base = File.exists?(curr) ? File.realpath(curr) : curr
        tail_parts.empty? ? base : File.join(base, tail_parts.join("/"))
      end

      unless inside_root?(resolved)
        raise Nightmare::SecurityError.new(
          "Path traversal violation: target '#{path}' resolves to '#{resolved}' outside workspace root '#{@root}'"
        )
      end

      resolved
    end

    # Formats the startup box-drawing notification banner (F1.7)
    def startup_banner : String
      home = Path.home.to_s
      display_config = @config_dir.starts_with?(home) ? @config_dir.sub(home, "~") : @config_dir
      display_state = @state_dir.starts_with?(home) ? @state_dir.sub(home, "~") : @state_dir

      display_config = "#{display_config}/" unless display_config.ends_with?('/')
      display_state = "#{display_state}/" unless display_state.ends_with?('/')

      line1 = "Workspace : #{@root}"
      line2 = "Config    : #{display_config}"
      line3 = "State/Logs: #{display_state}"

      max_content = [line1.size, line2.size, line3.size].max
      inner_width = [max_content + 2, 72].max
      total_width = inner_width + 4

      title = " NIGHTMARE "
      dash_count = total_width - 3 - title.size
      top_border = "┌──#{title}#{"─" * [dash_count, 1].max}┐"
      bottom_border = "└#{"─" * (total_width - 2)}┘"

      format_line = ->(text : String) {
        padding = inner_width - text.size
        "│ #{text}#{" " * [padding, 0].max} │"
      }

      String.build do |str|
        str.puts top_border
        str.puts format_line.call(line1)
        str.puts format_line.call(line2)
        str.puts format_line.call(line3)
        str.print bottom_border
      end
    end
  end
end
```

---

### 3.4 `src/nightmare/directives/resolver.cr` (F1.6, F1.8)

Implements the 5-tier directive resolution hierarchy and the in-memory mutable `DirectiveBuffer`.

```crystal
require "../workspace/environment"

module Nightmare::Directives
  enum Source
    CliFlag
    RepoOverride
    WorkspaceConfig
    GlobalConfig
    DefaultPersona
  end

  class Resolver
    DEFAULT_PERSONA = <<-MARKDOWN
    You are an execution agent operating in the current working directory.
    - Inspect files and execute tools to determine facts before taking action.
    - Prefer replace_in_file for edits; read before you write; never overwrite a file you have not inspected this session.
    - Be concise, direct, and factual.
    - Do not assume context; rely strictly on provided files, tool outputs, and user instructions.
    MARKDOWN.strip

    # Resolves directive text according to 5-tier precedence hierarchy:
    # 1. CLI flag (-s / --system)
    # 2. Repo committed override (.nightmare/prompt.md in root)
    # 3. Workspace central config ($XDG_CONFIG_HOME/nightmare/workspaces/<id>/prompt.md)
    # 4. Global central config ($XDG_CONFIG_HOME/nightmare/prompt.md)
    # 5. Default General Persona (fallback)
    def self.resolve(env : Workspace::Environment, cli_override : String? = nil) : String
      text, _source = resolve_with_source(env, cli_override)
      text
    end

    def self.resolve_with_source(env : Workspace::Environment, cli_override : String? = nil) : Tuple(String, Source)
      # Tier 1: CLI Override
      if cli_path = cli_override
        expanded = File.expand_path(cli_path)
        unless File.exists?(expanded)
          raise ArgumentError.new("System directive file not found: #{cli_path}")
        end
        return {File.read(expanded).strip, Source::CliFlag}
      end

      # Tier 2: Repository Override (.nightmare/prompt.md)
      if File.exists?(env.repo_prompt_path)
        return {File.read(env.repo_prompt_path).strip, Source::RepoOverride}
      end

      # Tier 3: Workspace Central Config
      if File.exists?(env.workspace_prompt_path)
        return {File.read(env.workspace_prompt_path).strip, Source::WorkspaceConfig}
      end

      # Tier 4: Global Central Config
      if File.exists?(env.global_prompt_path)
        return {File.read(env.global_prompt_path).strip, Source::GlobalConfig}
      end

      # Tier 5: Default General Persona
      {DEFAULT_PERSONA, Source::DefaultPersona}
    end
  end

  # F1.8: In-Memory Directive Buffer
  # Manages the active directive in RAM. /prompt edit launches an editor on a tempfile,
  # updating only the in-memory string upon exit without modifying any underlying files on disk.
  class DirectiveBuffer
    property current_text : String
    getter source : Source

    def initialize(@current_text : String, @source : Source = Source::DefaultPersona)
    end

    def self.from_environment(env : Workspace::Environment, cli_override : String? = nil) : DirectiveBuffer
      text, source = Resolver.resolve_with_source(env, cli_override)
      new(text, source)
    end

    # Opens $EDITOR on a tempfile containing current_text.
    # Updates current_text on clean exit. Underlying disk files remain untouched.
    def edit!(editor_command : String? = nil) : Bool
      editor = editor_command || ENV["EDITOR"]? || ENV["VISUAL"]? || (Process.find_executable("nano") ? "nano" : "vim")
      tempfile = File.tempfile("nightmare_prompt", ".md")
      begin
        File.write(tempfile.path, @current_text)
        status = Process.run(
          editor,
          [tempfile.path],
          input: Process::Redirect::Inherit,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit
        )
        if status.success?
          @current_text = File.read(tempfile.path).strip
          true
        else
          false
        end
      ensure
        tempfile.delete if File.exists?(tempfile.path)
      end
    end
  end
end
```

---

### 3.5 `src/nightmare.cr` (Entrypoint & Root Namespace)

Wires together the top-level namespace, defines `Nightmare::SecurityError`, sets up the CLI option parser (`-s`, `--system`, `--no-log`, `-v`, `-h`), and prevents CLI execution during specs using the macro guard `{% if !@top_level.has_constant?("Spec") %}`.

```crystal
require "option_parser"
require "mantle"
require "salamander"
require "./nightmare/workspace/manifest"
require "./nightmare/workspace/environment"
require "./nightmare/directives/resolver"

module Nightmare
  VERSION = "0.1.0"

  class SecurityError < Exception
  end

  class CLI
    def self.run(args : Array(String) = ARGV)
      cli_prompt : String? = nil
      no_log = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: nightmare [options]"
        opts.on("-s PATH", "--system PATH", "Path to custom system directive") do |path|
          cli_prompt = path
        end
        opts.on("--no-log", "Disable LLM call logging") do
          no_log = true
        end
        opts.on("-v", "--version", "Display version") do
          puts "NIGHTMARE #{VERSION}"
          exit 0
        end
        opts.on("-h", "--help", "Display this help screen") do
          puts opts
          exit 0
        end
      end

      parser.parse(args)

      env = Workspace::Environment.resolve
      directive = Directives::Resolver.resolve(env, cli_prompt)
      puts env.startup_banner
      # Future milestones will wire up Context, Harness, and Salamander REPL here
    end
  end
end

{% if !@top_level.has_constant?("Spec") %}
  Nightmare::CLI.run
{% end %}
```

---

### 3.6 `spec/spec_helper.cr`

Provides isolated test harnesses: `with_temp_dir` for isolated workspaces/XDG homes and `with_env` for scoped environment overrides.

```crystal
require "spec"
require "../src/nightmare"
require "file_utils"

# Creates an isolated temporary directory, yields the canonical path, and cleans it up afterward.
def with_temp_dir(& : String -> Nil)
  dir = File.tempfile("nightmare_spec_dir").path
  File.delete(dir) if File.exists?(dir)
  Dir.mkdir_p(dir)
  begin
    yield File.realpath(dir)
  ensure
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

# Scopes environment variable modifications to a block and restores them afterwards.
def with_env(vars : Hash(String, String?), &)
  original = {} of String => String?
  vars.each do |k, v|
    original[k] = ENV[k]?
    if v.nil?
      ENV.delete(k)
    else
      ENV[k] = v
    end
  end

  begin
    yield
  ensure
    original.each do |k, v|
      if v.nil?
        ENV.delete(k)
      else
        ENV[k] = v
      end
    end
  end
end
```

---

### 3.7 `spec/nightmare_spec.cr`

Fixes the existing failing spec placeholder (`false.should eq(true)`) to test `Nightmare::VERSION`:

```crystal
require "./spec_helper"

describe Nightmare do
  it "defines the current VERSION" do
    Nightmare::VERSION.should eq("0.1.0")
  end

  it "defines SecurityError exception type" do
    ex = Nightmare::SecurityError.new("Test violation")
    ex.should be_a(Exception)
    ex.message.should eq("Test violation")
  end
end
```

---

### 3.8 `spec/workspace_spec.cr`

Tests all workspace features: canonical root anchoring, deterministic workspace ID, central XDG isolation, zero repo litter, path traversal detection, symlink safety, manifest persistence, and banner generation.

```crystal
require "./spec_helper"

describe Nightmare::Workspace do
  describe Nightmare::Workspace::Environment do
    it "anchors to canonical realpath of current directory" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            env.root.should eq(dir)
          end
        end
      end
    end

    it "raises ArgumentError when workspace directory does not exist" do
      expect_raises(ArgumentError, /Workspace directory does not exist/) do
        Nightmare::Workspace::Environment.resolve("/non/existent/path/for/sure")
      end
    end

    it "generates deterministic workspace_id with sanitized slug and 8-character sha256 hash" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env1 = Nightmare::Workspace::Environment.resolve(dir)
            env2 = Nightmare::Workspace::Environment.resolve(dir)
            env1.workspace_id.should eq(env2.workspace_id)

            expected_slug = File.basename(dir).gsub(/[^a-zA-Z0-9_-]/, "_")
            expected_hash = Digest::SHA256.hexdigest(dir)[0..7]
            env1.workspace_id.should eq("#{expected_slug}-#{expected_hash}")
          end
        end
      end
    end

    it "enforces central XDG directory structure without writing inside target repo" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)

            Dir.exists?(env.config_dir).should be_true
            Dir.exists?(env.state_dir).should be_true
            Dir.exists?(env.cache_dir).should be_true

            # Zero repo litter invariant
            Dir.children(dir).should be_empty
          end
        end
      end
    end

    it "creates and touches workspace.json manifest in XDG config dir" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env1 = Nightmare::Workspace::Environment.resolve(dir)
            File.exists?(env1.manifest_path).should be_true

            manifest = Nightmare::Workspace::Manifest.from_json(File.read(env1.manifest_path))
            manifest.id.should eq(env1.workspace_id)
            manifest.canonical_path.should eq(dir)
            first_access = manifest.last_accessed

            sleep 5.milliseconds
            env2 = Nightmare::Workspace::Environment.resolve(dir)
            manifest2 = Nightmare::Workspace::Manifest.from_json(File.read(env2.manifest_path))
            (manifest2.last_accessed >= first_access).should be_true
          end
        end
      end
    end

    describe "#inside_root?" do
      it "returns true for paths inside root or root itself" do
        with_temp_dir do |dir|
          with_temp_dir do |xdg|
            with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
              env = Nightmare::Workspace::Environment.resolve(dir)
              env.inside_root?(dir).should be_true
              env.inside_root?(File.join(dir, "src", "app.cr")).should be_true
            end
          end
        end
      end

      it "returns false for paths sharing a prefix but outside root (prefix confusion attack)" do
        with_temp_dir do |dir|
          with_temp_dir do |xdg|
            with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
              env = Nightmare::Workspace::Environment.resolve(dir)
              fake_dir = "#{dir}_attack"
              env.inside_root?(fake_dir).should be_false
            end
          end
        end
      end
    end

    describe "#sanitize_path" do
      it "allows valid relative and absolute paths within root" do
        with_temp_dir do |dir|
          with_temp_dir do |xdg|
            with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
              env = Nightmare::Workspace::Environment.resolve(dir)
              File.write(File.join(dir, "file.txt"), "hello")

              env.sanitize_path("file.txt").should eq(File.join(dir, "file.txt"))
              env.sanitize_path(File.join(dir, "file.txt")).should eq(File.join(dir, "file.txt"))
            end
          end
        end
      end

      it "rejects path traversal attempts with SecurityError" do
        with_temp_dir do |dir|
          with_temp_dir do |xdg|
            with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
              env = Nightmare::Workspace::Environment.resolve(dir)

              expect_raises(Nightmare::SecurityError, /Path traversal violation/) do
                env.sanitize_path("../escaped.txt")
              end

              expect_raises(Nightmare::SecurityError, /Path traversal violation/) do
                env.sanitize_path("foo/../../escaped.txt")
              end

              expect_raises(Nightmare::SecurityError, /Path traversal violation/) do
                env.sanitize_path("/etc/passwd")
              end
            end
          end
        end
      end

      it "rejects symlinks pointing outside the workspace root" do
        with_temp_dir do |dir|
          with_temp_dir do |outside|
            with_temp_dir do |xdg|
              with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
                File.write(File.join(outside, "secret.txt"), "classified")
                symlink_path = File.join(dir, "link_to_outside")
                File.symlink(outside, symlink_path)

                env = Nightmare::Workspace::Environment.resolve(dir)
                expect_raises(Nightmare::SecurityError, /Path traversal violation/) do
                  env.sanitize_path("link_to_outside/secret.txt")
                end
              end
            end
          end
        end
      end
    end

    describe "#startup_banner" do
      it "renders a box banner containing root, config path, and state path" do
        with_temp_dir do |dir|
          with_temp_dir do |xdg|
            with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
              env = Nightmare::Workspace::Environment.resolve(dir)
              banner = env.startup_banner

              banner.should contain("┌── NIGHTMARE ")
              banner.should contain("Workspace : #{dir}")
              banner.should contain("Config    :")
              banner.should contain(env.workspace_id)
              banner.should contain("State/Logs:")
              banner.should contain("└")
              banner.should contain("┘")
            end
          end
        end
      end
    end
  end
end
```

---

### 3.9 `spec/directives_spec.cr`

Tests the 5-tier directive resolution hierarchy and in-memory mutation.

```crystal
require "./spec_helper"

describe Nightmare::Directives do
  describe Nightmare::Directives::Resolver do
    it "resolves Tier 5 (Default General Persona) when no overrides exist" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            content, source = Nightmare::Directives::Resolver.resolve_with_source(env)
            source.should eq(Nightmare::Directives::Source::DefaultPersona)
            content.should eq(Nightmare::Directives::Resolver::DEFAULT_PERSONA)
            content.should contain("You are an execution agent operating in the current working directory.")
          end
        end
      end
    end

    it "resolves Tier 4 (Global Central Config) when global prompt.md exists" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            global_prompt = File.join(xdg, "nightmare", "prompt.md")
            File.write(global_prompt, "Global custom prompt")

            content, source = Nightmare::Directives::Resolver.resolve_with_source(env)
            source.should eq(Nightmare::Directives::Source::GlobalConfig)
            content.should eq("Global custom prompt")
          end
        end
      end
    end

    it "resolves Tier 3 (Workspace Central Config) over Tier 4 and Tier 5" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            global_prompt = File.join(xdg, "nightmare", "prompt.md")
            File.write(global_prompt, "Global prompt")
            File.write(env.workspace_prompt_path, "Workspace custom prompt")

            content, source = Nightmare::Directives::Resolver.resolve_with_source(env)
            source.should eq(Nightmare::Directives::Source::WorkspaceConfig)
            content.should eq("Workspace custom prompt")
          end
        end
      end
    end

    it "resolves Tier 2 (Repo Committed Override) over Tiers 3, 4, and 5" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            File.write(env.workspace_prompt_path, "Workspace custom prompt")
            Dir.mkdir_p(File.join(dir, ".nightmare"))
            File.write(env.repo_prompt_path, "Repo committed prompt")

            content, source = Nightmare::Directives::Resolver.resolve_with_source(env)
            source.should eq(Nightmare::Directives::Source::RepoOverride)
            content.should eq("Repo committed prompt")
          end
        end
      end
    end

    it "resolves Tier 1 (CLI Flag Override) as highest priority over all other tiers" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            Dir.mkdir_p(File.join(dir, ".nightmare"))
            File.write(env.repo_prompt_path, "Repo committed prompt")

            cli_prompt_file = File.join(dir, "custom_cli_prompt.md")
            File.write(cli_prompt_file, "CLI forced prompt")

            content, source = Nightmare::Directives::Resolver.resolve_with_source(env, cli_prompt_file)
            source.should eq(Nightmare::Directives::Source::CliFlag)
            content.should eq("CLI forced prompt")
          end
        end
      end
    end

    it "raises ArgumentError when CLI prompt file does not exist" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            expect_raises(ArgumentError, /System directive file not found/) do
              Nightmare::Directives::Resolver.resolve(env, "/non/existent/prompt.md")
            end
          end
        end
      end
    end
  end

  describe Nightmare::Directives::DirectiveBuffer do
    it "allows mutating prompt in-memory without modifying files on disk" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            File.write(env.workspace_prompt_path, "Initial disk prompt")

            buffer = Nightmare::Directives::DirectiveBuffer.from_environment(env)
            buffer.current_text.should eq("Initial disk prompt")

            # Mock editor execution using a non-interactive sed command
            sed_editor = "sed -i 's/Initial disk/Mutated in-memory/'"
            result = buffer.edit!(sed_editor)
            result.should be_true
            buffer.current_text.should eq("Mutated in-memory prompt")

            # Disk file remains untouched
            File.read(env.workspace_prompt_path).should eq("Initial disk prompt")
          end
        end
      end
    end
  end
end
```

---

## 4. Step-by-Step Worker Execution Sequence

The worker should execute the tasks in this exact order:

```text
Step 1: Configure shard.yml
  └── Update shard.yml with path dependencies: mantle, salamander, tts_kokoro.
Step 2: Install Shards
  └── Run `shards install` with `BypassSandbox: true`.
  └── Verify symlinks in lib/ and verify `shards check`.
Step 3: Implement spec/spec_helper.cr
  └── Write `with_temp_dir` and `with_env` isolation helpers.
Step 4: Fix spec/nightmare_spec.cr
  └── Replace placeholder `false.should eq(true)` with version/SecurityError assertions.
Step 5: Implement src/nightmare/workspace/manifest.cr
  └── Manifest struct with load_or_create, touch, save, and JSON serialization.
Step 6: Implement src/nightmare/workspace/environment.cr
  └── Root anchor, deterministic slug-hash ID, XDG paths, sanitize_path, inside_root?, startup_banner.
Step 7: Implement src/nightmare/directives/resolver.cr
  └── 5-tier Resolver, DEFAULT_PERSONA, and DirectiveBuffer.
Step 8: Implement src/nightmare.cr
  └── Top-level namespace, SecurityError, CLI parser, and spec-guarded execution macro.
Step 9: Implement spec/workspace_spec.cr
  └── Run `crystal spec spec/workspace_spec.cr`. Verify all tests pass.
Step 10: Implement spec/directives_spec.cr
  └── Run `crystal spec spec/directives_spec.cr`. Verify all tests pass.
Step 11: Full Verification
  └── Run `crystal spec` across entire test suite. Verify 0 failures, 0 errors.
  └── Run `shards build` to verify clean compilation with 0 warnings.
  └── Execute `./bin/nightmare --help` and `./bin/nightmare --version` to verify CLI behavior.
```

---

## 5. Verification Strategy & Acceptance Criteria

### 5.1 Passing Criteria Checklist

| Check | Target | Command | Expected Outcome |
| :--- | :--- | :--- | :--- |
| **Dependency Resolution** | `shard.yml`, `lib/` | `shards check` | `Dependencies are satisfied`, zero errors |
| **Clean Build** | `bin/nightmare` | `shards build` | Exit code 0, zero compiler warnings, binary produced at `bin/nightmare` |
| **Unit Spec Pass** | `spec/` | `crystal spec` | 100% examples passing, 0 failures, 0 errors, 0 pending |
| **Security Validation** | `sanitize_path` | `crystal spec spec/workspace_spec.cr` | `../` traversals and external symlinks raise `Nightmare::SecurityError` |
| **Prefix Bound Check** | `inside_root?` | `crystal spec spec/workspace_spec.cr` | `/tmp/repo_attack` rejected when root is `/tmp/repo` |
| **Zero Repo Litter** | Workspace root | `crystal spec spec/workspace_spec.cr` | Target directory has 0 created files; all files go to XDG |
| **Directives Tiers** | Precedence | `crystal spec spec/directives_spec.cr` | Tiers 1 through 5 resolve in strict hierarchical order |
| **In-Memory Buffer** | `DirectiveBuffer` | `crystal spec spec/directives_spec.cr` | Prompt mutated in RAM; disk files untouched |
| **CLI Functionality** | Binary | `./bin/nightmare -v` | Outputs `NIGHTMARE 0.1.0` |

### 5.2 Verification Commands (Exact Shapes)

Worker must execute these commands with `Cwd: /home/cam/repos/adjutant/nightmare` and `BypassSandbox: true`:

```bash
# 1. Dependency check
shards check

# 2. Workspace unit tests
crystal spec spec/workspace_spec.cr

# 3. Directives unit tests
crystal spec spec/directives_spec.cr

# 4. Entire test suite
crystal spec

# 5. Shards build (zero warnings)
shards build

# 6. Binary smoke test
./bin/nightmare --version
```

---

## 6. Hazard Prevention & Anti-Patterns

1. **Path Prefix Spoofing**:
   - *Hazard*: Writing `path.starts_with?(@root)` allows `/tmp/target_evil` when `@root` is `/tmp/target`.
   - *Fix*: `inside_root?` must enforce `prefix = @root.ends_with?('/') ? @root : "#{@root}/"` and test `path == @root || path.starts_with?(prefix)`.
2. **CLI Runner Invoked During Specs**:
   - *Hazard*: Calling `Nightmare::CLI.run` directly at the top level of `src/nightmare.cr` causes the CLI OptionParser to parse `crystal spec` arguments, crashing test runs.
   - *Fix*: Wrap entry point invocation in `{% if !@top_level.has_constant?("Spec") %} Nightmare::CLI.run {% end %}`.
3. **Transient Transitive Dependency Failure (`tts_kokoro`)**:
   - *Hazard*: Omitting `tts_kokoro: path: ../tts_kokoro` from `nightmare/shard.yml` can cause `shards install` to attempt remote git fetches because `salamander` depends on `tts_kokoro`.
   - *Fix*: Declare all three path dependencies (`mantle`, `salamander`, `tts_kokoro`) explicitly in `shard.yml`.
4. **Target Workspace Littering**:
   - *Hazard*: Creating `.nightmare/` or `workspace.json` in `@root`.
   - *Fix*: Only read `.nightmare/prompt.md` if it was already committed; NEVER auto-create it. All state, manifests, and configs MUST be created under XDG directories outside `@root`.
5. **Multi-Repo Git / Command Chaining Violation**:
   - *Hazard*: Running `git -C nightmare status` or chaining `shards install && crystal spec`.
   - *Fix*: Set `Cwd` directly to `/home/cam/repos/adjutant/nightmare`, run commands individually, and set `BypassSandbox: true`.
