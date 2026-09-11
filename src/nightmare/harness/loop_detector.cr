# nightmare/harness/loop_detector.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "../config"

module Nightmare::Harness
  class LoopDetector
    getter counts : Hash(Tuple(String, String), Int32)
    getter threshold : Int32

    def initialize(@threshold : Int32 = Config::LOOP_DETECT_THRESHOLD)
      @counts = Hash(Tuple(String, String), Int32).new(0)
    end

    # Resets the call tracking table for a new turn
    def reset : Nil
      @counts.clear
    end

    # Checks whether (tool, args) has exceeded the loop threshold.
    # Returns true if the call should be refused without execution (T16).
    def check(tool_name : String, args_json : String) : Tuple(Bool, String?)
      key = {tool_name, args_json}
      @counts[key] += 1

      if @counts[key] >= @threshold
        refusal = "[Refused: identical call repeated #{@threshold} times. Change approach or ask the user.]"
        {true, refusal}
      else
        {false, nil}
      end
    end
  end
end
