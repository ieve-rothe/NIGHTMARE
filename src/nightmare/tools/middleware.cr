# nightmare/tools/middleware.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"
require "../harness/loop_detector"
require "../harness/tool_loop"
require "../ui/turn_presenter"

module Nightmare::Tools
  class CommandFailedError < Mantle::Tools::CommandFailedError
  end
end

module ToolMiddleware
  # Loop detector middleware acts as a hard circuit breaker, raising LoopCircuitBreakerException on repeat breach
  class LoopDetector < Base
    getter detector : Nightmare::Harness::LoopDetector

    def initialize(@detector : Nightmare::Harness::LoopDetector)
    end

    def call(
      tool_name : String,
      args : Hash(String, JSON::Any),
      next_handler : Proc(Hash(String, JSON::Any), String)
    ) : String
      refused, msg = @detector.check(tool_name, args.to_json)
      if refused
        raise Nightmare::Harness::LoopCircuitBreakerException.new(msg.not_nil!, tool_name, args.to_json)
      else
        next_handler.call(args)
      end
    end
  end

  # Presentation middleware surfaces tool execution results to TurnPresenter if active.
  # When presenter is nil (headless mode), no output is generated.
  class Presentation < Base
    property presenter : Nightmare::UI::TurnPresenter?

    def initialize(@presenter : Nightmare::UI::TurnPresenter? = nil)
    end

    def call(
      tool_name : String,
      args : Hash(String, JSON::Any),
      next_handler : Proc(Hash(String, JSON::Any), String)
    ) : String
      res = next_handler.call(args)
      if p = @presenter
        p.present_tool_result(tool_name, args, res)
      end
      res
    end
  end
end
