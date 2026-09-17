require "./spec_helper"

describe Nightmare::SystemPrompt do
  describe Nightmare::SystemPrompt::Resolver do
    it "resolves Tier 5 (Default General Persona) when no overrides exist" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            result = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)

            result.source.should eq(Nightmare::SystemPrompt::Source::DefaultPersona)
            result.path.should be_nil
            result.text.should eq(Nightmare::SystemPrompt::DEFAULT_PERSONA)
            result.text.should contain("You are an execution agent operating in the current working directory.")
            result.text.should contain("Prefer replace_in_file. Use whole-file writes only for new files.")

            # Direct property access (.text and .source)
            result2 = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            result2.source.should eq(Nightmare::SystemPrompt::Source::DefaultPersona)
            result2.text.should eq(Nightmare::SystemPrompt::DEFAULT_PERSONA)
          end
        end
      end
    end

    it "resolves Tier 4 (Global Central Config) when global prompt.md exists" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            global_prompt = env.global_prompt_path
            Dir.mkdir_p(File.dirname(global_prompt))
            File.write(global_prompt, "Global custom persona.")

            result = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            result.source.should eq(Nightmare::SystemPrompt::Source::GlobalConfig)
            result.path.should eq(global_prompt)
            result.text.should eq("Global custom persona.")
          end
        end
      end
    end

    it "resolves Tier 3 (Workspace Central Config) over Tier 4 and Tier 5" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            Dir.mkdir_p(File.dirname(env.global_prompt_path))
            File.write(env.global_prompt_path, "Global prompt.")
            File.write(env.workspace_prompt_path, "Workspace custom prompt.")

            result = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            result.source.should eq(Nightmare::SystemPrompt::Source::WorkspaceConfig)
            result.path.should eq(env.workspace_prompt_path)
            result.text.should eq("Workspace custom prompt.")
          end
        end
      end
    end

    it "resolves Tier 2 (Repo Committed Override) over Tiers 3, 4, and 5" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            Dir.mkdir_p(File.dirname(env.global_prompt_path))
            File.write(env.global_prompt_path, "Global prompt.")
            File.write(env.workspace_prompt_path, "Workspace prompt.")

            Dir.mkdir_p(File.dirname(env.repo_prompt_path))
            File.write(env.repo_prompt_path, "Repo committed prompt.")

            result = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            result.source.should eq(Nightmare::SystemPrompt::Source::RepoOverride)
            result.path.should eq(env.repo_prompt_path)
            result.text.should eq("Repo committed prompt.")
          end
        end
      end
    end

    it "resolves Tier 1 (CLI Flag Override) as highest priority over all other tiers" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            Dir.mkdir_p(File.dirname(env.repo_prompt_path))
            File.write(env.repo_prompt_path, "Repo committed prompt.")

            cli_prompt_file = File.join(dir, "custom_cli_prompt.md")
            File.write(cli_prompt_file, "CLI forced prompt.")

            result = Nightmare::SystemPrompt::Resolver.resolve_with_source(env, cli_prompt_file)
            result.source.should eq(Nightmare::SystemPrompt::Source::CliFlag)
            result.path.should eq(cli_prompt_file)
            result.text.should eq("CLI forced prompt.")
          end
        end
      end
    end

    it "resolves Tier 1 CLI flag with relative path against workspace root" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            relative_file = "prompts/dev.md"
            abs_file = File.join(dir, relative_file)
            Dir.mkdir_p(File.dirname(abs_file))
            File.write(abs_file, "Relative path prompt.")

            result = Nightmare::SystemPrompt::Resolver.resolve_with_source(env, relative_file)
            result.source.should eq(Nightmare::SystemPrompt::Source::CliFlag)
            result.path.should eq(abs_file)
            result.text.should eq("Relative path prompt.")
          end
        end
      end
    end

    it "raises ArgumentError when CLI flag points to a non-existent file" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            expect_raises(ArgumentError, /System prompt file not found/) do
              Nightmare::SystemPrompt::Resolver.resolve(env, "non_existent_prompt.md")
            end
          end
        end
      end
    end

    it "falls through to lower tier if a prompt file exists but contains only whitespace" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            Dir.mkdir_p(File.dirname(env.global_prompt_path))
            File.write(env.global_prompt_path, "Global valid prompt.")

            Dir.mkdir_p(File.dirname(env.repo_prompt_path))
            File.write(env.repo_prompt_path, "   \n\t  \n")

            result = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            result.source.should eq(Nightmare::SystemPrompt::Source::GlobalConfig)
            result.text.should eq("Global valid prompt.")
          end
        end
      end
    end

    it "never automatically creates .nightmare/prompt.md in repo if missing" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            Nightmare::SystemPrompt::Resolver.resolve(env)

            File.exists?(env.repo_prompt_path).should be_false
            Dir.exists?(File.join(dir, ".nightmare")).should be_false
          end
        end
      end
    end
  end

  describe Nightmare::SystemPrompt::SystemPromptBuffer do
    it "initializes with active prompt matching resolved original" do
      buffer = Nightmare::SystemPrompt::SystemPromptBuffer.new(
        current_text: "Initial prompt",
        source: Nightmare::SystemPrompt::Source::DefaultPersona
      )

      buffer.active_prompt.should eq("Initial prompt")
      buffer.current_text.should eq("Initial prompt")
      buffer.original_prompt.should eq("Initial prompt")
      buffer.modified?.should be_false
    end

    it "updates active prompt in RAM without touching disk" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            File.write(env.workspace_prompt_path, "Initial disk prompt")

            buffer = Nightmare::SystemPrompt::SystemPromptBuffer.from_environment(env)
            buffer.active_prompt.should eq("Initial disk prompt")

            buffer.update("Mutated RAM-only prompt")
            buffer.active_prompt.should eq("Mutated RAM-only prompt")
            buffer.original_prompt.should eq("Initial disk prompt")
            buffer.modified?.should be_true

            # Disk file remains completely untouched
            File.read(env.workspace_prompt_path).should eq("Initial disk prompt")
          end
        end
      end
    end

    it "resets active prompt back to original" do
      buffer = Nightmare::SystemPrompt::SystemPromptBuffer.new(
        current_text: "Original prompt",
        source: Nightmare::SystemPrompt::Source::DefaultPersona
      )

      buffer.update("Modified prompt")
      buffer.modified?.should be_true

      buffer.reset!
      buffer.active_prompt.should eq("Original prompt")
      buffer.modified?.should be_false
    end

    it "executes interactive edit on tempfile and updates prompt on exit 0" do
      buffer = Nightmare::SystemPrompt::SystemPromptBuffer.new(
        current_text: "Before edit",
        source: Nightmare::SystemPrompt::Source::DefaultPersona
      )

      mock_editor = "sh -c 'echo \" After edit\" >> \"$1\"' --"
      success = buffer.edit(editor_override: mock_editor)

      success.should be_true
      buffer.modified?.should be_true
      buffer.active_prompt.should eq("Before edit\n After edit")
    end

    it "reverts to prior prompt if editor exits with non-zero error status" do
      buffer = Nightmare::SystemPrompt::SystemPromptBuffer.new(
        current_text: "Initial uncorrupted prompt",
        source: Nightmare::SystemPrompt::Source::DefaultPersona
      )

      mock_failing_editor = "sh -c 'exit 1' --"
      err_io = IO::Memory.new
      success = buffer.edit(editor_override: mock_failing_editor, io_err: err_io)

      success.should be_false
      buffer.modified?.should be_false
      buffer.active_prompt.should eq("Initial uncorrupted prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status (1)")
    end

    it "safely handles abnormal editor exit caused by SIGKILL without raising exceptions" do
      buffer = Nightmare::SystemPrompt::SystemPromptBuffer.new(
        current_text: "Initial uncorrupted prompt",
        source: Nightmare::SystemPrompt::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      mock_killed_editor = "sh -c 'kill -9 $$' --"
      success = buffer.edit(editor_override: mock_killed_editor, io_err: err_io)

      success.should be_false
      buffer.modified?.should be_false
      buffer.active_prompt.should eq("Initial uncorrupted prompt")
      buffer.current_text.should eq("Initial uncorrupted prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status")
      err_io.to_s.should contain("signal KILL")
    end

    it "safely handles abnormal editor exit caused by SIGTERM without raising exceptions" do
      buffer = Nightmare::SystemPrompt::SystemPromptBuffer.new(
        current_text: "Initial uncorrupted prompt",
        source: Nightmare::SystemPrompt::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      mock_term_editor = "sh -c 'kill -15 $$' --"
      success = buffer.edit(editor_override: mock_term_editor, io_err: err_io)

      success.should be_false
      buffer.modified?.should be_false
      buffer.active_prompt.should eq("Initial uncorrupted prompt")
      buffer.current_text.should eq("Initial uncorrupted prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status")
      err_io.to_s.should contain("signal TERM")
    end

    it "safely handles missing temporary file if deleted by editor" do
      buffer = Nightmare::SystemPrompt::SystemPromptBuffer.new(
        current_text: "Initial uncorrupted prompt",
        source: Nightmare::SystemPrompt::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      mock_deleting_editor = "sh -c 'rm -f \"$1\"' --"
      success = buffer.edit(editor_override: mock_deleting_editor, io_err: err_io)

      success.should be_false
      buffer.modified?.should be_false
      buffer.active_prompt.should eq("Initial uncorrupted prompt")
      buffer.current_text.should eq("Initial uncorrupted prompt")
      err_io.to_s.should contain("Edited temporary file was removed")
    end

    it "allows mutating prompt in-memory via edit! without modifying files on disk" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)
            File.write(env.workspace_prompt_path, "Initial disk prompt")

            buffer = Nightmare::SystemPrompt::SystemPromptBuffer.from_environment(env)
            buffer.current_text.should eq("Initial disk prompt")

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
      options.error_message.not_nil!.should contain("unknown-flag")
    end
  end
end
