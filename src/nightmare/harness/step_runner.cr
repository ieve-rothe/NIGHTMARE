# nightmare/harness/step_runner.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"
require "../config"
require "../context/sliding_store"
require "../transcript"
require "./types"
require "./tool_loop"
require "./retrier"
require "./loop_detector"

module Nightmare::Harness
  class StepRunner
    getter client : Mantle::Clients::Client
    getter tools : Array(Mantle::Tools::Tool)
    getter tool_loop : ToolLoop
    getter retrier : Retrier
    property transcript : Transcript?
    property max_iterations : Int32
    property format_retries : Int32
    property overflow_retries : Int32

    def initialize(
      @client : Mantle::Clients::Client,
      @tools : Array(Mantle::Tools::Tool),
      @tool_loop : ToolLoop,
      @retrier : Retrier = Retrier.new,
      @transcript : Transcript? = nil,
      @max_iterations : Int32 = Config::MAX_ITERATIONS,
      @format_retries : Int32 = Config::FORMAT_RETRIES,
      @overflow_retries : Int32 = Config::CONTEXT_OVERFLOW_RETRIES
    )
    end

    # Executes a full conversational turn through Mantle::Step with in-turn shedding and typed boundaries
    def run_turn(
      system_prompt : String? = nil,
      pinned_block : String? = nil,
      &stream_callback : String -> Nil
    ) : TurnOutcome
      @retrier.execute do
        execute_turn_attempt(system_prompt, pinned_block, &stream_callback)
      end
    end

    # Overload for synchronous execution without stream block
    def run_turn(system_prompt : String? = nil, pinned_block : String? = nil) : TurnOutcome
      run_turn(system_prompt, pinned_block) { |_| }
    end

    private def execute_turn_attempt(
      system_prompt : String?,
      pinned_block : String?,
      &stream_callback : String -> Nil
    ) : TurnOutcome
      @tool_loop.reset_turn

      if @tool_loop.cancelled?
        rolled_back = @tool_loop.store.rollback_turn
        effects = rolled_back.try(&.side_effects) || [] of String
        @transcript.try &.record_interruption(effects)
        @tool_loop.cancelled = false

        return TurnOutcome.failure(
          StepError.new(StepErrorKind::Cancelled, "Interrupted by user")
        )
      end

      active = @tool_loop.store.active_turn
      return TurnOutcome.failure(StepError.new(StepErrorKind::ClientFailure, "No active turn in store")) unless active

      # Record user message in transcript
      @transcript.try &.record(active.user_message)

      wrapped_tools = wrap_tools_with_loop_detector(@tools, @tool_loop.loop_detector)
      overflow_retries_remaining = @overflow_retries
      format_retries_remaining = @format_retries

      wrapped_stream = ->(chunk : String) {
        if @tool_loop.cancelled?
          raise CancelledException.new("Turn cancelled by user interrupt")
        end
        stream_callback.call(chunk)
      }

      loop do
        messages = @tool_loop.store.assemble_messages(system_prompt, pinned_block)

        step = Mantle::Step.new(
          client: @client,
          tools: wrapped_tools,
          max_iterations: @max_iterations,
          on_iteration: @tool_loop.on_iteration_hook
        )

        begin
          result = step.run(messages, &wrapped_stream)

          # Check if step error is actually a context length rejection (HTTP 400 / context_length_exceeded)
          if result.err? && context_overflow_error?(result)
            if overflow_retries_remaining > 0
              overflow_retries_remaining -= 1
              # Emergency shed and prune (T11)
              recover_from_context_overflow
              next # retry turn
            else
              return TurnOutcome.failure(
                StepError.new(StepErrorKind::ContextOverflow, "Context length exceeded after emergency shedding"),
                result.thinking,
                result.iterations
              )
            end
          end

          # Check if step error is MalformedOutput -> single format correction turn
          if result.err? && result.error == Mantle::StepError::MalformedOutput
            if format_retries_remaining > 0
              format_retries_remaining -= 1
              if active = @tool_loop.store.active_turn
                active.messages << Mantle::Message.new("user", "The previous response had malformed output or arguments. Please reformat and proceed.")
              end
              next # retry turn with format correction
            end
          end

          return process_step_result(result)
        rescue ex : CancelledException
          # User cancelled turn cooperatively (T12)
          rolled_back = @tool_loop.store.rollback_turn
          effects = rolled_back.try(&.side_effects) || [] of String
          @transcript.try &.record_interruption(effects)
          @tool_loop.cancelled = false

          return TurnOutcome.failure(
            StepError.new(StepErrorKind::Cancelled, ex.message || "Interrupted by user")
          )
        rescue ex : SpendCapExceededException
          return TurnOutcome.failure(
            StepError.new(StepErrorKind::SpendCapExceeded, ex.message || "Spend cap exceeded")
          )
        rescue ex
          err_msg = (ex.message || "").downcase
          if (err_msg.includes?("context") || err_msg.includes?("length")) && overflow_retries_remaining > 0
            overflow_retries_remaining -= 1
            recover_from_context_overflow
            next
          end

          return TurnOutcome.failure(
            StepError.new(StepErrorKind::ClientFailure, "Inference failure: #{ex.message}")
          )
        end
      end
    end

    private def process_step_result(result : Mantle::StepResult(String, Mantle::StepError)) : TurnOutcome
      if result.ok?
        text = result.value.not_nil!

        # Complete active turn if not already completed
        if active = @tool_loop.store.active_turn
          if !active.complete?
            active.append_assistant(Mantle::Message.new("assistant", text))
          end

          # Record remaining assistant/tool messages in transcript before in-turn shedding
          if tr = @transcript
            active.messages[1..].each { |m| tr.record(m) }
          end

          # Check if turn exceeded shed trigger threshold:
          hardmax = @tool_loop.store.hardmax
          trigger_threshold = (hardmax.to_f * @tool_loop.shed_trigger_ratio).to_i
          total_chars = active.messages.sum { |m| (m.content || "").size }
          estimated = if pt = @tool_loop.last_prompt_tokens
            pt + @tool_loop.calibrator.estimate(total_chars)
          else
            @tool_loop.calibrator.estimate(total_chars)
          end

          if estimated > trigger_threshold
            Context::Shedder.shed_active_turn!(
              active,
              current_tokens: estimated,
              hardmax: hardmax,
              trigger_ratio: @tool_loop.shed_trigger_ratio,
              keep_chars: @tool_loop.shed_keep_chars,
              keep_verbatim: @tool_loop.shed_keep_verbatim,
              calibrator: @tool_loop.calibrator
            )
          end

          @tool_loop.store.commit_turn
        end

        TurnOutcome.success(
          value: text,
          thinking: result.thinking,
          iterations: result.iterations,
          prompt_tokens: result.raw_response.try(&.prompt_eval_count)
        )
      else
        error_kind = map_step_error(result.error.not_nil!)
        retryable = error_kind.rate_limited?
        msg = if em = result.error_message
          "Mantle step error: #{result.error} - #{em}"
        else
          "Mantle step error: #{result.error}"
        end

        TurnOutcome.failure(
          error: StepError.new(error_kind, msg, retryable: retryable),
          thinking: result.thinking,
          iterations: result.iterations,
          prompt_tokens: result.raw_response.try(&.prompt_eval_count)
        )
      end
    end

    private def map_step_error(err : Mantle::StepError) : StepErrorKind
      case err
      when Mantle::StepError::MalformedOutput
        StepErrorKind::MalformedOutput
      when Mantle::StepError::MaxIterationsReached
        StepErrorKind::MaxIterationsReached
      when Mantle::StepError::ClientFailure
        StepErrorKind::ClientFailure
      when Mantle::StepError::ToolExecutionFailure
        StepErrorKind::ToolExecutionFailure
      when Mantle::StepError::RateLimited
        StepErrorKind::RateLimited
      else
        StepErrorKind::ClientFailure
      end
    end

    private def context_overflow_error?(result : Mantle::StepResult(String, Mantle::StepError)) : Bool
      return false unless result.err?
      if raw = result.raw_response
        return true if raw.truncated?
      end
      false
    end

    private def recover_from_context_overflow : Nil
      hardmax = @tool_loop.store.hardmax
      current_tokens = hardmax + 1000

      if active = @tool_loop.store.active_turn
        Context::Shedder.shed_active_turn!(
          active,
          current_tokens: current_tokens,
          hardmax: hardmax,
          trigger_ratio: 0.5,
          keep_chars: 50,
          keep_verbatim: 1,
          calibrator: @tool_loop.calibrator
        )
      end

      Context::Shedder.prune_history!(
        @tool_loop.store.history,
        current_tokens: current_tokens,
        hardmax: hardmax,
        calibrator: @tool_loop.calibrator
      )
    end

    private def wrap_tools_with_loop_detector(
      tools : Array(Mantle::Tools::Tool),
      detector : LoopDetector
    ) : Array(Mantle::Tools::Tool)
      tools.map do |tool|
        orig_handler = tool.handler
        wrapped = tool.dup
        wrapped.handler = ->(args : Hash(String, JSON::Any)) {
          tool_name = tool.function.name
          args_json = args.to_json
          refused, msg = detector.check(tool_name, args_json)
          if refused
            puts msg.not_nil!
            STDOUT.flush
            msg.not_nil!
          elsif orig_handler
            begin
              res = orig_handler.call(args)
              puts res
              STDOUT.flush
              res
            rescue ex : SecurityError
              err = "[SecurityError: #{ex.message}]"
              puts err
              STDOUT.flush
              err
            rescue ex
              err = "[Tool error: #{ex.message}]"
              puts err
              STDOUT.flush
              err
            end
          else
            {error: "No handler for #{tool_name}"}.to_json
          end
        }
        wrapped
      end
    end
  end
end
