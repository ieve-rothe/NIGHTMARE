# nightmare/harness/tool_loop.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"
require "../config"
require "../context/sliding_store"
require "../context/token_calibrator"
require "../context/shedder"
require "./loop_detector"
require "./types"

module Nightmare::Harness
  class CancelledException < Exception
  end

  class SpendCapExceededException < Exception
  end

  class ContextOverflowException < Exception
  end

  class ToolLoop
    getter store : Context::SlidingStore
    getter calibrator : Context::TokenEstimator
    getter loop_detector : LoopDetector
    property? cancelled : Bool = false
    getter cumulative_spend : Int32 = 0
    getter last_prompt_tokens : Int32? = nil

    def initialize(
      @store : Context::SlidingStore,
      @calibrator : Context::TokenEstimator,
      @loop_detector : LoopDetector = LoopDetector.new
    )
    end

    def reset_turn : Nil
      @cumulative_spend = 0
      @last_prompt_tokens = nil
      @loop_detector.reset
    end

    # Supplies the Mantle on_iteration hook Proc for in-turn working buffer projection
    def on_iteration_hook : Proc(Array(Mantle::Message), Mantle::Clients::Response?, Array(Mantle::Message))
      ->(working_messages : Array(Mantle::Message), last_response : Mantle::Clients::Response?) {
        handle_iteration(working_messages, last_response)
      }
    end

    private def handle_iteration(
      working_messages : Array(Mantle::Message),
      last_response : Mantle::Clients::Response?
    ) : Array(Mantle::Message)
      # 1. Cooperative cancellation check
      if @cancelled
        raise CancelledException.new("Turn cancelled by user interrupt")
      end

      # 2. Token accounting & spend monitoring
      if last = last_response
        if prompt_tokens = last.prompt_eval_count
          @last_prompt_tokens = prompt_tokens
          if active = @store.active_turn
            active.prompt_tokens = prompt_tokens
          end

          chars = working_messages.sum { |m| (m.content || "").size }
          @calibrator.calibrate!(chars, prompt_tokens)
        end

        if eval_tokens = last.eval_count
          @cumulative_spend += eval_tokens
          if @cumulative_spend > Config::TURN_SPEND_CAP_TOKENS
            raise SpendCapExceededException.new("Turn spend cap (#{Config::TURN_SPEND_CAP_TOKENS} tokens) exceeded")
          end
        end
      end

      # 3. Synchronize working_messages to active_turn messages
      if active = @store.active_turn
        # Find index in working_messages where active turn messages start
        # working_messages has [system, ..., history..., active_messages...]
        # Synchronize new assistant and tool messages into active_turn
        sync_active_messages(active, working_messages)
      end

      # 4. Predictive check & in-turn shedding
      total_chars = working_messages.sum { |m| (m.content || "").size }
      estimated = if pt = @last_prompt_tokens
        pt + @calibrator.estimate(total_chars)
      else
        @calibrator.estimate(total_chars)
      end

      hardmax = @store.hardmax
      trigger_threshold = (hardmax.to_f * Config::SHED_TRIGGER_RATIO).to_i

      if estimated > trigger_threshold
        if active = @store.active_turn
          estimated = Context::Shedder.shed_active_turn!(
            active,
            current_tokens: estimated,
            hardmax: hardmax,
            trigger_ratio: Config::SHED_TRIGGER_RATIO,
            keep_chars: Config::SHED_KEEP_CHARS,
            keep_verbatim: Config::SHED_KEEP_VERBATIM,
            calibrator: @calibrator
          )
        end
      end

      if estimated > hardmax
        Context::Shedder.prune_history!(
          @store.history,
          current_tokens: estimated,
          hardmax: hardmax,
          calibrator: @calibrator
        )
      end

      # 5. Authoritative buffer rewrite via #map with keyword tool_call_id:
      if active = @store.active_turn
        working_messages.map do |msg|
          if msg.role == "tool"
            # Find matching exchange in active turn
            match = active.exchanges.find { |ex| ex.call.id == msg.tool_call_id }
            if match && match.shed?
              Mantle::Message.new("tool", match.result_message.content, tool_call_id: msg.tool_call_id)
            else
              msg
            end
          else
            msg
          end
        end
      else
        working_messages
      end
    end

    private def sync_active_messages(active : Context::Turn, working_messages : Array(Mantle::Message)) : Nil
      # Ensure active.messages contains the exact assistant and tool sequence from working_messages
      # Find user message matching active.user_message
      user_idx = working_messages.rindex { |m| m.role == "user" && m.content == active.user_message.content }
      return unless user_idx

      slice = working_messages[user_idx..]
      slice.each_with_index do |msg, i|
        if i >= active.messages.size
          case msg.role
          when "assistant"
            active.append_assistant(msg)
          when "tool"
            # Find preceding call
            if call_id = msg.tool_call_id
              last_assistant = active.messages.reverse.find { |m| m.role == "assistant" && m.tool_calls.try(&.any? { |c| c.id == call_id }) }
              call = last_assistant.try(&.tool_calls.try(&.find { |c| c.id == call_id })) || Mantle::Clients::ToolCall.new(
                id: call_id,
                type: "function",
                function: Mantle::Clients::ToolCallFunction.new(name: "tool", arguments: "{}")
              )
              active.append_tool_result(call, msg.content || "", (msg.content || "").bytesize)
            else
              active.messages << msg
            end
          end
        end
      end
    end
  end
end
