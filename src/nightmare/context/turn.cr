# nightmare/context/turn.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"
require "../config"

module Nightmare::Context
  # Atomic Turn Unit: pruned together, never split.
  # `messages` is the exact ordered wire sequence for this turn:
  #   [user] ([assistant(+tool_calls, maybe +content)] [tool]+)* [assistant]
  class Turn
    getter messages : Array(Mantle::Message)
    getter exchanges : Array(ToolExchange)   # views into @messages
    property prompt_tokens : Int32?          # Response#prompt_eval_count for this turn
    property started_at : Time
    property interrupted : Bool = false
    property side_effects : Array(String)    # paths mutated

    def initialize(user_message : Mantle::Message)
      @messages = [user_message]
      @exchanges = [] of ToolExchange
      @side_effects = [] of String
      @started_at = Time.utc
      @prompt_tokens = nil
    end

    def user_message : Mantle::Message
      @messages.first
    end

    def append_assistant(msg : Mantle::Message) : Nil
      @messages << msg
    end

    def append_tool_result(call : Mantle::Clients::ToolCall, content : String, raw_size : Int32) : ToolExchange
      tool_msg = Mantle::Message.new(
        role: "tool",
        content: content,
        tool_call_id: call.id
      )
      idx = @messages.size
      @messages << tool_msg
      exchange = ToolExchange.new(self, idx, call, raw_size)
      @exchanges << exchange
      exchange
    end

    # Rebuilds the turn and exchanges from an exact Mantle::Message sequence
    def self.from_messages(msgs : Array(Mantle::Message)) : Turn
      raise ArgumentError.new("Messages array cannot be empty") if msgs.empty?
      raise ArgumentError.new("Turn must start with user message") unless msgs.first.role == "user"

      turn = new(msgs.first)
      recent_calls = Hash(String, Mantle::Clients::ToolCall).new

      msgs[1..].each do |msg|
        case msg.role
        when "assistant"
          if tool_calls = msg.tool_calls
            tool_calls.each { |tc| recent_calls[tc.id] = tc }
          end
          turn.messages << msg
        when "tool"
          idx = turn.messages.size
          turn.messages << msg
          if id = msg.tool_call_id
            call = recent_calls[id]? || Mantle::Clients::ToolCall.new(
              id: id,
              type: "function",
              function: Mantle::Clients::ToolCallFunction.new(name: "unknown", arguments: "{}")
            )
            raw_size = msg.content.try(&.bytesize) || 0
            is_shed = msg.content.try(&.includes?("[... output truncated: was")) || false
            turn.exchanges << ToolExchange.new(turn, idx, call, raw_size, shed: is_shed)
          end
        else
          turn.messages << msg
        end
      end

      turn
    end

    def complete? : Bool
      if last = @messages.last?
        last.role == "assistant" && last.tool_calls.nil?
      else
        false
      end
    end

    # Returns the content of the most recent assistant message in this turn, if any.
    def last_assistant_text : String?
      @messages.reverse_each do |m|
        if m.role == "assistant" && (text = m.content)
          stripped = text.strip
          return stripped unless stripped.empty?
        end
      end
      nil
    end

    # Invariant, asserted after every mutation and every prune:
    # every tool_call id in an assistant message has exactly one following
    # tool message with the matching tool_call_id, and every tool message's
    # tool_call_id refers to a preceding assistant tool_call in the same turn.
    def well_formed?(allow_pending_tools : Bool = false) : Bool
      return false if @messages.empty?
      return false unless @messages.first.role == "user"

      calls_declared = Hash(String, Int32).new(0)
      open_calls = Set(String).new

      @messages.each_with_index do |msg, idx|
        next if idx == 0

        case msg.role
        when "assistant"
          if tool_calls = msg.tool_calls
            tool_calls.each do |tc|
              id = tc.id
              return false if calls_declared.has_key?(id)
              calls_declared[id] = 0
              open_calls.add(id)
            end
          end
        when "tool"
          id = msg.tool_call_id
          return false if id.nil? || id.empty?
          return false unless open_calls.includes?(id)
          calls_declared[id] += 1
          open_calls.delete(id)
        else
          return false
        end
      end

      if allow_pending_tools
        calls_declared.values.all? { |count| count <= 1 }
      else
        open_calls.empty? && calls_declared.values.all? { |count| count == 1 }
      end
    end
  end

  class ToolExchange
    getter turn : Turn
    getter index : Int32                     # position in turn.messages
    getter call : Mantle::Clients::ToolCall
    getter raw_size_bytes : Int32
    getter? shed : Bool = false

    def initialize(@turn : Turn, @index : Int32, @call : Mantle::Clients::ToolCall, @raw_size_bytes : Int32, @shed : Bool = false)
    end

    def result_message : Mantle::Message
      @turn.messages[@index]
    end

    def shed!(keep_chars : Int32 = Config::SHED_KEEP_CHARS) : Nil
      return if @shed
      msg = @turn.messages[@index]
      content = msg.content || ""
      return if content.size <= keep_chars
      msg.content = "#{content[0, keep_chars]}\n[... output truncated: was #{@raw_size_bytes} bytes]"
      @turn.messages[@index] = msg     # WRITE-BACK — required
      @shed = true
    end
  end
end
