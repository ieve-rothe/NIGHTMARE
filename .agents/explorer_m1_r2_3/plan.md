# Milestone 1 Iteration 2: Worker Implementation & Re-Verification Plan

**Author**: `explorer_m1_r2_3` (investigator, synthesizer)  
**Parent**: `orchestrator_1` (Conv ID: `3ad3ad0f-7c04-4b8b-8435-1ed5dba552db`)  
**Target Milestone**: Milestone 1 Iteration 2 (Workspace Anchoring & Central XDG Mapping)  
**Target Worker**: `worker_m1_2`  
**Purpose**: Formulate exact code changes, test suite integrations, and passing criteria to resolve Challenger `challenger_m1_2`'s rejection.

---

## 1. Context & Root Cause Analysis

### 1.1 Challenger Rejection Summary
In Milestone 1 Iteration 1, Challenger `challenger_m1_2` rejected the milestone gate with the following observation:
- In `src/nightmare/directives/resolver.cr:219`:
  ```crystal
  else
    io_err.puts "Notice: Editor exited with non-zero status (#{status.exit_code}). In-memory directive unchanged."
    false
  end
  ```
- When an editor process terminates abnormally due to an unhandled signal (e.g. `SIGKILL` / `kill -9 $$`, `SIGTERM`, `SIGINT`, or crashing with a segmentation fault), `status.normal_exit?` is `false`.
- Calling `status.exit_code` unconditionally causes Crystal's standard library (`/usr/lib/crystal/process/status.cr:312-314`) to raise:
  ```
  RuntimeError: Abnormal exit has no exit code
  ```
- This uncaught exception crashes the NIGHTMARE process during `/prompt edit`, violating the zero-crash REPL resiliency requirement and causing total loss of in-memory context.

### 1.2 Latent Edge Cases Identified
1. **Deprecated Method Avoidance**: `challenger_m1_2` mentioned `status.exit_signal`, but in Crystal stdlib (`/usr/lib/crystal/process/status.cr:280`), `Process::Status#exit_signal` is marked `@[Deprecated("Use '#exit_signal?' instead.")]` and raises `NotImplementedError` on Windows. The implementation must use `status.exit_signal?`.
2. **Missing Tempfile Defense**: If an editor deletes the temporary file before exiting cleanly (e.g. `rm -f "$1"` and exit 0), `File.read(temp_path)` at line 210 raises `File::NotFoundError`. The implementation must verify `File.exists?(temp_path)` first.
3. **General Exception Boundary**: Process invocation or unexpected IO failures must be rescued within `DirectiveBuffer#edit` so that the REPL session never aborts.

---

## 2. Exact Changes in `src/nightmare/directives/resolver.cr`

### 2.1 File Location
Target file: `src/nightmare/directives/resolver.cr`  
Target method: `Nightmare::Directives::DirectiveBuffer#edit` (lines 180–225)

### 2.2 Unified Diff
```diff
--- a/src/nightmare/directives/resolver.cr
+++ b/src/nightmare/directives/resolver.cr
@@ -209,16 +209,34 @@ module Nightmare::Directives
         if status.success?
+          unless File.exists?(temp_path)
+            io_err.puts "Warning: Edited temporary file was removed. Retaining previous directive."
+            return false
+          end
+
           edited_content = File.read(temp_path).strip
           if edited_content.empty?
             io_err.puts "Warning: Edited directive was empty. Retaining previous directive."
             return false
           end
 
           @current_text = edited_content
           true
         else
-          io_err.puts "Notice: Editor exited with non-zero status (#{status.exit_code}). In-memory directive unchanged."
+          status_desc = if status.normal_exit?
+                          status.exit_code.to_s
+                        elsif sig = status.exit_signal?
+                          "signal #{sig}"
+                        else
+                          "abnormal exit"
+                        end
+          io_err.puts "Notice: Editor exited with non-zero status (#{status_desc}). In-memory directive unchanged."
           false
         end
+      rescue ex : Exception
+        io_err.puts "Error during editor execution: #{ex.message}. In-memory directive unchanged."
+        false
       ensure
         File.delete(temp_path) if File.exists?(temp_path)
       end
```

### 2.3 Full Replacement Method for `DirectiveBuffer#edit`
```crystal
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
            io_err.puts "Warning: Edited temporary file was removed. Retaining previous directive."
            return false
          end

          edited_content = File.read(temp_path).strip
          if edited_content.empty?
            io_err.puts "Warning: Edited directive was empty. Retaining previous directive."
            return false
          end

          @current_text = edited_content
          true
        else
          status_desc = if status.normal_exit?
                          status.exit_code.to_s
                        elsif sig = status.exit_signal?
                          "signal #{sig}"
                        else
                          "abnormal exit"
                        end
          io_err.puts "Notice: Editor exited with non-zero status (#{status_desc}). In-memory directive unchanged."
          false
        end
      rescue ex : Exception
        io_err.puts "Error during editor execution: #{ex.message}. In-memory directive unchanged."
        false
      ensure
        File.delete(temp_path) if File.exists?(temp_path)
      end
    end
```

---

## 3. Integration Plan for `spec/directives_spec.cr`

### 3.1 Overview
`spec/empirical_directives_spec.cr` was authored by `challenger_m1_2` as an adversarial stress-test suite containing 14 specifications across F1.6, F1.8, and F1.7.

To ensure the test suite conforms to the canonical `PROJECT.md` layout and permanently prevents regressions, all empirical assertions must be integrated into `spec/directives_spec.cr`, and `spec/empirical_directives_spec.cr` must be updated so that the abnormal exit failure test asserts graceful handling.

### 3.2 Exact Additions in `spec/directives_spec.cr`

#### 3.2.1 Top-Level Requirement
At the top of `spec/directives_spec.cr` (line 1):
```crystal
require "./spec_helper"
require "digest/sha256"
```

#### 3.2.2 Additions to `describe Nightmare::Directives::Resolver`
Add the empirical edge-case tests to `describe Nightmare::Directives::Resolver` (around line 168):

```crystal
    it "enforces strict 5-tier precedence through sequential file deletion" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)

            cli_file = File.join(dir, "cli_prompt.md")
            File.write(cli_file, "Tier 1: CLI Directive")

            Dir.mkdir_p(File.dirname(env.repo_prompt_path))
            File.write(env.repo_prompt_path, "Tier 2: Repo Directive")

            Dir.mkdir_p(File.dirname(env.workspace_prompt_path))
            File.write(env.workspace_prompt_path, "Tier 3: Workspace Directive")

            Dir.mkdir_p(File.dirname(env.global_prompt_path))
            File.write(env.global_prompt_path, "Tier 4: Global Directive")

            # 1. All 4 present: CLI must win
            res1 = Nightmare::Directives::Resolver.resolve_with_source(env, cli_file)
            res1.source.should eq(Nightmare::Directives::Source::CliFlag)
            res1.text.should eq("Tier 1: CLI Directive")
            res1.path.should eq(cli_file)

            # 2. Without CLI: Repo must win
            res2 = Nightmare::Directives::Resolver.resolve_with_source(env, nil)
            res2.source.should eq(Nightmare::Directives::Source::RepoOverride)
            res2.text.should eq("Tier 2: Repo Directive")

            # 3. Delete Repo: Workspace must win
            File.delete(env.repo_prompt_path)
            res3 = Nightmare::Directives::Resolver.resolve_with_source(env, nil)
            res3.source.should eq(Nightmare::Directives::Source::WorkspaceConfig)
            res3.text.should eq("Tier 3: Workspace Directive")

            # 4. Delete Workspace: Global must win
            File.delete(env.workspace_prompt_path)
            res4 = Nightmare::Directives::Resolver.resolve_with_source(env, nil)
            res4.source.should eq(Nightmare::Directives::Source::GlobalConfig)
            res4.text.should eq("Tier 4: Global Directive")

            # 5. Delete Global: Default General Persona must win
            File.delete(env.global_prompt_path)
            res5 = Nightmare::Directives::Resolver.resolve_with_source(env, nil)
            res5.source.should eq(Nightmare::Directives::Source::DefaultPersona)
            res5.text.should eq(Nightmare::Directives::DEFAULT_PERSONA)
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
            File.write(env.global_prompt_path, "Global directive survived empty tiers")

            res = Nightmare::Directives::Resolver.resolve_with_source(env)
            res.source.should eq(Nightmare::Directives::Source::GlobalConfig)
            res.text.should eq("Global directive survived empty tiers")

            File.write(env.global_prompt_path, "")
            res2 = Nightmare::Directives::Resolver.resolve_with_source(env)
            res2.source.should eq(Nightmare::Directives::Source::DefaultPersona)
            res2.text.should eq(Nightmare::Directives::DEFAULT_PERSONA)
          end
        end
      end
    end

    it "handles CLI override edge cases: empty/whitespace files, relative paths, external paths, symlinks, errors" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)

            # 1. Directory passed as CLI flag raises ArgumentError
            sub_dir = File.join(dir, "some_dir")
            Dir.mkdir_p(sub_dir)
            expect_raises(ArgumentError, /System directive file not found/) do
              Nightmare::Directives::Resolver.resolve_with_source(env, sub_dir)
            end

            # 2. CLI flag pointing to empty or whitespace file returns DefaultPersona with CliFlag source
            empty_cli = File.join(dir, "empty_cli.md")
            File.write(empty_cli, "   \n\t  ")
            res_empty = Nightmare::Directives::Resolver.resolve_with_source(env, empty_cli)
            res_empty.source.should eq(Nightmare::Directives::Source::CliFlag)
            res_empty.text.should eq(Nightmare::Directives::DEFAULT_PERSONA)
            res_empty.path.should eq(empty_cli)

            # 3. External CLI path outside root is permitted
            with_temp_dir do |external_dir|
              ext_file = File.join(external_dir, "external_prompt.md")
              File.write(ext_file, "External System Prompt")
              res_ext = Nightmare::Directives::Resolver.resolve_with_source(env, ext_file)
              res_ext.source.should eq(Nightmare::Directives::Source::CliFlag)
              res_ext.path.should eq(ext_file)
              res_ext.text.should eq("External System Prompt")

              # 4. Symlink pointing to external file
              sym_file = File.join(dir, "symlink_prompt.md")
              File.symlink(ext_file, sym_file)
              res_sym = Nightmare::Directives::Resolver.resolve_with_source(env, sym_file)
              res_sym.source.should eq(Nightmare::Directives::Source::CliFlag)
              res_sym.text.should eq("External System Prompt")

              # 5. Dangling symlink raises ArgumentError
              dangling_sym = File.join(dir, "dangling.md")
              File.symlink(File.join(external_dir, "missing.md"), dangling_sym)
              expect_raises(ArgumentError, /System directive file not found/) do
                Nightmare::Directives::Resolver.resolve_with_source(env, dangling_sym)
              end
            end
          end
        end
      end
    end

    it "handles anomalous repository layout gracefully (collision with file named .nightmare or directory prompt.md)" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            File.write(File.join(dir, ".nightmare"), "I am a file, not a directory")
            env = Nightmare::Workspace::Environment.resolve(dir, ensure_dirs: false)

            res = Nightmare::Directives::Resolver.resolve_with_source(env)
            res.source.should eq(Nightmare::Directives::Source::DefaultPersona)

            File.delete(File.join(dir, ".nightmare"))
            Dir.mkdir_p(File.join(dir, ".nightmare", "prompt.md"))
            res2 = Nightmare::Directives::Resolver.resolve_with_source(env)
            res2.source.should eq(Nightmare::Directives::Source::DefaultPersona)
          end
        end
      end
    end
```

#### 3.2.3 Additions to `describe Nightmare::Directives::DirectiveBuffer`
Add the adversarial mutation, exit handling, signal crash regression, and tempfile deletion tests to `describe Nightmare::Directives::DirectiveBuffer` (around line 268):

```crystal
    it "mutates prompt strictly in RAM while disk files retain 100% identical SHA-256 checksums and mtimes" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          with_env({"XDG_CONFIG_HOME" => xdg, "XDG_STATE_HOME" => xdg, "XDG_CACHE_HOME" => xdg}) do
            env = Nightmare::Workspace::Environment.resolve(dir)

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
            before_shas = tracked_files.map { |f| Digest::SHA256.hexdigest(File.read(f)) }
            before_sizes = tracked_files.map { |f| File.size(f) }
            before_mtimes = tracked_files.map { |f| File.info(f).modification_time }

            [
              Nightmare::Directives::Resolver.resolve_manager(env, cli_file),
              Nightmare::Directives::Resolver.resolve_manager(env, nil),
            ].each do |buffer|
              buffer.modified?.should be_false
              original_val = buffer.active_directive

              mock_editor = "sed -i 's/v1.0/v2.0-MUTATED-IN-RAM/'"
              success = buffer.edit(editor_override: mock_editor)

              success.should be_true
              buffer.modified?.should be_true
              buffer.active_directive.should contain("v2.0-MUTATED-IN-RAM")
              buffer.original_directive.should eq(original_val)

              after_shas = tracked_files.map { |f| Digest::SHA256.hexdigest(File.read(f)) }
              after_sizes = tracked_files.map { |f| File.size(f) }
              after_mtimes = tracked_files.map { |f| File.info(f).modification_time }

              after_shas.should eq(before_shas)
              after_sizes.should eq(before_sizes)
              after_mtimes.should eq(before_mtimes)

              buffer.reset!
              buffer.active_directive.should eq(original_val)
              buffer.modified?.should be_false
            end
          end
        end
      end
    end

    it "handles normal editor non-zero exit codes (1, 2, 127) with rollback and no-op" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Clean Initial System Prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new

      # 1. Exit code 1
      res1 = buffer.edit(editor_override: "sh -c 'exit 1' --", io_err: err_io)
      res1.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Clean Initial System Prompt")
      err_io.to_s.should contain("Editor exited with non-zero status (1)")

      # 2. Exit code 2
      err_io.clear
      res2 = buffer.edit(editor_override: "sh -c 'exit 2' --", io_err: err_io)
      res2.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Clean Initial System Prompt")
      err_io.to_s.should contain("Editor exited with non-zero status (2)")

      # 3. Exit code 127
      err_io.clear
      res3 = buffer.edit(editor_override: "/bin/sh -c 'exit 127' --", io_err: err_io)
      res3.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Clean Initial System Prompt")
      err_io.to_s.should contain("Editor exited with non-zero status (127)")
    end

    it "safely handles abnormal editor exit caused by unhandled signals (SIGKILL, SIGTERM) without raising exceptions" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Initial uncorrupted prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new

      # 1. SIGKILL (kill -9)
      mock_killed_editor = "sh -c 'kill -9 $$' --"
      success1 = buffer.edit(editor_override: mock_killed_editor, io_err: err_io)

      success1.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Initial uncorrupted prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status (signal KILL)")

      # 2. SIGTERM (kill -15)
      err_io.clear
      mock_term_editor = "sh -c 'kill -15 $$' --"
      success2 = buffer.edit(editor_override: mock_term_editor, io_err: err_io)

      success2.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Initial uncorrupted prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status (signal TERM)")
    end

    it "safely handles missing temporary file if deleted by editor" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Initial uncorrupted prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new
      mock_deleting_editor = "sh -c 'rm -f \"$1\"' --"
      success = buffer.edit(editor_override: mock_deleting_editor, io_err: err_io)

      success.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Initial uncorrupted prompt")
      err_io.to_s.should contain("Warning: Edited temporary file was removed")
    end

    it "handles empty editor output with warning and retains previous directive" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Non-empty directive before edit",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new

      # Truncated to empty
      res = buffer.edit(editor_override: "sh -c '> \"$1\"' --", io_err: err_io)
      res.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Non-empty directive before edit")
      err_io.to_s.should contain("Warning: Edited directive was empty. Retaining previous directive.")

      # Truncated to whitespace
      err_io.clear
      res2 = buffer.edit(editor_override: "sh -c 'echo \"   \t\n  \" > \"$1\"' --", io_err: err_io)
      res2.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Non-empty directive before edit")
      err_io.to_s.should contain("Warning: Edited directive was empty. Retaining previous directive.")
    end

    it "guarantees clean tempfile deletion on both success and failure" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Tempfile cleanup test",
        source: Nightmare::Directives::Source::DefaultPersona
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
```

#### 3.2.4 Addition for Startup Notification Banner (F1.7)
Add the banner formatting tests to `spec/directives_spec.cr` (or ensure they exist under `describe "Startup Notification Banner Formatting & Integrity (F1.7)"` in `spec/directives_spec.cr`):

```crystal
  describe "Startup Notification Banner Formatting & Integrity (F1.7)" do
    it "renders exactly 76 columns width with box character integrity for standard paths" do
      with_temp_dir do |parent|
        short_dir = File.join(parent, "repo")
        Dir.mkdir(short_dir)
        env = Nightmare::Workspace::Environment.new(short_dir, ensure_dirs: false)
        banner = env.startup_banner

        lines = banner.lines
        lines.size.should eq(5)

        widths = lines.map(&.size)
        widths.uniq.size.should eq(1)
        widths.first.should eq(76)

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
        deep_dir = File.join(dir, "very_long_directory_name_for_stress_testing_box_alignment_and_expansion_1234567890")
        Dir.mkdir_p(deep_dir)
        real_deep = File.realpath(deep_dir)

        env = Nightmare::Workspace::Environment.new(real_deep, ensure_dirs: false)
        banner = env.startup_banner

        lines = banner.lines
        lines.size.should eq(5)

        widths = lines.map(&.size)
        widths.uniq.size.should eq(1)
        widths.first.should be > 76
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
```

---

## 4. Updates to `spec/empirical_directives_spec.cr`

In `spec/empirical_directives_spec.cr`:
Lines 314–327 currently assert that the process crashes:
```crystal
    it "demonstrates failure mode: editor terminated abnormally by signal crashes with unhandled RuntimeError" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Clean Initial System Prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new

      # When editor process is killed by signal, Process::Status#exit_code raises RuntimeError.
      # This causes buffer.edit to crash with an unhandled exception rather than returning false!
      expect_raises(RuntimeError, /Abnormal exit has no exit code/) do
        buffer.edit(editor_override: "sh -c 'kill -9 $$' --", io_err: err_io)
      end
    end
```

Update this specification to verify the regression fix:
```crystal
    it "gracefully handles editor terminated abnormally by signal without crashing" do
      buffer = Nightmare::Directives::DirectiveBuffer.new(
        current_text: "Clean Initial System Prompt",
        source: Nightmare::Directives::Source::DefaultPersona
      )

      err_io = IO::Memory.new

      res = buffer.edit(editor_override: "sh -c 'kill -9 $$' --", io_err: err_io)
      res.should be_false
      buffer.modified?.should be_false
      buffer.active_directive.should eq("Clean Initial System Prompt")
      err_io.to_s.should contain("Notice: Editor exited with non-zero status (signal KILL)")
    end
```

With this update:
1. `crystal spec spec/empirical_directives_spec.cr` will pass all 14 examples with 0 failures and 0 errors.
2. `crystal spec spec/directives_spec.cr` will pass all integrated examples with 0 failures and 0 errors.

---

## 5. Passing Criteria for `worker_m1_2`

`worker_m1_2` must satisfy all of the following criteria prior to submitting handoff:

1. **Clean Compilation (Zero Warnings, Zero Errors)**:
   - Command: `crystal build src/nightmare.cr --warnings all -o bin/nightmare`
   - Exit code must be `0`.
   - Compiler output must contain zero warnings (`0 warnings`) and zero errors.
   - Command: `shards build` must exit `0`.

2. **Directives Unit & Integration Specs Pass**:
   - Command: `crystal spec spec/directives_spec.cr`
   - All tests pass (0 failures, 0 errors, 0 pending).
   - Expected count: At least 35 examples.

3. **Empirical Directives Spec Passes Cleanly**:
   - Command: `crystal spec spec/empirical_directives_spec.cr`
   - All 14 tests pass (14 examples, 0 failures, 0 errors, 0 pending).

4. **Full Milestone 1 Test Suite Passes**:
   - Command: `crystal spec spec/nightmare_spec.cr spec/workspace_spec.cr spec/directives_spec.cr spec/empirical_directives_spec.cr spec/e2e/test_runner_spec.cr`
   - All tests pass: 60+ examples, 0 failures, 0 errors, 0 pending.

5. **Direct Empirical Verification of Signal Handling**:
   - Verify that running a one-liner with `kill -9 $$` returns `false` and does not raise an exception:
     ```bash
     crystal eval '
     require "./src/nightmare/workspace/environment"
     require "./src/nightmare/directives/resolver"
     buf = Nightmare::Directives::DirectiveBuffer.new("Test", Nightmare::Directives::Source::DefaultPersona)
     err = IO::Memory.new
     ok = buf.edit("sh -c '\''kill -9 $$'\'' --", io_err: err)
     raise "Failed" if ok != false || !err.to_s.includes?("signal KILL")
     puts "PASSED"
     '
     ```
     Must output `PASSED` with exit code `0`.

6. **Repository Cleanliness (Zero Litter)**:
   - `git status --porcelain` within `nightmare` sub-repository must only show modified files:
     - `src/nightmare/directives/resolver.cr`
     - `spec/directives_spec.cr`
     - `spec/empirical_directives_spec.cr`
   - No temporary files (`/tmp/nightmare_*` or repository root files) left behind.

---

## 6. Execution Order for `worker_m1_2`

1. Edit `src/nightmare/directives/resolver.cr`: Replace `DirectiveBuffer#edit` lines 180–225 with the implementation in Section 2.3.
2. Edit `spec/empirical_directives_spec.cr`: Update the abnormal exit test per Section 4.
3. Edit `spec/directives_spec.cr`: Add `require "digest/sha256"` and the empirical test blocks per Section 3.2.
4. Run compilation verification: `crystal build src/nightmare.cr --warnings all -o bin/nightmare`
5. Run spec suites:
   - `crystal spec spec/directives_spec.cr`
   - `crystal spec spec/empirical_directives_spec.cr`
   - `crystal spec spec/nightmare_spec.cr spec/workspace_spec.cr spec/directives_spec.cr spec/empirical_directives_spec.cr spec/e2e/test_runner_spec.cr`
6. Run signal evaluation test (Section 5.5).
7. Inspect `git diff` and `git status` to ensure only intended changes exist.
8. Document execution results and submit handoff report.
