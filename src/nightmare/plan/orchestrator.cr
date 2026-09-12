# nightmare/plan/orchestrator.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "digest/sha256"
require "./models"
require "./run_state"
require "./storage"
require "./worktree"
require "./verification"

module Nightmare::Plan
  # Abstract runner interface so orchestrator can be driven by either real SubagentRunner or mock runner
  abstract class SubagentDispatcher
    abstract def dispatch(
      item : PlanItem,
      run : PlanRun,
      worktree_path : String
    ) : NamedTuple(
      status: String,
      summary: String,
      files_touched: Array(String),
      tool_calls_count: Int32,
      shell_commands: Array(ExecutedCommand),
      proposed_items: Array(ProposedItem),
      proposed_targets: Array(String),
      tokens_used: Int32
    )
  end

  class Orchestrator
    getter plan : Plan
    getter worktree : Worktree
    getter verification : VerificationEngine
    getter dispatcher : SubagentDispatcher
    getter runs_dir : String
    getter lock_path : String
    property inter_item_pacing_seconds : Float64 = 0.0

    def initialize(
      @plan : Plan,
      @worktree : Worktree,
      @dispatcher : SubagentDispatcher,
      @runs_dir : String,
      @verification : VerificationEngine = VerificationEngine.new,
      @inter_item_pacing_seconds : Float64 = 0.0
    )
      @lock_path = File.join(@runs_dir, "#{@plan.id}.lock")
    end

    # Executes the plan state machine to completion or clean park
    def run_plan(run_id : String? = nil) : PlanRun
      Storage.with_lock(@lock_path) do
        # 1. Initialize or load run state
        active_run_id = run_id || "run-#{Time.utc.to_s("%Y%m%d-%H%M%S")}-#{Random.rand(1000..9999)}"
        run_file = File.join(@runs_dir, "#{active_run_id}.json")

        run = if File.exists?(run_file)
                Storage.load_and_recover(run_file)
              else
                init_new_run(active_run_id)
              end

        # 2. Provision worktree & baseline if new run
        if run.base_sha.nil?
          base_sha = @worktree.provision(@plan.base_ref, @plan.setup_command)
          run.base_sha = base_sha
          run.worktree_path = @worktree.worktree_path

          if baseline_cfg = @plan.baseline_verification
            baseline_state = @verification.capture_baseline(
              baseline_cfg,
              @worktree.worktree_path,
              @worktree.cache_dir
            )
            run.baseline = baseline_state
          end

          # Set initial base_sha for root items
          @plan.items.each do |it|
            if it.depends_on.empty?
              run.items[it.id].base_sha = base_sha
            end
          end

          Storage.save_run(run, @runs_dir)
        end

        # 3. State machine execution loop
        execute_state_machine(run)

        run
      end
    end

    private def init_new_run(run_id : String) : PlanRun
      run = PlanRun.new(
        run_id: run_id,
        plan_id: @plan.id,
        plan_schema_version: @plan.schema_version,
        started_at: Time.utc,
        updated_at: Time.utc,
        status: PlanRunStatus::Running
      )

      # Populate item states
      @plan.items.each do |item|
        run.items[item.id] = ItemRunState.new(
          id: item.id,
          status: PlanItemStatus::Pending,
          max_attempts: item.max_attempts
        )
      end

      # Populate transaction group states
      @plan.items.compact_map(&.group_id).uniq.each do |gid|
        run.groups[gid] = GroupRunState.new(group_id: gid)
      end

      run
    end

    private def execute_state_machine(run : PlanRun) : Nil
      loop do
        runnable_item = find_next_runnable_item(run)

        unless runnable_item
          # Check transaction group boundaries
          group_processed = check_transaction_groups(run)
          if group_processed
            next
          end

          # Check terminal status
          update_terminal_run_status(run)
          Storage.save_run(run, @runs_dir)
          break
        end

        item_id = runnable_item.id
        item_state = run.items[item_id]

        # Inter-item cadence pacing
        if @inter_item_pacing_seconds > 0.0
          sleep @inter_item_pacing_seconds.seconds
        end

        # Execute single item attempt
        execute_item_attempt(runnable_item, item_state, run)
        Storage.save_run(run, @runs_dir)
      end
    end

    private def execute_item_attempt(
      item : PlanItem,
      item_state : ItemRunState,
      run : PlanRun
    ) : Nil
      item_state.status = PlanItemStatus::Running
      item_state.attempts += 1
      item_state.started_at = Time.utc

      # Ensure base_sha is set
      base_sha = item_state.base_sha || run.base_sha.not_nil!
      item_state.base_sha = base_sha

      # Pre-attempt hard rollback to base_sha
      @worktree.rollback_to(base_sha)

      # Dispatch subagent / worker
      worker_res = @dispatcher.dispatch(item, run, @worktree.worktree_path)

      # Synthesize ground-truth telemetry
      item_state.files_touched = worker_res[:files_touched]
      item_state.tool_calls_count = worker_res[:tool_calls_count]
      item_state.shell_commands = worker_res[:shell_commands]
      item_state.worker_self_reported_status = worker_res[:status]
      item_state.summary = worker_res[:summary]
      item_state.proposed_items = worker_res[:proposed_items]
      item_state.proposed_targets = worker_res[:proposed_targets]
      item_state.tokens_used += worker_res[:tokens_used]

      # Check for BlockedOnApproval:
      if worker_res[:status].downcase.includes?("blocked")
        item_state.status = PlanItemStatus::Blocked
        item_state.finished_at = Time.utc
        @worktree.rollback_to(base_sha)
        propagate_blocked(item.id, run)
        return
      end

      # THE GATE IS THE SOLE AUTHORITY:
      diff_empty = @worktree.diff_empty?

      if diff_empty && item.verification.kind != VerificationKind::None
        # No work product produced -> immediate fail
        handle_item_failure(
          item,
          item_state,
          run,
          base_sha,
          "No work product produced: diff was empty but verification was required"
        )
        return
      end

      # Run verification gate
      gate_res = @verification.evaluate_gate(
        item.verification,
        run.baseline,
        @worktree.worktree_path,
        @worktree.cache_dir
      )

      if gate_res.passed
        # Commit checkpoint
        new_sha = @worktree.commit_checkpoint(item.id, item.title)
        item_state.status = PlanItemStatus::Completed
        item_state.result_sha = new_sha
        item_state.finished_at = Time.utc

        # Propagate result SHA to direct downstream dependents
        propagate_success_sha(item.id, new_sha, run)
      else
        # Gate failed -> archive patch & rollback
        handle_item_failure(
          item,
          item_state,
          run,
          base_sha,
          gate_res.summary
        )
      end
    end

    private def handle_item_failure(
      item : PlanItem,
      item_state : ItemRunState,
      run : PlanRun,
      base_sha : String,
      error_msg : String
    ) : Nil
      # 1. Archive failure patch
      patch_dir = File.join(@runs_dir, run.run_id, "failures")
      patch_file = File.join(patch_dir, "#{item.id}-attempt-#{item_state.attempts}.patch")
      @worktree.archive_failure_patch(patch_file)

      # 2. Capture diff before rolling back for thrash signature
      current_diff = @worktree.capture_diff

      # 3. Rollback to base_sha
      @worktree.rollback_to(base_sha)

      # 4. Thrash detection
      thrash_sig = compute_thrash_signature(current_diff, error_msg)

      if item_state.attempt_signatures.includes?(thrash_sig)
        item_state.status = PlanItemStatus::Failed
        item_state.finished_at = Time.utc
        item_state.error_history << "[Thrash detected: identical diff & failure repeated. Aborting item.]"
        propagate_failure(item.id, run)
      else
        item_state.attempt_signatures << thrash_sig
        item_state.error_history << error_msg

        if item_state.attempts >= item_state.max_attempts
          item_state.status = PlanItemStatus::Failed
          item_state.finished_at = Time.utc
          propagate_failure(item.id, run)
        else
          item_state.status = PlanItemStatus::Pending # ready for retry
        end
      end
    end

    private def check_transaction_groups(run : PlanRun) : Bool
      # Find groups where all items are completed
      run.groups.each do |gid, gstate|
        next if gstate.status == PlanItemStatus::Completed || gstate.status == PlanItemStatus::NeedsReview

        group_items = @plan.items.select { |it| it.group_id == gid }
        all_completed = group_items.all? { |it| run.items[it.id].status == PlanItemStatus::Completed }

        if all_completed && gstate.status != PlanItemStatus::Completed
          # All group items completed!
          gstate.status = PlanItemStatus::Completed
          gstate.result_sha = @worktree.get_head_sha(@worktree.worktree_path)
          return true
        end
      end

      false
    end

    private def find_next_runnable_item(run : PlanRun) : PlanItem?
      @plan.items.find do |item|
        state = run.items[item.id]?
        next false unless state && state.status == PlanItemStatus::Pending

        # All dependencies must be completed
        item.depends_on.all? do |dep_id|
          dep_state = run.items[dep_id]?
          dep_state && dep_state.status == PlanItemStatus::Completed
        end
      end
    end

    private def propagate_success_sha(completed_item_id : String, result_sha : String, run : PlanRun) : Nil
      @plan.items.each do |it|
        if it.depends_on.includes?(completed_item_id)
          run.items[it.id].base_sha = result_sha
        end
      end
    end

    private def propagate_failure(failed_item_id : String, run : PlanRun) : Nil
      # Transitive dependents of Failed -> Skipped
      @plan.items.each do |it|
        if it.depends_on.includes?(failed_item_id)
          state = run.items[it.id]
          if state.status == PlanItemStatus::Pending
            state.status = PlanItemStatus::Skipped
            state.finished_at = Time.utc
            propagate_failure(it.id, run)
          end
        end
      end
    end

    private def propagate_blocked(blocked_item_id : String, run : PlanRun) : Nil
      # Dependents of Blocked -> Blocked
      @plan.items.each do |it|
        if it.depends_on.includes?(blocked_item_id)
          state = run.items[it.id]
          if state.status == PlanItemStatus::Pending
            state.status = PlanItemStatus::Blocked
            state.finished_at = Time.utc
            propagate_blocked(it.id, run)
          end
        end
      end
    end

    private def update_terminal_run_status(run : PlanRun) : Nil
      all_items = run.items.values
      if all_items.all?(&.status.completed?)
        run.status = PlanRunStatus::Completed
      elsif all_items.any?(&.status.failed?)
        run.status = PlanRunStatus::Failed
      elsif all_items.any?(&.status.blocked?) || all_items.any?(&.status.needs_review?)
        run.status = PlanRunStatus::Partial
      else
        run.status = PlanRunStatus::Completed
      end
      run.updated_at = Time.utc
    end

    def compute_thrash_signature(diff : String, error : String) : String
      normalized_error = normalize_error(error)
      raw = "#{diff}\0#{normalized_error}"
      Digest::SHA256.hexdigest(raw)
    end

    private def normalize_error(err : String) : String
      # Strip ANSI color escapes, memory addresses, timestamps, and sort lines
      stripped = err.gsub(/\e\[[0-9;]*m/, "")
        .gsub(/0x[0-9a-fA-F]+/, "0xADDR")
        .gsub(/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?Z?/, "TIMESTAMP")
        .lines
        .map(&.strip)
        .reject(&.empty?)
        .sort
        .join("\n")
      stripped
    end
  end
end
