# nightmare/harness/retrier.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "../config"
require "./types"

module Nightmare::Harness
  class Retrier
    getter max_retries : Int32
    getter base_delay : Float64

    def initialize(@max_retries : Int32 = Config::RATE_LIMIT_RETRIES, @base_delay : Float64 = 0.5)
    end

    # Executes block with exponential backoff and jitter for retryable rate-limited errors
    def execute(&block : -> StepOutcome(T)) : StepOutcome(T) forall T
      attempts = 0

      loop do
        outcome = block.call
        return outcome if outcome.ok? || outcome.cancelled?

        err = outcome.error.not_nil!
        if err.kind.rate_limited? && attempts < @max_retries
          attempts += 1
          # exponential backoff with random jitter: base * 2^(attempts - 1) + jitter
          jitter = Random.rand * 0.2
          delay = (@base_delay * (2.0 ** (attempts - 1))) + jitter
          sleep delay.seconds
          next
        end

        return outcome
      end
    end
  end
end
