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
require "../ui/cancellation"
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

      registry = Nightmare::Tools::Registry.new(
        guard: guard,
        client: @client,
        diff_approval: diff_approval,
        shell_approval: shell_approval
      )
      registry.set_active_side_effects(files_touched)
      registry.shell.subagent_mode = true

      subagent_tools = registry.build_subagent_tools

      wrapped_subagent_tools = subagent_tools.map do |tool|
        orig_handler = tool.handler
        wrapped = tool.dup
        wrapped.handler = ->(args : Hash(String, JSON::Any)) {
          if cancelled?
            raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
          end
          res = orig_handler ? orig_handler.call(args) : ""
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

      messages = [
        Mantle::Message.new("system", system_prompt),
        Mantle::Message.new("user", user_prompt),
      ]

      tool_calls_count = 0
      on_iteration = ->(working_msgs : Array(Mantle::Message), last_res : Mantle::Clients::Response?) {
        if cancelled?
          raise Nightmare::Harness::CancelledException.new("Turn cancelled by user interrupt")
        end
        if last_res
          if calls = last_res.tool_calls
            tool_calls_count += calls.size
          end
          if p = @pacer
            p.pace_turn
          end
        end
        working_msgs
      }

      max_iterations = item.budget_iterations || @environment.settings.max_iterations
      step = Mantle::Step.new(
        client: @client,
        tools: wrapped_subagent_tools,
        max_iterations: max_iterations,
        on_iteration: on_iteration
      )

      tokens_used = 0
      summary = ""
      status = "completed"
      proposed_items = [] of Nightmare::Plan::ProposedItem
      proposed_targets = [] of String

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

        if result.ok?
          raw_response = result.unwrap
          summary, proposed_items, proposed_targets = parse_subagent_output(raw_response, item.id)
        else
          status = "failed"
          summary = "Subagent error: #{result.error}"
        end
      rescue ex : CancelledException
        raise ex
      rescue ex
        status = "failed"
        summary = "Subagent exception: #{ex.message}"
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

      registry = Nightmare::Tools::Registry.new(
        guard: guard,
        client: @client,
        diff_approval: active_diff_approval,
        shell_approval: active_shell_approval,
        default_command_timeout: @environment.settings.command_timeout_seconds,
        max_command_timeout: @environment.settings.max_command_timeout_seconds,
        tool_output_max_bytes: @environment.settings.tool_output_max_bytes
      )
      registry.set_active_side_effects(files_touched)
      registry.shell.subagent_mode = true

      subagent_tools = registry.build_subagent_tools

      system_prompt = build_workspace_system_prompt(files_targeted)
      user_prompt = "Task:\n#{task}\n\nExecute the task now."

      messages = [
        Mantle::Message.new("system", system_prompt),
        Mantle::Message.new("user", user_prompt),
      ]

      max_iterations = budget_iterations || @environment.settings.max_iterations
      telemetry = Nightmare::UI::SubagentTelemetry.new(
        task: task,
        max_iterations: max_iterations
      )
      tp = @turn_presenter
      if tp
        tp.active_subagent = telemetry
        tp.render_dashboard(action_label: "Subagent spawned")
      end

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
        working_msgs
      }

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

        if result.ok?
          raw_response = result.unwrap
          summary, _proposed_items, _proposed_targets = parse_subagent_output(raw_response, "subagent")
          String.build do |io|
            io << "[Subagent completed - " << tool_calls_count << " tool call" << (tool_calls_count == 1 ? "" : "s")
            unless files_touched.empty?
              io << ", files modified: " << files_touched.uniq.join(", ")
            end
            io << "]\n\n"
            io << summary
          end
        else
          "[Subagent error: #{result.error}]"
        end
      rescue ex : CancelledException
        raise ex
      rescue ex
        "[Subagent exception: #{ex.message}]"
      ensure
        if tp
          tp.active_subagent = nil
        end
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
  end
end
