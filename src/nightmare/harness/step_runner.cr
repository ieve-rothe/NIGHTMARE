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
require "../ui/turn_presenter"

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
    property failures_dir : String
    property turn_presenter : UI::TurnPresenter? = nil

    def initialize(
      @client : Mantle::Clients::Client,
      @tools : Array(Mantle::Tools::Tool),
      @tool_loop : ToolLoop,
      @retrier : Retrier = Retrier.new,
      @transcript : Transcript? = nil,
      @max_iterations : Int32 = Config::MAX_ITERATIONS,
      @format_retries : Int32 = Config::FORMAT_RETRIES,
      @overflow_retries : Int32 = Config::CONTEXT_OVERFLOW_RETRIES,
      @failures_dir : String = ""
    )
    end

    # Executes a full conversational turn through Mantle::Step with in-turn shedding and typed boundaries.
    # Accepts the active SlidingStore directly to prevent subagent/depth-1 state pollution.
    def run_turn(
      store : Context::SlidingStore,
      system_prompt : String? = nil,
      pinned_block : String? = nil,
      skill_block : String? = nil,
      &stream_callback : String -> Nil
    ) : TurnOutcome
      @retrier.execute do
        run_turn_attempt(store, system_prompt, pinned_block, skill_block, &stream_callback)
      end
    end

    # Overload for synchronous execution without stream block
    def run_turn(
      store : Context::SlidingStore,
      system_prompt : String? = nil,
      pinned_block : String? = nil,
      skill_block : String? = nil
    ) : TurnOutcome
      run_turn(store, system_prompt, pinned_block, skill_block) { |_| }
    end

    # Runs a single turn attempt against the provided SlidingStore
    def run_turn_attempt(
      store : Context::SlidingStore,
      system_prompt : String?,
      pinned_block : String?,
      skill_block : String? = nil,
      &stream_callback : String -> Nil
    ) : TurnOutcome
      @tool_loop.reset_turn

      if @tool_loop.cancelled?
        rolled_back = store.rollback_turn
        effects = rolled_back.try(&.side_effects) || [] of String
        @transcript.try &.record_interruption(effects)
        @tool_loop.cancelled = false

        return TurnOutcome.failure(
          StepError.new(StepErrorKind::Cancelled, "Interrupted by user")
        )
      end

      active = store.active_turn
      return TurnOutcome.failure(StepError.new(StepErrorKind::ClientFailure, "No active turn in store")) unless active

      # Record user message in transcript
      @transcript.try &.record(active.user_message)

      overflow_retries_remaining = @overflow_retries
      format_retries_remaining = @format_retries

      wrapped_stream = ->(chunk : String) {
        if @tool_loop.cancelled?
          raise CancelledException.new("Turn cancelled by user interrupt")
        end
        stream_callback.call(chunk)
      }

      loop do
        messages = store.assemble_messages(system_prompt, pinned_block, skill_block)

        on_iter = ->(working_msgs : Array(Mantle::Message), last_res : Mantle::Clients::Response?) {
          if last_res
            if txt = last_res.content
              if presenter = @turn_presenter
                presenter.last_agent_response = txt unless txt.empty?
              end
            end
            if th = last_res.thinking
              if presenter = @turn_presenter
                presenter.agent_thought = th unless th.empty?
              end
            end
          end
          @tool_loop.on_iteration_hook(store).call(working_msgs, last_res)
        }

        step = Mantle::Step.new(
          client: @client,
          tools: @tools,
          max_iterations: @max_iterations,
          on_iteration: on_iter
        )

        begin
          result = step.run(messages, &wrapped_stream)

          # Check if step error is actually a context length rejection (HTTP 400 / context_length_exceeded)
          if result.err? && context_overflow_error?(result)
            if overflow_retries_remaining > 0
              overflow_retries_remaining -= 1
              # Emergency shed and prune (T11)
              recover_from_context_overflow(store)
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
              if act = store.active_turn
                act.messages << Mantle::Message.new("user", "The previous response had malformed output or arguments. Please reformat and proceed.")
              end
              next # retry turn with format correction
            end
          end

          return process_step_result(result, store)
        rescue ex : LoopCircuitBreakerException
          return handle_loop_circuit_breaker(
            store: store,
            tool_name: ex.tool_name,
            args_json: ex.args_json,
            msg: ex.message || "ERR_DEGENERATE_LOOP",
            iterations: 0
          )
        rescue ex : CancelledException
          # User cancelled turn cooperatively (T12)
          rolled_back = store.rollback_turn
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
        rescue ex : Mantle::Clients::APIError
          if ex.context_overflow? && overflow_retries_remaining > 0
            overflow_retries_remaining -= 1
            recover_from_context_overflow(store)
            next
          end

          return TurnOutcome.failure(
            StepError.new(StepErrorKind::ClientFailure, "Inference API error (#{ex.status_code}): #{ex.message}")
          )
        rescue ex : IO::Error
          return TurnOutcome.failure(
            StepError.new(StepErrorKind::ClientFailure, "Network/IO failure: #{ex.message}")
          )
        end
      end
    end

    private def process_step_result(
      result : Mantle::StepResult(String, Mantle::StepError),
      store : Context::SlidingStore
    ) : TurnOutcome
      if @tool_loop.loop_detector.tripped? || (result.error == Mantle::StepError::ToolExecutionFailure && result.error_message.try(&.includes?("ERR_DEGENERATE_LOOP")))
        tool_name = @tool_loop.loop_detector.tripped_tool || "unknown"
        args_json = @tool_loop.loop_detector.tripped_args || ""
        msg = @tool_loop.loop_detector.last_refusal || result.error_message || "ERR_DEGENERATE_LOOP: identical tool call repeated"
        return handle_loop_circuit_breaker(
          store: store,
          tool_name: tool_name,
          args_json: args_json,
          msg: msg,
          thinking: result.thinking,
          iterations: result.iterations,
          prompt_tokens: result.raw_response.try(&.prompt_eval_count)
        )
      end

      if result.ok?
        text = result.value.not_nil!

        # Complete active turn if not already completed
        if active = store.active_turn
          if !active.complete?
            active.append_assistant(Mantle::Message.new("assistant", text))
          end

          # Record remaining assistant/tool messages in transcript before in-turn shedding
          if tr = @transcript
            active.messages[1..].each { |m| tr.record(m) }
          end

          # Check if turn exceeded shed trigger threshold:
          hardmax = store.hardmax
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

          store.commit_turn
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
      if msg = result.error_message
        return true if msg.includes?("context_length_exceeded") || msg.includes?("maximum context length")
      end
      false
    end

    private def recover_from_context_overflow(store : Context::SlidingStore) : Nil
      hardmax = store.hardmax
      current_tokens = hardmax + 1000

      if active = store.active_turn
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
        store.history,
        current_tokens: current_tokens,
        hardmax: hardmax,
        calibrator: @tool_loop.calibrator
      )
    end

    private def handle_loop_circuit_breaker(
      store : Context::SlidingStore,
      tool_name : String,
      args_json : String,
      msg : String,
      thinking : String? = nil,
      iterations : Int32 = 0,
      prompt_tokens : Int32? = nil
    ) : TurnOutcome
      dump_failure_report(store, tool_name, args_json, msg, iterations, prompt_tokens)

      TurnOutcome.failure(
        StepError.new(StepErrorKind::DegenerateLoopCircuitBreaker, msg, retryable: false),
        thinking: thinking,
        iterations: iterations,
        prompt_tokens: prompt_tokens
      )
    end

    private def dump_failure_report(
      store : Context::SlidingStore,
      tool_name : String,
      args_json : String,
      msg : String,
      iterations : Int32,
      prompt_tokens : Int32?
    ) : Nil
      begin
        Dir.mkdir_p(@failures_dir)
        now = Time.utc
        timestamp_slug = now.to_s("%Y%m%d_%H%M%S_%L")
        seq_id = Random::Secure.hex(4)
        filename = "failure_#{timestamp_slug}_#{seq_id}.json"
        path = File.join(@failures_dir, filename)

        active = store.active_turn
        history_msgs = active.try(&.messages) || [] of Mantle::Message
        serialized_messages = history_msgs.map do |m|
          {
            "role" => m.role,
            "content" => m.content,
            "tool_calls" => m.tool_calls.try(&.map { |tc| {"id" => tc.id, "name" => tc.function.name, "arguments" => tc.function.arguments} })
          }
        end

        parsed_args = begin
          JSON.parse(args_json)
        rescue
          JSON::Any.new(args_json)
        end

        report = {
          "timestamp" => now.to_rfc3339,
          "error_code" => "ERR_DEGENERATE_LOOP",
          "message" => msg,
          "offending_tool" => tool_name,
          "arguments" => parsed_args,
          "messages" => serialized_messages,
          "token_metrics" => {
            "iterations" => iterations,
            "prompt_tokens" => prompt_tokens,
            "cumulative_spend" => @tool_loop.cumulative_spend,
            "spend_cap" => @tool_loop.spend_cap
          }
        }

        File.write(path, report.to_pretty_json)
      rescue
        # Failure dump must not crash the shutdown sequence
      end
    end
  end
end
