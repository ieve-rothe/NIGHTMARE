# spec/integration/workflows_spec.cr
require "../spec_helper"
require "../support/integration_harness"

describe "Core Developer Workflows (Integration)" do
  # =========================================================================
  # Phase 1 Workflows (Retrofit with Adversarial Verification)
  # =========================================================================

  describe "Workflow 1: Codebase Survey & Zero Repository Litter" do
    it "executes autonomous read-only exploration tools and leaves zero repo litter" do
      Nightmare::Integration.with_sandbox("survey_workflow_") do |sandbox|
        sandbox.init_git_repo!
        sandbox.write_file("src/app.cr", "module App\n  def self.run; puts 'running'; end\nend\n")
        sandbox.write_file("shard.yml", "name: app\nversion: 0.1.0\n")

        Nightmare::Integration.with_mock_llm do |mock|
          # Enqueue tool calls using official schema parameter "path"
          mock.enqueue_tool_call("list_files", {"path" => "."})
          mock.enqueue_tool_call("file_info", {"path" => "src/app.cr"})
          mock.enqueue_text_response("Workspace survey completed. Found App module in src/app.cr.")

          Nightmare::Integration.with_session(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            # Send instruction
            session.send_line("Survey this project")

            # Read tools execute autonomously (zero approval modals needed)
            session.wait_for("Workspace survey completed")

            session.send_line("/exit")
            status = session.wait_exit
            status.exit_code.should eq(0)

            # 1. Output assertion: Agent confirmed findings in stdout
            session.stdout.should contain("Found App module in src/app.cr")

            # 2. Falsifiability assertion: Verify Mock LLM actually received requests for list_files & file_info
            requests = mock.recorded_requests
            requests.size.should be >= 3
            req_bodies = requests.map(&.[:body])
            req_bodies.any? { |b| b.includes?("list_files") }.should be_true
            req_bodies.any? { |b| b.includes?("file_info") }.should be_true

            # 3. State assertion: Central XDG directories were created
            Dir.exists?(sandbox.workspace_config_dir).should be_true
            sandbox.manifest_exists?.should be_true

            # 4. Security & Cleanliness invariant: Repo root contains ZERO agent litter
            sandbox.assert_zero_repo_litter!
          end

          mock.assert_all_consumed!
        end
      end
    end
  end

  describe "Workflow 2: File Mutation with Unified Diff Approval Modal" do
    it "presents diff modal; user rejection [N] leaves file untouched and returns rejection to agent" do
      Nightmare::Integration.with_sandbox("mutation_reject_") do |sandbox|
        original_code = "def calculate(x)\n  x * 2\nend\n"
        sandbox.write_file("src/calc.cr", original_code)

        Nightmare::Integration.with_mock_llm do |mock|
          mock.enqueue_tool_call("replace_in_file", {
            "path"        => "src/calc.cr",
            "target"      => "x * 2",
            "replacement" => "x * 99",
          })
          mock.enqueue_text_response("Agent acknowledges user rejection.")

          Nightmare::Integration.with_session(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            session.send_line("Multiply by 99 instead")

            # REPL must suspend and render the unified diff modal
            session.wait_for("--- Diff ---")
            session.stdout.should contain("-  x * 2")
            session.stdout.should contain("+  x * 99")
            session.wait_for("[y/N/a]")

            # User rejects with 'N'
            session.send_line("N")

            session.wait_for("Agent acknowledges user rejection")
            session.send_line("/exit")
            session.wait_exit

            # Strict assertion 1: Target file on disk MUST NOT have changed
            sandbox.read_file("src/calc.cr").should eq(original_code)

            # Strict assertion 2: Agent was notified of rejection in the tool exchange
            requests = mock.recorded_requests
            requests.last[:body].should contain("rejected by user")
          end

          mock.assert_all_consumed!
        end
      end
    end

    it "presents diff modal; user approval [y] updates file on disk" do
      Nightmare::Integration.with_sandbox("mutation_approve_") do |sandbox|
        original_code = "def calculate(x)\n  x * 2\nend\n"
        sandbox.write_file("src/calc.cr", original_code)

        Nightmare::Integration.with_mock_llm do |mock|
          mock.enqueue_tool_call("replace_in_file", {
            "path"        => "src/calc.cr",
            "target"      => "x * 2",
            "replacement" => "x * 10",
          })
          mock.enqueue_text_response("Calculation updated successfully.")

          Nightmare::Integration.with_session(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            session.send_line("Update calculation to times 10")

            # REPL renders diff modal with expected chunks
            session.wait_for("--- Diff ---")
            session.stdout.should contain("-  x * 2")
            session.stdout.should contain("+  x * 10")
            session.wait_for("[y/N/a]")

            # User approves with 'y'
            session.send_line("y")

            session.wait_for("Calculation updated successfully")
            session.send_line("/exit")
            session.wait_exit

            # Strict assertion: Target file on disk MUST be mutated
            sandbox.read_file("src/calc.cr").should eq("def calculate(x)\n  x * 10\nend\n")
          end

          mock.assert_all_consumed!
        end
      end
    end

    it "returns error tool message when target string is not found in file" do
      Nightmare::Integration.with_sandbox("mutation_missing_") do |sandbox|
        sandbox.write_file("src/calc.cr", "def add(a, b); a + b; end\n")

        Nightmare::Integration.with_mock_llm do |mock|
          mock.enqueue_tool_call("replace_in_file", {
            "path"        => "src/calc.cr",
            "target"      => "NON_EXISTENT_STRING",
            "replacement" => "something_else",
          })
          mock.enqueue_text_response("Handled missing target error.")

          Nightmare::Integration.with_session(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            session.send_line("Replace non-existent code")
            session.wait_for("Handled missing target error")

            session.send_line("/exit")
            session.wait_exit

            # Verify tool returned clear error message to model without crashing REPL
            requests = mock.recorded_requests
            requests.last[:body].should contain("Target string not found")
          end

          mock.assert_all_consumed!
        end
      end
    end
  end

  # =========================================================================
  # Phase 2 Workflows (Core REPL & Execution Subsystems)
  # =========================================================================

  describe "Workflow 3: Shell Execution, Allowlisting & Metacharacter Anti-Injection" do
    it "auto-approves whitelisted prefix, but metacharacters unconditionally force modal" do
      Nightmare::Integration.with_sandbox("shell_allowlist_") do |sandbox|
        sandbox.init_git_repo!
        injected_file = File.join(sandbox.root_path, "injected_breach.txt")

        Nightmare::Integration.with_mock_llm do |mock|
          # 1. First command: git status (prompts modal, saved via 'p')
          mock.enqueue_tool_call("run_command", {"command" => "git status"})
          # 2. Second command: git status (auto-approved silently)
          mock.enqueue_tool_call("run_command", {"command" => "git status"})
          # 3. Third command: command substitution injection attack -> MUST force modal
          mock.enqueue_tool_call("run_command", {"command" => "git status $(whoami)"})
          # 4. Fourth command: chained semicolon injection attack -> MUST force modal
          mock.enqueue_tool_call("run_command", {"command" => "git status; echo 'pwned' > #{injected_file}"})
          mock.enqueue_text_response("All shell commands processed.")

          Nightmare::Integration.with_session(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            session.send_line("Check git repository status")

            # 1. First run prompts approval modal
            session.wait_for("Command: git status")
            session.wait_for("[p] save prefix")

            # Approve and save prefix with 'p'
            session.send_line("p")

            # Allowlist file created in workspace config with prefix pattern
            session.wait_for(/(?:On branch main|nothing to commit)/i)
            sandbox.read_allowlist.any? { |line| line.includes?("git status") }.should be_true

            # 2. Command substitution $(whoami) MUST force approval modal despite 'git status' prefix
            session.wait_for("Command: git status $(whoami)")
            session.send_line("N")

            # 3. Chained semicolon injection MUST also force approval modal
            session.wait_for("Command: git status; echo 'pwned'")
            session.send_line("N")

            session.wait_for("All shell commands processed")
            session.send_line("/exit")
            session.wait_exit

            # Strict assertion: Injected file was NEVER created
            File.exists?(injected_file).should be_false

            # Verify both rejections were reported back to model
            requests = mock.recorded_requests
            requests[-2][:body].should contain("rejected by user")
            requests[-1][:body].should contain("rejected by user")
          end

          mock.assert_all_consumed!
        end
      end
    end
  end

  describe "Workflow 4: Hard Subprocess Timeout & Process Group Reap" do
    it "terminates long-running subprocess and reaps entire process tree without zombies" do
      Nightmare::Integration.with_sandbox("timeout_reap_") do |sandbox|
        unique_sleep = "sleep 58.7492"

        Nightmare::Integration.with_mock_llm do |mock|
          # Request unique sleep command with 1s timeout
          mock.enqueue_tool_call("run_command", {
            "command" => unique_sleep,
            "timeout" => "1",
          })
          mock.enqueue_text_response("Handled timeout cleanly.")

          Nightmare::Integration.with_session(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            session.send_line("Run slow sleep")

            # Approve the sleep command once with 'y'
            session.wait_for("Command: #{unique_sleep}")
            session.send_line("y")

            # REPL must catch timeout after 1s and display timeout notice
            session.wait_for(/(?:timed out after 1|ExecutionTimeout)/i)

            session.wait_for("Handled timeout cleanly")
            session.send_line("/exit")
            session.wait_exit

            # Strict OS Process Table check with polling: Ensure no orphaned unique sleep remains alive
            reaped = false
            5.times do
              status = Process.run("pgrep", ["-f", unique_sleep], output: Process::Redirect::Pipe)
              if !status.success?
                reaped = true
                break
              end
              sleep 30.milliseconds
            end
            reaped.should be_true
          end

          mock.assert_all_consumed!
        end
      end
    end
  end

  describe "Workflow 5: Pinned Working Set & Live Disk Re-Read" do
    it "short-circuits read_file when file is pinned and live re-reads upon external modification" do
      Nightmare::Integration.with_sandbox("pinned_live_read_") do |sandbox|
        sandbox.write_file("src/shared.cr", "INITIAL_CONTENT_V1")

        Nightmare::Integration.with_mock_llm do |mock|
          # 1. Model attempts to read_file on pinned file -> will short-circuit in middleware
          mock.enqueue_tool_call("read_file", {"path" => "src/shared.cr"})
          # 2. Response to the short-circuit
          mock.enqueue_text_response("Observed pinned status.")
          # 3. Follow-up query verifying live prompt assembly
          mock.enqueue_text_response("Confirmed V2 in active context.")

          Nightmare::Integration.with_session(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            # 1. Operator pins the file
            session.send_line("/add src/shared.cr")
            session.wait_for("Pinned")

            # 2. Agent tries to read_file -> must short-circuit with notice
            session.send_line("Inspect shared.cr")
            session.wait_for("already pinned")

            # 3. External developer modifies the file on disk
            sandbox.write_file("src/shared.cr", "MUTATED_CONTENT_V2")

            # 4. Review command re-assembles the prompt with live disk re-read
            session.send_line("/review")
            session.wait_for("MUTATED_CONTENT_V2")

            # Ensure old content is evicted and NOT duplicated
            session.stdout.should_not contain("INITIAL_CONTENT_V1")

            # 5. Follow-up turn sends updated prompt over the wire
            session.send_line("Verify updated context")
            session.wait_for("Confirmed V2 in active context")

            session.send_line("/exit")
            session.wait_exit

            # Strict assertion: Latest wire request contained MUTATED_CONTENT_V2
            requests = mock.recorded_requests
            requests.last[:body].should contain("MUTATED_CONTENT_V2")
          end

          mock.assert_all_consumed!
        end
      end
    end
  end

  describe "Workflow 6: Interactive Turn Interruption & Context Rollback on Ctrl+C" do
    it "gracefully cancels streaming generation on SIGINT, rolls back active turn, and preserves session" do
      Nightmare::Integration.with_sandbox("interrupt_rollback_") do |sandbox|
        Nightmare::Integration.with_mock_llm do |mock|
          # Multi-chunk streaming response with 40ms delay between chunks to reliably test mid-stream cancel
          chunks = ["First chunk of text... ", "Second chunk of text... ", "Third chunk... ", "Final answer."]
          mock.enqueue_stream_response(chunks, prompt_tokens: 40, chunk_delay: 40.milliseconds)
          mock.enqueue_text_response("Recovered after interruption and ready for next task.")

          Nightmare::Integration.with_session(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            session.send_line("Generate long response")

            # Wait for first chunk to appear on stdout
            session.wait_for("First chunk of text")

            # Send SIGINT (Ctrl+C) while streaming is actively in-flight
            session.send_signal(Signal::INT)

            # Wait for cancellation message or prompt return
            session.wait_for(/(?:cancelled by user|Cancelled|>)/i)

            # Active session remains fully interactive; send next command
            session.send_line("Continue with follow-up")
            session.wait_for("Recovered after interruption")

            # Verify context store has only 1 committed turn and did not commit the interrupted prompt
            session.send_line("/review")
            session.wait_for("Conversation History")
            session.stdout.should contain("(1 turns)")
            session.stdout.should_not contain("Generate long response")

            session.send_line("/exit")
            session.wait_exit
          end

          mock.assert_all_consumed!
        end
      end
    end
  end
end
