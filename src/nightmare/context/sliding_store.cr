# nightmare/context/sliding_store.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"
require "../config"
require "./turn"
require "./token_calibrator"
require "./shedder"

module Nightmare::Context
  class SlidingStore
    getter history : Array(Turn)
    property active_turn : Turn?
    getter soft_cap : Int32
    getter hardmax : Int32
    getter pending_side_effects : Array(String)

    def initialize(@soft_cap : Int32 = Config::TURN_SOFT_CAP, @hardmax : Int32 = Config::TOKEN_HARDMAX)
      @history = [] of Turn
      @active_turn = nil
      @pending_side_effects = [] of String
    end

    # Starts a new active turn from a user message.
    # If a prior turn was interrupted with side effects, prepends an advisory note.
    # If an existing uncommitted active turn has progress (>1 message), it is sealed and pushed to history.
    def start_turn(user_message : Mantle::Message) : Turn
      if prior = @active_turn
        if prior.messages.size > 1
          salvage_uncommitted_turn(prior)
        end
      end

      msg = user_message
      if !@pending_side_effects.empty?
        note = "[Previous turn was interrupted after modifying: #{@pending_side_effects.join(", ")}]\n\n"
        existing = msg.content || ""
        msg = Mantle::Message.new("user", "#{note}#{existing}")
        @pending_side_effects.clear
      end

      turn = Turn.new(msg)
      @active_turn = turn
      turn
    end

    # Starts an active turn directly from raw string prompt
    def start_turn(prompt : String) : Turn
      start_turn(Mantle::Message.new("user", prompt))
    end

    # Pushes an arbitrary completed well-formed turn into history and applies FIFO soft-cap eviction
    def push_turn(turn : Turn) : Nil
      unless turn.well_formed?
        raise Nightmare::Error.new("Cannot push malformed turn: unpaired tool calls or results")
      end

      @history << turn
      while @history.size > @soft_cap
        @history.shift
      end
    end

    # Commits the active turn to completed history and applies FIFO soft-cap eviction.
    def commit_turn : Turn?
      active = @active_turn
      return nil unless active

      unless active.well_formed?
        raise Nightmare::Error.new("Cannot commit malformed turn: unpaired tool calls or results")
      end

      @history << active
      @active_turn = nil

      # FIFO soft-cap eviction
      while @history.size > @soft_cap
        @history.shift
      end

      active
    end

    # Seals any unfulfilled tool calls in an uncommitted turn and commits it to history
    private def salvage_uncommitted_turn(turn : Turn) : Nil
      # 0. Disambiguate duplicate tool_call IDs if any exist
      seen_ids = Set(String).new
      turn.messages.each_with_index do |m, idx|
        if m.role == "assistant" && (tcs = m.tool_calls)
          tcs.each_with_index do |tc, tc_idx|
            if seen_ids.includes?(tc.id)
              new_id = "#{tc.id}_dup#{idx}_#{tc_idx}"
              ((idx + 1)...turn.messages.size).each do |tm_idx|
                tm = turn.messages[tm_idx]
                if tm.role == "tool" && tm.tool_call_id == tc.id
                  turn.messages[tm_idx] = Mantle::Message.new(
                    role: "tool",
                    content: tm.content,
                    tool_calls: tm.tool_calls,
                    tool_call_id: new_id
                  )
                  break
                end
              end
              tcs[tc_idx] = Mantle::Clients::ToolCall.new(new_id, tc.function, tc.type)
              seen_ids.add(new_id)
            else
              seen_ids.add(tc.id)
            end
          end
        end
      end

      open_calls = Set(String).new
      turn.messages.each_with_index do |m, idx|
        next if idx == 0
        if m.role == "assistant"
          if tcs = m.tool_calls
            tcs.each { |tc| open_calls.add(tc.id) }
          end
        elsif m.role == "tool"
          if tid = m.tool_call_id
            open_calls.delete(tid)
          end
        end
      end

      open_calls.each do |unclosed_id|
        turn.messages << Mantle::Message.new(
          role: "tool",
          content: %({"error": "Turn ended abruptly before tool result was recorded", "refused": true}),
          tool_call_id: unclosed_id
        )
      end

      if turn.messages.last?.try(&.role) != "assistant"
        turn.append_assistant(Mantle::Message.new(
          "assistant",
          "Turn execution ended abruptly or was superseded by operator."
        ))
      end

      if turn.well_formed?
        push_turn(turn)
      end
      @active_turn = nil
    end

    # Cancels and rolls back the active turn, preserving any mutated side-effect paths.
    def rollback_turn : Turn?
      active = @active_turn
      return nil unless active

      active.interrupted = true
      unless active.side_effects.empty?
        @pending_side_effects.concat(active.side_effects)
        @pending_side_effects.uniq!
      end

      @active_turn = nil
      active
    end

    def self.current_date_note : String
      "Today's date: #{Time.local.to_s("%Y-%m-%d")}"
    end

    # Assembles wire-format messages in strict order:
    # 1. System prompt
    # 2. Ephemeral current date note
    # 3. Active skill block
    # 4. Pinned files block
    # 5. Completed historical turns splatted in order
    # 6. Active in-flight turn messages
    def assemble_messages(system_prompt : String? = nil, pinned_block : String? = nil, skill_block : String? = nil) : Array(Mantle::Message)
      result = [] of Mantle::Message

      system_parts = [] of String
      system_parts << system_prompt if system_prompt && !system_prompt.empty?
      system_parts << SlidingStore.current_date_note
      system_parts << skill_block if skill_block && !skill_block.empty?
      system_parts << pinned_block if pinned_block && !pinned_block.empty?

      unless system_parts.empty?
        result << Mantle::Message.new("system", system_parts.join("\n\n"))
      end

      @history.each do |turn|
        result.concat(turn.messages)
      end

      if active = @active_turn
        result.concat(active.messages)
      end

      result
    end

    # Calculates total characters across all assembled messages
    def total_characters(system_prompt : String? = nil, pinned_block : String? = nil, skill_block : String? = nil) : Int32
      msgs = assemble_messages(system_prompt, pinned_block, skill_block)
      msgs.sum { |m| (m.content || "").size }
    end

    # Estimates total tokens across all assembled messages using the calibrator
    def total_estimated_tokens(calibrator : TokenEstimator, system_prompt : String? = nil, pinned_block : String? = nil, skill_block : String? = nil) : Int32
      calibrator.estimate(total_characters(system_prompt, pinned_block, skill_block))
    end

    # Asserts that all history turns and active turn (if any) satisfy pair integrity
    def well_formed? : Bool
      hist_ok = @history.all?(&.well_formed?)
      active_ok = @active_turn.nil? || @active_turn.not_nil!.well_formed?(allow_pending_tools: true)
      hist_ok && active_ok
    end

    def clear : Nil
      @history.clear
      @active_turn = nil
      @pending_side_effects.clear
    end
  end
end
