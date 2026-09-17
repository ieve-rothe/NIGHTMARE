# spec/harness_spec.cr
require "./spec_helper"
require "../src/nightmare/tools/middleware"

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

      outcome = runner.run_turn(store)

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
      outcome = runner.run_turn(store)

      outcome.ok?.should be_true
      outcome.value.should eq("Success after emergency shed")
      client.call_count.should eq(2)

      # Retried request was measurably smaller (T11)
      client.recorded_messages.size.should eq(2)
      first_req_chars = client.recorded_messages[0].sum { |m| (m.content || "").size }
      second_req_chars = client.recorded_messages[1].sum { |m| (m.content || "").size }
      second_req_chars.should be < first_req_chars
    end

    it "does not trigger context overflow on network/socket IO errors" do
      store = Nightmare::Context::SlidingStore.new
      calibrator = Nightmare::Context::TokenEstimator.new
      tool_loop = Nightmare::Harness::ToolLoop.new(store, calibrator)

      # Network error with "length" in the message
      client = FakeClient.new
      client.raise_on_call[1] = IO::Error.new("Connection reset by peer (length mismatch)")

      runner = Nightmare::Harness::StepRunner.new(
        client: client,
        tools: [] of Mantle::Tools::Tool,
        tool_loop: tool_loop
      )

      store.start_turn("Network test prompt")
      outcome = runner.run_turn(store)

      outcome.ok?.should be_false
      outcome.error.not_nil!.kind.should eq(Nightmare::Harness::StepErrorKind::ClientFailure)
      outcome.error.not_nil!.message.should contain("Connection reset by peer")
      client.call_count.should eq(1)
      # History must NOT be shed
      store.active_turn.should_not be_nil
    end

    it "recovers from MalformedOutput via format correction retry and successfully commits turn" do
      store = Nightmare::Context::SlidingStore.new
      calibrator = Nightmare::Context::TokenEstimator.new
      tool_loop = Nightmare::Harness::ToolLoop.new(store, calibrator)

      resp1 = Mantle::Clients::Response.new(content: nil, tool_calls: nil, thinking: "Thinking only...")
      resp2 = Mantle::Clients::Response.new(content: "Success after format retry", tool_calls: nil)

      client = FakeClient.new([resp1, resp2])

      runner = Nightmare::Harness::StepRunner.new(
        client: client,
        tools: [] of Mantle::Tools::Tool,
        tool_loop: tool_loop,
        format_retries: 1
      )

      store.start_turn("Format retry prompt")
      outcome = runner.run_turn(store)

      outcome.ok?.should be_true
      outcome.value.should eq("Success after format retry")
      client.call_count.should eq(2)

      # Turn committed cleanly in store history
      store.active_turn.should be_nil
      store.history.size.should eq(1)
      committed_turn = store.history.first
      committed_turn.messages.any? { |m| m.content.try(&.includes?("malformed output or arguments")) }.should be_true
      committed_turn.well_formed?.should be_true
      store.well_formed?.should be_true
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
      outcome = runner.run_turn(store)

      outcome.ok?.should be_false
      outcome.error.not_nil!.kind.should eq(Nightmare::Harness::StepErrorKind::MaxIterationsReached)
      client.call_count.should eq(2)
    end
  end

  describe "explicit SlidingStore isolation (subagent depth-1)" do
    it "uses the provided store and does not pollute another store" do
      orchestrator_store = Nightmare::Context::SlidingStore.new
      subagent_store = Nightmare::Context::SlidingStore.new
      calibrator = Nightmare::Context::TokenEstimator.new
      tool_loop = Nightmare::Harness::ToolLoop.new(orchestrator_store, calibrator)

      orchestrator_store.start_turn("Orchestrator prompt")

      subagent_client = FakeClient.new([
        Mantle::Clients::Response.new(content: "Subagent answer", tool_calls: nil)
      ])

      runner = Nightmare::Harness::StepRunner.new(
        client: subagent_client,
        tools: [] of Mantle::Tools::Tool,
        tool_loop: tool_loop
      )

      subagent_store.start_turn("Subagent subtask")
      outcome = runner.run_turn(subagent_store)

      outcome.ok?.should be_true
      outcome.value.should eq("Subagent answer")

      # Subagent turn committed in subagent store
      subagent_store.history.size.should eq(1)
      subagent_store.history.first.user_message.content.should eq("Subagent subtask")

      # Orchestrator turn remained untouched and uncommitted
      orchestrator_store.history.size.should eq(0)
      orchestrator_store.active_turn.should_not be_nil
      orchestrator_store.active_turn.not_nil!.user_message.content.should eq("Orchestrator prompt")
    end
  end

  describe "strict error boundary" do
    it "traps operational errors and returns them as tool result strings" do
      schema = Mantle::Tools::ParametersSchema.new({} of String => Mantle::Tools::PropertyDefinition)

      # 1. SecurityError
      func1 = Mantle::Tools::FunctionDefinition.new("sec_tool", "desc", schema)
      t1 = Mantle::Tools::Tool.new(func1) { |_| raise SecurityError.new("outside root") }

      # 2. File::NotFoundError
      func2 = Mantle::Tools::FunctionDefinition.new("file_tool", "desc", schema)
      t2 = Mantle::Tools::Tool.new(func2) { |_| raise File::NotFoundError.new("File not found", file: "missing.txt") }

      # 3. ArgumentError
      func3 = Mantle::Tools::FunctionDefinition.new("arg_tool", "desc", schema)
      t3 = Mantle::Tools::Tool.new(func3) { |_| raise ArgumentError.new("invalid param") }

      # 4. JSON::ParseException
      func4 = Mantle::Tools::FunctionDefinition.new("json_tool", "desc", schema)
      t4 = Mantle::Tools::Tool.new(func4) { |_| raise JSON::ParseException.new("bad json", 1, 1) }

      # 5. CommandFailedError
      func5 = Mantle::Tools::FunctionDefinition.new("cmd_tool", "desc", schema)
      t5 = Mantle::Tools::Tool.new(func5) { |_| raise Nightmare::Tools::CommandFailedError.new(1, "exit status 1") }

      tools = [t1, t2, t3, t4, t5]
      hardened = ToolMiddleware.wrap_all(tools, [ToolMiddleware::ExceptionTrapping.new] of ToolMiddleware::Base)

      hardened[0].execute({} of String => JSON::Any).should eq("[SecurityError: outside root]")
      hardened[1].execute({} of String => JSON::Any).should eq("[FileError: File not found]")
      hardened[2].execute({} of String => JSON::Any).should eq("[ArgumentError: invalid param]")
      hardened[3].execute({} of String => JSON::Any).should contain("[JSONError: bad json")
      hardened[4].execute({} of String => JSON::Any).should eq("[CommandFailed: exit status 1]")
    end

    it "lets developer bugs (NilAssertionError, IndexError, TypeCastError) crash without being trapped" do
      schema = Mantle::Tools::ParametersSchema.new({} of String => Mantle::Tools::PropertyDefinition)

      func1 = Mantle::Tools::FunctionDefinition.new("nil_tool", "desc", schema)
      t1 = Mantle::Tools::Tool.new(func1) { |_| raise NilAssertionError.new("nil bug") }

      func2 = Mantle::Tools::FunctionDefinition.new("idx_tool", "desc", schema)
      t2 = Mantle::Tools::Tool.new(func2) { |_| raise IndexError.new("index bug") }

      func3 = Mantle::Tools::FunctionDefinition.new("type_tool", "desc", schema)
      t3 = Mantle::Tools::Tool.new(func3) { |_| raise TypeCastError.new("cast bug") }

      hardened = ToolMiddleware.wrap_all([t1, t2, t3], [ToolMiddleware::ExceptionTrapping.new] of ToolMiddleware::Base)

      expect_raises(NilAssertionError, "nil bug") do
        hardened[0].execute({} of String => JSON::Any)
      end

      expect_raises(IndexError, "index bug") do
        hardened[1].execute({} of String => JSON::Any)
      end

      expect_raises(TypeCastError, "cast bug") do
        hardened[2].execute({} of String => JSON::Any)
      end
    end
  end
end
