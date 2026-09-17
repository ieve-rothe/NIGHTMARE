require "../workspace/environment"
require "../ui/editor"

module Nightmare::SystemPrompt
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

  DEFAULT_PERSONA = <<-MARKDOWN.strip
  You are an execution agent operating in the current working directory.
  You have a hard limit of 15 tool calls per turn. Plan for 15.

  BUDGET
  - At most 3 read/search calls before your first mutating call.
  - One broad search (grep/glob) beats four targeted reads. Search first.
  - If you reach call 8 with no edit made, stop reading and make the best
    edit you can justify from what you have.

  DECIDE
  - You have enough information when you can name the file and the exact
    string or line numbers to change. You do not need to understand the whole codebase.
  - Uncertainty is not a reason to read another file. Act, and state the
    assumption in one line.
  - When modifying files, prefer line-anchored replacement (start_line, end_line)
    referencing line numbers from read_file.

  ACT
  - Prefer replace_in_file. Use whole-file writes only for new files.
  - Do not re-read a file to verify an edit the tool reported as applied.
  - When an operation fails or produces an unexpected error, execute a
    diagnostic read to inspect the file state before attempting subsequent edits.

  DELEGATE
  - Spawn a subagent when a subtask needs more than ~5 tool calls of its
    own, or would dump output you don't need verbatim (large surveys,
    multi-file refactors, test runs).
  - Give the subagent one concrete deliverable. Never delegate the
    decision about what to do.

  PERSIST
  - There is no automatic memory. Before your last call of a turn, append
    to PROGRESS.md: what changed, what's next, open questions.
  - Near the limit, spend the final call on PROGRESS.md, not one more read.

  Be concise, direct, factual. Report what you did, not what you plan to do.
  MARKDOWN

  struct ResolutionResult
    getter text : String
    getter source : Source
    getter path : String?

    def initialize(@text : String, @source : Source, @path : String? = nil)
    end
  end

  class Resolver
    DEFAULT_PERSONA = Nightmare::SystemPrompt::DEFAULT_PERSONA

    def self.resolve(env : Workspace::Environment, cli_override : String? = nil) : String
      resolve_with_source(env, cli_override).text
    end

    def self.resolve_with_source(env : Workspace::Environment, cli_override : String? = nil) : ResolutionResult
      # Tier 1: CLI Flag
      if cli_override && !cli_override.strip.empty?
        resolved_path = File.expand_path(cli_override, env.root)
        unless File.file?(resolved_path)
          raise ArgumentError.new("System prompt file not found: #{cli_override} (resolved to #{resolved_path})")
        end
        content = File.read(resolved_path)
        return ResolutionResult.new(
          text: content.strip.empty? ? DEFAULT_PERSONA : content.strip,
          source: Source::CliFlag,
          path: resolved_path
        )
      end

      # Candidates for Tiers 2-4 table-driven cascade
      candidates = [
        {Source::RepoOverride, env.repo_prompt_path},
        {Source::WorkspaceConfig, env.workspace_prompt_path},
        {Source::GlobalConfig, env.global_prompt_path},
      ]

      candidates.each do |source, path|
        if File.file?(path)
          content = File.read(path).strip
          return ResolutionResult.new(text: content, source: source, path: path) unless content.empty?
        end
      end

      # Tier 5: Default General Persona Fallback
      ResolutionResult.new(
        text: DEFAULT_PERSONA,
        source: Source::DefaultPersona,
        path: nil
      )
    end

    def self.resolve_manager(env : Workspace::Environment, cli_override : String? = nil) : SystemPromptBuffer
      result = resolve_with_source(env, cli_override)
      SystemPromptBuffer.new(
        current_text: result.text,
        source: result.source,
        source_path: result.path
      )
    end

    def self.from_environment(env : Workspace::Environment, cli_override : String? = nil) : SystemPromptBuffer
      resolve_manager(env, cli_override)
    end

    def self.repo_prompt_path(env : Workspace::Environment) : String
      env.repo_prompt_path
    end

    def self.workspace_prompt_path(env : Workspace::Environment) : String
      env.workspace_prompt_path
    end

    def self.global_prompt_path(env : Workspace::Environment) : String
      env.global_prompt_path
    end
  end

  class SystemPromptBuffer
    property current_text : String
    getter original_prompt : String
    getter source : Source
    getter source_path : String?

    def initialize(@current_text : String, @source : Source = Source::DefaultPersona, @source_path : String? = nil)
      @original_prompt = @current_text
    end

    def active_prompt : String
      @current_text
    end

    def active_prompt=(val : String) : Nil
      @current_text = val
    end

    def modified? : Bool
      @current_text != @original_prompt
    end

    def update(new_prompt : String) : Nil
      @current_text = new_prompt
    end

    def reset! : Nil
      @current_text = @original_prompt
    end

    def self.from_environment(env : Workspace::Environment, cli_override : String? = nil) : SystemPromptBuffer
      Resolver.resolve_manager(env, cli_override)
    end

    def edit(
      editor_override : String? = nil,
      io_in : IO = STDIN,
      io_out : IO = STDOUT,
      io_err : IO = STDERR
    ) : Bool
      if edited = UI::Editor.edit(
        initial_text: @current_text,
        editor_override: editor_override,
        io_in: io_in,
        io_out: io_out,
        io_err: io_err,
        tempfile_prefix: "nightmare_prompt_",
        tempfile_suffix: ".md",
        subject: "system prompt"
      )
        @current_text = edited
        true
      else
        false
      end
    end

    def edit!(editor_command : String? = nil) : Bool
      edit(editor_override: editor_command)
    end

    def resolve_editor(override : String? = nil) : String?
      UI::Editor.resolve_editor(override)
    end
  end

  alias Manager = SystemPromptBuffer
end
