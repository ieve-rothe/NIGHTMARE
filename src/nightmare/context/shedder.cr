# nightmare/context/shedder.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "../config"
require "./turn"
require "./token_calibrator"

module Nightmare::Context
  module Shedder
    # Checks whether a tool exchange has been observed (consumed) by the model,
    # indicated by the existence of a subsequent assistant message in the turn.
    def self.consumed?(turn : Turn, exchange : ToolExchange) : Bool
      last_assistant_idx = turn.messages.rindex { |m| m.role == "assistant" }
      return false if last_assistant_idx.nil?
      exchange.index < last_assistant_idx
    end

    # Returns all consumed tool exchanges in the turn
    def self.consumed_exchanges(turn : Turn) : Array(ToolExchange)
      turn.exchanges.select { |ex| consumed?(turn, ex) }
    end

    # In-turn shedding: compresses consumed tool results in the active turn,
    # keeping the last `keep_verbatim` consumed results intact.
    # Stops as soon as current_tokens falls below trigger threshold.
    def self.shed_active_turn!(
      turn : Turn,
      current_tokens : Int32,
      hardmax : Int32 = Config::TOKEN_HARDMAX,
      trigger_ratio : Float64 = Config::SHED_TRIGGER_RATIO,
      keep_chars : Int32 = Config::SHED_KEEP_CHARS,
      keep_verbatim : Int32 = Config::SHED_KEEP_VERBATIM,
      calibrator : TokenEstimator? = nil
    ) : Int32
      target_threshold = (hardmax.to_f * trigger_ratio).to_i
      tokens = current_tokens
      return tokens if tokens <= target_threshold

      consumed = consumed_exchanges(turn)
      return tokens if consumed.size <= keep_verbatim

      # Eligible exchanges: all consumed except the last `keep_verbatim`
      eligible_count = consumed.size - keep_verbatim
      eligible = consumed[0...eligible_count]

      eligible.each do |ex|
        break if tokens <= target_threshold
        next if ex.shed?

        old_size = ex.result_message.content.try(&.size) || 0
        ex.shed!(keep_chars)
        new_size = ex.result_message.content.try(&.size) || 0

        diff_chars = old_size - new_size
        if diff_chars > 0
          saved = calibrator ? calibrator.estimate(diff_chars) : (diff_chars.to_f / Config::INITIAL_DIVISOR).ceil.to_i
          tokens = Math.max(0, tokens - saved)
        end
      end

      tokens
    end

    # Prunes history when total tokens exceed hardmax:
    # Phase 1: Sheds tool messages in completed historical turns (oldest first).
    # Phase 2: If still over hardmax, evicts entire completed turns (FIFO).
    # Never touches the active turn or user prompt.
    def self.prune_history!(
      history : Array(Turn),
      current_tokens : Int32,
      hardmax : Int32 = Config::TOKEN_HARDMAX,
      keep_chars : Int32 = Config::SHED_KEEP_CHARS,
      keep_verbatim : Int32 = Config::SHED_KEEP_VERBATIM,
      calibrator : TokenEstimator? = nil
    ) : Int32
      tokens = current_tokens
      return tokens if tokens <= hardmax || history.empty?

      # Phase 1: Shed tool messages across completed historical turns, oldest first
      history.each do |hist_turn|
        break if tokens <= hardmax

        consumed = consumed_exchanges(hist_turn)
        next if consumed.empty?

        eligible_count = Math.max(0, consumed.size - keep_verbatim)
        next if eligible_count == 0

        consumed[0...eligible_count].each do |ex|
          break if tokens <= hardmax
          next if ex.shed?

          old_size = ex.result_message.content.try(&.size) || 0
          ex.shed!(keep_chars)
          new_size = ex.result_message.content.try(&.size) || 0

          diff_chars = old_size - new_size
          if diff_chars > 0
            saved = calibrator ? calibrator.estimate(diff_chars) : (diff_chars.to_f / Config::INITIAL_DIVISOR).ceil.to_i
            tokens = Math.max(0, tokens - saved)
          end
        end
      end

      # Phase 2: Evict entire oldest completed turns if still over budget
      while tokens > hardmax && !history.empty?
        evicted = history.shift
        evicted_chars = evicted.messages.sum { |m| (m.content || "").size }
        saved = calibrator ? calibrator.estimate(evicted_chars) : (evicted_chars.to_f / Config::INITIAL_DIVISOR).ceil.to_i
        tokens = Math.max(0, tokens - saved)
      end

      tokens
    end
  end
end
