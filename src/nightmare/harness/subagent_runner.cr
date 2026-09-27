# nightmare/harness/subagent_runner.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"
require "../plan/models"
require "../plan/run_state"
require "../plan/orchestrator"
require "../plan/pacer"
require "../workspace/environment"
require "../tools/registry"
require "../tools/guard"
require "../tools/shell"
require "../tools/mutation"
require "../tools/read_only"
require "../tools/middleware"
require "../ui/cancellation"
require "../context/sliding_store"
require "../context/token_calibrator"
require "../context/shedder"
require "./loop_detector"
require "./types"
require "./tool_loop"

module Nightmare::Harness
  class SubagentRunner < Nightmare::Plan::SubagentDispatcher
    getter client : Mantle::Clients::Client
    getter environment : Nightmare::Workspace::Environment
    getter pacer : Nightmare::Plan::Pacer?
    getter diff_approval : Proc(String, String, Bool)?
    getter shell_approval : Proc(String, Array(String), Bool, Int32, Tuple(Nightmare::Tools::ApprovalOutcome, String?))?
    property turn_presenter : Nightmare::UI::TurnPresenter?
    property cancellation_check : Proc(Bool)?

    def initialize(
      @client : Mantle::Clients::Client,
      @environment : Nightmare::Workspace::Environment,
      @pacer : Nightmare::Plan::Pacer? = nil,
      @diff_approval : Proc(String, String, Bool)? = nil,
      @shell_approval : Proc(String, Array(String), Bool, Int32, Tuple(Nightmare::Tools::ApprovalOutcome, String?))? = nil,
      @turn_presenter : Nightmare::UI::TurnPresenter? = nil,
      @cancellation_check : Proc(Bool)? = nil
    )
    end

    def cancelled? : Bool
      if check = @cancellation_check
        return true if check.call
      end
      UI::Cancellation.cancelled?
    end

    def dispatch(
      item : Nightmare::Plan::PlanItem,
      run : Nightmare::Plan::PlanRun,
      worktree_path : String
    ) : NamedTuple(
      status: String,
      summary: String,
      files_touched: Array(String),
      tool_calls_count: Int32,
      shell_commands: Array(Nightmare::Plan::ExecutedCommand),
      proposed_items: Array(Nightmare::Plan::ProposedItem),
      proposed_targets: Array(String),
      tokens_used: Int32
    )
      # Setup isolated worktree environment
      worktree_env = Nightmare::Workspace::Environment.new(
        root_path: worktree_path,
        xdg_config_home: @environment.xdg_config_home,
        xdg_state_home: @environment.xdg_state_home,
        xdg_cache_home: @environment.xdg_cache_home,
        ensure_dirs: false
      )

      # Create Guard enforcing files_targeted
      guard = Nightmare::Tools::Guard.new(worktree_env, item.files_targeted)

      # Side effects tracker for files touched
      files_touched = [] of String

      diff_approval = ->(_diff : String, _desc : String) { true }
      shell_approval = ->(_cmd : String, _argv : Array(String), _metachar : Bool, _timeout : Int32) {
        {Nightmare::Tools::ApprovalOutcome::Yes, nil.as(String?)}
      }

      loop_detector = Nightmare::Harness::LoopDetector.new(threshold: @environment.settings.loop_detect_threshold)
      registry = Nightmare::Tools::Registry.new(
        guard: guard,
        client: @client,
        diff_approval: diff_approval,
        shell_approval: shell_approval,
        default_command_timeout: @environment.settings.command_timeout_seconds,
        max_command_timeout: @environment.settings.max_command_timeout_seconds,
        tool_output_max_bytes: @environment.settings.tool_output_max_bytes
      )
      registry.middlewares = [
        ToolMiddleware::LoopDetector.new(loop_detector),
        ToolMiddleware::ExceptionTrapping.new,
      ] of ToolMiddleware::Base
      registry.set_active_side_effects(files_touched)
      registry.shell.subagent_mode = true

      subagent_tools = registry.build_subagent_tools

      executed_tool_results = [] of Tuple(String, Hash(String, JSON::Any), String)
      wrapped_subagent_tools = subagent_tools.map do |tool|
        orig_handler = tool.handler
        wrapped = tool.dup
        wrapped.handler = ->(args : Hash(String, JSON::Any)) {
          if cancelled?
            raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
          end
          tool_name = tool.function.name
          res = orig_handler ? orig_handler.call(args) : ""
          executed_tool_results << {tool_name, args, res}
          if cancelled?
            raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
          end
          res
        }
        wrapped
      end

      # Build prompt
      system_prompt = build_system_prompt(item, worktree_path)
      user_prompt = build_user_prompt(item)

      store = Nightmare::Context::SlidingStore.new(hardmax: @environment.settings.token_hardmax)
      store.start_turn(Mantle::Message.new("user", user_prompt))
      calibrator = Nightmare::Context::TokenEstimator.new(divisor: @environment.settings.initial_divisor)
      tool_loop = Nightmare::Harness::ToolLoop.new(
        store: store,
        calibrator: calibrator,
        loop_detector: loop_detector,
        spend_cap: @environment.settings.turn_spend_cap_tokens,
        shed_trigger_ratio: @environment.settings.shed_trigger_ratio,
        shed_keep_chars: @environment.settings.shed_keep_chars,
        shed_keep_verbatim: @environment.settings.shed_keep_verbatim
      )

      tool_calls_count = 0
      last_thinking : String? = nil
      on_iteration = ->(working_msgs : Array(Mantle::Message), last_res : Mantle::Clients::Response?) {
        if cancelled?
          raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
        end
        if last_res
          if calls = last_res.tool_calls
            tool_calls_count += calls.size
          end
          if th = last_res.thinking
            last_thinking = th
          end
          if p = @pacer
            p.pace_turn
          end
        end
        tool_loop.on_iteration_hook(store).call(working_msgs, last_res)
      }

      max_iterations = item.budget_iterations || @environment.settings.subagent_max_iterations
      overflow_retries_remaining = @environment.settings.context_overflow_retries

      tokens_used = 0
      summary = ""
      status = "completed"
      proposed_items = [] of Nightmare::Plan::ProposedItem
      proposed_targets = [] of String

      loop do
        messages = store.assemble_messages(system_prompt)
        step = Mantle::Step.new(
          client: @client,
          tools: wrapped_subagent_tools,
          max_iterations: max_iterations,
          on_iteration: on_iteration
        )

        begin
          result = step.run(messages) do |_chunk|
            if cancelled?
              raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
            end
          end

          if cancelled? || (result.err? && result.error_message.try(&.includes?("Turn cancelled by user interrupt")))
            raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
          end

          if resp = result.raw_response
            tokens_used = (resp.prompt_eval_count || 0) + (resp.eval_count || 0)
          end
          if tool_loop.cumulative_spend > 0
            tokens_used += tool_loop.cumulative_spend
          end

          # Check for context overflow error
          if result.err? && context_overflow_error?(result)
            if overflow_retries_remaining > 0
              overflow_retries_remaining -= 1
              recover_from_context_overflow(store, calibrator)
              next
            else
              status = "failed"
              summary = conduct_subagent_exit_interview(
                reason: "Context length exceeded after emergency shedding",
                store: store,
                calibrator: calibrator,
                files_touched: files_touched,
                tool_calls_count: tool_calls_count,
                last_thinking: last_thinking,
                allow_llm: false,
                raw_response: result.raw_response,
                executed_tool_results: executed_tool_results
              )
              break
            end
          end

          # Check for loop circuit breaker trip
          if loop_detector.tripped? || (result.error == Mantle::StepError::ToolExecutionFailure && result.error_message.try(&.includes?("ERR_DEGENERATE_LOOP")))
            status = "failed"
            summary = conduct_subagent_exit_interview(
              reason: "Subagent loop circuit breaker tripped: #{loop_detector.last_refusal || result.error_message || "ERR_DEGENERATE_LOOP"}",
              store: store,
              calibrator: calibrator,
              files_touched: files_touched,
              tool_calls_count: tool_calls_count,
              last_thinking: last_thinking || result.thinking,
              allow_llm: true,
              raw_response: result.raw_response,
              executed_tool_results: executed_tool_results
            )
            break
          end

          if result.ok?
            raw_response = result.unwrap
            summary, proposed_items, proposed_targets = parse_subagent_output(raw_response, item.id)
          else
            status = "failed"
            summary = conduct_subagent_exit_interview(
              reason: "Subagent error: #{result.error}",
              store: store,
              calibrator: calibrator,
              files_touched: files_touched,
              tool_calls_count: tool_calls_count,
              last_thinking: last_thinking || result.thinking,
              allow_llm: (result.error == Mantle::StepError::MaxIterationsReached),
              raw_response: result.raw_response,
              executed_tool_results: executed_tool_results
            )
          end
          break
        rescue ex : CancelledException
          raise ex
        rescue ex : SpendCapExceededException
          status = "failed"
          summary = conduct_subagent_exit_interview(
            reason: "Subagent spend cap exceeded: #{ex.message}",
            store: store,
            calibrator: calibrator,
            files_touched: files_touched,
            tool_calls_count: tool_calls_count,
            last_thinking: last_thinking,
            allow_llm: false,
            executed_tool_results: executed_tool_results
          )
          break
        rescue ex : Mantle::Clients::APIError
          if ex.context_overflow? && overflow_retries_remaining > 0
            overflow_retries_remaining -= 1
            recover_from_context_overflow(store, calibrator)
            next
          end
          status = "failed"
          summary = conduct_subagent_exit_interview(
            reason: "Subagent exception: #{ex.message}",
            store: store,
            calibrator: calibrator,
            files_touched: files_touched,
            tool_calls_count: tool_calls_count,
            last_thinking: last_thinking,
            allow_llm: false,
            executed_tool_results: executed_tool_results
          )
          break
        rescue ex
          status = "failed"
          summary = conduct_subagent_exit_interview(
            reason: "Subagent exception: #{ex.message}",
            store: store,
            calibrator: calibrator,
            files_touched: files_touched,
            tool_calls_count: tool_calls_count,
            last_thinking: last_thinking,
            allow_llm: false,
            executed_tool_results: executed_tool_results
          )
          break
        end
      end

      {
        status: status,
        summary: summary,
        files_touched: files_touched.uniq,
        tool_calls_count: tool_calls_count,
        shell_commands: registry.shell.executed_commands,
        proposed_items: proposed_items,
        proposed_targets: proposed_targets,
        tokens_used: tokens_used,
      }
    end

    # Executes an autonomous subagent for a single-turn delegation in the current workspace environment.
    # Uses build_subagent_tools to ensure subagents have file/shell tools but cannot recursively spawn subagents.
    def run_subagent(
      task : String,
      files_targeted : Array(String) = [] of String,
      budget_iterations : Int32? = nil
    ) : String
      guard = Nightmare::Tools::Guard.new(@environment, files_targeted)
      files_touched = [] of String

      active_diff_approval = @diff_approval || ->(_diff : String, _desc : String) { true }
      active_shell_approval = @shell_approval || ->(_cmd : String, _argv : Array(String), _meta : Bool, _to : Int32) {
        {Nightmare::Tools::ApprovalOutcome::Yes, nil.as(String?)}
      }

      loop_detector = Nightmare::Harness::LoopDetector.new(threshold: @environment.settings.loop_detect_threshold)
      registry = Nightmare::Tools::Registry.new(
        guard: guard,
        client: @client,
        diff_approval: active_diff_approval,
        shell_approval: active_shell_approval,
        default_command_timeout: @environment.settings.command_timeout_seconds,
        max_command_timeout: @environment.settings.max_command_timeout_seconds,
        tool_output_max_bytes: @environment.settings.tool_output_max_bytes
      )
      registry.middlewares = [
        ToolMiddleware::LoopDetector.new(loop_detector),
        ToolMiddleware::ExceptionTrapping.new,
      ] of ToolMiddleware::Base
      registry.set_active_side_effects(files_touched)
      registry.shell.subagent_mode = true

      subagent_tools = registry.build_subagent_tools

      system_prompt = build_workspace_system_prompt(files_targeted)
      user_prompt = "Task:\n#{task}\n\nExecute the task now."

      store = Nightmare::Context::SlidingStore.new(hardmax: @environment.settings.token_hardmax)
      store.start_turn(Mantle::Message.new("user", user_prompt))
      calibrator = Nightmare::Context::TokenEstimator.new(divisor: @environment.settings.initial_divisor)
      tool_loop = Nightmare::Harness::ToolLoop.new(
        store: store,
        calibrator: calibrator,
        loop_detector: loop_detector,
        spend_cap: @environment.settings.turn_spend_cap_tokens,
        shed_trigger_ratio: @environment.settings.shed_trigger_ratio,
        shed_keep_chars: @environment.settings.shed_keep_chars,
        shed_keep_verbatim: @environment.settings.shed_keep_verbatim
      )

      max_iterations = budget_iterations || @environment.settings.subagent_max_iterations
      telemetry = Nightmare::UI::SubagentTelemetry.new(
        task: task,
        max_iterations: max_iterations
      )
      tp = @turn_presenter
      if tp
        tp.active_subagent = telemetry
        tp.render_dashboard(action_label: "Subagent spawned")
      end

      executed_tool_results = [] of Tuple(String, Hash(String, JSON::Any), String)
      wrapped_subagent_tools = subagent_tools.map do |tool|
        orig_handler = tool.handler
        wrapped = tool.dup
        wrapped.handler = ->(args : Hash(String, JSON::Any)) {
          if cancelled?
            raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
          end

          tool_name = tool.function.name
          args_summary = args.map { |k, v| "#{k}: #{v}" }.join(", ")
          telemetry.active_tool = "#{tool_name}(#{args_summary})"
          telemetry.tool_calls_count += 1
          telemetry.files_touched = files_touched.dup

          res = orig_handler ? orig_handler.call(args) : ""
          executed_tool_results << {tool_name, args, res}
          if tp
            tp.present_tool_result(tool_name, args, res)
          end

          if cancelled?
            raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
          end
          res
        }
        wrapped
      end

      tool_calls_count = 0
      last_thinking : String? = nil
      on_iteration = ->(working_msgs : Array(Mantle::Message), last_res : Mantle::Clients::Response?) {
        if cancelled?
          raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
        end
        if last_res
          if calls = last_res.tool_calls
            tool_calls_count += calls.size
            telemetry.tool_calls_count = tool_calls_count
          end
          if th = last_res.thinking
            telemetry.last_thought = th
            last_thinking = th
          end
          telemetry.iteration += 1
          telemetry.files_touched = files_touched.dup
          if tp
            tp.render_dashboard(action_label: "Subagent step #{telemetry.iteration}")
          end
          if p = @pacer
            p.pace_turn
          end
        end
        tool_loop.on_iteration_hook(store).call(working_msgs, last_res)
      }

      overflow_retries_remaining = @environment.settings.context_overflow_retries

      begin
        loop do
          messages = store.assemble_messages(system_prompt)
          step = Mantle::Step.new(
            client: @client,
            tools: wrapped_subagent_tools,
            max_iterations: max_iterations,
            on_iteration: on_iteration
          )

          result = step.run(messages) do |_chunk|
            if cancelled?
              raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
            end
          end

          if cancelled? || (result.err? && result.error_message.try(&.includes?("Turn cancelled by user interrupt")))
            raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
          end

          # Check for context overflow error
          if result.err? && context_overflow_error?(result)
            if overflow_retries_remaining > 0
              overflow_retries_remaining -= 1
              recover_from_context_overflow(store, calibrator)
              next
            else
              return conduct_subagent_exit_interview(
                reason: "Context length exceeded after emergency shedding",
                store: store,
                calibrator: calibrator,
                files_touched: files_touched,
                tool_calls_count: tool_calls_count,
                last_thinking: last_thinking,
                allow_llm: false,
                raw_response: result.raw_response,
                executed_tool_results: executed_tool_results
              )
            end
          end

          # Check for loop circuit breaker trip
          if loop_detector.tripped? || (result.error == Mantle::StepError::ToolExecutionFailure && result.error_message.try(&.includes?("ERR_DEGENERATE_LOOP")))
            return conduct_subagent_exit_interview(
              reason: "Subagent loop circuit breaker tripped: #{loop_detector.last_refusal || result.error_message || "ERR_DEGENERATE_LOOP"}",
              store: store,
              calibrator: calibrator,
              files_touched: files_touched,
              tool_calls_count: tool_calls_count,
              last_thinking: last_thinking || result.thinking,
              allow_llm: true,
              raw_response: result.raw_response,
              executed_tool_results: executed_tool_results
            )
          end

          if result.ok?
            raw_response = result.unwrap
            summary, _proposed_items, _proposed_targets = parse_subagent_output(raw_response, "subagent")
            return String.build do |io|
              io << "[Subagent completed - " << tool_calls_count << " tool call" << (tool_calls_count == 1 ? "" : "s")
              unless files_touched.empty?
                io << ", files modified: " << files_touched.uniq.join(", ")
              end
              io << "]\n\n"
              io << summary
            end
          else
            return conduct_subagent_exit_interview(
              reason: "Subagent error: #{result.error}",
              store: store,
              calibrator: calibrator,
              files_touched: files_touched,
              tool_calls_count: tool_calls_count,
              last_thinking: last_thinking || result.thinking,
              allow_llm: (result.error == Mantle::StepError::MaxIterationsReached),
              raw_response: result.raw_response,
              executed_tool_results: executed_tool_results
            )
          end
        end
      rescue ex : CancelledException
        raise ex
      rescue ex : SpendCapExceededException
        conduct_subagent_exit_interview(
          reason: "Subagent spend cap exceeded: #{ex.message}",
          store: store,
          calibrator: calibrator,
          files_touched: files_touched,
          tool_calls_count: tool_calls_count,
          last_thinking: last_thinking,
          allow_llm: false,
          executed_tool_results: executed_tool_results
        )
      rescue ex : Mantle::Clients::APIError
        conduct_subagent_exit_interview(
          reason: "Subagent API error: #{ex.message}",
          store: store,
          calibrator: calibrator,
          files_touched: files_touched,
          tool_calls_count: tool_calls_count,
          last_thinking: last_thinking,
          allow_llm: false,
          executed_tool_results: executed_tool_results
        )
      rescue ex
        conduct_subagent_exit_interview(
          reason: "Subagent exception: #{ex.message}",
          store: store,
          calibrator: calibrator,
          files_touched: files_touched,
          tool_calls_count: tool_calls_count,
          last_thinking: last_thinking,
          allow_llm: false,
          executed_tool_results: executed_tool_results
        )
      ensure
        if tp
          tp.active_subagent = nil
        end
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

    private def recover_from_context_overflow(store : Context::SlidingStore, calibrator : Context::TokenEstimator) : Nil
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
          calibrator: calibrator
        )
      end
    end

    private def build_workspace_system_prompt(files_targeted : Array(String)) : String
      String.build do |io|
        io << "You are an autonomous subagent executing a specific subtask in " << @environment.root << ".\n"
        if files_targeted.empty?
          io << "Target Files: Any permitted within workspace\n"
        else
          io << "Target Files (Strictly bounded): " << files_targeted.join(", ") << "\n"
        end
        io << "\nCONSTRAINTS & RULES:\n"
        io << "1. Execute the subtask thoroughly using your available tools.\n"
        io << "2. NEVER run git commit, git checkout, git reset, git merge, git push, or other git mutation commands.\n"
        io << "3. You are restricted to modifying files within your target file bounds if specified.\n"
        io << "4. When complete, provide a final response summarizing what you inspected, changed, or discovered.\n"
        io << "5. DO NOT read files to 'understand the whole system' or 'explore the architecture'. You have a strict token limit. Target ONLY the specific lines/files relevant to your task.\n"
        io << "6. If your task is a research question, inspect only the minimum necessary files, extract the exact answer, and report it concisely.\n"
      end
    end

    private def build_system_prompt(item : Nightmare::Plan::PlanItem, worktree_path : String) : String
      String.build do |io|
        io << "You are an autonomous leaf worker executing a specific task in an isolated Git worktree.\n"
        io << "Worktree Directory: " << worktree_path << "\n"
        io << "Plan Item ID: " << item.id << "\n"
        io << "Title: " << item.title << "\n"
        if pr = item.prompt
          io << "Prompt: " << pr << "\n"
        end
        if item.files_targeted.empty?
          io << "Target Files: Any permitted within workspace\n"
        else
          io << "Target Files (Strictly bounded): " << item.files_targeted.join(", ") << "\n"
        end
        io << "\nCONSTRAINTS & RULES:\n"
        io << "1. You are working in an isolated Git worktree. Work product is gated and committed by the programmatic orchestrator.\n"
        io << "2. NEVER run git commit, git checkout, git reset, git merge, git push, or other git mutation commands. The orchestrator manages all git checkpoints and rollbacks.\n"
        io << "3. You are restricted to modifying files within your target file bounds. Any attempt to write outside these bounds will be rejected.\n"
        io << "4. When your task is complete, produce a final response describing your changes.\n"
        io << "If you discovered new work items or new target files that should be tackled in subsequent items, include them formatted as:\n"
        io << "[SUMMARY]\n<concise summary of changes>\n"
        io << "[PROPOSED_ITEMS]\n- Title of proposed item\n"
        io << "[PROPOSED_TARGETS]\n- path/to/additional/file.cr\n"
      end
    end

    private def build_user_prompt(item : Nightmare::Plan::PlanItem) : String
      String.build do |io|
        io << "Task: " << item.title << "\n\n"
        if pr = item.prompt
          io << "Instructions:\n" << pr << "\n\n"
        end
        io << "Execute the task now."
      end
    end

    private def parse_subagent_output(
      output : String,
      parent_id : String
    ) : Tuple(String, Array(Nightmare::Plan::ProposedItem), Array(String))
      summary = output
      proposed_items = [] of Nightmare::Plan::ProposedItem
      proposed_targets = [] of String

      if output.includes?("[SUMMARY]")
        parts = output.split("[SUMMARY]")
        after_summary = parts[1]? || ""

        if after_summary.includes?("[PROPOSED_ITEMS]")
          summary_part, rest = after_summary.split("[PROPOSED_ITEMS]", 2)
          summary = summary_part.strip

          if rest.includes?("[PROPOSED_TARGETS]")
            items_part, targets_part = rest.split("[PROPOSED_TARGETS]", 2)
            parse_proposed_items(items_part, parent_id, proposed_items)
            parse_proposed_targets(targets_part, proposed_targets)
          else
            parse_proposed_items(rest, parent_id, proposed_items)
          end
        elsif after_summary.includes?("[PROPOSED_TARGETS]")
          summary_part, targets_part = after_summary.split("[PROPOSED_TARGETS]", 2)
          summary = summary_part.strip
          parse_proposed_targets(targets_part, proposed_targets)
        else
          summary = after_summary.strip
        end
      end

      {summary, proposed_items, proposed_targets}
    end

    private def parse_proposed_items(
      text : String,
      parent_id : String,
      result : Array(Nightmare::Plan::ProposedItem)
    ) : Nil
      text.each_line do |line|
        trimmed = line.strip.lstrip('-').lstrip('*').strip
        next if trimmed.empty?
        result << Nightmare::Plan::ProposedItem.new(title: trimmed)
      end
    end

    private def parse_proposed_targets(
      text : String,
      result : Array(String)
    ) : Nil
      text.each_line do |line|
        trimmed = line.strip.lstrip('-').lstrip('*').strip
        next if trimmed.empty?
        result << trimmed
      end
    end

    private def conduct_subagent_exit_interview(
      reason : String,
      store : Context::SlidingStore,
      calibrator : Context::TokenEstimator,
      files_touched : Array(String),
      tool_calls_count : Int32,
      last_thinking : String? = nil,
      allow_llm : Bool = true,
      raw_response : Mantle::Clients::Response? = nil,
      executed_tool_results : Array(Tuple(String, Hash(String, JSON::Any), String)) = [] of Tuple(String, Hash(String, JSON::Any), String)
    ) : String
      active = store.active_turn
      return "[Subagent error: #{reason}]" unless active

      sync_last_iteration(active, raw_response, executed_tool_results)
      effective_tool_calls_count = Math.max(tool_calls_count, executed_tool_results.size)

      files_inspected = Set(String).new
      commands_run = [] of String
      last_action : String? = nil
      last_thought : String? = last_thinking

      executed_tool_results.each do |record|
        t_name, t_args, _ = record
        args_summary = t_args.map { |k, v| "#{k}: #{v}" }.join(", ")
        last_action = "#{t_name}(#{args_summary})"
        if t_name == "read_file" || t_name == "file_info" || t_name == "replace_in_file" || t_name == "append_to_file"
          if p = t_args["path"]?.try(&.as_s?) || t_args["file"]?.try(&.as_s?)
            files_inspected << p
          end
        elsif t_name == "run_command"
          if cmd = t_args["command"]?.try(&.as_s?)
            commands_run << cmd
          end
        end
      end

      active.messages.each do |msg|
        if tcs = msg.tool_calls
          tcs.each do |tc|
            fn_name = tc.function.name
            args_str = tc.function.arguments
            last_action ||= "#{fn_name}(#{args_str})"
            begin
              if parsed = JSON.parse(args_str).as_h?
                if p = parsed["path"]?.try(&.as_s?) || parsed["file"]?.try(&.as_s?)
                  files_inspected << p
                end
                if cmd = parsed["command"]?.try(&.as_s?)
                  commands_run << cmd
                end
              end
            rescue
            end
          end
        elsif msg.role == "assistant" && (cnt = msg.content)
          last_thought ||= cnt unless cnt.empty?
        end
      end

      # Seal any unclosed tool calls to prevent API 400 errors
      seal_open_tool_calls(active, reason)

      if allow_llm && @environment.settings.subagent_exit_interview
        begin
          # Check context headroom: emergency shed if close to hardmax
          hardmax = store.hardmax
          total_chars = active.messages.sum { |m| (m.content || "").size }
          estimated = calibrator.estimate(total_chars)
          if estimated > (hardmax.to_f * 0.75).to_i
            Context::Shedder.shed_active_turn!(
              active,
              current_tokens: estimated,
              hardmax: hardmax,
              trigger_ratio: 0.5,
              keep_chars: 50,
              keep_verbatim: 1,
              calibrator: calibrator
            )
          end

          interview_prompt = String.build do |io|
            io << "[SUPERVISOR INTERVENTION - PENCILS DOWN]\n"
            io << "Your execution budget has ended (" << reason << "). Do NOT attempt to invoke any tools.\n"
            io << "Provide an immediate Exit Summary for the parent agent:\n"
            io << "1. Progress & Discoveries: What key facts, files, or answers did you find?\n"
            io << "2. Actions Taken: Which files or lines did you inspect or edit?\n"
            io << "3. Blockers & Unfinished Work: Where did you get stuck or run out of turns?\n"
            io << "4. Recommendation: What concrete next step should the parent agent take?"
          end

          interview_messages = active.messages.dup
          interview_messages << Mantle::Message.new("user", interview_prompt)

          interview_res = @client.execute(interview_messages, tools: nil)
          if content = interview_res.content
            clean_content = content.strip
            unless clean_content.empty?
              return String.build do |io|
                io << format_subagent_header(reason, effective_tool_calls_count, files_touched) << "\n\n"
                unless files_inspected.empty?
                  io << "Files inspected: " << files_inspected.join(", ") << "\n"
                end
                if last_action
                  io << "Last action: " << last_action << "\n"
                end
                io << "\n### Subagent Exit Report:\n" << clean_content
              end
            end
          end
        rescue ex
          # If LLM interview fails (API error, timeout, etc.), fall through to deterministic post-mortem
        end
      end

      build_deterministic_post_mortem(
        reason: reason,
        files_inspected: files_inspected.to_a,
        files_touched: files_touched,
        commands_run: commands_run,
        tool_calls_count: effective_tool_calls_count,
        last_action: last_action,
        last_thought: last_thought
      )
    end

    private def sync_last_iteration(
      active : Context::Turn,
      raw_response : Mantle::Clients::Response?,
      executed_tool_results : Array(Tuple(String, Hash(String, JSON::Any), String))
    ) : Nil
      return unless resp = raw_response
      return unless tcs = resp.tool_calls
      return if tcs.empty?

      already_synced = active.messages.reverse.any? do |m|
        m.role == "assistant" && m.tool_calls.try(&.any? { |tc| tcs.any? { |target| target.id == tc.id } })
      end

      unless already_synced
        active.append_assistant(Mantle::Message.new(
          role: "assistant",
          content: resp.content,
          tool_calls: tcs
        ))
      end

      tcs.each do |tc|
        already_has_tool_msg = active.messages.any? { |m| m.role == "tool" && m.tool_call_id == tc.id }
        next if already_has_tool_msg

        matching_idx = executed_tool_results.rindex { |record| record[0] == tc.function.name }
        tool_content = if matching_idx
          executed_tool_results[matching_idx][2]
        else
          %({"error":"Execution halted before tool response","refused":true})
        end

        active.messages << Mantle::Message.new(
          role: "tool",
          content: tool_content,
          tool_call_id: tc.id
        )
      end
    end

    private def seal_open_tool_calls(active : Context::Turn, reason : String) : Nil
      open_calls = Set(String).new
      active.messages.each_with_index do |m, idx|
        next if idx == 0
        if m.role == "assistant"
          if tcs = m.tool_calls
            tcs.each { |tc| open_calls.add(tc.id) }
          end
        elsif m.role == "tool"
          if tid = m.tool_call_id
            open_calls.delete(tid)
          end
        end
      end

      open_calls.each do |unclosed_id|
        active.messages << Mantle::Message.new(
          role: "tool",
          content: %({"error":"Execution halted before tool response: #{reason}","refused":true}),
          tool_call_id: unclosed_id
        )
      end
    end

    private def format_subagent_header(reason : String, tool_calls_count : Int32, files_touched : Array(String)) : String
      prefix = if reason.starts_with?("Subagent loop circuit breaker tripped:") ||
                  reason.starts_with?("Subagent spend cap exceeded:") ||
                  reason.starts_with?("Subagent error:") ||
                  reason.starts_with?("Subagent exception:") ||
                  reason.starts_with?("Subagent API error:")
        reason
      else
        "Subagent error: #{reason}"
      end

      String.build do |io|
        io << "[" << prefix << "]"
        io << " (" << tool_calls_count << " tool call" << (tool_calls_count == 1 ? "" : "s")
        unless files_touched.empty?
          io << ", files modified: " << files_touched.uniq.join(", ")
        end
        io << ")"
      end
    end

    private def build_deterministic_post_mortem(
      reason : String,
      files_inspected : Array(String),
      files_touched : Array(String),
      commands_run : Array(String),
      tool_calls_count : Int32,
      last_action : String?,
      last_thought : String?
    ) : String
      String.build do |io|
        io << format_subagent_header(reason, tool_calls_count, files_touched) << "\n\n"
        io << "### Subagent Telemetry Post-Mortem:\n"
        unless files_inspected.empty?
          io << "- Files inspected: " << files_inspected.join(", ") << "\n"
        end
        unless commands_run.empty?
          io << "- Commands run: " << commands_run.last(3).join("; ") << "\n"
        end
        if last_action
          io << "- Last action: " << last_action << "\n"
        end
        if last_thought && !last_thought.strip.empty?
          thought_snippet = last_thought.lines.map(&.strip).reject(&.empty?).first(3).join(" ")
          io << "- Last thought: " << thought_snippet << "\n"
        end
      end
    end
  end
end
