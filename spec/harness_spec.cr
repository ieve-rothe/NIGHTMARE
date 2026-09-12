# spec/harness_spec.cr
require "./spec_helper"

describe "Nightmare Harness & Step Runner" do
  describe "loop detection (T16)" do
    it "detects and refuses identical (tool, args) called 3 times without execution" do
      detector = Nightmare::Harness::LoopDetector.new(3)
      tool_name = "read_file"
      args = %({"path":"src/app.cr"})

      refused1, _ = detector.check(tool_name, args)
      refused1.should be_false

      refused2, _ = detector.check(tool_name, args)
      refused2.should be_false

      # Third identical call triggers refusal
      refused3, msg = detector.check(tool_name, args)
      refused3.should be_true
      msg.should_not be_nil
      msg.not_nil!.should contain("[Refused: identical call repeated 3 times. Change approach or ask the user.]")
    end
  end

  describe "cancelled is not a failure (T12)" do
    it "rolls back turn cleanly on cancellation without invoking retrier" do
      store = Nightmare::Context::SlidingStore.new
      calibrator = Nightmare::Context::TokenEstimator.new
      tool_loop = Nightmare::Harness::ToolLoop.new(store, calibrator)

      client = FakeClient.new([
        Mantle::Clients::Response.new(content: "Chunk 1", tool_calls: nil)
      ])

      runner = Nightmare::Harness::StepRunner.new(
        client: client,
        tools: [] of Mantle::Tools::Tool,
        tool_loop: tool_loop
      )

      # Start turn
      store.start_turn("Cancel test prompt")

      # Trigger cancellation flag
      tool_loop.cancelled = true

      outcome = runner.run_turn

      outcome.ok?.should be_false
      outcome.cancelled?.should be_true
      outcome.error.not_nil!.kind.should eq(Nightmare::Harness::StepErrorKind::Cancelled)

      # Active turn was rolled back
      store.active_turn.should be_nil
      store.well_formed?.should be_true
    end
  end

  describe "context overflow recovery (T11)" do
    it "performs emergency shed and retries turn successfully" do
      store = Nightmare::Context::SlidingStore.new
      calibrator = Nightmare::Context::TokenEstimator.new
      tool_loop = Nightmare::Harness::ToolLoop.new(store, calibrator)

      # Historical turn with verbose messages
      h1 = store.start_turn("Hist prompt")
      c1 = Mantle::Clients::ToolCall.new(id: "h_c1", function: Mantle::Clients::ToolCallFunction.new(name: "grep", arguments: "{}"))
      h1.append_assistant(Mantle::Message.new("assistant", nil, tool_calls: [c1]))
      h1.append_tool_result(c1, "Very large history output " * 50, 1000)
      h1.append_assistant(Mantle::Message.new("assistant", "History done"))
      store.commit_turn

      # Call 1 returns truncated response (context overflow / length rejection)
      overflow_resp = Mantle::Clients::Response.new(
        content: nil,
        tool_calls: nil,
        done_reason: "length"
      )

      # Call 2 succeeds with final answer
      success_resp = Mantle::Clients::Response.new(
        content: "Success after emergency shed",
        tool_calls: nil,
        prompt_eval_count: 150
      )

      client = FakeClient.new([overflow_resp, success_resp])

      runner = Nightmare::Harness::StepRunner.new(
        client: client,
        tools: [] of Mantle::Tools::Tool,
        tool_loop: tool_loop
      )

      store.start_turn("Overflow prompt")
      outcome = runner.run_turn

      outcome.ok?.should be_true
      outcome.value.should eq("Success after emergency shed")
      client.call_count.should eq(2)

      # Retried request was measurably smaller (T11)
      client.recorded_messages.size.should eq(2)
      first_req_chars = client.recorded_messages[0].sum { |m| (m.content || "").size }
      second_req_chars = client.recorded_messages[1].sum { |m| (m.content || "").size }
      second_req_chars.should be < first_req_chars
    end
  end

  describe "configurable max_iterations" do
    it "honors custom max_iterations passed to StepRunner" do
      store = Nightmare::Context::SlidingStore.new
      calibrator = Nightmare::Context::TokenEstimator.new
      tool_loop = Nightmare::Harness::ToolLoop.new(store, calibrator)

      call1 = Mantle::Clients::ToolCall.new(id: "c1", function: Mantle::Clients::ToolCallFunction.new(name: "dummy_tool", arguments: "{}"))
      call2 = Mantle::Clients::ToolCall.new(id: "c2", function: Mantle::Clients::ToolCallFunction.new(name: "dummy_tool", arguments: "{}"))
      call3 = Mantle::Clients::ToolCall.new(id: "c3", function: Mantle::Clients::ToolCallFunction.new(name: "dummy_tool", arguments: "{}"))

      responses = [
        Mantle::Clients::Response.new(content: nil, tool_calls: [call1]),
        Mantle::Clients::Response.new(content: nil, tool_calls: [call2]),
        Mantle::Clients::Response.new(content: nil, tool_calls: [call3]),
      ]
      client = FakeClient.new(responses)

      schema = Mantle::Tools::ParametersSchema.new({} of String => Mantle::Tools::PropertyDefinition)
      func = Mantle::Tools::FunctionDefinition.new("dummy_tool", "Dummy tool", schema)
      dummy_tool = Mantle::Tools::Tool.new(func) { |_args| "ok" }

      runner = Nightmare::Harness::StepRunner.new(
        client: client,
        tools: [dummy_tool],
        tool_loop: tool_loop,
        max_iterations: 2
      )

      store.start_turn("Test max iterations")
      outcome = runner.run_turn

      outcome.ok?.should be_false
      outcome.error.not_nil!.kind.should eq(Nightmare::Harness::StepErrorKind::MaxIterationsReached)
      client.call_count.should eq(2)
    end
  end
end
