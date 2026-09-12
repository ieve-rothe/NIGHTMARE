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
    def start_turn(user_message : Mantle::Message) : Turn
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

    # Assembles wire-format messages in strict order:
    # 1. System prompt
    # 2. Pinned files block
    # 3. Completed historical turns splatted in order
    # 4. Active in-flight turn messages
    def assemble_messages(system_prompt : String? = nil, pinned_block : String? = nil) : Array(Mantle::Message)
      result = [] of Mantle::Message

      has_prompt = system_prompt && !system_prompt.empty?
      has_pinned = pinned_block && !pinned_block.empty?

      if has_prompt && has_pinned
        result << Mantle::Message.new("system", "#{system_prompt}\n\n#{pinned_block}")
      elsif has_prompt
        result << Mantle::Message.new("system", system_prompt)
      elsif has_pinned
        result << Mantle::Message.new("system", pinned_block)
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
    def total_characters(system_prompt : String? = nil, pinned_block : String? = nil) : Int32
      msgs = assemble_messages(system_prompt, pinned_block)
      msgs.sum { |m| (m.content || "").size }
    end

    # Estimates total tokens across all assembled messages using the calibrator
    def total_estimated_tokens(calibrator : TokenEstimator, system_prompt : String? = nil, pinned_block : String? = nil) : Int32
      calibrator.estimate(total_characters(system_prompt, pinned_block))
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
