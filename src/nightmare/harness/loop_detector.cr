# nightmare/harness/loop_detector.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "../config"

module Nightmare::Harness
  class LoopDetector
    getter counts : Hash(Tuple(String, String), Int32)
    getter threshold : Int32
    getter? tripped : Bool = false
    getter last_refusal : String? = nil
    getter tripped_tool : String? = nil
    getter tripped_args : String? = nil
    getter consecutive_count : Int32 = 0
    getter last_tool : String? = nil
    getter last_args : String? = nil

    def initialize(@threshold : Int32 = Config::LOOP_DETECT_THRESHOLD)
      @counts = Hash(Tuple(String, String), Int32).new(0)
    end

    # Resets the call tracking table for a new turn
    def reset : Nil
      @counts.clear
      @tripped = false
      @last_refusal = nil
      @tripped_tool = nil
      @tripped_args = nil
      @consecutive_count = 0
      @last_tool = nil
      @last_args = nil
    end

    # Resets consecutive tracking when a workspace mutation occurs
    def record_mutation : Nil
      @consecutive_count = 0
      @last_tool = nil
      @last_args = nil
      @counts.clear
    end

    # Checks whether (tool, args) has exceeded the consecutive loop threshold.
    # Returns true if the call should be refused without execution (T16).
    def check(tool_name : String, args_json : String) : Tuple(Bool, String?)
      if @last_tool == tool_name && @last_args == args_json
        @consecutive_count += 1
      else
        @last_tool = tool_name
        @last_args = args_json
        @consecutive_count = 1
        @counts.clear
      end

      key = {tool_name, args_json}
      @counts[key] = @consecutive_count

      if @consecutive_count >= @threshold
        @tripped = true
        @tripped_tool = tool_name
        @tripped_args = args_json
        refusal = "ERR_DEGENERATE_LOOP: identical call to #{tool_name} repeated #{@threshold} times. Halting execution."
        @last_refusal = refusal
        {true, refusal}
      else
        {false, nil}
      end
    end
  end
end
