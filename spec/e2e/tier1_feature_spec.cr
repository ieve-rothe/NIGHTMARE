require "../spec_helper"
require "./test_runner"

describe "Tier 1: Feature Coverage (Opaque-Box E2E)" do
  # 1. Canonical Root Anchor & Workspace Resolution
  describe "Feature 1: Canonical Root Anchor (F1.1)" do
    it "TC-T1-F01-01: anchors to current working directory realpath" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain(sandbox.root_path)
      end
    end

    it "TC-T1-F01-02: resolves canonical realpath when launched via symlink" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sym_dir = Nightmare::E2E::WorkspaceSandbox.make_temp_dir("symlink_ws_")
        File.symlink(sandbox.root_path, File.join(sym_dir, "linked_root"))
        session = Nightmare::E2E.spawn_nightmare(sandbox, bin_path: Nightmare::E2E::BIN_PATH)
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain(sandbox.root_path)
      ensure
        FileUtils.rm_rf(sym_dir) if sym_dir && Dir.exists?(sym_dir)
      end
    end

    it "TC-T1-F01-03: confines all file lookups within root" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("test.txt", "hello")
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should_not contain("SecurityError")
      end
    end

    it "TC-T1-F01-04: enforces root containment during subfolder navigation" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("nested/inner/file.cr", "puts 1")
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        sandbox.file_exists?("nested/inner/file.cr").should be_true
      end
    end

    it "TC-T1-F01-05: verifies immutable root anchor survives multi-command execution" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/help")
        session.send_line("/clear")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain(sandbox.root_path)
      end
    end
  end

  # 2. Deterministic Workspace ID
  describe "Feature 2: Deterministic Workspace ID (F1.3)" do
    it "TC-T1-F02-01: generates slug from root basename" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        expected_slug = File.basename(sandbox.root_path).gsub(/[^a-zA-Z0-9_-]/, "_")
        sandbox.workspace_id.should start_with(expected_slug)
      end
    end

    it "TC-T1-F02-02: generates 8-character SHA-256 hash from canonical path" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        expected_hash = Digest::SHA256.hexdigest(sandbox.root_path)[0..7]
        sandbox.workspace_id.should end_with(expected_hash)
      end
    end

    it "TC-T1-F02-03: creates workspace directory matching deterministic ID in XDG config" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        Dir.exists?(sandbox.workspace_config_dir).should be_true
      end
    end

    it "TC-T1-F02-04: creates workspace.json manifest on first startup" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        sandbox.manifest_exists?.should be_true
        manifest = sandbox.read_manifest.not_nil!
        manifest["id"].as_s.should eq(sandbox.workspace_id)
        manifest["canonical_path"].as_s.should eq(sandbox.root_path)
      end
    end

    it "TC-T1-F02-05: reuses existing workspace manifest on subsequent launches" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session1 = Nightmare::E2E.spawn_nightmare(sandbox)
        session1.send_line("/exit")
        session1.wait_exit
        m1 = sandbox.read_manifest.not_nil!

        sleep 10.milliseconds
        session2 = Nightmare::E2E.spawn_nightmare(sandbox)
        session2.send_line("/exit")
        session2.wait_exit
        m2 = sandbox.read_manifest.not_nil!
        m2["id"].as_s.should eq(m1["id"].as_s)
      end
    end
  end

  # 3. Central XDG Storage & Zero Repo Litter
  describe "Feature 3: Zero Repo Litter & Central XDG Isolation (F1.4, F1.5)" do
    it "TC-T1-F03-01: creates no configuration files inside workspace repository" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        sandbox.assert_zero_repo_litter!
      end
    end

    it "TC-T1-F03-02: isolates logs in XDG state directory" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_text_response("Hello from LLM")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Hello world")
          session.send_line("/exit")
          session.wait_exit
          Dir.exists?(sandbox.workspace_state_dir).should be_true
          sandbox.assert_zero_repo_litter!
        end
      end
    end

    it "TC-T1-F03-03: respects --no-log flag by suppressing state log creation" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox, args: ["--no-log"])
        session.send_line("/exit")
        session.wait_exit
        File.exists?(File.join(sandbox.workspace_state_dir, "llm_calls.jsonl")).should be_false
      end
    end

    it "TC-T1-F03-04: maintains cache isolation in XDG cache directory" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        Dir.exists?(sandbox.workspace_cache_dir).should be_true
      end
    end

    it "TC-T1-F03-05: preserves zero repo litter after multiple slash commands" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/help")
        session.send_line("/prompt")
        session.send_line("/cls")
        session.send_line("/clear")
        session.send_line("/exit")
        session.wait_exit
        sandbox.assert_zero_repo_litter!
      end
    end
  end

  # 4. Startup Notification Banner
  describe "Feature 4: Startup Notification Banner (F1.7)" do
    it "TC-T1-F04-01: prints NIGHTMARE title header in box banner" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("NIGHTMARE")
      end
    end

    it "TC-T1-F04-02: prints Workspace realpath in banner" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain(sandbox.root_path)
      end
    end

    it "TC-T1-F04-03: prints central Config directory in banner" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain(sandbox.workspace_config_dir)
      end
    end

    it "TC-T1-F04-04: prints central State/Logs directory in banner" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain(sandbox.workspace_state_dir)
      end
    end

    it "TC-T1-F04-05: prints border box formatting characters" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should match(/[┌─│└]/)
      end
    end
  end

  # 5. System Prompt Precedence & Resolution
  describe "Feature 5: System Prompt Precedence (F1.6, F1.8)" do
    it "TC-T1-F05-01: uses default general persona when no custom prompt is provided" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/prompt")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("execution agent operating in the current working directory")
      end
    end

    it "TC-T1-F05-02: overrides default with global XDG prompt" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        global_dir = File.join(sandbox.xdg_config, "nightmare")
        Dir.mkdir_p(global_dir)
        File.write(File.join(global_dir, "prompt.md"), "GLOBAL CUSTOM PERSONA")

        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/prompt")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("GLOBAL CUSTOM PERSONA")
      end
    end

    it "TC-T1-F05-03: overrides global prompt with workspace XDG prompt" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Dir.mkdir_p(sandbox.workspace_config_dir)
        File.write(File.join(sandbox.workspace_config_dir, "prompt.md"), "WORKSPACE CUSTOM PERSONA")

        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/prompt")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("WORKSPACE CUSTOM PERSONA")
      end
    end

    it "TC-T1-F05-04: overrides workspace prompt with repository .nightmare/prompt.md" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file(".nightmare/prompt.md", "REPO COMMITTED PERSONA")
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/prompt")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("REPO COMMITTED PERSONA")
      end
    end

    it "TC-T1-F05-05: overrides repository prompt with CLI -s / --system flag" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file(".nightmare/prompt.md", "REPO PERSONA")
        cli_file = sandbox.write_file("cli_prompt.md", "CLI ABSOLUTE HIGHEST PRIORITY PERSONA")

        session = Nightmare::E2E.spawn_nightmare(sandbox, args: ["-s", cli_file])
        session.send_line("/prompt")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("CLI ABSOLUTE HIGHEST PRIORITY PERSONA")
      end
    end
  end

  # 6. Read-Only Observation Tools
  describe "Feature 6: Read-Only Tools (F3.1)" do
    it "TC-T1-F06-01: list_files returns directory entries excluding .git/" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.init_git_repo!
        sandbox.write_file("src/app.cr", "puts 1")
        sandbox.write_file("README.md", "# App")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("list_files", {"directory" => "."})
          mock.enqueue_text_response("Listed files.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("List the files")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should_not contain(".git/HEAD")
        end
      end
    end

    it "TC-T1-F06-02: read_file reads line slices accurately" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        content = (1..50).map { |i| "Line #{i}" }.join("\n")
        sandbox.write_file("lines.txt", content)

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("read_file", {"path" => "lines.txt", "offset" => "5", "limit" => "3"})
          mock.enqueue_text_response("Read slice.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Read lines 5-7")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T1-F06-03: search finds matches across files" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("src/file1.cr", "def target_func; end")
        sandbox.write_file("src/file2.cr", "call target_func")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("search", {"pattern" => "target_func"})
          mock.enqueue_text_response("Found target.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Search for target_func")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T1-F06-04: file_info returns metadata without modifying file" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        path = sandbox.write_file("data.bin", "sample data")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("file_info", {"path" => "data.bin"})
          mock.enqueue_text_response("File info inspected.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Inspect data.bin")
          session.send_line("/exit")
          session.wait_exit
          sandbox.read_file("data.bin").should eq("sample data")
        end
      end
    end

    it "TC-T1-F06-05: read tools reject sensitive pattern matches automatically" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file(".env.secret", "SECRET=123")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("read_file", {"path" => ".env.secret"})
          mock.enqueue_text_response("Handled rejection.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Read .env.secret")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end
  end

  # 7. Safe Mutation Tools & Overwrite Modal
  describe "Feature 7: Mutation Tools & Overwrite Modals (F3.2, F3.3, F3.4)" do
    it "TC-T1-F07-01: write_file auto-approves creation of brand new file" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("write_file", {"path" => "new_created.txt", "content" => "auto created"})
          mock.enqueue_text_response("Created file.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Create new_created.txt")
          session.send_line("/exit")
          session.wait_exit
          sandbox.file_exists?("new_created.txt").should be_true
          sandbox.read_file("new_created.txt").should eq("auto created")
        end
      end
    end

    it "TC-T1-F07-02: write_file requires approval modal before overwriting existing file" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("existing.txt", "original")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("write_file", {"path" => "existing.txt", "content" => "overwritten"})
          mock.enqueue_text_response("Done.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Overwrite existing.txt")
          # Approve with 'y'
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
          sandbox.read_file("existing.txt").should eq("overwritten")
        end
      end
    end

    it "TC-T1-F07-03: write_file rejection leaves original file untouched" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("protected.txt", "original state")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("write_file", {"path" => "protected.txt", "content" => "modified"})
          mock.enqueue_text_response("Handled rejection.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Update protected.txt")
          session.wait_for("Approve")
          session.send_line("N")
          session.send_line("/exit")
          session.wait_exit
          sandbox.read_file("protected.txt").should eq("original state")
        end
      end
    end

    it "TC-T1-F07-04: replace_in_file performs exact substring replacement" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("code.cr", "def foo\n  val = 10\nend")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("replace_in_file", {"path" => "code.cr", "target" => "val = 10", "replacement" => "val = 20"})
          mock.enqueue_text_response("Replaced.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Update code.cr")
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
          sandbox.read_file("code.cr").should contain("val = 20")
        end
      end
    end

    it "TC-T1-F07-05: append_to_file adds lines to EOF" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("log.txt", "line 1\n")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("append_to_file", {"path" => "log.txt", "content" => "line 2\n"})
          mock.enqueue_text_response("Appended.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Append line 2")
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
          sandbox.read_file("log.txt").should eq("line 1\nline 2\n")
        end
      end
    end
  end

  # 8. Shell Execution & Interactive Approval Modal
  describe "Feature 8: Shell Execution (F3.6, F3.7, F3.8)" do
    it "TC-T1-F08-01: executes shell command and captures stdout" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "echo 'hello shell'"})
          mock.enqueue_text_response("Executed command.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Echo test")
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T1-F08-02: supports user rejection with [N]" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "rm -rf tmp"})
          mock.enqueue_text_response("Rejection handled.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Remove tmp")
          session.wait_for("Approve")
          session.send_line("N")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T1-F08-03: supports editing command inline with [e]" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "echo 'bad'"})
          mock.enqueue_text_response("Edit executed.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run echo")
          session.wait_for("Approve")
          session.send_line("e")
          session.wait_for("Edit command:")
          session.send_line("echo 'good'")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T1-F08-04: adds exact command to allowlist with [a]" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "git status"})
          mock.enqueue_text_response("Status checked.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Check status")
          session.wait_for("Approve")
          session.send_line("a")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T1-F08-05: adds prefix command pattern to allowlist with [p]" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "git diff HEAD~1"})
          mock.enqueue_text_response("Diff checked.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Check diff")
          session.wait_for("Approve")
          session.send_line("p")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end
  end

  # 9. Slash Commands
  describe "Feature 9: Slash Commands Router (F5.6)" do
    it "TC-T1-F09-01: /help lists available commands and options" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/help")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("/clear")
        session.stdout.should contain("/save")
        session.stdout.should contain("/prompt")
      end
    end

    it "TC-T1-F09-02: /clear wipes conversation without deleting pinned files and clears screen" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/clear")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("cleared")
        session.stdout.should contain("\e[2J\e[H")
      end
    end

    it "TC-T1-F09-03: /cls sends ANSI terminal clear screen sequence" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/cls")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("\e[2J\e[H")
      end
    end

    it "TC-T1-F09-04: /save exports transcript to Markdown file" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/save transcript.md")
        session.send_line("/exit")
        session.wait_exit
        sandbox.file_exists?("transcript.md").should be_true
      end
    end

    it "TC-T1-F09-05: /exit terminates REPL session with exit code 0" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("/exit")
        status = session.wait_exit
        status.exit_code.should eq(0)
      end
    end
  end
end
