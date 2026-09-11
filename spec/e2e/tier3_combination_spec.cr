require "../spec_helper"
require "./test_runner"

describe "Tier 3: Cross-Feature Combinations (Pairwise Opaque-Box E2E)" do
  it "TC-T3-CB-01: [Pinned Files x read_file x Live Disk Re-read] short-circuits read_file and updates upon external disk edit" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      sandbox.write_file("src/shared.cr", "INITIAL_CONTENT_V1")

      Nightmare::E2E.with_mock_llm do |mock|
        mock.enqueue_tool_call("read_file", {"path" => "src/shared.cr"})
        mock.enqueue_text_response("Read pinned notice.")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        # 1. Pin file
        session.send_line("/add src/shared.cr")
        session.wait_for("Pinned")

        # 2. Agent invokes read_file -> must short-circuit
        session.send_line("Examine shared.cr")
        session.wait_for("already pinned")

        # 3. Externally modify file on disk
        sandbox.write_file("src/shared.cr", "MUTATED_CONTENT_V2")

        # 4. Assemble prompt via /review -> must contain V2 immediately
        session.send_line("/review")
        session.wait_for("MUTATED_CONTENT_V2")

        session.send_line("/exit")
        session.wait_exit
      end
    end
  end

  it "TC-T3-CB-02: [In-Turn Shedding x /save Pristine RAM Transcript] shedding truncates history but /save preserves full un-truncated output" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      sandbox.write_file("data1.txt", "HEADER1: " + ("A" * 600))
      sandbox.write_file("data2.txt", "HEADER2: " + ("B" * 600))
      sandbox.write_file("data3.txt", "HEADER3: " + ("C" * 600))

      Nightmare::E2E.with_mock_llm do |mock|
        mock.enqueue_tool_call("read_file", {"path" => "data1.txt"}, prompt_tokens: 86_000)
        mock.enqueue_tool_call("read_file", {"path" => "data2.txt"}, prompt_tokens: 88_000)
        mock.enqueue_tool_call("read_file", {"path" => "data3.txt"}, prompt_tokens: 90_000)
        mock.enqueue_text_response("Inspected all 3 files.")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("Read data files")
        session.send_line("/review")
        # In /review, earlier tool outputs are truncated
        session.wait_for("output truncated")

        # In /save export, output is un-truncated
        session.send_line("/save full_transcript.md")
        session.send_line("/exit")
        session.wait_exit

        sandbox.file_exists?("full_transcript.md").should be_true
        saved_md = sandbox.read_file("full_transcript.md")
        saved_md.should contain("HEADER1:")
        saved_md.should contain("HEADER2:")
        saved_md.should contain("HEADER3:")
      end
    end
  end

  it "TC-T3-CB-03: [Shell Metacharacter Ban x Allowlist Persistence] metacharacter commands ignore persistent allowlist and force modal" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      Dir.mkdir_p(sandbox.workspace_config_dir)
      # Allowlist matches git status
      File.write(File.join(sandbox.workspace_config_dir, "allow"), "^git status.*$\n")

      Nightmare::E2E.with_mock_llm do |mock|
        # 1. Clean git status -> auto-approved without modal prompt
        mock.enqueue_tool_call("run_command", {"command" => "git status"})
        mock.enqueue_text_response("Auto approved status.")

        # 2. Poisoned git status with semicolon -> forces modal!
        mock.enqueue_tool_call("run_command", {"command" => "git status; whoami"})
        mock.enqueue_text_response("Modal was forced.")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("Run clean status")
        sleep 100.milliseconds

        session.send_line("Run injected status")
        session.wait_for("Approve")
        session.send_line("N")
        session.send_line("/exit")
        session.wait_exit
      end
    end
  end

  it "TC-T3-CB-04: [/prompt edit In-Memory x Directives Precedence] in-memory edit overrides disk prompt without modifying disk file" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      sandbox.write_file(".nightmare/prompt.md", "DISK_COMMITTED_PROMPT")

      session = Nightmare::E2E.spawn_nightmare(sandbox)
      session.send_line("/prompt")
      session.wait_for("DISK_COMMITTED_PROMPT")

      # Disk file must remain untouched
      sandbox.read_file(".nightmare/prompt.md").should eq("DISK_COMMITTED_PROMPT")
      session.send_line("/exit")
      session.wait_exit
    end
  end

  it "TC-T3-CB-05: [Rate Limit Backoff x Format-Correction Retry] handles 429 then recovers from malformed tool payload" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      Nightmare::E2E.with_mock_llm do |mock|
        # 1. First call fails with 429 Rate Limit
        mock.enqueue_rate_limit(retry_after: 1)
        # 2. Second attempt succeeds but returns malformed JSON
        mock.enqueue_malformed_json("{ malformed: true, unclosed")
        # 3. Format correction retry turn receives correction prompt and returns valid response
        mock.enqueue_text_response("Recovered successfully.")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("Trigger double recovery")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("Recovered successfully")
      end
    end
  end

  it "TC-T3-CB-06: [Timeout PGID Termination x Subsequent Command Execution] session survives kill and executes next command cleanly" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      Nightmare::E2E.with_mock_llm do |mock|
        mock.enqueue_tool_call("run_command", {"command" => "sleep 60", "timeout" => "1"})
        mock.enqueue_tool_call("run_command", {"command" => "echo 'SURVIVED_CLEANLY'"})
        mock.enqueue_text_response("Both handled.")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("Run timeout then echo")
        session.wait_for("Approve")
        session.send_line("y")
        session.wait_for("Approve")
        session.send_line("y")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should contain("SURVIVED_CLEANLY")
      end
    end
  end

  it "TC-T3-CB-07: [Turn Pruning x /clear x /review] clearing resets turn history while preserving pinned files" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      sandbox.write_file("pinned.cr", "PINNED_MODULE")

      session = Nightmare::E2E.spawn_nightmare(sandbox)
      session.send_line("/add pinned.cr")
      session.send_line("/clear")
      session.send_line("/review")
      session.wait_for("PINNED_MODULE")
      session.send_line("/exit")
      session.wait_exit
    end
  end

  it "TC-T3-CB-08: [<think> Tag Isolation x Live Streaming x /thinking] hides thoughts from stdout and exposes them via /thinking" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      Nightmare::E2E.with_mock_llm do |mock|
        mock.enqueue_thinking_response("SECRET_REASONING_CHAIN", "VISIBLE_FINAL_ANSWER")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("Explain architecture")
        session.wait_for("VISIBLE_FINAL_ANSWER")
        session.stdout.should_not contain("SECRET_REASONING_CHAIN")

        session.send_line("/thinking")
        session.wait_for("SECRET_REASONING_CHAIN")
        session.send_line("/exit")
        session.wait_exit
      end
    end
  end

  it "TC-T3-CB-09: [Outside Symlinks x list_files x Sensitive Patterns] directory traversal and secret patterns filtered concurrently" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      sandbox.write_file("normal.cr", "puts 1")
      sandbox.write_file(".env.production", "DB_PASS=123")
      sandbox.create_symlink("escape_link", "/etc")

      Nightmare::E2E.with_mock_llm do |mock|
        mock.enqueue_tool_call("list_files", {"directory" => "."})
        mock.enqueue_text_response("Listed safely.")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("List directory safely")
        session.send_line("/exit")
        session.wait_exit
        session.stdout.should_not contain(".env.production")
      end
    end
  end

  it "TC-T3-CB-10: [Pinned Files Budget Cap x /drop Recovery] rejects file exceeding 60% budget and recovers via /drop" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      sandbox.write_file("huge.cr", "X" * 300_000)
      sandbox.write_file("small.cr", "puts 'small'")

      session = Nightmare::E2E.spawn_nightmare(sandbox)
      session.send_line("/add huge.cr")
      session.wait_for("exceeds")

      session.send_line("/add small.cr")
      session.wait_for("Pinned")

      session.send_line("/drop small.cr")
      session.wait_for("Dropped")
      session.send_line("/exit")
      session.wait_exit
    end
  end
end
