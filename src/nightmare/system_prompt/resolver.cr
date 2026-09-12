require "../workspace/environment"

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
  - Inspect files and execute tools to determine facts before taking action.
  - Prefer replace_in_file for edits; read before you write; never overwrite a file you have not inspected this session.
  - Be concise, direct, and factual.
  - Do not assume context; rely strictly on provided files, tool outputs, and user instructions.
  - Don't try to do everything yourself - you'll run out of context and tool call retry limits. We're working on local inference. Farm tasks out to subagents to save context and attention.
  - There is no automated memory function - if we need to remember something, it needs to be written to file.
  MARKDOWN

  struct ResolutionResult
    getter text : String
    getter source : Source
    getter path : String?

    def initialize(@text : String, @source : Source, @path : String? = nil)
    end

    def to_tuple : Tuple(String, Source)
      {@text, @source}
    end

    def [](index : Int32) : String | Source
      case index
      when 0 then @text
      when 1 then @source
      else raise IndexError.new("Index #{index} out of bounds for ResolutionResult")
      end
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

      # Tier 2: Repository Committed Override (.nightmare/prompt.md)
      repo_prompt = repo_prompt_path(env)
      if File.file?(repo_prompt)
        content = File.read(repo_prompt)
        unless content.strip.empty?
          return ResolutionResult.new(
            text: content.strip,
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
            text: content.strip,
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
            text: content.strip,
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
      editor = resolve_editor(editor_override)
      unless editor
        io_err.puts "Error: No editor found in $EDITOR, $VISUAL, or PATH (nano, vim, vi)."
        return false
      end

      tempfile = File.tempfile("nightmare_prompt_", ".md")
      temp_path = tempfile.path

      begin
        tempfile.puts(@current_text)
        tempfile.flush
        tempfile.close

        cmd = "#{editor} #{Process.quote(temp_path)}"
        status = Process.run(
          command: "/bin/sh",
          args: ["-c", cmd],
          input: io_in,
          output: io_out,
          error: io_err
        )

        if status.success?
          unless File.exists?(temp_path)
            io_err.puts "Warning: Edited temporary file was removed. Retaining previous system prompt."
            return false
          end

          edited_content = File.read(temp_path).strip
          if edited_content.empty?
            io_err.puts "Warning: Edited system prompt was empty. Retaining previous system prompt."
            return false
          end

          @current_text = edited_content
          true
        else
          status_desc = status.normal_exit? ? status.exit_code.to_s : "signal #{status.exit_signal? || "UNKNOWN"}"
          io_err.puts "Notice: Editor exited with non-zero status (#{status_desc}). In-memory system prompt unchanged."
          false
        end
      rescue ex : Exception
        io_err.puts "Warning: Error during editor execution: #{ex.message}. In-memory system prompt unchanged."
        false
      ensure
        File.delete(temp_path) if File.exists?(temp_path)
      end
    end

    def edit!(editor_command : String? = nil) : Bool
      edit(editor_override: editor_command)
    end

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

  alias Manager = SystemPromptBuffer
end
