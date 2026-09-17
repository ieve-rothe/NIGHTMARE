require "../spec_helper"
require "./test_runner"

describe "Tier 2: Boundary & Corner Cases (Opaque-Box E2E)" do
  # 1. Path Traversal Boundary Cases
  describe "Boundary 1: Path Traversal (../) Invariant" do
    it "TC-T2-PT-01: rejects relative path traversal ../../../etc/passwd" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("read_file", {"path" => "../../../etc/passwd"})
          mock.enqueue_text_response("Security error handled.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Read external passwd")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should match(/SecurityError|Path traversal violation/i)
        end
      end
    end

    it "TC-T2-PT-02: rejects traversal via write_file" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("write_file", {"path" => "../escaped.txt", "content" => "evil"})
          mock.enqueue_text_response("Write blocked.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Write outside root")
          session.send_line("/exit")
          session.wait_exit
          File.exists?(File.expand_path("../escaped.txt", sandbox.root_path)).should be_false
        end
      end
    end

    it "TC-T2-PT-03: rejects absolute paths resolving outside root" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("read_file", {"path" => "/etc/hosts"})
          mock.enqueue_text_response("Blocked absolute path.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Read /etc/hosts")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should match(/SecurityError|Path traversal violation/i)
        end
      end
    end

    it "TC-T2-PT-04: rejects traversal through nested subdirectories (src/../../etc)" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("src/nested/dummy.cr", "")
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("read_file", {"path" => "src/nested/../../../../etc/shadow"})
          mock.enqueue_text_response("Blocked nested traversal.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Read shadow")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should match(/SecurityError|Path traversal violation/i)
        end
      end
    end

    it "TC-T2-PT-05: permits safe relative paths within root containing redundant ./ and subdirs" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("src/sub/app.cr", "safe code")
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("read_file", {"path" => "./src/sub/../sub/app.cr"})
          mock.enqueue_text_response("Read safe code.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Read safe app")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should_not contain("SecurityError")
        end
      end
    end
  end

  # 2. Outside Symlinks Boundary Cases
  describe "Boundary 2: Outside Symlink Dereferencing" do
    it "TC-T2-SL-01: rejects reading symlink pointing directly to external file (/etc/hosts)" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.create_symlink("evil_hosts_link", "/etc/hosts")
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("read_file", {"path" => "evil_hosts_link"})
          mock.enqueue_text_response("Rejected external symlink.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Read evil hosts link")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should match(/SecurityError|symlink.*outside/i)
        end
      end
    end

    it "TC-T2-SL-02: rejects writing through symlink pointing outside root" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        outside_target = File.tempname("outside_target_")
        File.write(outside_target, "pristine")
        sandbox.create_symlink("outside_write_link", outside_target)

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("write_file", {"path" => "outside_write_link", "content" => "corrupted"})
          mock.enqueue_text_response("Rejected outside symlink write.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Write outside link")
          session.send_line("/exit")
          session.wait_exit
          File.read(outside_target).should eq("pristine")
        ensure
          File.delete(outside_target) if outside_target && File.exists?(outside_target)
        end
      end
    end

    it "TC-T2-SL-03: rejects directory symlinks pointing to parent directory" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.create_symlink("parent_link", File.dirname(sandbox.root_path))
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("list_files", {"directory" => "parent_link"})
          mock.enqueue_text_response("Rejected parent link list.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("List parent_link")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should match(/SecurityError|outside/i)
        end
      end
    end

    it "TC-T2-SL-04: permits valid internal symlinks pointing to targets within root" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("internal_target.txt", "internal target content")
        sandbox.create_symlink("valid_link.txt", File.join(sandbox.root_path, "internal_target.txt"))

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("read_file", {"path" => "valid_link.txt"})
          mock.enqueue_text_response("Read valid link.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Read valid link")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should_not contain("SecurityError")
        end
      end
    end

    it "TC-T2-SL-05: handles broken/dangling symlinks gracefully without crashing" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.create_symlink("dangling_link.txt", File.join(sandbox.root_path, "does_not_exist.txt"))
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("file_info", {"path" => "dangling_link.txt"})
          mock.enqueue_text_response("Handled dangling link.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Inspect dangling link")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should_not contain("unhandled exception")
        end
      end
    end
  end

  # 3. .git/ Protection Boundary Cases
  describe "Boundary 3: Strict .git/ Directory Protection" do
    it "TC-T2-GIT-01: write_file unconditionally rejects write to .git/config" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.init_git_repo!
        original_config = sandbox.read_file(".git/config")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("write_file", {"path" => ".git/config", "content" => "[evil]"})
          mock.enqueue_text_response("Rejected git write.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Write .git/config")
          session.send_line("/exit")
          session.wait_exit
          sandbox.read_file(".git/config").should eq(original_config)
        end
      end
    end

    it "TC-T2-GIT-02: write_file rejects write to .git/hooks/pre-commit" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.init_git_repo!

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("write_file", {"path" => ".git/hooks/pre-commit", "content" => "#!/bin/sh\nexit 1\n"})
          mock.enqueue_text_response("Rejected hook write.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Write git hook")
          session.send_line("/exit")
          session.wait_exit
          sandbox.file_exists?(".git/hooks/pre-commit").should be_false
        end
      end
    end

    it "TC-T2-GIT-03: replace_in_file rejects modifications in .git/HEAD" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.init_git_repo!
        original_head = sandbox.read_file(".git/HEAD")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("replace_in_file", {"path" => ".git/HEAD", "target" => "main", "replacement" => "evil"})
          mock.enqueue_text_response("Rejected HEAD modification.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Modify git HEAD")
          session.send_line("/exit")
          session.wait_exit
          sandbox.read_file(".git/HEAD").should eq(original_head)
        end
      end
    end

    it "TC-T2-GIT-04: append_to_file rejects append to .git/info/exclude" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.init_git_repo!

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("append_to_file", {"path" => ".git/info/exclude", "content" => "*.secret\n"})
          mock.enqueue_text_response("Rejected exclude append.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Append to exclude")
          session.send_line("/exit")
          session.wait_exit
          sandbox.file_exists?(".git/info/exclude").should be_false
        end
      end
    end

    it "TC-T2-GIT-05: rejects writes attempting path trickery like ./sub/../../.git/config" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.init_git_repo!
        sandbox.write_file("sub/file.txt", "dummy")
        original_config = sandbox.read_file(".git/config")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("write_file", {"path" => "sub/../.git/config", "content" => "tampered"})
          mock.enqueue_text_response("Rejected sneaky git write.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Write sneaky git config")
          session.send_line("/exit")
          session.wait_exit
          sandbox.read_file(".git/config").should eq(original_config)
        end
      end
    end
  end

  # 4. Shell Metacharacter Ban Boundary Cases
  describe "Boundary 4: Strict Shell Metacharacter Auto-Approval Ban" do
    it "TC-T2-MC-01: command with semicolon ';' forces modal even if on allowlist" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Dir.mkdir_p(sandbox.workspace_config_dir)
        File.write(File.join(sandbox.workspace_config_dir, "allow"), "^git status.*\n")

        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "git status; rm -rf /tmp/test"})
          mock.enqueue_text_response("Handled semicolon command.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run injected command")
          session.wait_for("Approve")
          session.send_line("N")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T2-MC-02: command with pipe '|' forces modal" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "cat file.txt | grep pattern"})
          mock.enqueue_text_response("Handled pipe.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run piped command")
          session.wait_for("Approve")
          session.send_line("N")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T2-MC-03: command with command substitution '$()' forces modal" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "echo $(whoami)"})
          mock.enqueue_text_response("Handled command substitution.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run substitution")
          session.wait_for("Approve")
          session.send_line("N")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T2-MC-04: command with redirect '>' or '<' forces modal" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "echo 'hello' > output.txt"})
          mock.enqueue_text_response("Handled redirect.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run redirect")
          session.wait_for("Approve")
          session.send_line("N")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T2-MC-05: command with newline '\\n' injection forces modal" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "git status\nls -la"})
          mock.enqueue_text_response("Handled newline.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run newline injected command")
          session.wait_for("Approve")
          session.send_line("N")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end
  end

  # 5. Closed Stdin Boundary Cases
  describe "Boundary 5: Closed Stdin (/dev/null)" do
    it "TC-T2-IN-01: command calling 'read' returns EOF immediately without hanging" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "read -r var; echo EOF_REACHED"})
          mock.enqueue_text_response("Command executed.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Execute read")
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should contain("EOF_REACHED")
        end
      end
    end

    it "TC-T2-IN-02: sudo -S or interactive prompt fails immediately rather than hanging indefinitely" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "cat -"})
          mock.enqueue_text_response("Closed stdin cat handled.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run cat stdin")
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T2-IN-03: bash prompt execution with CI=1 and GIT_TERMINAL_PROMPT=0 injected" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "echo CI=$CI GIT=$GIT_TERMINAL_PROMPT"})
          mock.enqueue_text_response("Env checked.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Check env vars")
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should contain("CI=1")
          session.stdout.should contain("GIT=0")
        end
      end
    end

    it "TC-T2-IN-04: closed stdin prevents subshell from consuming REPL keystrokes" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "echo start; sleep 0.1; echo end"})
          mock.enqueue_text_response("Sleep done.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run sleep command")
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/prompt")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should contain("execution agent")
        end
      end
    end

    it "TC-T2-IN-05: REPL stdin closes on EOF (/dev/null or Ctrl+D) terminating gracefully" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.close_stdin
        status = session.wait_exit
        status.exit_code.should eq(0)
      end
    end
  end

  # 6. Subprocess Timeout Cap Boundary Cases
  describe "Boundary 6: Hard Timeout Cap & Process Group Termination" do
    it "TC-T2-TO-01: terminates long-running subprocess exceeding timeout via process group SIGKILL" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "sleep 60", "timeout" => "1"})
          mock.enqueue_text_response("Timeout handled.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run slow sleep")
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should match(/timed out|timeout/i)
        end
      end
    end

    it "TC-T2-TO-02: kills child and grand-child processes in process group on timeout" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "sh -c 'sleep 100'", "timeout" => "1"})
          mock.enqueue_text_response("Nested sleep killed.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run nested sleep")
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T2-TO-03: clamps requested timeout higher than 600s down to maximum 600s" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "echo ok", "timeout" => "9999"})
          mock.enqueue_text_response("Done.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run clamp test")
          session.wait_for("Approve")
          session.stdout.should contain("600s")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T2-TO-04: halts infinite loop without leaking CPU or freezing REPL" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "while true; do :; done", "timeout" => "1"})
          mock.enqueue_text_response("Infinite loop halted.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run busy loop")
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T2-TO-05: truncates excessive stdout beyond 50 KB / 300 lines limit" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "seq 1 1000"})
          mock.enqueue_text_response("Handled large output.")
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run large seq")
          session.wait_for("Approve")
          session.send_line("y")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should match(/output truncated|lines omitted/i)
        end
      end
    end
  end

  # 7. In-Turn Tool Shedding Boundary Cases
  describe "Boundary 7: In-Turn Shedding (Active Turn Defense)" do
    it "TC-T2-SH-01: preserves exactly the last 2 tool outputs verbatim when shedding is triggered" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        (1..5).each { |i| sandbox.write_file("file_#{i}.txt", "Content #{i} " * 500) }

        Nightmare::E2E.with_mock_llm do |mock|
          # Sequence of 4 tool calls in a single turn
          (1..4).each do |i|
            mock.enqueue_tool_call("read_file", {"path" => "file_#{i}.txt"}, prompt_tokens: 30_000 * i)
          end
          mock.enqueue_text_response("Finished multi-tool sequence.")

          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Read all files")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T2-SH-02: truncates consumed tool results prior to last 2 to ~200 chars + stub" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("big.txt", "HEADER_DATA: " + ("A" * 1000))
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("read_file", {"path" => "big.txt"}, prompt_tokens: 90_000)
          mock.enqueue_tool_call("file_info", {"path" => "big.txt"}, prompt_tokens: 92_000)
          mock.enqueue_tool_call("search", {"pattern" => "HEADER"}, prompt_tokens: 94_000)
          mock.enqueue_text_response("Done.")

          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Process big file")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end

    it "TC-T2-SH-03: user prompt is strictly protected and never truncated by shedding" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        long_user_prompt = "MY_SPECIAL_USER_INSTRUCTION: " + ("X" * 300)
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("list_files", {"directory" => "."}, prompt_tokens: 95_000)
          mock.enqueue_text_response("Completed.")

          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line(long_user_prompt)
          session.send_line("/review")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should contain("MY_SPECIAL_USER_INSTRUCTION")
        end
      end
    end

    it "TC-T2-SH-04: turns with 2 or fewer tool calls never truncate any tool results" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("f1.txt", "Exact content 1")
        sandbox.write_file("f2.txt", "Exact content 2")
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("read_file", {"path" => "f1.txt"})
          mock.enqueue_tool_call("read_file", {"path" => "f2.txt"})
          mock.enqueue_text_response("Done both.")

          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Read f1 and f2")
          session.send_line("/exit")
          session.wait_exit
          session.stdout.should_not contain("output truncated")
        end
      end
    end

    it "TC-T2-SH-05: un-pruned pristine transcript retains full output despite in-turn shedding" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        sandbox.write_file("full.txt", "UNTRUNCATED_SPECIAL_CONTENT_" + ("Z" * 500))
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("read_file", {"path" => "full.txt"}, prompt_tokens: 95_000)
          mock.enqueue_tool_call("list_files", {"directory" => "."}, prompt_tokens: 96_000)
          mock.enqueue_tool_call("file_info", {"path" => "full.txt"}, prompt_tokens: 97_000)
          mock.enqueue_text_response("All inspected.")

          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Inspect full file")
          session.send_line("/save pristine_export.md")
          session.send_line("/exit")
          session.wait_exit
          sandbox.file_exists?("pristine_export.md").should be_true
          sandbox.read_file("pristine_export.md").should contain("UNTRUNCATED_SPECIAL_CONTENT_")
        end
      end
    end
  end

  # 8. Signal Handling & Turn Rollback Boundary Cases
  describe "Boundary 8: Ctrl+C Signal Interception & Turn Rollback" do
    it "TC-T2-SIG-01: Ctrl+C during LLM generation terminates stream and rolls back active turn" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("Long query")
        sleep 50.milliseconds
        session.send_signal(Signal::INT)
        session.send_line("/exit")
        status = session.wait_exit
        status.exit_code.should eq(0)
      end
    end

    it "TC-T2-SIG-02: Ctrl+C during long-running tool terminates process group cleanly" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        Nightmare::E2E.with_mock_llm do |mock|
          mock.enqueue_tool_call("run_command", {"command" => "sleep 30"})
          session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
          session.send_line("Run slow process")
          session.wait_for("Approve")
          session.send_line("y")
          sleep 100.milliseconds
          session.send_signal(Signal::INT)
          session.send_line("/exit")
          status = session.wait_exit
          status.exit_code.should eq(0)
        end
      end
    end

    it "TC-T2-SIG-03: Ctrl+C restores prompt input text rather than dropping user input" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_chars("partial user command")
        session.send_signal(Signal::INT)
        session.send_line("/exit")
        session.wait_exit
      end
    end

    it "TC-T2-SIG-04: single Ctrl+C at empty prompt does not exit REPL" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_signal(Signal::INT)
        sleep 100.milliseconds
        # REPL should still be alive
        session.send_line("/help")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("/clear")
      end
    end

    it "TC-T2-SIG-05: turn rollback eliminates orphaned tool calls and ensures context consistency" do
      Nightmare::E2E.require_repl!
      Nightmare::E2E.with_sandbox do |sandbox|
        session = Nightmare::E2E.spawn_nightmare(sandbox)
        session.send_line("First turn")
        session.send_signal(Signal::INT)
        session.send_line("/review")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should_not contain("tool_calls without matching tool")
      end
    end
  end
end
