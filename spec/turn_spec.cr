# spec/turn_spec.cr
require "./spec_helper"

describe Nightmare::Context::Turn do
  describe "pair integrity and well_formed? invariant (T1)" do
    it "considers single user turn well formed when complete" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Hello"))
      turn.append_assistant(Mantle::Message.new("assistant", "Hi there"))
      turn.complete?.should be_true
      turn.well_formed?.should be_true
    end

    it "validates matched tool calls and results across iterations" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Calculate"))
      call1 = Mantle::Clients::ToolCall.new(
        id: "call_1",
        type: "function",
        function: Mantle::Clients::ToolCallFunction.new(name: "calc", arguments: "{}")
      )
      turn.append_assistant(Mantle::Message.new("assistant", nil, tool_calls: [call1]))
      turn.well_formed?(allow_pending_tools: true).should be_true
      turn.well_formed?.should be_false # incomplete

      turn.append_tool_result(call1, "42", 2)
      turn.well_formed?(allow_pending_tools: true).should be_true
      turn.complete?.should be_false

      turn.append_assistant(Mantle::Message.new("assistant", "The answer is 42"))
      turn.complete?.should be_true
      turn.well_formed?.should be_true
    end

    it "detects orphaned tool calls (missing tool message)" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Run tool"))
      call1 = Mantle::Clients::ToolCall.new(
        id: "call_1",
        type: "function",
        function: Mantle::Clients::ToolCallFunction.new(name: "tool_a", arguments: "{}")
      )
      turn.append_assistant(Mantle::Message.new("assistant", nil, tool_calls: [call1]))
      turn.append_assistant(Mantle::Message.new("assistant", "Premature ending"))

      turn.well_formed?.should be_false
    end

    it "detects dangling tool messages without preceding tool calls" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Run tool"))
      turn.messages << Mantle::Message.new("tool", "orphan result", tool_call_id: "nonexistent")
      turn.append_assistant(Mantle::Message.new("assistant", "Done"))

      turn.well_formed?.should be_false
    end

    it "handles multi-call assistant messages and preserves pair integrity" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Multi call"))
      c1 = Mantle::Clients::ToolCall.new(id: "c1", function: Mantle::Clients::ToolCallFunction.new(name: "f1", arguments: "{}"))
      c2 = Mantle::Clients::ToolCall.new(id: "c2", function: Mantle::Clients::ToolCallFunction.new(name: "f2", arguments: "{}"))
      turn.append_assistant(Mantle::Message.new("assistant", "Starting two tools", tool_calls: [c1, c2]))

      turn.append_tool_result(c1, "res1", 4)
      turn.append_tool_result(c2, "res2", 4)

      turn.append_assistant(Mantle::Message.new("assistant", "Both complete"))
      turn.complete?.should be_true
      turn.well_formed?.should be_true
    end

    it "considers turn with in-turn format correction user message well formed when calls paired" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Initial prompt"))
      c1 = Mantle::Clients::ToolCall.new(id: "c1", function: Mantle::Clients::ToolCallFunction.new(name: "f1", arguments: "{}"))
      turn.append_assistant(Mantle::Message.new("assistant", "Tool 1", tool_calls: [c1]))
      turn.append_tool_result(c1, "res1", 4)
      # Format retry injected by StepRunner
      turn.messages << Mantle::Message.new("user", "The previous response had malformed output or arguments. Please reformat and proceed.")
      c2 = Mantle::Clients::ToolCall.new(id: "c2", function: Mantle::Clients::ToolCallFunction.new(name: "f2", arguments: "{}"))
      turn.append_assistant(Mantle::Message.new("assistant", "Tool 2", tool_calls: [c2]))
      turn.append_tool_result(c2, "res2", 4)
      turn.append_assistant(Mantle::Message.new("assistant", "All done"))

      turn.complete?.should be_true
      turn.well_formed?.should be_true
    end

    it "rejects turn if user message occurs while a tool call is still pending" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Initial prompt"))
      c1 = Mantle::Clients::ToolCall.new(id: "c1", function: Mantle::Clients::ToolCallFunction.new(name: "f1", arguments: "{}"))
      turn.append_assistant(Mantle::Message.new("assistant", "Tool 1", tool_calls: [c1]))
      # User message inserted before tool result for c1
      turn.messages << Mantle::Message.new("user", "Interrupted prematurely")
      turn.append_tool_result(c1, "res1", 4)
      turn.append_assistant(Mantle::Message.new("assistant", "Done"))

      turn.well_formed?.should be_false
    end
  end

  describe "struct write-back invariant (T3)" do
    it "actually mutates the message in Turn#messages when shed! is called" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Search"))
      call = Mantle::Clients::ToolCall.new(id: "c_1", function: Mantle::Clients::ToolCallFunction.new(name: "search", arguments: "{}"))
      turn.append_assistant(Mantle::Message.new("assistant", nil, tool_calls: [call]))

      huge_payload = "A" * 500
      exchange = turn.append_tool_result(call, huge_payload, 500)

      # Shed exchange down to 200 chars
      exchange.shed!(200)
      exchange.shed?.should be_true

      # Verify the underlying Turn#messages was mutated via indexed write-back!
      turn_tool_msg = turn.messages[exchange.index]
      turn_tool_msg.content.not_nil!.size.should be < 500
      turn_tool_msg.content.not_nil!.should contain("[... output truncated: was 500 bytes]")
      turn_tool_msg.tool_call_id.should eq("c_1")
    end
  end
end
