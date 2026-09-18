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
            session.wait_for(/git.*status/)
            session.wait_for("[p] save prefix")

            # Approve and save prefix with 'p'
            session.send_line("p")

            # Allowlist file created in workspace config with prefix pattern
            session.wait_for(/(?:On branch main|nothing to commit)/i)
            sandbox.read_allowlist.any? { |line| line.includes?("git status") }.should be_true

            # 2. Command substitution $(whoami) MUST force approval modal despite 'git status' prefix
            session.wait_for(/git.*status.*\$\(whoami\)/)
            session.send_line("N")

            # 3. Chained semicolon injection MUST also force approval modal
            session.wait_for(/echo.*pwned/)
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
            session.wait_for(/sleep.*58\.7492/)
            session.send_line("y")

            # REPL must catch timeout after 1s and display timeout notice
            session.wait_for(/(?:timed out after 1|ExecutionTimeout)/i)

            session.wait_for("Handled timeout cleanly")
            session.send_line("/exit")
            session.wait_exit

            # Strict OS Process Table check with polling: Ensure no orphaned unique sleep remains alive
            deadline = Time.instant + 4.seconds
            reaped = false
            while Time.instant < deadline
              status = Process.run("pgrep", ["-f", unique_sleep], output: Process::Redirect::Pipe)
              if !status.success?
                reaped = true
                break
              end
              sleep 50.milliseconds
            end
            reaped.should be_true
          end

          mock.assert_all_consumed!
        end
      end
    end
  end

  describe "Workflow 5: Pinned Working Set & Live Disk Re-Read" do
    it "short-circuits redundant file reads and hot-reloads mutated content on next turn" do
      Nightmare::Integration.with_sandbox("pinned_reread_") do |sandbox|
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

            # 5. Follow-up turn sends updated prompt over the wire
            session.send_line("Verify updated context")
            session.wait_for("Confirmed V2 in active context")

            session.send_line("/exit")
            session.wait_exit

            # Strict assertion: Latest wire request contained MUTATED_CONTENT_V2 and NOT INITIAL_CONTENT_V1
            requests = mock.recorded_requests
            latest_wire = requests.last[:body]
            latest_wire.should contain("MUTATED_CONTENT_V2")
            latest_wire.should_not contain("INITIAL_CONTENT_V1")
          end

          mock.assert_all_consumed!
        end
      end
    end
  end

  describe "Workflow 6: Interactive Turn Interruption & Rollback on Ctrl+C" do
    it "rolls back interrupted assistant response without leaving orphaned tool calls" do
      Nightmare::Integration.with_sandbox("interrupt_rollback_") do |sandbox|
        Nightmare::Integration.with_mock_llm do |mock|
          # Multi-chunk streaming response with 100ms delay between chunks to reliably test mid-stream cancel
          chunks = ["First chunk of text... ", "Second chunk of text... ", "Third chunk... ", "Final answer."]
          mock.enqueue_stream_response(chunks, prompt_tokens: 40, chunk_delay: 100.milliseconds)
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

  # =========================================================================
  # Phase 3 Workflows (Advanced Subsystem & Resilience Workflows)
  # =========================================================================

  describe "Workflow 7: In-Turn Context Shedding vs. Pristine Transcript Export" do
    it "sheds older tool outputs in RAM context to protect token budget while exporting pristine uncompressed outputs to /save transcript" do
      Nightmare::Integration.with_sandbox("shed_transcript_") do |sandbox|
        # Pre-seed settings with a low token hardmax and trigger ratio to deterministically trigger in-turn shedding
        cfg_dir = sandbox.workspace_config_dir
        Dir.mkdir_p(cfg_dir)
        settings = Nightmare::Settings.new
        settings.token_hardmax = 500
        settings.shed_trigger_ratio = 0.50 # triggers when estimated tokens > 250
        settings.shed_keep_chars = 100
        settings.shed_keep_verbatim = 0    # shed consumed tool results once threshold is exceeded
        File.write(File.join(cfg_dir, "config.json"), settings.to_pretty_json)

        # Create large file on disk
        large_content = "LINE_DATA_" + ("A" * 3000) + "\n"
        sandbox.write_file("data/dump1.txt", large_content)
        sandbox.write_file("data/dump2.txt", "SMALL_DATA_LATEST")

        Nightmare::Integration.with_mock_llm do |mock|
          # Turn with multiple tool calls:
          # Call 1: read_file dump1.txt (large output)
          # Model consumes dump1 and decides to call read_file dump2.txt
          # Call 2: read_file dump2.txt (small output)
          # Final response: summaries both
          mock.enqueue_tool_call("read_file", {"path" => "data/dump1.txt"})
          mock.enqueue_tool_call("read_file", {"path" => "data/dump2.txt"})
          mock.enqueue_text_response("Analysis of both files completed.")

          Nightmare::Integration.with_session(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            session.send_line("Analyze both data dumps")
            session.wait_for("Analysis of both files completed")

            # Check context review: RAM store should show tool output shedding for dump1
            session.send_line("/review")
            session.wait_for("Conversation History")
            session.stdout.should contain("[... remaining output shed: was")

            # Export transcript via /save
            export_path = "exported_transcript.md"
            session.send_line("/save #{export_path}")
            session.wait_for("Transcript saved to")

            session.send_line("/exit")
            session.wait_exit

            # Strict verification:
            # 1. Exported transcript contains full pristine un-shed content
            transcript_content = sandbox.read_file(export_path)
            transcript_content.should contain("LINE_DATA_")
            transcript_content.should contain("A" * 1500)
            transcript_content.should_not contain("[... remaining output shed: was")

            # 2. Wire request sent to LLM for the subsequent step (request 2) shows shedding happened
            requests = mock.recorded_requests
            requests.size.should be >= 3
            # Verify that the tool result payload sent over the wire actually contained the shed tombstone
            step2_body = requests[2][:body]
            step2_body.should contain("[... remaining output shed: was")
            step2_body.should_not contain("A" * 1500)
          end

          mock.assert_all_consumed!
        end
      end
    end
  end

  describe "Workflow 8: System Prompt Precedence Hierarchy" do
    it "adheres strictly to 5-tier precedence: CLI flag > repo override > workspace config > global config > default persona" do
      Nightmare::Integration.with_sandbox("prompt_precedence_") do |sandbox|
        # 1. Default fallback tier: default persona
        Nightmare::Integration.with_session(sandbox) do |session|
          session.send_line("/review")
          session.wait_for("--- System Prompt ---")
          session.stdout.should contain("You are an execution agent operating in the current working directory.")
          session.send_line("/exit")
          session.wait_exit
        end

        # 2. Global Central Config tier (~/.config/nightmare/prompt.md)
        global_cfg_dir = File.join(sandbox.xdg_config, "nightmare")
        Dir.mkdir_p(global_cfg_dir)
        File.write(File.join(global_cfg_dir, "prompt.md"), "GLOBAL_CENTRAL_PROMPT_TIER_4")

        Nightmare::Integration.with_session(sandbox) do |session|
          session.send_line("/review")
          session.wait_for("--- System Prompt ---")
          session.stdout.should contain("GLOBAL_CENTRAL_PROMPT_TIER_4")
          session.send_line("/exit")
          session.wait_exit
        end

        # 3. Workspace Central Config tier (<workspace_config_dir>/prompt.md)
        ws_cfg_dir = sandbox.workspace_config_dir
        Dir.mkdir_p(ws_cfg_dir)
        File.write(File.join(ws_cfg_dir, "prompt.md"), "WORKSPACE_CENTRAL_PROMPT_TIER_3")

        Nightmare::Integration.with_session(sandbox) do |session|
          session.send_line("/review")
          session.wait_for("--- System Prompt ---")
          session.stdout.should contain("WORKSPACE_CENTRAL_PROMPT_TIER_3")
          session.send_line("/exit")
          session.wait_exit
        end

        # 4. Repository Committed Override tier (.nightmare/prompt.md in repo root)
        repo_nightmare_dir = File.join(sandbox.root_path, ".nightmare")
        Dir.mkdir_p(repo_nightmare_dir)
        File.write(File.join(repo_nightmare_dir, "prompt.md"), "REPO_COMMITTED_PROMPT_TIER_2")

        Nightmare::Integration.with_session(sandbox) do |session|
          session.send_line("/review")
          session.wait_for("--- System Prompt ---")
          session.stdout.should contain("REPO_COMMITTED_PROMPT_TIER_2")
          session.send_line("/exit")
          session.wait_exit
        end

        # 5. CLI Flag tier (-s / --system)
        cli_prompt_file = sandbox.write_file("custom_prompt.md", "CLI_FLAG_PROMPT_TIER_1")

        Nightmare::Integration.with_session(
          sandbox,
          args: ["-s", cli_prompt_file]
        ) do |session|
          session.send_line("/review")
          session.wait_for("--- System Prompt ---")
          session.stdout.should contain("CLI_FLAG_PROMPT_TIER_1")
          session.send_line("/exit")
          session.wait_exit
        end
      end
    end
  end

  describe "Workflow 9: Tool Call Loop Detection & Breaker" do
    it "trips circuit breaker on 3 identical tool calls with same parameters, refusing execution without invoking tool" do
      Nightmare::Integration.with_sandbox("loop_breaker_") do |sandbox|
        sandbox.write_file("loop_target.txt", "initial content")

        Nightmare::Integration.with_mock_llm do |mock|
          # Enqueue 3 identical tool calls with identical arguments
          mock.enqueue_tool_call("run_command", {"command" => "echo loop_attempt"})
          mock.enqueue_tool_call("run_command", {"command" => "echo loop_attempt"})
          mock.enqueue_tool_call("run_command", {"command" => "echo loop_attempt"})

          Nightmare::Integration.with_session(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            session.send_line("Repeat the shell command")

            # Call 1 prompts approval modal
            session.wait_for(/echo.*loop_attempt/)
            session.send_line("y")

            # Call 2 prompts approval modal
            session.wait_for(/echo.*loop_attempt/)
            session.send_line("y")

            # Call 3 trips LoopDetector threshold (threshold = 3)
            # Middleware raises LoopCircuitBreakerException WITHOUT calling shell or prompting approval modal
            session.wait_for(/(?:ERR_DEGENERATE_LOOP|DegenerateLoopCircuitBreaker)/i)

            # Assert session is not crashed and can receive slash commands
            session.send_line("/review")
            session.wait_for("Conversation History")

            session.send_line("/exit")
            session.wait_exit
          end

          # Verify failure dump report was recorded in workspace state dir
          state_failures = File.join(sandbox.workspace_state_dir, "failures")
          Dir.exists?(state_failures).should be_true
          failure_files = Dir.children(state_failures)
          failure_files.empty?.should be_false
          dump_json = File.read(File.join(state_failures, failure_files.first))
          dump_data = JSON.parse(dump_json)
          dump_data["error_code"].as_s.should eq("ERR_DEGENERATE_LOOP")
          dump_data["offending_tool"].as_s.should eq("run_command")
          dump_data["arguments"]["command"].as_s.should eq("echo loop_attempt")
        end
      end
    end
  end

  describe "Workflow 10: Multi-Line Paste & Input Handling" do
    it "buffers multiline blocks via \"\"\" delimiters and /paste command, submitting all lines as single turn prompt" do
      Nightmare::Integration.with_sandbox("multiline_paste_") do |sandbox|
        Nightmare::Integration.with_mock_llm do |mock|
          # Expect two separate turns, each receiving the combined multiline string
          mock.enqueue_text_response("Received block 1 successfully.")
          mock.enqueue_text_response("Received block 2 successfully.")

          Nightmare::Integration.with_session(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            # 1. Triple-quote multiline paste block
            session.send_line("\"\"\"")
            session.wait_for("Multi-line mode active")
            session.send_line("def calculate_sum(a, b)")
            session.send_line("  a + b")
            session.send_line("end")
            session.send_line("\"\"\"")

            session.wait_for("Received block 1 successfully")

            # Verify prompt in first turn contains all buffered lines
            requests = mock.recorded_requests
            requests.first[:body].should contain("def calculate_sum(a, b)")
            requests.first[:body].should contain("  a + b")
            requests.first[:body].should contain("end")

            # 2. /paste command multiline block ended with /end
            session.send_line("/paste")
            session.wait_for("Multi-line mode active")
            session.send_line("SELECT id, name")
            session.send_line("FROM users")
            session.send_line("WHERE active = true;")
            session.send_line("/end")

            session.wait_for("Received block 2 successfully")

            # Verify prompt in second turn contains sql query
            requests = mock.recorded_requests
            requests.last[:body].should contain("SELECT id, name")
            requests.last[:body].should contain("WHERE active = true;")

            session.send_line("/exit")
            session.wait_exit
          end

          mock.assert_all_consumed!
        end
      end
    end
  end

  describe "Workflow 11: Ghost Mode & Anti-Exfiltration Guarantee" do
    it "runs with --no-logs without writing to audit logs, state dirs, or leaving any disk footprint" do
      Nightmare::Integration.with_sandbox("ghost_mode_") do |sandbox|
        Nightmare::Integration.with_mock_llm do |mock|
          mock.enqueue_text_response("Ghost turn processed silently.")

          Nightmare::Integration.with_session(
            sandbox,
            args: ["--no-logs"],
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          ) do |session|
            # Banner displays ghost mode confirmation
            session.wait_for("Mode      : --no-logs (nothing is persisted)", from_start: true)

            session.send_line("Execute sensitive operation")
            session.wait_for("Ghost turn processed silently")

            session.send_line("/exit")
            session.wait_exit
          end

          mock.assert_all_consumed!
        end

        # Strict Anti-Exfiltration Guarantees:
        # 1. No state directory created under XDG_STATE_HOME/nightmare
        Dir.exists?(File.join(sandbox.xdg_state, "nightmare")).should be_false

        # 2. No cache directory created under XDG_CACHE_HOME/nightmare
        Dir.exists?(File.join(sandbox.xdg_cache, "nightmare")).should be_false

        # 3. No config directory created under XDG_CONFIG_HOME/nightmare
        Dir.exists?(File.join(sandbox.xdg_config, "nightmare")).should be_false

        # 4. Zero repo litter in target repository
        sandbox.assert_zero_repo_litter!
      end
    end
  end
end
