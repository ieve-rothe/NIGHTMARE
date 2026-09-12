# nightmare/commands/router.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "../context/sliding_store"
require "../context/pinned_files"
require "../context/token_calibrator"
require "../transcript"
require "../tools/guard"
require "../workspace/environment"
require "../plan"
require "../harness/subagent_runner"

module Nightmare::Commands
  class Router
    getter store : Context::SlidingStore
    getter pinned_files : Context::PinnedFiles
    getter calibrator : Context::TokenCalibrator
    getter guard : Tools::Guard
    getter env : Workspace::Environment
    property transcript : Transcript
    property current_prompt : String
    property current_model : String
    property last_thinking : String? = nil
    property on_model_change : Proc(String, Nil)? = nil
    property client : Mantle::Clients::Client?
    property pacer : Nightmare::Plan::Pacer
    property active_orchestrator : Nightmare::Plan::Orchestrator? = nil
    property last_plan_run : Nightmare::Plan::PlanRun? = nil

    def initialize(
      @store : Context::SlidingStore,
      @pinned_files : Context::PinnedFiles,
      @calibrator : Context::TokenCalibrator,
      @guard : Tools::Guard,
      @env : Workspace::Environment,
      @transcript : Transcript,
      @current_prompt : String,
      @current_model : String,
      @on_model_change : Proc(String, Nil)? = nil,
      @client : Mantle::Clients::Client? = nil,
      @pacer : Nightmare::Plan::Pacer = Nightmare::Plan::Pacer.new
    )
    end

    # Checks if an input line is a slash command
    def slash_command?(input : String) : Bool
      input.strip.starts_with?('/')
    end

    # Routes and executes a slash command. Returns true if handled, false if not a command.
    # May return a String if the command produces input for the LLM (e.g. /paste).
    def handle(input : String) : Tuple(Bool, String?)
      trimmed = input.strip
      return {false, nil} unless trimmed.starts_with?('/')

      parts = trimmed.split(' ', 2)
      cmd = parts[0].downcase
      args = parts.size > 1 ? parts[1].strip : ""

      case cmd
      when "/help"
        print_help
        {true, nil}
      when "/clear"
        @store.clear
        clear_screen
        puts "Conversation history cleared."
        {true, nil}
      when "/cls"
        clear_screen
        {true, nil}
      when "/drop", "/rm"
        handle_drop(args)
        {true, nil}
      when "/add"
        handle_add(args)
        {true, nil}
      when "/save"
        handle_save(args)
        {true, nil}
      when "/prompt"
        handle_prompt(args)
        {true, nil}
      when "/review"
        handle_review
        {true, nil}
      when "/thinking"
        handle_thinking
        {true, nil}
      when "/model"
        handle_model(args)
        {true, nil}
      when "/paste"
        text = handle_paste
        {true, text}
      when "/plan"
        handle_plan(args)
        {true, nil}
      when "/mode"
        handle_mode(args)
        {true, nil}
      when "/exit", "/quit"
        exit(0)
      else
        puts "Unknown command: #{cmd}. Type /help for available commands."
        {true, nil}
      end
    end

    private def clear_screen : Nil
      print "\e[2J\e[H"
      STDOUT.flush
    end

    private def print_help : Nil
      puts <<-HELP
Available Slash Commands:
  /help            Show this help reference
  /plan run <file> Execute autonomous plan in isolated Git worktree
  /plan status [id]Inspect active or recent plan run state
  /plan report [id]Generate comprehensive plan report & telemetry
  /plan review <f> Pre-flight check plan for cycles, targets & warnings
  /mode [mode]     Set pacing mode: sprint (0s), pace (3s), step (6s)
  /clear           Clear screen and wipe turn history (retains pinned files)
  /cls             Clear terminal screen ANSI display
  /add <path>      Pin a workspace file into context
  /drop [path]     Unpin a file from context (or /rm)
  /save [path]     Export pristine RAM transcript to Markdown
  /prompt [edit]   View or edit in-memory system prompt
  /review          Inspect assembled prompt, pinned files, and token usage
  /thinking        View model internal chain-of-thought from last turn
  /model [name]    Inspect or change the active LLM model
  /paste           Enter multi-line input paste mode
  /exit            Exit the session
HELP
    end

    private def handle_drop(path : String) : Nil
      if path.empty?
        @pinned_files.clear
        puts "Dropped all pinned files."
      else
        if @pinned_files.remove(path)
          puts "Dropped pinned file: #{path}"
        else
          puts "No pinned file found matching: #{path}"
        end
      end
    end

    private def handle_add(path : String) : Nil
      if path.empty?
        puts "Usage: /add <path>"
        return
      end

      begin
        file = @pinned_files.add(
          path: path,
          guard: @guard,
          calibrator: @calibrator,
          hardmax: @store.hardmax,
          budget_ratio: @env.settings.pinned_budget_ratio
        )
        puts "Pinned #{file.path} (estimated #{file.cached_tokens} tokens)."
      rescue ex : SecurityError
        puts "SecurityError: #{ex.message}"
      rescue ex : Nightmare::Error
        puts ex.message
      rescue ex
        puts "Failed to pin file: #{ex.message}"
      end
    end

    private def handle_save(path : String) : Nil
      target_path = if path.empty?
        File.join(@env.workspace_state_dir, "transcript.md")
      else
        @guard.resolve_write(path)
      end

      begin
        @transcript.save_to(target_path)
        puts "Transcript saved to #{target_path}"
      rescue ex
        puts "Failed to save transcript: #{ex.message}"
      end
    end

    private def handle_prompt(args : String) : Nil
      if args.empty?
        puts "Current System Prompt:"
        puts "----------------------"
        puts @current_prompt
        puts "----------------------"
      elsif args.starts_with?("edit")
        sub_args = args[4..].strip
        if !sub_args.empty?
          @current_prompt = sub_args
          puts "Updated in-memory system prompt."
        else
          puts "Enter new in-memory system prompt (single line or empty to cancel):"
          print "> "
          STDOUT.flush
          if input = STDIN.gets.try(&.strip)
            if !input.empty?
              @current_prompt = input
              puts "Updated in-memory system prompt."
            else
              puts "Prompt edit cancelled."
            end
          end
        end
      else
        puts "Usage: /prompt [edit [text]]"
      end
    end

    private def handle_review : Nil
      puts "\n=== Context Review ==="
      puts "--- System Prompt ---"
      puts @current_prompt
      puts

      if block = @pinned_files.render_pinned_block(@guard)
        puts "--- Pinned Files ---"
        puts block
        puts
      end

      puts "--- Conversation History (#{@store.history.size} turns) ---"
      @store.history.each_with_index do |turn, idx|
        puts "[Turn #{idx + 1}]"
        turn.messages.each do |msg|
          role = msg.role.capitalize
          content = msg.content
          puts "  #{role}: #{content}"
        end
      end

      if active = @store.active_turn
        puts "[Active Turn]"
        active.messages.each do |msg|
          puts "  #{msg.role.capitalize}: #{msg.content}"
        end
      end

      pinned_tokens = @pinned_files.total_estimated_tokens(@guard, @calibrator)
      total_tokens = @store.total_estimated_tokens(@calibrator, @current_prompt, block)
      prompt_tokens = @calibrator.estimate(@current_prompt.size)

      puts "\n--- Token Budget ---"
      puts "Estimated total tokens: #{total_tokens} / #{@store.hardmax} tokens"
      puts "  System prompt: ~#{prompt_tokens} tokens"
      puts "  Pinned files:  ~#{pinned_tokens} tokens"
      puts "  Calibrator divisor: #{@calibrator.divisor.round(2)}"
      puts "=====================\n"
    end

    private def handle_thinking : Nil
      if t = @last_thinking
        puts "\n=== Model Internal Reasoning ==="
        puts t
        puts "================================\n"
      else
        puts "No thinking recorded for the last turn."
      end
    end

    private def handle_model(name : String) : Nil
      if name.empty?
        puts "Active model: #{@current_model}"
      else
        @current_model = name
        @on_model_change.try &.call(name)
        puts "Model set to: #{@current_model}"
      end
    end

    private def handle_paste : String?
      puts "Paste mode enabled. Enter lines below. Submit with a line containing '/end' or empty line:"
      lines = [] of String
      while line = STDIN.gets
        break if line.strip == "/end" || line.strip.empty?
        lines << line
      end
      joined = lines.join("\n")
      joined.empty? ? nil : joined
    end

    private def handle_plan(args : String) : Nil
      sub_parts = args.split(' ', 2)
      subcmd = sub_parts[0]?.try(&.downcase) || ""
      sub_args = sub_parts[1]?.try(&.strip) || ""

      case subcmd
      when "run"
        handle_plan_run(sub_args)
      when "status"
        handle_plan_status(sub_args)
      when "report"
        handle_plan_report(sub_args)
      when "review", "lint"
        handle_plan_review(sub_args)
      else
        puts <<-USAGE
Usage:
  /plan run <path/to/plan.json>    Execute autonomous plan in isolated worktree
  /plan status [run_id]           Inspect active or recent plan run state
  /plan report [run_id]           Generate comprehensive telemetry & test diff report
  /plan review <path/to/plan.json> Pre-flight check plan for cycles, targets & warnings
USAGE
      end
    end

    private def handle_plan_run(path : String) : Nil
      if path.empty?
        puts "Usage: /plan run <path/to/plan.json>"
        return
      end

      full_path = File.expand_path(path, @env.root)
      unless File.exists?(full_path)
        puts "Error: Plan file not found at #{full_path}"
        return
      end

      plan = begin
        Nightmare::Plan::Plan.from_json(File.read(full_path))
      rescue ex
        puts "Error parsing plan JSON: #{ex.message}"
        return
      end

      # 1. Pre-flight linting
      linter = Nightmare::Plan::Linter.new(plan)
      findings = linter.lint(@env.root)

      errors = findings.select { |f| f.severity == "error" }
      warnings = findings.select { |f| f.severity == "warning" }

      if !warnings.empty?
        puts "Plan Warnings (#{warnings.size}):"
        warnings.each do |w|
          item_str = w.item_id ? "[Item: #{w.item_id}] " : ""
          puts "  ⚠️  #{item_str}#{w.message}"
        end
      end

      if !errors.empty?
        puts "Plan Errors (#{errors.size}):"
        errors.each do |e|
          item_str = e.item_id ? "[Item: #{e.item_id}] " : ""
          puts "  ❌ #{item_str}#{e.message}"
        end
        puts "Plan execution aborted due to pre-flight lint errors."
        return
      end

      client = @client
      unless client
        puts "Error: No LLM client configured for plan execution."
        return
      end

      puts "🚀 Initializing plan '#{plan.id}' (#{plan.goal})..."
      puts "Provisioning isolated Git worktree..."

      worktree = begin
        wt_path = File.join(@env.workspace_state_dir, "worktree-#{plan.id}")
        cache_path = File.join(@env.workspace_state_dir, "cache")
        wt = Nightmare::Plan::Worktree.new(@env.root, wt_path, cache_path, "nightmare/plan-#{plan.id}")
        wt.provision(base_ref: plan.base_ref, setup_command: plan.setup_command)
        wt
      rescue ex
        puts "Failed to provision worktree: #{ex.message}"
        return
      end

      dispatcher = Nightmare::Harness::SubagentRunner.new(
        client: client,
        environment: @env,
        pacer: @pacer
      )

      verification = Nightmare::Plan::VerificationEngine.new

      orchestrator = Nightmare::Plan::Orchestrator.new(
        plan: plan,
        worktree: worktree,
        dispatcher: dispatcher,
        runs_dir: @env.workspace_state_dir,
        verification: verification,
        inter_item_pacing_seconds: @pacer.inter_item_pacing_seconds
      )
      @active_orchestrator = orchestrator

      puts "Starting orchestrator execution..."
      run = orchestrator.run_plan
      @last_plan_run = run

      # Print summary
      completed = run.items.count { |_, s| s.status == Nightmare::Plan::PlanItemStatus::Completed }
      failed = run.items.count { |_, s| s.status == Nightmare::Plan::PlanItemStatus::Failed }
      blocked = run.items.count { |_, s| s.status == Nightmare::Plan::PlanItemStatus::Blocked }
      total_tokens = run.items.values.sum(&.tokens_used)

      puts "\n=== Plan Execution Summary ==="
      puts "Status: #{run.status}"
      puts "Completed items: #{completed} / #{run.items.size}"
      puts "Failed items: #{failed}"
      puts "Blocked items: #{blocked}"
      puts "Total tokens used: #{total_tokens}"
      if run.status == Nightmare::Plan::PlanRunStatus::Completed
        puts "✅ Plan completed successfully! Changes committed to worktree branch."
      else
        puts "❌ Plan ended with status: #{run.status}. Run '/plan report' for details."
      end
    end

    private def handle_plan_status(run_id_arg : String) : Nil
      run = resolve_plan_run(run_id_arg)
      unless run
        puts "No plan run found. Run '/plan run <file>' first or specify run ID."
        return
      end

      puts "\n=== Plan Run Status: #{run.plan_id} (Run: #{run.run_id}) ==="
      puts "Overall Status: #{run.status}"
      puts "Base SHA      : #{run.base_sha || "none"}"
      puts "Started At    : #{run.started_at}"
      puts "Updated At    : #{run.updated_at}"

      puts "\nItems:"
      run.items.each do |item_id, item_state|
        status_icon = case item_state.status
                      when Nightmare::Plan::PlanItemStatus::Completed then "✅"
                      when Nightmare::Plan::PlanItemStatus::Failed    then "❌"
                      when Nightmare::Plan::PlanItemStatus::Running   then "⏳"
                      when Nightmare::Plan::PlanItemStatus::Blocked   then "🚫"
                      else "⚪"
                      end
        puts "  #{status_icon} #{item_id} [#{item_state.status}] (Attempts: #{item_state.attempts}/#{item_state.max_attempts})"
        if s = item_state.summary
          first_line = s.lines.first?.try(&.strip) || ""
          puts "     Summary: #{first_line}"
        end
      end
    end

    private def handle_plan_report(run_id_arg : String) : Nil
      run = resolve_plan_run(run_id_arg)
      unless run
        puts "No plan run found. Run '/plan run <file>' first or specify run ID."
        return
      end

      puts "\n" + "=" * 60
      puts "PLAN EXECUTION REPORT: #{run.plan_id}"
      puts "=" * 60
      puts "Run ID     : #{run.run_id}"
      puts "Status     : #{run.status}"
      puts "Base SHA   : #{run.base_sha}"
      puts "Started    : #{run.started_at}"
      puts "Updated    : #{run.updated_at}"

      b = run.baseline
      puts "\nBaseline Verification:"
      puts "  Total Tests   : #{b.total_tests}"
      puts "  Known Failures: #{b.known_failing_tests.size} tests"

      puts "\n--- Item Breakdown ---"
      run.items.each do |item_id, st|
        puts "\n[Item: #{item_id}] Status: #{st.status} (Attempts: #{st.attempts})"
        puts "  Base SHA     : #{st.base_sha}"
        puts "  Result SHA   : #{st.result_sha || "none"}"
        puts "  Tokens Used  : #{st.tokens_used}"
        puts "  Files Touched: #{st.files_touched.empty? ? "none" : st.files_touched.join(", ")}"
        if !st.error_history.empty?
          puts "  Errors       : #{st.error_history.join("; ")}"
        end
        if !st.shell_commands.empty?
          puts "  Shell Commands (#{st.shell_commands.size}):"
          st.shell_commands.each do |cmd|
            puts "    - `#{cmd.cmd.join(" ")}` -> exit #{cmd.exit_code} (#{cmd.duration_ms}ms)"
          end
        end
        if !st.proposed_items.empty?
          puts "  Proposed Follow-up Items:"
          st.proposed_items.each do |p|
            puts "    - #{p.title}"
          end
        end
        if !st.proposed_targets.empty?
          puts "  Proposed Targets: #{st.proposed_targets.join(", ")}"
        end
      end
      puts "\n" + "=" * 60
    end

    private def handle_plan_review(path : String) : Nil
      if path.empty?
        puts "Usage: /plan review <path/to/plan.json>"
        return
      end

      full_path = File.expand_path(path, @env.root)
      unless File.exists?(full_path)
        puts "Error: Plan file not found at #{full_path}"
        return
      end

      plan = begin
        Nightmare::Plan::Plan.from_json(File.read(full_path))
      rescue ex
        puts "Error parsing plan JSON: #{ex.message}"
        return
      end

      linter = Nightmare::Plan::Linter.new(plan)
      findings = linter.lint(@env.root)

      puts "\n=== Plan Review: #{plan.id} (#{plan.goal}) ==="
      puts "Items count: #{plan.items.size}"
      if findings.empty?
        puts "✅ No errors or warnings found. Plan is valid and ready to execute."
      else
        findings.each do |f|
          icon = f.severity == "error" ? "❌" : "⚠️ "
          item_str = f.item_id ? "[Item: #{f.item_id}] " : ""
          puts "  #{icon} #{item_str}#{f.message}"
        end
      end
    end

    private def handle_mode(args : String) : Nil
      mode = args.strip.downcase
      case mode
      when "sprint"
        @pacer.inter_item_pacing_seconds = 0.0
        @pacer.inter_turn_pacing_seconds = 0.0
        puts "Mode set to SPRINT (0s delays, maximum throughput)."
      when "pace"
        @pacer.inter_item_pacing_seconds = 3.0
        @pacer.inter_turn_pacing_seconds = 0.5
        puts "Mode set to PACE (3.0s inter-item, 0.5s inter-turn, GPU thermal tripwire active)."
      when "step"
        @pacer.inter_item_pacing_seconds = 6.0
        @pacer.inter_turn_pacing_seconds = 1.0
        puts "Mode set to STEP (6.0s inter-item, 1.0s inter-turn pacing)."
      when ""
        puts "Current Mode & Pacing:"
        puts "  Inter-Item Delay : #{@pacer.inter_item_pacing_seconds}s"
        puts "  Inter-Turn Delay : #{@pacer.inter_turn_pacing_seconds}s"
        puts "  Thermal Ceiling  : #{@pacer.thermal_ceiling_celsius}°C"
        puts "  Thermal Resume   : #{@pacer.thermal_resume_celsius}°C"
        puts "Available modes: /mode sprint, /mode pace, /mode step"
      else
        puts "Unknown mode: #{args}. Usage: /mode [sprint | pace | step]"
      end
    end

    private def resolve_plan_run(run_id_arg : String) : Nightmare::Plan::PlanRun?
      if !run_id_arg.empty?
        path = if File.exists?(run_id_arg)
                 run_id_arg
               else
                 File.join(@env.workspace_state_dir, "#{run_id_arg}.json")
               end
        return nil unless File.exists?(path)
        Nightmare::Plan::Storage.load_run(path)
      elsif last = @last_plan_run
        last
      else
        latest_file = Dir.glob(File.join(@env.workspace_state_dir, "run-*.json")).max_by? { |f| File.info(f).modification_time }
        latest_file ? Nightmare::Plan::Storage.load_run(latest_file) : nil
      end
    end
  end
end
