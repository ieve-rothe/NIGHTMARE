# spec/shedder_and_store_spec.cr
require "./spec_helper"

describe "Shedder and SlidingStore Context Engine" do
  describe "in-turn shedding preserving last 2 verbatim (T4)" do
    it "sheds older consumed tool results while keeping the last 2 verbatim" do
      turn = Nightmare::Context::Turn.new(Mantle::Message.new("user", "Multi-iteration task"))

      # Simulate 6 tool iterations
      # In iteration 1..5: assistant requests tool, tool result appended, next assistant requested
      # In iteration 6: assistant requests tool, tool result appended, final assistant emitted
      6.times do |i|
        call = Mantle::Clients::ToolCall.new(
          id: "call_#{i + 1}",
          type: "function",
          function: Mantle::Clients::ToolCallFunction.new(name: "tool_#{i + 1}", arguments: "{}")
        )
        turn.append_assistant(Mantle::Message.new("assistant", "Working on step #{i + 1}", tool_calls: [call]))
        # 1000 byte verbose output
        turn.append_tool_result(call, "Verbose output #{i + 1} " * 50, 1000)
      end

      # Final completion consumes all tool exchanges
      turn.append_assistant(Mantle::Message.new("assistant", "All steps completed"))
      turn.complete?.should be_true
      turn.exchanges.size.should eq(6)

      # Trigger shedding: current tokens = 10,000, hardmax = 5,000, trigger_ratio = 0.5
      Nightmare::Context::Shedder.shed_active_turn!(
        turn,
        current_tokens: 10_000,
        hardmax: 5_000,
        trigger_ratio: 0.5,
        keep_chars: 200,
        keep_verbatim: 2
      )

      # Exchanges 0..3 (1st to 4th) must be shed!
      4.times do |i|
        turn.exchanges[i].shed?.should be_true
        turn.exchanges[i].result_message.content.not_nil!.should contain("[... output truncated: was")
      end

      # Exchanges 4 and 5 (5th and 6th, last 2) MUST remain verbatim!
      turn.exchanges[4].shed?.should be_false
      turn.exchanges[4].result_message.content.not_nil!.should start_with("Verbose output 5")
      turn.exchanges[5].shed?.should be_false
      turn.exchanges[5].result_message.content.not_nil!.should start_with("Verbose output 6")

      # User message untouched
      turn.user_message.content.should eq("Multi-iteration task")

      # Pair integrity preserved
      turn.well_formed?.should be_true
    end
  end

  describe "shed -> rebuild is byte-identical for unchanged history (T2)" do
    it "does not alter historical turn messages when shedding active turn" do
      store = Nightmare::Context::SlidingStore.new

      # Completed historical turn 1
      t1 = store.start_turn("Turn 1 prompt")
      t1.append_assistant(Mantle::Message.new("assistant", "Response 1"))
      store.commit_turn

      # Completed historical turn 2 with a tool call
      t2 = store.start_turn("Turn 2 prompt")
      c2 = Mantle::Clients::ToolCall.new(id: "c2", function: Mantle::Clients::ToolCallFunction.new(name: "t2", arguments: "{}"))
      t2.append_assistant(Mantle::Message.new("assistant", nil, tool_calls: [c2]))
      t2.append_tool_result(c2, "Tool 2 output", 13)
      t2.append_assistant(Mantle::Message.new("assistant", "Response 2"))
      store.commit_turn

      # Snapshot historical wire messages
      history_snapshot = store.history.map { |t| t.messages.map(&.dup) }

      # Now start active turn with multiple tool iterations
      active = store.start_turn("Active turn")
      3.times do |i|
        call = Mantle::Clients::ToolCall.new(id: "ac_#{i}", function: Mantle::Clients::ToolCallFunction.new(name: "act", arguments: "{}"))
        active.append_assistant(Mantle::Message.new("assistant", nil, tool_calls: [call]))
        active.append_tool_result(call, "Big content #{i}" * 50, 700)
      end
      active.append_assistant(Mantle::Message.new("assistant", "Active done"))

      # Shed only active turn
      Nightmare::Context::Shedder.shed_active_turn!(active, current_tokens: 10_000, hardmax: 1_000, trigger_ratio: 0.1)

      # Check historical messages in store.history: they must be byte-identical!
      store.history.size.should eq(2)
      store.history.each_with_index do |turn, t_idx|
        turn.messages.size.should eq(history_snapshot[t_idx].size)
        turn.messages.each_with_index do |msg, m_idx|
          msg.content.should eq(history_snapshot[t_idx][m_idx].content)
          msg.role.should eq(history_snapshot[t_idx][m_idx].role)
        end
      end
    end
  end

  describe "active turn and user prompt are never evicted (T5)" do
    it "prunes completed turns under extreme pressure without touching active turn" do
      store = Nightmare::Context::SlidingStore.new

      # Fill 5 completed turns
      5.times do |i|
        t = store.start_turn("User #{i}")
        t.append_assistant(Mantle::Message.new("assistant", "Assistant #{i} reply"))
        store.commit_turn
      end
      store.history.size.should eq(5)

      # Start active turn
      active = store.start_turn("Important active question")
      active.append_assistant(Mantle::Message.new("assistant", "Active reply in progress"))

      # Prune history under extreme pressure (hardmax = 1 token forces eviction of historical turns)
      Nightmare::Context::Shedder.prune_history!(store.history, current_tokens: 50_000, hardmax: 1)

      # Historical turns were evicted to recover budget
      store.history.empty?.should be_true

      # Active turn is completely intact and user prompt untouched
      store.active_turn.should_not be_nil
      store.active_turn.not_nil!.user_message.content.should eq("Important active question")
      store.active_turn.not_nil!.messages.size.should eq(2)
    end
  end

  describe "side-effect note survives rollback (T13)" do
    it "prepends modified files note to next user turn after interrupted turn" do
      store = Nightmare::Context::SlidingStore.new

      # Start turn that mutates files
      turn1 = store.start_turn("Build project")
      turn1.side_effects << "src/app.cr"
      turn1.side_effects << "config.json"

      # User interrupts (Ctrl+C rollback)
      rolled_back = store.rollback_turn
      rolled_back.should_not be_nil
      rolled_back.not_nil!.interrupted.should be_true
      store.active_turn.should be_nil

      # Next user turn starts
      turn2 = store.start_turn("Try another command")

      # Next user message content must carry the advisory note!
      turn2.user_message.content.not_nil!.should contain("[Previous turn was interrupted after modifying: src/app.cr, config.json]")
      turn2.user_message.content.not_nil!.should contain("Try another command")
    end
  end

  describe "sliding store assembly" do
    it "assembles wire format in strict order: system prompt -> pinned -> history -> active" do
      store = Nightmare::Context::SlidingStore.new

      # History
      h1 = store.start_turn("Q1")
      h1.append_assistant(Mantle::Message.new("assistant", "A1"))
      store.commit_turn

      # Active
      store.start_turn("Q2")

      msgs = store.assemble_messages(system_prompt: "System prompt", pinned_block: "=== PINNED FILE: a.cr ===")

      # First message: system prompt + pinned block
      msgs[0].role.should eq("system")
      msgs[0].content.not_nil!.should contain("System prompt")
      msgs[0].content.not_nil!.should contain("=== PINNED FILE: a.cr ===")

      # History: Q1, A1
      msgs[1].role.should eq("user")
      msgs[1].content.should eq("Q1")
      msgs[2].role.should eq("assistant")
      msgs[2].content.should eq("A1")

      # Active: Q2
      msgs[3].role.should eq("user")
      msgs[3].content.should eq("Q2")
    end

    it "assembles wire format in strict order: system prompt -> ephemeral date -> active skill -> pinned files -> history -> active" do
      store = Nightmare::Context::SlidingStore.new

      h1 = store.start_turn("Q1")
      h1.append_assistant(Mantle::Message.new("assistant", "A1"))
      store.commit_turn

      store.start_turn("Q2")

      msgs = store.assemble_messages(
        system_prompt: "Harness System Prompt",
        pinned_block: "=== PINNED FILE: code.cr ===",
        skill_block: "=== ACTIVE SKILL: mail_sorter_v2 (global) ==="
      )

      msgs[0].role.should eq("system")
      content = msgs[0].content.not_nil!
      prompt_idx = content.index("Harness System Prompt").not_nil!
      date_str = Nightmare::Context::SlidingStore.current_date_note
      content.should contain(date_str)
      date_idx = content.index(date_str).not_nil!
      skill_idx = content.index("=== ACTIVE SKILL: mail_sorter_v2 (global) ===").not_nil!
      pinned_idx = content.index("=== PINNED FILE: code.cr ===").not_nil!

      (prompt_idx < date_idx).should be_true
      (date_idx < skill_idx).should be_true
      (skill_idx < pinned_idx).should be_true
    end

    it "injects ephemeral date even when system prompt is nil" do
      store = Nightmare::Context::SlidingStore.new
      msgs = store.assemble_messages(system_prompt: nil)
      msgs[0].role.should eq("system")
      msgs[0].content.not_nil!.should eq(Nightmare::Context::SlidingStore.current_date_note)
    end
  end
end
