# spec/loop_circuit_breaker_spec.cr
require "./spec_helper"
require "../src/nightmare/harness/loop_detector"
require "../src/nightmare/harness/tool_loop"
require "../src/nightmare/harness/step_runner"
require "../src/nightmare/tools/middleware"

describe "Loop Detector Hard Circuit Breaker & CAPA Failure Dump (TKT-008)" do
  describe "ToolMiddleware::LoopDetector" do
    it "raises LoopCircuitBreakerException immediately when repetition threshold is breached" do
      detector = Nightmare::Harness::LoopDetector.new(threshold: 3)
      middleware = ToolMiddleware::LoopDetector.new(detector)

      dummy_handler = ->(args : Hash(String, JSON::Any)) { "executed successfully" }
      args = {"path" => JSON::Any.new("test.txt")}

      # 1st call
      res1 = middleware.call("read_file", args, dummy_handler)
      res1.should eq("executed successfully")
      detector.tripped?.should be_false

      # 2nd call
      res2 = middleware.call("read_file", args, dummy_handler)
      res2.should eq("executed successfully")
      detector.tripped?.should be_false

      # 3rd call: Circuit Breaker Trips!
      expect_raises(Nightmare::Harness::LoopCircuitBreakerException) do
        middleware.call("read_file", args, dummy_handler)
      end

      detector.tripped?.should be_true
      detector.tripped_tool.should eq("read_file")
      detector.last_refusal.not_nil!.should contain("ERR_DEGENERATE_LOOP")
    end
  end

  describe "StepRunner Circuit Breaker & Failure State Dump" do
    it "halts turn, records ERR_DEGENERATE_LOOP, and writes failure dump JSON to .nightmare/failures/" do
      with_temp_dir do |dir|
        store = Nightmare::Context::SlidingStore.new
        calibrator = Nightmare::Context::TokenEstimator.new
        detector = Nightmare::Harness::LoopDetector.new(threshold: 3)
        tool_loop = Nightmare::Harness::ToolLoop.new(store, calibrator, loop_detector: detector)

        # Repeating tool call in client responses
        repeated_call = Mantle::Clients::ToolCall.new(
          id: "call_1",
          function: Mantle::Clients::ToolCallFunction.new(
            name: "looping_tool",
            arguments: %({"path":"foo.txt"})
          )
        )

        client = FakeClient.new([
          Mantle::Clients::Response.new(content: nil, tool_calls: [repeated_call]),
          Mantle::Clients::Response.new(content: nil, tool_calls: [repeated_call]),
          Mantle::Clients::Response.new(content: nil, tool_calls: [repeated_call]),
          Mantle::Clients::Response.new(content: nil, tool_calls: [repeated_call])
        ])

        # Tool wrapped with LoopDetector middleware
        raw_tool_func = Mantle::Tools::FunctionDefinition.new(
          "looping_tool",
          "Test looping tool",
          Mantle::Tools::ParametersSchema.new({"path" => Mantle::Tools::PropertyDefinition.new("string", "path")})
        )
        raw_tool = Mantle::Tools::Tool.new(raw_tool_func) { |_| "ok" }
        wrapped_tools = ToolMiddleware.wrap_all([raw_tool], [ToolMiddleware::LoopDetector.new(detector)] of ToolMiddleware::Base)

        failures_path = File.join(dir, ".nightmare", "failures")
        runner = Nightmare::Harness::StepRunner.new(
          client: client,
          tools: wrapped_tools,
          tool_loop: tool_loop,
          failures_dir: failures_path
        )

        store.start_turn("Update the skill file")

        outcome = runner.run_turn(store)

        # 1. Turn outcome must be failure with DegenerateLoopCircuitBreaker
        outcome.ok?.should be_false
        err = outcome.error.not_nil!
        err.kind.should eq(Nightmare::Harness::StepErrorKind::DegenerateLoopCircuitBreaker)
        err.retryable.should be_false
        err.message.should contain("ERR_DEGENERATE_LOOP")

        # 2. Failure dump JSON must exist and contain diagnostic CAPA data
        Dir.exists?(failures_path).should be_true
        dump_files = Dir.children(failures_path)
        dump_files.size.should eq(1)

        dump_content = File.read(File.join(failures_path, dump_files.first))
        json_data = JSON.parse(dump_content)

        json_data["error_code"].as_s.should eq("ERR_DEGENERATE_LOOP")
        json_data["offending_tool"].as_s.should eq("looping_tool")
        json_data["arguments"]["path"].as_s.should eq("foo.txt")
        json_data["token_metrics"]["spend_cap"].as_i.should be > 0
        json_data["messages"].as_a.size.should be > 0
      end
    end
  end
end
