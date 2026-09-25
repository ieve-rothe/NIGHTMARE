# spec/plan/subagent_runner_spec.cr
require "../spec_helper"
require "../../src/nightmare/harness/subagent_runner"

describe Nightmare::Harness::SubagentRunner do
  it "blocks relative path traversal outside files_targeted" do
    temp_dir = File.tempname("guard_targeted_test")
    Dir.mkdir_p(File.join(temp_dir, "src"))
    Dir.mkdir_p(File.join(temp_dir, "spec"))

    begin
      env = Nightmare::Workspace::Environment.new(
        root_path: temp_dir,
        xdg_config_home: File.join(temp_dir, ".config"),
        xdg_state_home: File.join(temp_dir, ".state"),
        xdg_cache_home: File.join(temp_dir, ".cache"),
        ensure_dirs: false
      )

      guard = Nightmare::Tools::Guard.new(env, files_targeted: ["src/**"])
      mutation = Nightmare::Tools::Mutation.new(guard, approval_handler: ->(_diff : String, _desc : String) { true })

      # Writing inside src/** should succeed
      mutation.write_file("src/hello.cr", "puts 123")
      File.exists?(File.join(temp_dir, "src", "hello.cr")).should be_true

      # Attempting relative path traversal to bypass glob
      expect_raises(Nightmare::SecurityError, /not within allowed files_targeted/) do
        mutation.write_file("src/../spec/bypass.cr", "puts 456")
      end

      # Attempting direct write outside src/**
      expect_raises(Nightmare::SecurityError, /not within allowed files_targeted/) do
        mutation.write_file("spec/direct.cr", "puts 789")
      end
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "blocks git mutation commands in subagent mode while allowing inspection" do
    temp_dir = File.tempname("shell_subagent_test")
    Dir.mkdir_p(temp_dir)

    begin
      env = Nightmare::Workspace::Environment.new(
        root_path: temp_dir,
        xdg_config_home: File.join(temp_dir, ".config"),
        xdg_state_home: File.join(temp_dir, ".state"),
        xdg_cache_home: File.join(temp_dir, ".cache"),
        ensure_dirs: false
      )

      guard = Nightmare::Tools::Guard.new(env)
      shell = Nightmare::Tools::Shell.new(guard, subagent_mode: true)

      # Git mutations should be rejected with structured error
      res_commit = shell.run_command("git commit -m 'evil'")
      res_commit.should contain("forbidden in subagent mode")

      res_checkout = shell.run_command("git checkout -b evil-branch")
      res_checkout.should contain("forbidden in subagent mode")

      res_reset = shell.run_command("git reset --hard HEAD~1")
      res_reset.should contain("forbidden in subagent mode")

      # Allowed inspection commands are not rejected by subagent filter
      # (They may fail in git because temp_dir is not a git repo, but they are not blocked by subagent mode)
      res_status = shell.run_command("git status")
      res_status.should_not contain("forbidden in subagent mode")
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "records command telemetry for executed shell commands" do
    temp_dir = File.tempname("shell_telemetry_test")
    Dir.mkdir_p(temp_dir)

    begin
      env = Nightmare::Workspace::Environment.new(
        root_path: temp_dir,
        xdg_config_home: File.join(temp_dir, ".config"),
        xdg_state_home: File.join(temp_dir, ".state"),
        xdg_cache_home: File.join(temp_dir, ".cache"),
        ensure_dirs: false
      )

      guard = Nightmare::Tools::Guard.new(env)
      shell_approval = ->(_cmd : String, _argv : Array(String), _metachar : Bool, _timeout : Int32) {
        {Nightmare::Tools::ApprovalOutcome::Yes, nil.as(String?)}
      }
      shell = Nightmare::Tools::Shell.new(guard, subagent_mode: true, approval_handler: shell_approval)

      shell.run_command("echo telemetry_check")
      shell.executed_commands.size.should eq(1)

      cmd = shell.executed_commands.first
      cmd.cmd.should eq(["echo", "telemetry_check"])
      cmd.exit_code.should eq(0)
      cmd.duration_ms.should be >= 0
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end

  describe "subagent cooperative cancellation (TKT-018)" do
    it "raises CancelledException when cancelled during token streaming" do
      with_temp_dir do |temp_dir|
        env = Nightmare::Workspace::Environment.new(
          root_path: temp_dir,
          xdg_config_home: File.join(temp_dir, ".config"),
          xdg_state_home: File.join(temp_dir, ".state"),
          xdg_cache_home: File.join(temp_dir, ".cache"),
          ensure_dirs: false
        )

        client = FakeClient.new([
          Mantle::Clients::Response.new(content: "Streaming response token", tool_calls: nil)
        ])

        cancelled = false
        runner = Nightmare::Harness::SubagentRunner.new(
          client: client,
          environment: env,
          cancellation_check: ->{ cancelled }
        )

        # Trigger cancellation
        cancelled = true

        expect_raises(Nightmare::Harness::CancelledException, /Turn cancelled by user interrupt/) do
          runner.run_subagent("Assess documentation")
        end
      end
    end

    it "raises CancelledException when cancelled during tool execution" do
      with_temp_dir do |temp_dir|
        env = Nightmare::Workspace::Environment.new(
          root_path: temp_dir,
          xdg_config_home: File.join(temp_dir, ".config"),
          xdg_state_home: File.join(temp_dir, ".state"),
          xdg_cache_home: File.join(temp_dir, ".cache"),
          ensure_dirs: false
        )

        tool_call = Mantle::Clients::ToolCall.new(
          id: "call_tool_1",
          function: Mantle::Clients::ToolCallFunction.new(
            name: "list_files",
            arguments: %({"path":"."})
          )
        )

        client = FakeClient.new([
          Mantle::Clients::Response.new(content: nil, tool_calls: [tool_call]),
          Mantle::Clients::Response.new(content: "Done", tool_calls: nil)
        ])

        cancelled = false
        runner = Nightmare::Harness::SubagentRunner.new(
          client: client,
          environment: env,
          cancellation_check: ->{ cancelled }
        )

        # Cancel right before tool executes or during
        cancelled = true

        expect_raises(Nightmare::Harness::CancelledException, /Turn cancelled by user interrupt/) do
          runner.run_subagent("Inspect workspace")
        end
      end
    end

    it "raises CancelledException in dispatch when cancelled" do
      with_temp_dir do |temp_dir|
        env = Nightmare::Workspace::Environment.new(
          root_path: temp_dir,
          xdg_config_home: File.join(temp_dir, ".config"),
          xdg_state_home: File.join(temp_dir, ".state"),
          xdg_cache_home: File.join(temp_dir, ".cache"),
          ensure_dirs: false
        )

        client = FakeClient.new([
          Mantle::Clients::Response.new(content: "Working on plan item", tool_calls: nil)
        ])

        cancelled = true
        runner = Nightmare::Harness::SubagentRunner.new(
          client: client,
          environment: env,
          cancellation_check: ->{ cancelled }
        )

        item = Nightmare::Plan::PlanItem.new(
          id: "item-1",
          title: "Setup database"
        )
        plan = Nightmare::Plan::Plan.new(
          id: "test-plan",
          goal: "Test Plan",
          items: [item]
        )
        run = Nightmare::Plan::PlanRun.new(
          run_id: "run-1",
          plan_id: plan.id,
          plan_schema_version: plan.schema_version,
          started_at: Time.utc,
          updated_at: Time.utc,
          status: Nightmare::Plan::PlanRunStatus::Running
        )

        expect_raises(Nightmare::Harness::CancelledException, /Turn cancelled by user interrupt/) do
          runner.dispatch(item, run, temp_dir)
        end
      end
    end

    it "integrates with UI::Cancellation.cancel!" do
      with_temp_dir do |temp_dir|
        env = Nightmare::Workspace::Environment.new(
          root_path: temp_dir,
          xdg_config_home: File.join(temp_dir, ".config"),
          xdg_state_home: File.join(temp_dir, ".state"),
          xdg_cache_home: File.join(temp_dir, ".cache"),
          ensure_dirs: false
        )

        store = Nightmare::Context::SlidingStore.new
        calibrator = Nightmare::Context::TokenEstimator.new
        tool_loop = Nightmare::Harness::ToolLoop.new(store, calibrator)
        guard = Nightmare::Tools::Guard.new(env)
        shell = Nightmare::Tools::Shell.new(guard)
        cancellation = Nightmare::UI::Cancellation.new(tool_loop, shell)
        cancellation.busy = true

        client = FakeClient.new([
          Mantle::Clients::Response.new(content: "Autonomous subagent answer", tool_calls: nil)
        ])

        runner = Nightmare::Harness::SubagentRunner.new(
          client: client,
          environment: env
        )

        # Signal cancellation via UI::Cancellation
        Nightmare::UI::Cancellation.cancel!

        expect_raises(Nightmare::Harness::CancelledException, /Turn cancelled by user interrupt/) do
          runner.run_subagent("Perform review")
        end

        tool_loop.cancelled?.should be_true
      ensure
        Nightmare::UI::Cancellation.current_instance = nil
      end
    end
  end

  describe "Shell global process group tracking and kill_all_active!" do
    it "registers running process groups and terminates them via kill_all_active!" do
      with_temp_dir do |temp_dir|
        env = Nightmare::Workspace::Environment.new(
          root_path: temp_dir,
          xdg_config_home: File.join(temp_dir, ".config"),
          xdg_state_home: File.join(temp_dir, ".state"),
          xdg_cache_home: File.join(temp_dir, ".cache"),
          ensure_dirs: false
        )

        guard = Nightmare::Tools::Guard.new(env)
        shell_approval = ->(_cmd : String, _argv : Array(String), _metachar : Bool, _timeout : Int32) {
          {Nightmare::Tools::ApprovalOutcome::Yes, nil.as(String?)}
        }
        shell = Nightmare::Tools::Shell.new(guard, approval_handler: shell_approval)

        spawn do
          # Run long sleep command in background fiber
          shell.run_command("sleep 30")
        end

        # Wait briefly for process to spawn and pgid to register
        10.times do
          Fiber.yield
          break unless Nightmare::Tools::Shell.active_pgids.empty?
          sleep 10.milliseconds
        end

        Nightmare::Tools::Shell.active_pgids.empty?.should be_false
        pgid = Nightmare::Tools::Shell.active_pgids.first

        # Kill all active processes
        Nightmare::Tools::Shell.kill_all_active!

        # Wait for ensure block to clean up pgid
        sleep 100.milliseconds
        Nightmare::Tools::Shell.active_pgids.should_not contain(pgid)
      end
    end
  end

  describe "Subagent Context Resilience (TKT-020)" do
    it "triggers in-turn shedding during multi-file reads" do
      with_temp_dir do |temp_dir|
        env = Nightmare::Workspace::Environment.new(
          root_path: temp_dir,
          xdg_config_home: File.join(temp_dir, ".config"),
          xdg_state_home: File.join(temp_dir, ".state"),
          xdg_cache_home: File.join(temp_dir, ".cache"),
          ensure_dirs: false
        )
        env.settings.token_hardmax = 2_000
        env.settings.shed_trigger_ratio = 0.5
        env.settings.shed_keep_verbatim = 1
        env.settings.shed_file_keep_chars = 200

        File.write(File.join(temp_dir, "doc1.txt"), "Doc1 Header\n" + ("Line of content A\n" * 250))
        File.write(File.join(temp_dir, "doc2.txt"), "Doc2 Header\n" + ("Line of content B\n" * 250))
        File.write(File.join(temp_dir, "doc3.txt"), "Doc3 Header\n" + ("Line of content C\n" * 250))

        call1 = Mantle::Clients::ToolCall.new(
          id: "call_1",
          function: Mantle::Clients::ToolCallFunction.new(name: "read_file", arguments: %({"path":"doc1.txt"}))
        )
        call2 = Mantle::Clients::ToolCall.new(
          id: "call_2",
          function: Mantle::Clients::ToolCallFunction.new(name: "read_file", arguments: %({"path":"doc2.txt"}))
        )
        call3 = Mantle::Clients::ToolCall.new(
          id: "call_3",
          function: Mantle::Clients::ToolCallFunction.new(name: "read_file", arguments: %({"path":"doc3.txt"}))
        )

        client = FakeClient.new([
          Mantle::Clients::Response.new(content: nil, tool_calls: [call1]),
          Mantle::Clients::Response.new(content: "Examined doc1", tool_calls: [call2]),
          Mantle::Clients::Response.new(content: "Examined doc2", tool_calls: [call3]),
          Mantle::Clients::Response.new(content: "Examined doc3, completed task.", tool_calls: nil),
        ])

        runner = Nightmare::Harness::SubagentRunner.new(client: client, environment: env)
        result = runner.run_subagent("Review documentation files")

        result.should contain("[Subagent completed - 3 tool calls")
        result.should contain("Examined doc3, completed task.")

        recorded = client.recorded_messages.last
        tool_doc1 = recorded.find { |m| m.role == "tool" && m.tool_call_id == "call_1" }
        tool_doc1.should_not be_nil
        tool_doc1.not_nil!.content.not_nil!.should contain("[... remaining output shed: was")
      end
    end

    it "trips loop circuit breaker when subagent makes repetitive tool calls" do
      with_temp_dir do |temp_dir|
        env = Nightmare::Workspace::Environment.new(
          root_path: temp_dir,
          xdg_config_home: File.join(temp_dir, ".config"),
          xdg_state_home: File.join(temp_dir, ".state"),
          xdg_cache_home: File.join(temp_dir, ".cache"),
          ensure_dirs: false
        )
        env.settings.loop_detect_threshold = 3

        call = Mantle::Clients::ToolCall.new(
          id: "call_repeat",
          function: Mantle::Clients::ToolCallFunction.new(name: "list_files", arguments: %({"path":"."}))
        )

        client = FakeClient.new([
          Mantle::Clients::Response.new(content: nil, tool_calls: [call]),
          Mantle::Clients::Response.new(content: "Repeating", tool_calls: [call]),
          Mantle::Clients::Response.new(content: "Repeating again", tool_calls: [call]),
        ])

        runner = Nightmare::Harness::SubagentRunner.new(client: client, environment: env)
        result = runner.run_subagent("List everything repeatedly")

        result.should contain("Subagent loop circuit breaker tripped:")
      end
    end

    it "enforces spend cap during subagent execution" do
      with_temp_dir do |temp_dir|
        env = Nightmare::Workspace::Environment.new(
          root_path: temp_dir,
          xdg_config_home: File.join(temp_dir, ".config"),
          xdg_state_home: File.join(temp_dir, ".state"),
          xdg_cache_home: File.join(temp_dir, ".cache"),
          ensure_dirs: false
        )
        env.settings.turn_spend_cap_tokens = 500

        call = Mantle::Clients::ToolCall.new(
          id: "call_1",
          function: Mantle::Clients::ToolCallFunction.new(name: "list_files", arguments: %({"path":"."}))
        )

        resp1 = Mantle::Clients::Response.new(content: nil, tool_calls: [call])
        resp1.eval_count = 600

        resp2 = Mantle::Clients::Response.new(content: "Finished", tool_calls: nil)

        client = FakeClient.new([resp1, resp2])
        runner = Nightmare::Harness::SubagentRunner.new(client: client, environment: env)
        result = runner.run_subagent("Task that burns tokens")

        result.should contain("[Subagent spend cap exceeded:")
      end
    end

    it "recovers from context overflow error using emergency shedding" do
      with_temp_dir do |temp_dir|
        env = Nightmare::Workspace::Environment.new(
          root_path: temp_dir,
          xdg_config_home: File.join(temp_dir, ".config"),
          xdg_state_home: File.join(temp_dir, ".state"),
          xdg_cache_home: File.join(temp_dir, ".cache"),
          ensure_dirs: false
        )
        env.settings.context_overflow_retries = 1

        call1 = Mantle::Clients::ToolCall.new(
          id: "call_overflow",
          function: Mantle::Clients::ToolCallFunction.new(name: "read_file", arguments: %({"path":"big.txt"}))
        )
        File.write(File.join(temp_dir, "big.txt"), "A" * 2000)

        client = FakeClient.new([
          Mantle::Clients::Response.new(content: nil, tool_calls: [call1]),
          Mantle::Clients::Response.new(content: "Successfully recovered after retry", tool_calls: nil),
        ])

        client.raise_on_call[2] = Exception.new("400 Bad Request: context_length_exceeded")

        runner = Nightmare::Harness::SubagentRunner.new(client: client, environment: env)
        result = runner.run_subagent("Task encountering overflow")

        result.should contain("Successfully recovered after retry")
      end
    end

    it "trips loop circuit breaker and halts in dispatch" do
      with_temp_dir do |temp_dir|
        env = Nightmare::Workspace::Environment.new(
          root_path: temp_dir,
          xdg_config_home: File.join(temp_dir, ".config"),
          xdg_state_home: File.join(temp_dir, ".state"),
          xdg_cache_home: File.join(temp_dir, ".cache"),
          ensure_dirs: false
        )
        env.settings.loop_detect_threshold = 3

        call = Mantle::Clients::ToolCall.new(
          id: "call_repeat_dispatch",
          function: Mantle::Clients::ToolCallFunction.new(name: "list_files", arguments: %({"path":"."}))
        )

        client = FakeClient.new([
          Mantle::Clients::Response.new(content: nil, tool_calls: [call]),
          Mantle::Clients::Response.new(content: "Repeating in dispatch", tool_calls: [call]),
          Mantle::Clients::Response.new(content: "Repeating again in dispatch", tool_calls: [call]),
        ])

        runner = Nightmare::Harness::SubagentRunner.new(client: client, environment: env)
        item = Nightmare::Plan::PlanItem.new(id: "item-loop", title: "Repetitive task")
        run = Nightmare::Plan::PlanRun.new(run_id: "run-1", plan_id: "test-plan")

        outcome = runner.dispatch(item, run, temp_dir)
        outcome[:status].should eq("failed")
        outcome[:summary].should contain("Subagent loop circuit breaker tripped:")
      end
    end
  end
end
