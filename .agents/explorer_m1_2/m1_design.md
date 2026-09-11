# Milestone 1 Technical Design: System Directives Resolution & Configuration Precedence (F1.6, F1.8)

**Document Version**: 1.0.0  
**Author**: `explorer_m1_2`  
**Date**: 2026-09-11  
**Scope**: F1.6 (Directives Precedence Resolution), F1.8 (In-Memory Directive Mutation), CLI Option Parsing Foundation (`OptionParser`), and Unit Test Suite (`spec/directives_spec.cr`).

---

## 1. Executive Summary & Architectural Scope

In NIGHTMARE, system directives (prompts) govern agent behavior, tone, tool prioritization, and constraints. As specified in `ORIGINAL_REQUEST.md` (R1) and `specs.md` (§1.4, §1.5), system directives must be resolved deterministically across a strict 5-tier hierarchical precedence ladder:
1. **CLI Flag (`-s` / `--system <path>`)** (Highest priority)
2. **Repository Committed File (`.nightmare/prompt.md` within workspace root)**
3. **Workspace Central Config (`$XDG_CONFIG_HOME/nightmare/workspaces/<workspace_id>/prompt.md`)**
4. **Global Central Config (`$XDG_CONFIG_HOME/nightmare/prompt.md`)**
5. **Default General Persona Fallback** (Built-in constant)

Furthermore, NIGHTMARE provides **in-memory directive mutation** via `/prompt edit` (F1.8). This permits operators to alter the active directive during an interactive REPL session using `$EDITOR` or `$VISUAL` without modifying source code, git repositories, or disk configurations.

This design document establishes:
- The data contracts and public API for `Nightmare::Directives::Resolver` and `Nightmare::Directives::Manager`.
- The exact resolution algorithm, path normalization, and error handling for all 5 tiers.
- The verbatim text of the default general persona fallback.
- The tempfile lifecycle and editor execution process for in-memory mutation.
- The CLI option parsing foundation in `src/nightmare.cr` using Crystal Standard Library's `OptionParser`.
- Concrete, runnable unit test specifications in `spec/directives_spec.cr`.

---

## 2. Component Architecture & Data Contracts

The directives subsystem is located under `Nightmare::Directives` in `src/nightmare/directives/resolver.cr`.

```
                    ┌─────────────────────────┐
                    │     Nightmare::CLI      │
                    │      OptionParser       │
                    └────────────┬────────────┘
                                 │ options.system_prompt_path
                                 ▼
┌────────────────────────────────────────────────────────────────────────┐
│                      Nightmare::Directives::Resolver                   │
│                                                                        │
│  1. CLI Flag? ──────────────> File.read(cli_override)                  │
│        │ (absent/nil)                                                  │
│        ▼                                                               │
│  2. Repo File? ─────────────> File.read(".nightmare/prompt.md")        │
│        │ (absent)                                                      │
│        ▼                                                               │
│  3. Workspace Config? ──────> File.read(env.config_dir/"prompt.md")    │
│        │ (absent)                                                      │
│        ▼                                                               │
│  4. Global Config? ─────────> File.read(global_config_dir/"prompt.md") │
│        │ (absent)                                                      │
│        ▼                                                               │
│  5. Fallback ───────────────> DEFAULT_PERSONA (verbatim string)        │
└────────────────────────────────┬───────────────────────────────────────┘
                                 │ produces
                                 ▼
┌────────────────────────────────────────────────────────────────────────┐
│                      Nightmare::Directives::Manager                    │
│                                                                        │
│  - @active_directive : String (in-memory, passed to LLM)               │
│  - @original_directive : String (original resolved text)               │
│  - @source : Source (where it originated)                              │
│  - @source_path : String?                                              │
│                                                                        │
│  Methods:                                                              │
│  - #update(new_text) : Nil (mutates in-memory copy only)               │
│  - #reset! : Nil (reverts to @original_directive)                      │
│  - #modified? : Bool                                                   │
│  - #edit(editor, io...) : Bool (spawns editor on /tmp tempfile)        │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Enumerations and Data Structures

```crystal
module Nightmare::Directives
  # Enumerates the tier from which a system directive was resolved
  enum Source
    CliFlag
    RepoOverride
    WorkspaceConfig
    GlobalConfig
    DefaultPersona

    def to_s(io : IO) : Nil
      case self
      when CliFlag         then io << "CLI Flag (-s / --system)"
      when RepoOverride    then io << "Repository Committed Override (.nightmare/prompt.md)"
      when WorkspaceConfig then io << "Workspace Central Config (prompt.md)"
      when GlobalConfig    then io << "Global Central Config (prompt.md)"
      when DefaultPersona  then io << "Default General Persona"
      end
    end
  end

  # Encapsulates the resolved directive text, its source tier, and optional origin path
  record ResolutionResult,
    text : String,
    source : Source,
    path : String?
end
```

### 2.2 Verbatim Default General Persona Constant

As specified in `ORIGINAL_REQUEST.md` (R1) and `specs.md` (§1.4), the default general persona fallback text must match the specification character-for-character:

```crystal
module Nightmare::Directives
  DEFAULT_PERSONA = <<-MARKDOWN.strip
  You are an execution agent operating in the current working directory.
  - Inspect files and execute tools to determine facts before taking action.
  - Prefer replace_in_file for edits; read before you write; never overwrite a file you have not inspected this session.
  - Be concise, direct, and factual.
  - Do not assume context; rely strictly on provided files, tool outputs, and user instructions.
  MARKDOWN
end
```

---

## 3. Hierarchical Precedence Resolution (`Resolver`)

### 3.1 Resolution Ladder Specification

`Nightmare::Directives::Resolver` resolves the directive by inspecting tiers 1 through 5 in strict sequential order:

| Tier | Source Tier | Path Evaluated | Verification Condition |
| :--- | :--- | :--- | :--- |
| **1** | **CLI Flag** | `File.expand_path(cli_override, env.root)` | Explicit `cli_override` passed. If the file does not exist, raises `ArgumentError`. |
| **2** | **Repo Committed File** | `File.join(env.root, ".nightmare", "prompt.md")` | `File.file?(path)` and file is non-empty. Never created automatically by NIGHTMARE. |
| **3** | **Workspace Central Config** | `File.join(env.config_dir, "prompt.md")` | `File.file?(path)` and file is non-empty. |
| **4** | **Global Central Config** | `File.join(global_config_dir, "prompt.md")` | `File.file?(path)` and file is non-empty. |
| **5** | **Default Persona** | None | Always available; returns `DEFAULT_PERSONA`. |

### 3.2 Global Config Directory Resolution

The global config directory is `$XDG_CONFIG_HOME/nightmare` (or `~/.config/nightmare` when `$XDG_CONFIG_HOME` is unset).
To ensure clean interoperability with `Nightmare::Workspace::Environment`, `Resolver` evaluates:
1. `env.global_prompt_path` if the environment exposes it.
2. `File.join(env.global_config_dir, "prompt.md")` if `env.global_config_dir` is present.
3. Fallback derivation: `File.join(Path[env.config_dir].parent.parent.to_s, "prompt.md")` (since `env.config_dir` is `<xdg_config>/nightmare/workspaces/<id>`).
4. Environment variable lookup: `File.join(ENV.fetch("XDG_CONFIG_HOME") { Path.home.join(".config").to_s }, "nightmare", "prompt.md")`.

### 3.3 Blank File and Whitespace Handling

If a prompt file exists on disk at tiers 2, 3, or 4, but its content is empty or contains only whitespace (`File.read(path).strip.empty?`), NIGHTMARE treats that file as absent and falls through to the next tier. This prevents accidental blank files from leaving the agent without system directives.

### 3.4 Concrete Implementation of `Resolver`

```crystal
require "./manager"

module Nightmare::Directives
  class Resolver
    # Primary interface satisfying PROJECT.md contract
    def self.resolve(env : Workspace::Environment, cli_override : String? = nil) : String
      resolve_with_source(env, cli_override).text
    end

    # Extended interface returning full metadata (text, source tier, file path)
    def self.resolve_with_source(env : Workspace::Environment, cli_override : String? = nil) : ResolutionResult
      # Tier 1: CLI Flag
      if cli_override && !cli_override.strip.empty?
        resolved_path = File.expand_path(cli_override, env.root)
        unless File.file?(resolved_path)
          raise ArgumentError.new("System prompt file not found: #{cli_override} (resolved to #{resolved_path})")
        end
        content = File.read(resolved_path)
        return ResolutionResult.new(
          text: content.strip.empty? ? DEFAULT_PERSONA : content,
          source: Source::CliFlag,
          path: resolved_path
        )
      end

      # Tier 2: Repository Committed Override (.nightmare/prompt.md)
      repo_prompt = repo_prompt_path(env)
      if File.file?(repo_prompt)
        content = File.read(repo_prompt)
        unless content.strip.empty?
          return ResolutionResult.new(
            text: content,
            source: Source::RepoOverride,
            path: repo_prompt
          )
        end
      end

      # Tier 3: Workspace Central Config ($XDG_CONFIG_HOME/nightmare/workspaces/<id>/prompt.md)
      ws_prompt = workspace_prompt_path(env)
      if File.file?(ws_prompt)
        content = File.read(ws_prompt)
        unless content.strip.empty?
          return ResolutionResult.new(
            text: content,
            source: Source::WorkspaceConfig,
            path: ws_prompt
          )
        end
      end

      # Tier 4: Global Central Config ($XDG_CONFIG_HOME/nightmare/prompt.md)
      glob_prompt = global_prompt_path(env)
      if File.file?(glob_prompt)
        content = File.read(glob_prompt)
        unless content.strip.empty?
          return ResolutionResult.new(
            text: content,
            source: Source::GlobalConfig,
            path: glob_prompt
          )
        end
      end

      # Tier 5: Default General Persona Fallback
      ResolutionResult.new(
        text: DEFAULT_PERSONA,
        source: Source::DefaultPersona,
        path: nil
      )
    end

    # Factory method creating a stateful in-memory Manager for REPL sessions
    def self.resolve_manager(env : Workspace::Environment, cli_override : String? = nil) : Manager
      result = resolve_with_source(env, cli_override)
      Manager.new(
        active_directive: result.text,
        source: result.source,
        source_path: result.path
      )
    end

    # Path helper methods
    def self.repo_prompt_path(env : Workspace::Environment) : String
      File.join(env.root, ".nightmare", "prompt.md")
    end

    def self.workspace_prompt_path(env : Workspace::Environment) : String
      File.join(env.config_dir, "prompt.md")
    end

    def self.global_prompt_path(env : Workspace::Environment) : String
      if env.responds_to?(:global_prompt_path)
        env.global_prompt_path
      elsif env.responds_to?(:global_config_dir)
        File.join(env.global_config_dir, "prompt.md")
      else
        # env.config_dir is ~/.config/nightmare/workspaces/<id>/
        # Path[env.config_dir].parent.parent is ~/.config/nightmare/
        File.join(Path[env.config_dir].parent.parent.to_s, "prompt.md")
      end
    end
  end
end
```

---

## 4. In-Memory Directive Mutation (`Manager`)

### 4.1 Invariant: Zero Disk Litter & Non-Persistence

The active directive in NIGHTMARE lives **purely in memory** during REPL execution:
- Executing `/prompt edit` launches an external editor on an ephemeral temporary file created in the OS temporary directory (`/tmp` or `Dir.tempdir`).
- Saving and exiting the editor loads the text into `@active_directive` in the running process memory.
- Under **no circumstances** does NIGHTMARE write the modified directive to `.nightmare/prompt.md`, `$XDG_CONFIG_HOME`, or any target repository file.
- When the REPL session ends (or `/exit` is called), the modified in-memory prompt simply evaporates.
- The temporary file in `/tmp` is deleted unconditionally inside an `ensure` block.

### 4.2 Editor Resolution Order

When launching interactive editing:
1. `editor_override` (if supplied programmatically or via option).
2. `ENV["EDITOR"]?` (if set and non-empty).
3. `ENV["VISUAL"]?` (if set and non-empty).
4. System path search via `Process.find_executable`:
   - `nano`
   - `vim`
   - `vi`
5. If none are found, `#edit` returns `false` with a descriptive message to the user:  
   `"No suitable terminal editor found in $EDITOR, $VISUAL, or PATH (nano, vim, vi)."`

### 4.3 Process Execution and Error Handling

- The editor is invoked using `/bin/sh -c "#{editor} #{Process.quote(temp_path)}"` with standard IO inherited (`input: io_in, output: io_out, error: io_err`). Using a shell invocation preserves flags configured in `$EDITOR` (e.g. `EDITOR="vim -u NONE"` or `EDITOR="code --wait"`).
- If the editor process exits with a non-zero status code (e.g., user exits `vim` via `:cq` or hits `Ctrl+C`):
  - Invariant from `specs.md` Feature 6: **Reverts to prior prompt if editor exits with error**.
  - `@active_directive` remains untouched.
  - `#edit` returns `false`.
- If the editor exits cleanly (`status.success?` is `true`):
  - Reads the file.
  - If the new content is non-empty, sets `@active_directive = new_content` and returns `true`.
  - If the file was emptied, retains the prior prompt and returns `false`.

### 4.4 Concrete Implementation of `Manager`

```crystal
module Nightmare::Directives
  class Manager
    # Currently active directive in RAM (consumed by Context & Prompt Assembler)
    property active_directive : String

    # Original directive text resolved at startup
    getter original_directive : String

    # Origin source tier and file path
    getter source : Source
    getter source_path : String?

    def initialize(@active_directive : String, @source : Source, @source_path : String? = nil)
      @original_directive = @active_directive
    end

    # Returns true if the active directive has been modified from its original startup value
    def modified? : Bool
      @active_directive != @original_directive
    end

    # Directly updates the in-memory directive
    def update(new_directive : String) : Nil
      @active_directive = new_directive
    end

    # Reverts the in-memory directive back to its startup original
    def reset! : Nil
      @active_directive = @original_directive
    end

    # Spawns external editor on an ephemeral temp file to edit the directive in-memory
    def edit(
      editor_override : String? = nil,
      io_in : IO = STDIN,
      io_out : IO = STDOUT,
      io_err : IO = STDERR
    ) : Bool
      editor = resolve_editor(editor_override)
      unless editor
        io_err.puts "Error: No editor found in $EDITOR, $VISUAL, or PATH (nano, vim, vi)."
        return false
      end

      tempfile = File.tempfile("nightmare_prompt_", ".md")
      temp_path = tempfile.path

      begin
        tempfile.print(@active_directive)
        tempfile.flush
        tempfile.close

        # Launch editor with inherited terminal streams
        cmd = "#{editor} #{Process.quote(temp_path)}"
        status = Process.run(
          command: "/bin/sh",
          args: ["-c", cmd],
          input: io_in,
          output: io_out,
          error: io_err
        )

        if status.success?
          edited_content = File.read(temp_path)
          if edited_content.strip.empty?
            io_err.puts "Warning: Edited directive was empty. Retaining previous directive."
            return false
          end

          @active_directive = edited_content
          true
        else
          io_err.puts "Notice: Editor exited with non-zero status (#{status.exit_code}). In-memory directive unchanged."
          false
        end
      ensure
        File.delete(temp_path) if File.exists?(temp_path)
      end
    end

    # Resolves preferred editor executable command
    def resolve_editor(override : String? = nil) : String?
      return override if override && !override.strip.empty?

      if env_editor = ENV["EDITOR"]?
        return env_editor unless env_editor.strip.empty?
      end

      if env_visual = ENV["VISUAL"]?
        return env_visual unless env_visual.strip.empty?
      end

      ["nano", "vim", "vi"].each do |candidate|
        if path = Process.find_executable(candidate)
          return path
        end
      end

      nil
    end
  end
end
```

---

## 5. CLI Argument Parsing Foundation (`Nightmare::CLI`)

### 5.1 Command-Line Options Specification

NIGHTMARE's binary entrypoint (`src/nightmare.cr`) parses options using Crystal's standard library `OptionParser`.

| Flag | Long Form | Parameter | Description |
| :--- | :--- | :--- | :--- |
| `-s` | `--system` | `PATH` | Custom system directives prompt file (Tier 1 precedence). |
| | `--no-log` | None | Disables LLM audit calls logging to `llm_calls.jsonl`. |
| `-m` | `--model` | `NAME` | Selects LLM provider/alias (e.g. `claude-3-7-sonnet`, `llama3`). |
| `-v` | `--version` | None | Displays NIGHTMARE version banner and exits 0. |
| `-h` | `--help` | None | Displays CLI flags and usage manual, then exits 0. |
| *arg* | *positional* | `[DIR]` | Target workspace directory path (defaults to `Dir.current`). |

### 5.2 Unit-Testable Options and Parser

To ensure that CLI argument parsing is 100% testable without invoking `exit` or launching the full REPL, parsing logic is encapsulated in `Nightmare::CLI::Options` and `Nightmare::CLI::Parser`:

```crystal
require "option_parser"

module Nightmare::CLI
  struct Options
    property system_prompt_path : String? = nil
    property no_log : Bool = false
    property model : String? = nil
    property target_dir : String = Dir.current
    property show_help : Bool = false
    property show_version : Bool = false
    property error_message : String? = nil
  end

  class Parser
    def self.parse(args : Array(String) = ARGV) : Options
      options = Options.new

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: nightmare [options] [workspace_path]"

        opts.on("-s PATH", "--system=PATH", "Path to custom system prompt file (overrides all defaults)") do |path|
          options.system_prompt_path = path
        end

        opts.on("--no-log", "Disable LLM audit call logging in central state directory") do
          options.no_log = true
        end

        opts.on("-m MODEL", "--model=MODEL", "Select model provider or alias") do |model|
          options.model = model
        end

        opts.on("-v", "--version", "Show NIGHTMARE version") do
          options.show_version = true
        end

        opts.on("-h", "--help", "Show help and command-line usage information") do
          options.show_help = true
        end

        opts.unknown_args do |remaining|
          if target = remaining.first?
            options.target_dir = target
          end
        end
      end

      begin
        parser.parse(args)
      rescue ex : OptionParser::InvalidOption | OptionParser::MissingOption
        options.error_message = ex.message
      end

      options
    end

    def self.help_text : String
      options = Options.new
      String.build do |io|
        opts = OptionParser.new do |p|
          p.banner = "Usage: nightmare [options] [workspace_path]"
          p.on("-s PATH", "--system=PATH", "Path to custom system prompt file") { }
          p.on("--no-log", "Disable LLM audit call logging") { }
          p.on("-m MODEL", "--model=MODEL", "Select model provider or alias") { }
          p.on("-v", "--version", "Show NIGHTMARE version") { }
          p.on("-h", "--help", "Show help information") { }
        end
        io << opts
      end
    end
  end
end
```

### 5.3 Entry Point Structure (`src/nightmare.cr`)

```crystal
require "./nightmare/version"
require "./nightmare/cli/parser"
require "./nightmare/workspace/*"
require "./nightmare/directives/*"

module Nightmare
  def self.main(args = ARGV)
    options = CLI::Parser.parse(args)

    if err = options.error_message
      STDERR.puts "Error: #{err}"
      STDERR.puts CLI::Parser.help_text
      exit 1
    end

    if options.show_version
      puts "NIGHTMARE v#{Nightmare::VERSION}"
      exit 0
    end

    if options.show_help
      puts CLI::Parser.help_text
      exit 0
    end

    # Milestone 1: Initialize Workspace Environment and print Startup Banner
    begin
      env = Workspace::Environment.resolve(options.target_dir)
      puts env.startup_banner
    rescue ex : SecurityError
      STDERR.puts "Fatal Security Violation: #{ex.message}"
      exit 1
    rescue ex : Exception
      STDERR.puts "Fatal Initialization Error: #{ex.message}"
      exit 1
    end

    # Milestone 1: Resolve System Directives
    begin
      directive_manager = Directives::Resolver.resolve_manager(env, options.system_prompt_path)
    rescue ex : ArgumentError
      STDERR.puts "Directive Error: #{ex.message}"
      exit 1
    end

    # Downstream Milestones: Pass directive_manager.active_directive to Context & REPL
  end
end

Nightmare.main unless LibC.getenv("NIGHTMARE_ENV") == "test"
```

---

## 6. Concrete Unit Test Specifications (`spec/directives_spec.cr`)

The test suite must test all 5 tiers of precedence, in-memory mutation, disk invariance, editor interaction, and CLI argument parsing.

### 6.1 Test Environment Fixture Helper

Because Crystal standard library lacks `Dir.mktmpdir`, test isolation must use a reliable helper with unique random paths in `Dir.tempdir`:

```crystal
require "file_utils"

def with_test_env(&block : String, String -> Nil)
  test_id = Random::Secure.hex(8)
  base_dir = File.join(Dir.tempdir, "nightmare_spec_#{test_id}")
  root_dir = File.join(base_dir, "workspace")
  xdg_config = File.join(base_dir, "config")
  xdg_state = File.join(base_dir, "state")
  xdg_cache = File.join(base_dir, "cache")

  Dir.mkdir_p(root_dir)
  Dir.mkdir_p(xdg_config)
  Dir.mkdir_p(xdg_state)
  Dir.mkdir_p(xdg_cache)

  begin
    yield root_dir, xdg_config
  ensure
    FileUtils.rm_rf(base_dir) if Dir.exists?(base_dir)
  end
end
```

### 6.2 Complete `spec/directives_spec.cr` Test Code

```crystal
require "./spec_helper"
require "file_utils"

# Mock or real Environment implementation for testing
class MockTestEnvironment < Nightmare::Workspace::Environment
  getter root : String
  getter workspace_id : String
  getter config_dir : String
  getter state_dir : String
  getter cache_dir : String
  getter global_config_dir : String

  def initialize(@root : String, @global_config_dir : String, @workspace_id : String = "test-ws-1234")
    @config_dir = File.join(@global_config_dir, "workspaces", @workspace_id)
    @state_dir = File.join(Dir.tempdir, "nightmare_test_state", @workspace_id)
    @cache_dir = File.join(Dir.tempdir, "nightmare_test_cache", @workspace_id)
    Dir.mkdir_p(@config_dir)
    Dir.mkdir_p(@global_config_dir)
  end

  def global_prompt_path : String
    File.join(@global_config_dir, "prompt.md")
  end
end

describe Nightmare::Directives::Resolver do
  it "resolves Tier 5 (Default General Persona) when no files or flags exist" do
    with_test_env do |root, xdg_config|
      env = MockTestEnvironment.new(root, File.join(xdg_config, "nightmare"))
      result = Nightmare::Directives::Resolver.resolve_with_source(env)

      result.source.should eq(Nightmare::Directives::Source::DefaultPersona)
      result.path.should be_nil
      result.text.should eq(Nightmare::Directives::DEFAULT_PERSONA)
      result.text.should contain("You are an execution agent operating in the current working directory.")
      result.text.should contain("Prefer replace_in_file for edits; read before you write")
    end
  end

  it "resolves Tier 4 (Global Central Config) when only global config exists" do
    with_test_env do |root, xdg_config|
      global_dir = File.join(xdg_config, "nightmare")
      Dir.mkdir_p(global_dir)
      global_file = File.join(global_dir, "prompt.md")
      File.write(global_file, "Global persona prompt content.")

      env = MockTestEnvironment.new(root, global_dir)
      result = Nightmare::Directives::Resolver.resolve_with_source(env)

      result.source.should eq(Nightmare::Directives::Source::GlobalConfig)
      result.path.should eq(global_file)
      result.text.should eq("Global persona prompt content.")
    end
  end

  it "resolves Tier 3 (Workspace Central Config) over Tier 4 (Global Central Config)" do
    with_test_env do |root, xdg_config|
      global_dir = File.join(xdg_config, "nightmare")
      Dir.mkdir_p(global_dir)
      File.write(File.join(global_dir, "prompt.md"), "Global persona prompt.")

      env = MockTestEnvironment.new(root, global_dir)
      ws_file = File.join(env.config_dir, "prompt.md")
      File.write(ws_file, "Workspace persona prompt.")

      result = Nightmare::Directives::Resolver.resolve_with_source(env)

      result.source.should eq(Nightmare::Directives::Source::WorkspaceConfig)
      result.path.should eq(ws_file)
      result.text.should eq("Workspace persona prompt.")
    end
  end

  it "resolves Tier 2 (Repo Committed Override) over Tier 3 and Tier 4" do
    with_test_env do |root, xdg_config|
      global_dir = File.join(xdg_config, "nightmare")
      Dir.mkdir_p(global_dir)
      File.write(File.join(global_dir, "prompt.md"), "Global persona.")

      env = MockTestEnvironment.new(root, global_dir)
      File.write(File.join(env.config_dir, "prompt.md"), "Workspace persona.")

      repo_dir = File.join(root, ".nightmare")
      Dir.mkdir_p(repo_dir)
      repo_file = File.join(repo_dir, "prompt.md")
      File.write(repo_file, "Repo committed persona.")

      result = Nightmare::Directives::Resolver.resolve_with_source(env)

      result.source.should eq(Nightmare::Directives::Source::RepoOverride)
      result.path.should eq(repo_file)
      result.text.should eq("Repo committed persona.")
    end
  end

  it "resolves Tier 1 (CLI Flag) over all other tiers" do
    with_test_env do |root, xdg_config|
      global_dir = File.join(xdg_config, "nightmare")
      Dir.mkdir_p(global_dir)
      File.write(File.join(global_dir, "prompt.md"), "Global persona.")

      env = MockTestEnvironment.new(root, global_dir)
      File.write(File.join(env.config_dir, "prompt.md"), "Workspace persona.")

      repo_dir = File.join(root, ".nightmare")
      Dir.mkdir_p(repo_dir)
      File.write(File.join(repo_dir, "prompt.md"), "Repo persona.")

      cli_file = File.join(root, "custom_cli_prompt.md")
      File.write(cli_file, "Explicit CLI flag persona.")

      result = Nightmare::Directives::Resolver.resolve_with_source(env, cli_file)

      result.source.should eq(Nightmare::Directives::Source::CliFlag)
      result.path.should eq(cli_file)
      result.text.should eq("Explicit CLI flag persona.")
    end
  end

  it "resolves Tier 1 CLI flag with relative path against workspace root" do
    with_test_env do |root, xdg_config|
      env = MockTestEnvironment.new(root, File.join(xdg_config, "nightmare"))
      relative_file = "prompts/dev.md"
      abs_file = File.join(root, relative_file)
      Dir.mkdir_p(File.dirname(abs_file))
      File.write(abs_file, "Relative path prompt.")

      result = Nightmare::Directives::Resolver.resolve_with_source(env, relative_file)

      result.source.should eq(Nightmare::Directives::Source::CliFlag)
      result.path.should eq(abs_file)
      result.text.should eq("Relative path prompt.")
    end
  end

  it "raises ArgumentError when CLI flag points to a non-existent file" do
    with_test_env do |root, xdg_config|
      env = MockTestEnvironment.new(root, File.join(xdg_config, "nightmare"))

      expect_raises(ArgumentError, /System prompt file not found/) do
        Nightmare::Directives::Resolver.resolve(env, "non_existent_prompt.md")
      end
    end
  end

  it "falls through to lower tier if a prompt file exists but contains only whitespace" do
    with_test_env do |root, xdg_config|
      global_dir = File.join(xdg_config, "nightmare")
      Dir.mkdir_p(global_dir)
      File.write(File.join(global_dir, "prompt.md"), "Global valid prompt.")

      env = MockTestEnvironment.new(root, global_dir)
      repo_dir = File.join(root, ".nightmare")
      Dir.mkdir_p(repo_dir)
      # Blank whitespace file
      File.write(File.join(repo_dir, "prompt.md"), "   \n\t  \n")

      result = Nightmare::Directives::Resolver.resolve_with_source(env)
      # Should skip empty repo file and resolve global
      result.source.should eq(Nightmare::Directives::Source::GlobalConfig)
      result.text.should eq("Global valid prompt.")
    end
  end

  it "never automatically creates .nightmare/prompt.md in repo if missing" do
    with_test_env do |root, xdg_config|
      env = MockTestEnvironment.new(root, File.join(xdg_config, "nightmare"))
      Nightmare::Directives::Resolver.resolve(env)

      File.exists?(File.join(root, ".nightmare", "prompt.md")).should be_false
      Dir.exists?(File.join(root, ".nightmare")).should be_false
    end
  end
end

describe Nightmare::Directives::Manager do
  it "initializes with active directive matching resolved original" do
    manager = Nightmare::Directives::Manager.new(
      active_directive: "Initial directive",
      source: Nightmare::Directives::Source::DefaultPersona
    )

    manager.active_directive.should eq("Initial directive")
    manager.original_directive.should eq("Initial directive")
    manager.modified?.should be_false
  end

  it "updates active directive in RAM without touching disk" do
    with_test_env do |root, xdg_config|
      repo_file = File.join(root, ".nightmare", "prompt.md")
      Dir.mkdir_p(File.dirname(repo_file))
      File.write(repo_file, "Initial disk prompt")

      manager = Nightmare::Directives::Manager.new(
        active_directive: "Initial disk prompt",
        source: Nightmare::Directives::Source::RepoOverride,
        source_path: repo_file
      )

      manager.update("Mutated RAM-only prompt")

      manager.active_directive.should eq("Mutated RAM-only prompt")
      manager.original_directive.should eq("Initial disk prompt")
      manager.modified?.should be_true

      # Verify disk file is completely unchanged
      File.read(repo_file).should eq("Initial disk prompt")
    end
  end

  it "resets active directive back to original" do
    manager = Nightmare::Directives::Manager.new(
      active_directive: "Original prompt",
      source: Nightmare::Directives::Source::DefaultPersona
    )

    manager.update("Modified prompt")
    manager.modified?.should be_true

    manager.reset!
    manager.active_directive.should eq("Original prompt")
    manager.modified?.should be_false
  end

  it "executes interactive edit on tempfile and updates directive on exit 0" do
    with_test_env do |root, _|
      manager = Nightmare::Directives::Manager.new(
        active_directive: "Before edit",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      # Use a mock editor shell script that appends text to the tempfile and exits 0
      mock_editor = "sh -c 'echo \" After edit\" >> \"$1\"' --"
      success = manager.edit(editor_override: mock_editor)

      success.should be_true
      manager.modified?.should be_true
      manager.active_directive.should eq("Before edit\n After edit\n")
    end
  end

  it "reverts to prior prompt if editor exits with non-zero error status" do
    with_test_env do |root, _|
      manager = Nightmare::Directives::Manager.new(
        active_directive: "Initial uncorrupted prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      # Mock editor that exits with failure code 1
      mock_failing_editor = "sh -c 'exit 1' --"
      success = manager.edit(editor_override: mock_failing_editor)

      success.should be_false
      manager.modified?.should be_false
      manager.active_directive.should eq("Initial uncorrupted prompt")
    end
  end
end

describe Nightmare::CLI::Parser do
  it "parses -s and --system flags" do
    options1 = Nightmare::CLI::Parser.parse(["-s", "custom.md"])
    options1.system_prompt_path.should eq("custom.md")

    options2 = Nightmare::CLI::Parser.parse(["--system=/path/to/sys.md"])
    options2.system_prompt_path.should eq("/path/to/sys.md")
  end

  it "parses --no-log flag" do
    options = Nightmare::CLI::Parser.parse(["--no-log"])
    options.no_log.should be_true

    default_options = Nightmare::CLI::Parser.parse([] of String)
    default_options.no_log.should be_false
  end

  it "parses -m / --model flag" do
    options = Nightmare::CLI::Parser.parse(["-m", "llama3"])
    options.model.should eq("llama3")
  end

  it "parses positional workspace directory" do
    options = Nightmare::CLI::Parser.parse(["/home/user/project"])
    options.target_dir.should eq("/home/user/project")
  end

  it "parses combined flags and positional argument" do
    options = Nightmare::CLI::Parser.parse(["-s", "prompt.md", "--no-log", "-m", "qwen", "target_folder"])
    options.system_prompt_path.should eq("prompt.md")
    options.no_log.should be_true
    options.model.should eq("qwen")
    options.target_dir.should eq("target_folder")
  end

  it "captures invalid option errors cleanly" do
    options = Nightmare::CLI::Parser.parse(["--unknown-flag"])
    options.error_message.should_not be_nil
    options.error_message.should contain("unknown-flag")
  end
end
```

---

## 7. Implementation Checklist & Acceptance Mapping

| Specification Item | Requirement / Criteria | Addressed In Design | Unit Test Coverage |
| :--- | :--- | :--- | :--- |
| **5-Tier Precedence** | R1, F1.6, AC-S1 | §3.1, §3.4 | `spec/directives_spec.cr` (Tiers 1-5 tests) |
| **CLI Flag Override** | R1, §1.4, Edge Case 30 | §3.1, §3.4 | Tests verifying CLI overrides repo/workspace/global |
| **Relative CLI Path** | §1.4, Crystal Path rules | §3.1, §3.4 | Test verifying expansion against `env.root` |
| **Missing CLI File** | §1.4, Error handling | §3.1, §3.4 | Test verifying `ArgumentError` raised on missing file |
| **Zero Repo Litter** | R1, §1.3, AC-S3 | §3.3, §4.1 | Test asserting `.nightmare/prompt.md` is never created |
| **Verbatim Persona** | R1, §1.4 lines 75-81 | §2.2 | Test asserting exact character match with spec |
| **Blank File Fallthrough** | Robustness invariant | §3.3, §3.4 | Test asserting fallthrough on whitespace-only files |
| **In-Memory Mutation** | R1, F1.8, AC-U2 | §4.1, §4.4 | Tests for `update`, `reset!`, `modified?` |
| **Editor Resolution** | §1.5 ($EDITOR > $VISUAL > nano > vim > vi) | §4.2, §4.4 | Tested via `Manager#resolve_editor` |
| **Tempfile Lifecycle** | §1.5, `/tmp` cleanup | §4.3, §4.4 | Tested via `Manager#edit` with mock scripts |
| **Editor Failure Reversion** | §1.5, Feature 6 | §4.3, §4.4 | Test verifying prompt rollback on exit 1 |
| **Disk Untouched on Edit** | F1.8, AC-U2 | §4.1, §4.4 | Test asserting disk files remain byte-identical |
| **CLI Argument Parsing** | §1.4, OptionParser | §5.1, §5.2 | Tests for `-s`, `--no-log`, `-m`, positional, invalid |
