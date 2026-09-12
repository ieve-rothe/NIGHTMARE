# spec/transcript_spec.cr
require "./spec_helper"

describe Nightmare::Transcript do
  describe "crash survival via incremental append (T15)" do
    it "flushes messages to transcript.md on disk as they are produced" do
      with_temp_dir do |dir|
        transcript = Nightmare::Transcript.new(dir)
        disk_path = File.join(dir, "transcript.md")

        File.exists?(disk_path).should be_false

        # User message
        transcript.record(Mantle::Message.new("user", "Hello transcript"))
        File.exists?(disk_path).should be_true
        File.read(disk_path).should contain("Hello transcript")

        # Assistant tool call
        call = Mantle::Clients::ToolCall.new(
          id: "tc_1",
          type: "function",
          function: Mantle::Clients::ToolCallFunction.new(name: "grep", arguments: %({"q":"test"}))
        )
        transcript.record(Mantle::Message.new("assistant", "Searching...", tool_calls: [call]))

        content_after_call = File.read(disk_path)
        content_after_call.should contain("Searching...")
        content_after_call.should contain("grep")
        content_after_call.should contain("tc_1")

        # Even if process terminates here, transcript.md exists and contains both messages
      end
    end
  end

  describe "/save exports pristine history (T14)" do
    it "preserves original untruncated tool outputs even when in-turn shedding occurred in context" do
      with_temp_dir do |dir|
        transcript = Nightmare::Transcript.new(dir)

        # Record huge tool output in transcript
        huge_tool_output = "Line: " + ("1234567890\n" * 100) # ~1100 chars
        call = Mantle::Clients::ToolCall.new(id: "c1", function: Mantle::Clients::ToolCallFunction.new(name: "cat", arguments: "{}"))

        transcript.record(Mantle::Message.new("user", "Show me the logs"))
        transcript.record(Mantle::Message.new("assistant", nil, tool_calls: [call]))
        transcript.record(Mantle::Message.new("tool", huge_tool_output, tool_call_id: "c1"))

        # In context store, a Turn would shed this tool output
        turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Show me the logs"))
        turn.append_assistant(Mantle::Message.new("assistant", nil, tool_calls: [call]))
        ex = turn.append_tool_result(call, huge_tool_output, huge_tool_output.bytesize)
        ex.shed!(100)

        # Context store version is truncated
        turn.messages[ex.index].content.not_nil!.should contain("[... output truncated: was")

        # Export transcript via save_to
        save_target = File.join(dir, "exported_transcript.md")
        transcript.save_to(save_target)

        # Exported transcript file must contain the FULL, pristine, untruncated tool output!
        exported_content = File.read(save_target)
        exported_content.should contain(huge_tool_output)
        exported_content.should_not contain("[... output truncated: was")
      end
    end
  end

  describe "ghost mode memory-only operation (R7)" do
    it "does not touch disk when enabled is false, but allows on-demand /save" do
      with_temp_dir do |dir|
        transcript = Nightmare::Transcript.new(dir, enabled: false)
        disk_path = File.join(dir, "transcript.md")

        transcript.file_path.should be_nil
        File.exists?(disk_path).should be_false

        transcript.record(Mantle::Message.new("user", "Secret query in memory"))
        transcript.record(Mantle::Message.new("assistant", "Secret response in memory"))

        # No transcript file on disk
        File.exists?(disk_path).should be_false

        # In-memory entries retained
        transcript.entries.size.should eq(2)

        # On-demand export via save_to still works
        save_target = File.join(dir, "custom_export.md")
        transcript.save_to(save_target)

        File.exists?(save_target).should be_true
        File.read(save_target).should contain("Secret query in memory")
        File.read(save_target).should contain("Secret response in memory")
      end
    end
  end
end
