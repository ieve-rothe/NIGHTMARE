# nightmare/harness/loop_detector.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"

module Nightmare::Harness
  alias LoopDetector = Mantle::Tools::Middleware::LoopBreaker
end
