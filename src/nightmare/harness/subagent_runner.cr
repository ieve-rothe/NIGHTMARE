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
require "./types"

module Nightmare::Harness
  class SubagentRunner < Nightmare::Plan::SubagentDispatcher
    getter client : Mantle::Clients::Client
    getter environment : Nightmare::Workspace::Environment
    getter pacer : Nightmare::Plan::Pacer?

    def initialize(
      @client : Mantle::Clients::Client,
      @environment : Nightmare::Workspace::Environment,
      @pacer : Nightmare::Plan::Pacer? = nil
    )
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

      # Build prompt
      system_prompt = build_system_prompt(item, worktree_path)
      user_prompt = build_user_prompt(item)

      messages = [
        Mantle::Message.new("system", system_prompt),
        Mantle::Message.new("user", user_prompt),
      ]

      tool_calls_count = 0
      on_iteration = ->(working_msgs : Array(Mantle::Message), last_res : Mantle::Clients::Response?) {
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
        tools: subagent_tools,
        max_iterations: max_iterations,
        on_iteration: on_iteration
      )

      tokens_used = 0
      summary = ""
      status = "completed"
      proposed_items = [] of Nightmare::Plan::ProposedItem
      proposed_targets = [] of String

      begin
        result = step.run(messages)
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
