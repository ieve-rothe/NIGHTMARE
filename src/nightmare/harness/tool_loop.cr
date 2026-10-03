# nightmare/harness/tool_loop.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"

module Nightmare::Harness
  alias CancelledException = Mantle::Steps::CancelledException
  alias SpendCapExceededException = Mantle::Steps::SpendCapExceededException
  alias ContextOverflowException = Mantle::Steps::ContextOverflowException
  alias LoopCircuitBreakerException = Mantle::Tools::LoopCircuitBreakerException
  alias ToolLoop = Mantle::Steps::ToolLoop
end
