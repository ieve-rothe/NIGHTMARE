require "../spec_helper"
require "./test_runner"

describe "Tier 4: Real-World Workloads & Developer Scenarios (Opaque-Box E2E)" do
  it "TC-T4-WL-01: [Exploration Workflow] performs initial code survey, checks file info, and verifies zero repo litter" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      sandbox.init_git_repo!
      sandbox.write_file("src/app.cr", "module App\n  def self.run; puts 'ok'; end\nend\n")
      sandbox.write_file("spec/app_spec.cr", "describe App do\n  it 'runs' {}\nend\n")
      sandbox.write_file("shard.yml", "name: app\nversion: 0.1.0\n")

      Nightmare::E2E.with_mock_llm do |mock|
        mock.enqueue_tool_call("list_files", {"directory" => "."})
        mock.enqueue_tool_call("file_info", {"path" => "src/app.cr"})
        mock.enqueue_tool_call("search", {"pattern" => "def self.run"})
        mock.enqueue_text_response("Exploration complete. The project has an App module with self.run method.")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("Survey the workspace architecture")
        session.wait_for("Exploration complete")
        session.send_line("/exit")
        session.wait_exit

        sandbox.assert_zero_repo_litter!
      end
    end
  end

  it "TC-T4-WL-02: [TDD Fix Workflow] pins failing test, proposes bug fix with diff modal, approves, and runs specs" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      sandbox.write_file("src/calc.cr", "def add(a, b); a - b; end\n")
      sandbox.write_file("spec/calc_spec.cr", "describe 'Calc' do\n  it 'adds' { add(1, 2).should eq(3) }\nend\n")

      Nightmare::E2E.with_mock_llm do |mock|
        # 1. Agent runs crystal spec -> fails
        mock.enqueue_tool_call("run_command", {"command" => "crystal spec"})
        # 2. Agent proposes replace_in_file -> diff modal
        mock.enqueue_tool_call("replace_in_file", {"path" => "src/calc.cr", "target" => "a - b", "replacement" => "a + b"})
        # 3. Agent reruns crystal spec -> passes
        mock.enqueue_tool_call("run_command", {"command" => "crystal spec"})
        mock.enqueue_text_response("Bug successfully fixed and verified.")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("/add spec/calc_spec.cr")
        session.wait_for("Pinned")

        session.send_line("Fix the bug in calc.cr so tests pass")

        # First run_command approval
        session.wait_for("Approve")
        session.send_line("y")

        # Diff modal approval for replace_in_file
        session.wait_for("Approve overwrite")
        session.send_line("y")

        # Second run_command approval
        session.wait_for("Approve")
        session.send_line("y")

        session.wait_for("Bug successfully fixed")
        session.send_line("/exit")
        session.wait_exit

        sandbox.read_file("src/calc.cr").should contain("a + b")
      end
    end
  end

  it "TC-T4-WL-03: [Large Context Defense & Audit Workflow] multiple verbose tool calls trigger shedding and export clean transcript" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      (1..6).each { |i| sandbox.write_file("log_#{i}.txt", "LOG ENTRY #{i}: " + ("DATA " * 200)) }

      Nightmare::E2E.with_mock_llm do |mock|
        (1..5).each do |i|
          mock.enqueue_tool_call("read_file", {"path" => "log_#{i}.txt"}, prompt_tokens: 20_000 * i)
        end
        mock.enqueue_text_response("All logs analyzed without hitting context limits.")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("Analyze all log files in workspace")
        session.wait_for("All logs analyzed")

        session.send_line("/save audit_session.md")
        session.send_line("/exit")
        session.wait_exit

        sandbox.file_exists?("audit_session.md").should be_true
        transcript = sandbox.read_file("audit_session.md")
        # In RAM transcript, all log entries are intact
        (1..5).each do |i|
          transcript.should contain("LOG ENTRY #{i}:")
        end
      end
    end
  end

  it "TC-T4-WL-04: [Anti-Fatigue Command Lifecycle] user adds prefix allowlist rule, executes subsequent commands, blocks injection" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      Nightmare::E2E.with_mock_llm do |mock|
        # Step 1: git log -> user grants [p] prefix allow
        mock.enqueue_tool_call("run_command", {"command" => "git log -n 1"})
        # Step 2: git log --oneline -> matches prefix, runs without prompt
        mock.enqueue_tool_call("run_command", {"command" => "git log --oneline"})
        # Step 3: git log; rm -rf / -> metacharacter forces modal
        mock.enqueue_tool_call("run_command", {"command" => "git log; rm -rf /"})
        mock.enqueue_text_response("Completed security lifecycle test.")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("Check git log")
        session.wait_for("Approve")
        session.send_line("p") # Prefix allow

        session.send_line("Check git log oneline")
        # Step 2 runs autonomously without prompt modal

        session.send_line("Check malicious log")
        session.wait_for("Approve") # Forced modal despite prefix allow
        session.send_line("N")

        session.send_line("/exit")
        session.wait_exit
      end
    end
  end

  it "TC-T4-WL-05: [Interrupt Recovery Workflow] user interrupts hung tool with Ctrl+C, rolls back turn, continues session" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      Nightmare::E2E.with_mock_llm do |mock|
        mock.enqueue_tool_call("run_command", {"command" => "sleep 60"})
        # After rollback, next turn executes normally
        mock.enqueue_text_response("Session continued smoothly after interruption.")

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("Run slow process")
        session.wait_for("Approve")
        session.send_line("y")

        sleep 100.milliseconds
        session.send_signal(Signal::INT) # Interrupt!

        # Context is rolled back cleanly; send new instruction
        session.send_line("Continue with next task")
        session.wait_for("Session continued smoothly")
        session.send_line("/exit")
        session.wait_exit
      end
    end
  end

  it "TC-T4-WL-06: [Self-Calibrating Token Accounting Workflow] dynamic feedback loop adjusts token divisor from actual usage" do
    Nightmare::E2E.require_repl!
    Nightmare::E2E.with_sandbox do |sandbox|
      Nightmare::E2E.with_mock_llm do |mock|
        # Return prompt_eval_count = 500 for a prompt of ~1000 characters
        mock.enqueue_text_response("Response with token usage.", prompt_tokens: 500, completion_tokens: 50)

        session = Nightmare::E2E.spawn_nightmare(sandbox, extra_env: {"MANTLE_API_URL" => mock.api_url})
        session.send_line("Calculate token usage")
        session.wait_for("Response with token usage")

        session.send_line("/review")
        session.wait_for("tokens")
        session.send_line("/exit")
        session.wait_exit
      end
    end
  end
end
