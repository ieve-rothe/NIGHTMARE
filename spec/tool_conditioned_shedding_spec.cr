# spec/tool_conditioned_shedding_spec.cr
require "./spec_helper"
require "../src/nightmare/context/turn"
require "../src/nightmare/context/shedder"

describe "Tool-Conditioned Context Shedding (TKT-008)" do
  describe "ToolExchange#shed!" do
    it "retains the tail (last 1,500 chars) for run_command output to protect stack traces" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Run compiler"))
      call = Mantle::Clients::ToolCall.new(
        id: "c_cmd",
        function: Mantle::Clients::ToolCallFunction.new(name: "run_command", arguments: "{}")
      )
      turn.append_assistant(Mantle::Message.new("assistant", nil, tool_calls: [call]))

      # Create 3,000 characters of output: top is harmless noise, bottom is compiler error
      noise_head = "COMPILING NOISE...\n" * 100
      error_tail = "FATAL ERROR at line 42: undefined method 'foo' for Bar\nSTACK TRACE:\n  bar.cr:42 in 'execute'\n"
      padding_size = 3000 - error_tail.size
      raw_output = ("A" * padding_size) + error_tail
      raw_bytes = raw_output.bytesize

      exchange = turn.append_tool_result(call, raw_output, raw_bytes)
      exchange.shed! # nil keep_chars -> uses Config::SHED_SHELL_KEEP_CHARS (1,500)

      exchange.shed?.should be_true
      shed_content = exchange.result_message.content.not_nil!

      # Must start with earlier output shed prefix
      shed_content.should start_with("[... earlier output shed: was #{raw_bytes} bytes]\n")

      # Must preserve the error stack trace at the tail!
      shed_content.should contain("FATAL ERROR at line 42: undefined method 'foo' for Bar")
      shed_content.should contain("bar.cr:42 in 'execute'")

      # Tail size should be exactly 1,500 characters
      expected_tail = raw_output[(raw_output.size - Nightmare::Config::SHED_SHELL_KEEP_CHARS)..]
      shed_content.should end_with(expected_tail)
    end

    it "retains the head (first 3,000 chars) for read_file output" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Read file"))
      call = Mantle::Clients::ToolCall.new(
        id: "c_read",
        function: Mantle::Clients::ToolCallFunction.new(name: "read_file", arguments: "{}")
      )
      turn.append_assistant(Mantle::Message.new("assistant", nil, tool_calls: [call]))

      raw_output = "HEADER LINE: important structure\n" + ("BODY LINE: data\n" * 300)
      raw_bytes = raw_output.bytesize

      exchange = turn.append_tool_result(call, raw_output, raw_bytes)
      exchange.shed! # nil keep_chars -> uses Config::SHED_FILE_KEEP_CHARS (3,000)

      exchange.shed?.should be_true
      shed_content = exchange.result_message.content.not_nil!

      # Must retain the head
      shed_content.should start_with("HEADER LINE: important structure\n")
      expected_head = raw_output[0, Nightmare::Config::SHED_FILE_KEEP_CHARS]
      shed_content.should start_with(expected_head)

      # Must append remaining output shed notice
      shed_content.should end_with("\n[... remaining output shed: was #{raw_bytes} bytes]")
    end

    it "retains default 200 chars head for other tools" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Search files"))
      call = Mantle::Clients::ToolCall.new(
        id: "c_search",
        function: Mantle::Clients::ToolCallFunction.new(name: "search", arguments: "{}")
      )
      turn.append_assistant(Mantle::Message.new("assistant", nil, tool_calls: [call]))

      raw_output = "Result 1\n" + ("Extra search result\n" * 50)
      raw_bytes = raw_output.bytesize

      exchange = turn.append_tool_result(call, raw_output, raw_bytes)
      exchange.shed! # nil keep_chars -> uses Config::SHED_KEEP_CHARS (200)

      exchange.shed?.should be_true
      shed_content = exchange.result_message.content.not_nil!

      expected_head = raw_output[0, Nightmare::Config::SHED_KEEP_CHARS]
      shed_content.should start_with(expected_head)
      shed_content.should end_with("\n[... output truncated: was #{raw_bytes} bytes]")
    end
  end
end
