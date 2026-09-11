# nightmare/tools/delegation.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"

module Nightmare::Tools
  class Delegation
    getter client : Mantle::Clients::Client

    def initialize(@client : Mantle::Clients::Client)
    end

    # Executes stateless one-shot model delegation without history contamination
    def ask_model(prompt : String) : String
      step = Mantle::Step.new(
        client: @client,
        tools: [] of Mantle::Tools::Tool,
        max_iterations: 1,
        on_iteration: nil # strictly no iteration hook for delegation
      )

      messages = [Mantle::Message.new("user", prompt)]
      result = step.run(messages)

      if result.ok?
        result.unwrap
      else
        "[Model delegation error: #{result.error}]"
      end
    rescue ex
      "[Model delegation exception: #{ex.message}]"
    end
  end
end
