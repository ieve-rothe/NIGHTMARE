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
    end

    # Checks whether (tool, args) has exceeded the loop threshold.
    # Returns true if the call should be refused without execution (T16).
    def check(tool_name : String, args_json : String) : Tuple(Bool, String?)
      key = {tool_name, args_json}
      @counts[key] += 1

      if @counts[key] >= @threshold
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
