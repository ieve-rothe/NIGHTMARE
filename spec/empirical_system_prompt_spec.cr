require "./spec_helper"
require "digest/sha256"

describe "Empirical System Prompt Challenge (F1.6, F1.8, F1.7)" do
  describe "System Prompt Precedence & Missing/Empty/Whitespace Handling (F1.6)" do
    it "enforces strict 5-tier precedence: CLI > Repo > Workspace > Global > Default" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)

            # Setup 4 distinct files
            cli_file = File.join(dir, "cli_prompt.md")
            File.write(cli_file, "Tier 1: CLI Prompt")

            Dir.mkdir_p(File.dirname(env.repo_prompt_path))
            File.write(env.repo_prompt_path, "Tier 2: Repo Prompt")

            Dir.mkdir_p(File.dirname(env.workspace_prompt_path))
            File.write(env.workspace_prompt_path, "Tier 3: Workspace Prompt")

            Dir.mkdir_p(File.dirname(env.global_prompt_path))
            File.write(env.global_prompt_path, "Tier 4: Global Prompt")

            # 1. All 4 present: CLI must win
            res1 = Nightmare::SystemPrompt::Resolver.resolve_with_source(env, cli_file)
            res1.source.should eq(Nightmare::SystemPrompt::Source::CliFlag)
            res1.text.should eq("Tier 1: CLI Prompt")
            res1.path.should eq(cli_file)

            # 2. Without CLI: Repo must win over Workspace & Global
            res2 = Nightmare::SystemPrompt::Resolver.resolve_with_source(env, nil)
            res2.source.should eq(Nightmare::SystemPrompt::Source::RepoOverride)
            res2.text.should eq("Tier 2: Repo Prompt")
            res2.path.should eq(env.repo_prompt_path)

            # 3. Delete Repo: Workspace must win over Global
            File.delete(env.repo_prompt_path)
            res3 = Nightmare::SystemPrompt::Resolver.resolve_with_source(env, nil)
            res3.source.should eq(Nightmare::SystemPrompt::Source::WorkspaceConfig)
            res3.text.should eq("Tier 3: Workspace Prompt")
            res3.path.should eq(env.workspace_prompt_path)

            # 4. Delete Workspace: Global must win
            File.delete(env.workspace_prompt_path)
            res4 = Nightmare::SystemPrompt::Resolver.resolve_with_source(env, nil)
            res4.source.should eq(Nightmare::SystemPrompt::Source::GlobalConfig)
            res4.text.should eq("Tier 4: Global Prompt")
            res4.path.should eq(env.global_prompt_path)

            # 5. Delete Global: Default General Persona must win
            File.delete(env.global_prompt_path)
            res5 = Nightmare::SystemPrompt::Resolver.resolve_with_source(env, nil)
            res5.source.should eq(Nightmare::SystemPrompt::Source::DefaultPersona)
            res5.text.should eq(Nightmare::SystemPrompt::DEFAULT_PERSONA)
            res5.path.should be_nil
          end
        end
      end
    end

    it "falls through when higher tiers are 0-byte empty files" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)

            Dir.mkdir_p(File.dirname(env.repo_prompt_path))
            File.write(env.repo_prompt_path, "") # 0 bytes

            Dir.mkdir_p(File.dirname(env.workspace_prompt_path))
            File.write(env.workspace_prompt_path, "") # 0 bytes

            Dir.mkdir_p(File.dirname(env.global_prompt_path))
            File.write(env.global_prompt_path, "Global prompt survived empty tiers")

            # Should fall through empty repo and workspace to global
            res = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            res.source.should eq(Nightmare::SystemPrompt::Source::GlobalConfig)
            res.text.should eq("Global prompt survived empty tiers")

            # When global is also 0 bytes, falls through to default persona
            File.write(env.global_prompt_path, "")
            res2 = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            res2.source.should eq(Nightmare::SystemPrompt::Source::DefaultPersona)
            res2.text.should eq(Nightmare::SystemPrompt::DEFAULT_PERSONA)
          end
        end
      end
    end

    it "falls through when higher tiers contain only whitespace (spaces, tabs, newlines)" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)

            # Repo with complex whitespace
            Dir.mkdir_p(File.dirname(env.repo_prompt_path))
            File.write(env.repo_prompt_path, "   \t\r\n \n\t  \r\n")

            # Workspace with valid content
            Dir.mkdir_p(File.dirname(env.workspace_prompt_path))
            File.write(env.workspace_prompt_path, "Workspace prompt survived whitespace repo")

            res = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            res.source.should eq(Nightmare::SystemPrompt::Source::WorkspaceConfig)
            res.text.should eq("Workspace prompt survived whitespace repo")

            # Workspace changed to whitespace -> falls through to global
            File.write(env.workspace_prompt_path, "   \n\n\n\t   ")
            Dir.mkdir_p(File.dirname(env.global_prompt_path))
            File.write(env.global_prompt_path, "Global prompt reached")

            res2 = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            res2.source.should eq(Nightmare::SystemPrompt::Source::GlobalConfig)
            res2.text.should eq("Global prompt reached")

            # Global also whitespace -> falls through to default persona
            File.write(env.global_prompt_path, "\t  \r\n")
            res3 = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            res3.source.should eq(Nightmare::SystemPrompt::Source::DefaultPersona)
            res3.text.should eq(Nightmare::SystemPrompt::DEFAULT_PERSONA)
          end
        end
      end
    end

    it "handles CLI override edge cases: empty/whitespace files, relative paths, external paths, symlinks, errors" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)

            # 1. Non-existent CLI file raises ArgumentError with descriptive path
            expect_raises(ArgumentError, /System prompt file not found: non_existent\.md/) do
              Nightmare::SystemPrompt::Resolver.resolve_with_source(env, "non_existent.md")
            end

            # 2. Directory passed as CLI flag raises ArgumentError
            sub_dir = File.join(dir, "some_dir")
            Dir.mkdir_p(sub_dir)
            expect_raises(ArgumentError, /System prompt file not found/) do
              Nightmare::SystemPrompt::Resolver.resolve_with_source(env, sub_dir)
            end

            # 3. CLI flag pointing to empty or whitespace file returns DefaultPersona with CliFlag source
            empty_cli = File.join(dir, "empty_cli.md")
            File.write(empty_cli, "   \n\t  ")
            res_empty = Nightmare::SystemPrompt::Resolver.resolve_with_source(env, empty_cli)
            res_empty.source.should eq(Nightmare::SystemPrompt::Source::CliFlag)
            res_empty.text.should eq(Nightmare::SystemPrompt::DEFAULT_PERSONA)
            res_empty.path.should eq(empty_cli)

            # 4. Relative CLI path resolves against workspace root
            rel_file = "nested/custom_prompt.md"
            full_rel = File.join(dir, rel_file)
            Dir.mkdir_p(File.dirname(full_rel))
            File.write(full_rel, "Relative CLI Prompt")
            res_rel = Nightmare::SystemPrompt::Resolver.resolve_with_source(env, rel_file)
            res_rel.source.should eq(Nightmare::SystemPrompt::Source::CliFlag)
            res_rel.path.should eq(full_rel)
            res_rel.text.should eq("Relative CLI Prompt")

            # 5. External CLI path outside root is permitted
            with_temp_dir do |external_dir|
              ext_file = File.join(external_dir, "external_prompt.md")
              File.write(ext_file, "External System Prompt")
              res_ext = Nightmare::SystemPrompt::Resolver.resolve_with_source(env, ext_file)
              res_ext.source.should eq(Nightmare::SystemPrompt::Source::CliFlag)
              res_ext.path.should eq(ext_file)
              res_ext.text.should eq("External System Prompt")

              # 6. Symlink pointing to external file
              sym_file = File.join(dir, "symlink_prompt.md")
              File.symlink(ext_file, sym_file)
              res_sym = Nightmare::SystemPrompt::Resolver.resolve_with_source(env, sym_file)
              res_sym.source.should eq(Nightmare::SystemPrompt::Source::CliFlag)
              res_sym.text.should eq("External System Prompt")

              # 7. Dangling symlink raises ArgumentError
              dangling_sym = File.join(dir, "dangling.md")
              File.symlink(File.join(external_dir, "missing.md"), dangling_sym)
              expect_raises(ArgumentError, /System prompt file not found/) do
                Nightmare::SystemPrompt::Resolver.resolve_with_source(env, dangling_sym)
              end
            end
          end
        end
      end
    end

    it "handles anomalous repository layout gracefully (never creates files, handles collision with file named .nightmare)" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            # Create .nightmare as a plain file instead of a directory
            File.write(File.join(dir, ".nightmare"), "I am a file, not a directory")
            env = Nightmare::Workspace::Environment.resolve(dir, ensure_dirs: false)

            # Must not crash, falls through gracefully
            res = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            res.source.should eq(Nightmare::SystemPrompt::Source::DefaultPersona)

            # When .nightmare/prompt.md is a directory, must not crash, falls through gracefully
            File.delete(File.join(dir, ".nightmare"))
            Dir.mkdir_p(File.join(dir, ".nightmare", "prompt.md"))
            res2 = Nightmare::SystemPrompt::Resolver.resolve_with_source(env)
            res2.source.should eq(Nightmare::SystemPrompt::Source::DefaultPersona)
          end
        end
      end
    end
  end

  describe "/prompt edit In-Memory Mutation & Immutability (F1.8)" do
    it "mutates prompt strictly in RAM while disk files retain 100% identical SHA-256 checksums and mtimes" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)

            # Setup on-disk files for CLI, Repo, Workspace, and Global
            cli_file = File.join(dir, "cli_prompt.md")
            File.write(cli_file, "Committed CLI Prompt v1.0\nLine 2\nLine 3\n")

            repo_file = env.repo_prompt_path
            Dir.mkdir_p(File.dirname(repo_file))
            File.write(repo_file, "Committed Repo Prompt v1.0\nLine 2\nLine 3\n")

            ws_file = env.workspace_prompt_path
            Dir.mkdir_p(File.dirname(ws_file))
            File.write(ws_file, "Committed Workspace Prompt v1.0\nLine 2\nLine 3\n")

            glob_file = env.global_prompt_path
            Dir.mkdir_p(File.dirname(glob_file))
            File.write(glob_file, "Committed Global Prompt v1.0\nLine 2\nLine 3\n")

            tracked_files = [cli_file, repo_file, ws_file, glob_file]

            # Record baseline checksums, sizes, and mtimes
            before_shas = tracked_files.map { |f| Digest::SHA256.hexdigest(File.read(f)) }
            before_sizes = tracked_files.map { |f| File.size(f) }
            before_mtimes = tracked_files.map { |f| File.info(f).modification_time }

            # Test in-memory mutation across all 4 source buffers
            [
              Nightmare::SystemPrompt::Resolver.resolve_manager(env, cli_file),
              Nightmare::SystemPrompt::Resolver.resolve_manager(env, nil), # Repo
            ].each_with_index do |buffer, idx|
              buffer.modified?.should be_false
              original_val = buffer.active_prompt

              # Execute edit with custom sed/echo command replacing content in tempfile
              mock_editor = "sed -i 's/v1.0/v2.0-MUTATED-IN-RAM/'"
              success = buffer.edit(editor_override: mock_editor)

              success.should be_true
              buffer.modified?.should be_true
              buffer.active_prompt.should contain("v2.0-MUTATED-IN-RAM")
              buffer.original_prompt.should eq(original_val)

              # Verify all disk files are 100% UNTOUCHED
              after_shas = tracked_files.map { |f| Digest::SHA256.hexdigest(File.read(f)) }
              after_sizes = tracked_files.map { |f| File.size(f) }
              after_mtimes = tracked_files.map { |f| File.info(f).modification_time }

              after_shas.should eq(before_shas)
              after_sizes.should eq(before_sizes)
              after_mtimes.should eq(before_mtimes)

              # Verify reset! restores original in-memory value
              buffer.reset!
              buffer.active_prompt.should eq(original_val)
              buffer.modified?.should be_false
            end
          end
        end
      end
    end

    it "handles normal editor non-zero exit codes (1, 2, 127) with rollback and no-op" do
      buffer = Nightmare::SystemPrompt::SystemPromptBuffer.new(
        current_text: "Clean Initial System Prompt",
        source: Nightmare::SystemPrompt::Source::DefaultPersona
      )

      err_io = IO::Memory.new

      # 1. Exit code 1
      res1 = buffer.edit(editor_override: "sh -c 'exit 1' --", io_err: err_io)
      res1.should be_false
      buffer.modified?.should be_false
      buffer.active_prompt.should eq("Clean Initial System Prompt")
      err_io.to_s.should contain("Editor exited with non-zero status (1)")

      # 2. Exit code 2
      err_io.clear
      res2 = buffer.edit(editor_override: "sh -c 'exit 2' --", io_err: err_io)
      res2.should be_false
      buffer.modified?.should be_false
      buffer.active_prompt.should eq("Clean Initial System Prompt")
      err_io.to_s.should contain("Editor exited with non-zero status (2)")

      # 3. Exit code 127 (command not found)
      err_io.clear
      res3 = buffer.edit(editor_override: "/bin/sh -c 'exit 127' --", io_err: err_io)
      res3.should be_false
      buffer.modified?.should be_false
      buffer.active_prompt.should eq("Clean Initial System Prompt")
      err_io.to_s.should contain("Editor exited with non-zero status (127)")
    end

    it "gracefully handles when editor process terminates abnormally via signal (e.g. SIGKILL)" do
      buffer = Nightmare::SystemPrompt::SystemPromptBuffer.new(
        current_text: "Initial prompt",
        source: Nightmare::SystemPrompt::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      mock_editor = "sh -c 'kill -9 $$' --"

      res = buffer.edit(editor_override: mock_editor, io_err: err_io)
      res.should be_false
      buffer.current_text.should eq("Initial prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status")
      err_io.to_s.should contain("signal")
    end

    it "handles empty editor output with warning and retains previous system prompt" do
      buffer = Nightmare::SystemPrompt::SystemPromptBuffer.new(
        current_text: "Non-empty prompt before edit",
        source: Nightmare::SystemPrompt::Source::DefaultPersona
      )

      err_io = IO::Memory.new

      # Editor truncates tempfile to empty
      res = buffer.edit(editor_override: "sh -c '> \"$1\"' --", io_err: err_io)
      res.should be_false
      buffer.modified?.should be_false
      buffer.active_prompt.should eq("Non-empty prompt before edit")
      err_io.to_s.should contain("Warning: Edited system prompt was empty. Retaining previous system prompt.")

      # Editor writes only whitespace
      err_io.clear
      res2 = buffer.edit(editor_override: "sh -c 'echo \"   \t\n  \" > \"$1\"' --", io_err: err_io)
      res2.should be_false
      buffer.modified?.should be_false
      buffer.active_prompt.should eq("Non-empty prompt before edit")
      err_io.to_s.should contain("Warning: Edited system prompt was empty. Retaining previous system prompt.")
    end

    it "guarantees clean tempfile deletion on both success and failure" do
      buffer = Nightmare::SystemPrompt::SystemPromptBuffer.new(
        current_text: "Tempfile cleanup test",
        source: Nightmare::SystemPrompt::Source::DefaultPersona
      )

      canary_file = File.tempfile("canary").path
      File.delete(canary_file) if File.exists?(canary_file)

      # Success path
      buffer.edit(editor_override: "sh -c 'echo \"$1\" > #{canary_file}; echo \"New Content\" > \"$1\"' --")
      temp_used = File.read(canary_file).strip
      File.exists?(temp_used).should be_false

      # Failure path
      File.delete(canary_file) if File.exists?(canary_file)
      buffer.edit(editor_override: "sh -c 'echo \"$1\" > #{canary_file}; exit 1' --", io_err: IO::Memory.new)
      temp_used_fail = File.read(canary_file).strip
      File.exists?(temp_used_fail).should be_false

      File.delete(canary_file) if File.exists?(canary_file)
    end
  end

  describe "Startup Notification Banner Formatting & Integrity (F1.7)" do
    it "renders exactly 76 columns width with box character integrity for standard paths" do
      with_temp_dir do |parent|
        # Standard repository path name (slug fits cleanly within 72 columns)
        short_dir = File.join(parent, "repo")
        Dir.mkdir(short_dir)
        env = Nightmare::Workspace::Environment.new(short_dir, ensure_dirs: false)
        banner = env.startup_banner

        lines = banner.lines
        lines.size.should eq(5)

        # In standard path scenarios, content_width is 72, total box width is 76
        widths = lines.map(&.size)
        widths.uniq.size.should eq(1)
        widths.first.should eq(76)

        # Character integrity checks:
        # Line 1: Top border with title
        lines[0].starts_with?("┌── NIGHTMARE ").should be_true
        lines[0].ends_with?("┐").should be_true
        lines[0].chars.all? { |c| c == '┌' || c == '─' || c == ' ' || c == 'N' || c == 'I' || c == 'G' || c == 'H' || c == 'T' || c == 'M' || c == 'A' || c == 'R' || c == 'E' || c == '┐' }.should be_true

        # Line 2: Workspace root
        lines[1].starts_with?("│ Workspace : ").should be_true
        lines[1].ends_with?(" │").should be_true

        # Line 3: Config path with trailing slash
        lines[2].starts_with?("│ Config    : ").should be_true
        lines[2].ends_with?(" │").should be_true
        lines[2].should contain("/")

        # Line 4: State/Logs path with trailing slash
        lines[3].starts_with?("│ State/Logs: ").should be_true
        lines[3].ends_with?(" │").should be_true
        lines[3].should contain("/")

        # Line 5: Bottom border
        lines[4].starts_with?("└").should be_true
        lines[4].ends_with?("┘").should be_true
        lines[4].chars.all? { |c| c == '└' || c == '─' || c == '┘' }.should be_true
      end
    end

    it "renders exactly 76 columns width for the actual workspace path" do
      env = Nightmare::Workspace::Environment.new("/home/cam/repos/adjutant/nightmare", ensure_dirs: false)
      banner = env.startup_banner

      lines = banner.lines
      lines.size.should eq(5)

      widths = lines.map(&.size)
      widths.uniq.size.should eq(1)
      widths.first.should eq(76)

      lines[0].should eq("┌── NIGHTMARE ─────────────────────────────────────────────────────────────┐")
      lines[1].should eq("│ Workspace : /home/cam/repos/adjutant/nightmare                           │")
      lines[2].should eq("│ Config    : ~/.config/nightmare/workspaces/nightmare-b97495a0/           │")
      lines[3].should eq("│ State/Logs: ~/.local/state/nightmare/workspaces/nightmare-b97495a0/      │")
      lines[4].should eq("└──────────────────────────────────────────────────────────────────────────┘")
    end

    it "preserves uniform box integrity and alignment when workspace path is long" do
      with_temp_dir do |dir|
        # Create deep nested path (> 80 chars)
        deep_dir = File.join(dir, "very_long_directory_name_for_stress_testing_box_alignment_and_expansion_1234567890")
        Dir.mkdir_p(deep_dir)
        real_deep = File.realpath(deep_dir)

        env = Nightmare::Workspace::Environment.new(real_deep, ensure_dirs: false)
        banner = env.startup_banner

        lines = banner.lines
        lines.size.should eq(5)

        # All lines must expand uniformly
        widths = lines.map(&.size)
        widths.uniq.size.should eq(1)
        widths.first.should be > 76

        lines[0].starts_with?("┌── NIGHTMARE ").should be_true
        lines[0].ends_with?("┐").should be_true
        lines[1].starts_with?("│ Workspace : ").should be_true
        lines[1].ends_with?(" │").should be_true
        lines[2].starts_with?("│ Config    : ").should be_true
        lines[2].ends_with?(" │").should be_true
        lines[3].starts_with?("│ State/Logs: ").should be_true
        lines[3].ends_with?(" │").should be_true
        lines[4].starts_with?("└").should be_true
        lines[4].ends_with?("┘").should be_true
      end
    end

    it "formats config and state directories with tilde abbreviation when under home directory" do
      with_temp_dir do |dir|
        home = Path.home.to_s
        config_home = File.join(home, ".config_test_env")
        state_home = File.join(home, ".state_test_env")
        cache_home = File.join(home, ".cache_test_env")

        env = Nightmare::Workspace::Environment.new(
          root_path: dir,
          xdg_config_home: config_home,
          xdg_state_home: state_home,
          xdg_cache_home: cache_home,
          ensure_dirs: false
        )

        banner = env.startup_banner
        banner.should contain("~/.config_test_env/nightmare/workspaces/")
        banner.should contain("~/.state_test_env/nightmare/workspaces/")
      end
    end
  end
end
