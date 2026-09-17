# nightmare/harness/types.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "../exceptions"

module Nightmare::Harness
  enum StepErrorKind
    MaxIterationsReached   # iteration cap hit (§7 MAX_ITERATIONS)
    RateLimited            # provider 429; Retrier applies backoff+jitter
    ClientFailure          # transport / API failure
    MalformedOutput        # unparseable or empty completion
    ToolExecutionFailure   # tool handler raised a terminal error
    ExecutionTimeout       # tool/subprocess exceeded its timeout
    Cancelled              # user interrupt; a first-class outcome, not a failure
    ContextOverflow        # provider rejected request for length
    SpendCapExceeded       # per-turn token/cost cap hit (§7)
    DegenerateLoopCircuitBreaker # repeated identical tool calls breached threshold (circuit breaker)
  end

  record StepError,
    kind : StepErrorKind,
    message : String,
    retryable : Bool = false do
    def cancelled? : Bool
      kind.cancelled?
    end
  end

  class StepOutcome(T)
    getter value : T?
    getter error : StepError?
    getter thinking : String?
    getter iterations : Int32
    getter prompt_tokens : Int32?   # from Response#prompt_eval_count

    def initialize(
      @value : T? = nil,
      @error : StepError? = nil,
      @thinking : String? = nil,
      @iterations : Int32 = 0,
      @prompt_tokens : Int32? = nil
    )
    end

    def self.success(value : T, thinking : String? = nil, iterations : Int32 = 0, prompt_tokens : Int32? = nil) : StepOutcome(T)
      new(value: value, thinking: thinking, iterations: iterations, prompt_tokens: prompt_tokens)
    end

    def self.failure(error : StepError, thinking : String? = nil, iterations : Int32 = 0, prompt_tokens : Int32? = nil) : StepOutcome(T)
      new(error: error, thinking: thinking, iterations: iterations, prompt_tokens: prompt_tokens)
    end

    def ok? : Bool
      @error.nil?
    end

    def err? : Bool
      !@error.nil?
    end

    def cancelled? : Bool
      @error.try(&.kind.cancelled?) || false
    end

    def unwrap : T
      if err = @error
        raise Nightmare::Error.new("Unwrap failed: #{err.message} (#{err.kind})")
      else
        @value.not_nil!
      end
    end
  end

  alias TurnOutcome = StepOutcome(String)
end
