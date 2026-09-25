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
require "../config"
require "../skills"
require "colorize"

module Nightmare::Commands
  class Router
    getter store : Context::SlidingStore
    getter pinned_files : Context::PinnedFiles
    getter calibrator : Context::TokenCalibrator
    getter guard : Tools::Guard
    getter env : Workspace::Environment
    getter skills_manager : Skills::SkillManager
    property transcript : Transcript
    property current_prompt : String
    property current_model : String
    property last_thinking : String? = nil
    property on_model_change : Proc(String, Nil)? = nil
    property client : Mantle::Clients::Client?
    property pacer : Nightmare::Plan::Pacer
    property active_orchestrator : Nightmare::Plan::Orchestrator? = nil
    property last_plan_run : Nightmare::Plan::PlanRun? = nil

    getter stdin : IO
    getter stdout : IO

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
      @pacer : Nightmare::Plan::Pacer = Nightmare::Plan::Pacer.new,
      @stdin : IO = STDIN,
      @stdout : IO = STDOUT,
      skills_manager : Skills::SkillManager? = nil
    )
      @skills_manager = skills_manager || Skills::SkillManager.new(@env.repo_skills_dir, @env.global_skills_dir)
    end

    # Checks if an input line is a slash command or multiline trigger
    def slash_command?(input : String) : Bool
      trimmed = input.strip
      trimmed.starts_with?('/') || trimmed.starts_with?("\"\"\"")
    end

    # Routes and executes a slash command. Returns true if handled, false if not a command.
    # May return a String if the command produces input for the LLM (e.g. /paste).
    def handle(input : String) : Tuple(Bool, String?)
      trimmed = input.strip
      return {false, nil} unless trimmed.starts_with?('/') || trimmed.starts_with?("\"\"\"")

      if trimmed.starts_with?("\"\"\"")
        if trimmed.ends_with?("\"\"\"") && trimmed.size >= 6
          content = trimmed[3..-4].strip
          return {true, content.empty? ? nil : content}
        end

        initial_line = trimmed.size > 3 ? trimmed[3..-1] : nil
        text = handle_paste(initial_line)
        return {true, text}
      end

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
      when "/recover"
        handle_recover(args)
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
      when "/theme"
        handle_theme(args)
        {true, nil}
      when "/skill"
        handle_skill(args)
        {true, nil}
      when "/exit", "/quit"
        exit(0)
      else
        puts "Unknown command: #{cmd}. Type /help for available commands."
        {true, nil}
      end
    end

    private def clear_screen : Nil
      @stdout.print "\e[2J\e[H"
      @stdout.flush
    end

    private def puts(obj = "") : Nil
      @stdout.puts(obj)
    end

    private def print(obj) : Nil
      @stdout.print(obj)
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
  /skill [name]    Toggle, switch, or list task skills (/skill off)
  /review          Inspect assembled prompt, pinned files, and token usage
  /recover [opt]   Inspect and restore context from failure/crash dumps
  /thinking        View model internal chain-of-thought from last turn
  /theme [name]    Switch theme (cyberpunk, outrun, phosphor, classic)
  /model [name]    Inspect or change the active LLM model
  /paste           Enter multi-line input paste mode (or """)
  /exit            Exit the session
HELP
    end

    private def handle_theme(args : String) : Nil
      if args.empty?
        active = Salamander::UI::Theme.current.name
        puts "\nAvailable Themes:"
        Salamander::UI::Theme.all_names.each do |name|
          marker = (name == active) ? "● (active)" : "○"
          puts "  #{marker} #{name}"
        end
        puts "\nUsage: /theme <name> (e.g. /theme outrun, /theme phosphor, /theme cyberpunk, /theme classic)"
      else
        target = args.downcase
        begin
          new_theme = Salamander::UI::Theme.set_theme(target)
          @env.settings.theme = target
          puts "Theme switched to #{new_theme.title}#{target.upcase}#{Salamander::UI::Theme::RESET}."
        rescue ex : ArgumentError
          puts ex.message
        end
      end
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
          @stdout.flush
          if input = @stdin.gets.try(&.strip)
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

    private def handle_skill(args : String) : Nil
      trimmed = args.strip

      if trimmed.empty?
        skills = @skills_manager.scan_all
        if skills.empty?
          puts "No skills found. Add .md files to #{@env.repo_skills_dir} (local) or #{@env.global_skills_dir} (global)."
          return
        end

        active = @skills_manager.active_skill
        puts "\nAvailable Skills:"
        skills.each do |s|
          is_active = active && active.name == s.name
          marker = is_active ? "●" : "○"
          tokens = @calibrator.estimate(s.content.size)
          scope_str = "(#{s.scope})"
          active_str = is_active ? " [ACTIVE]" : ""
          override_str = s.overrides_global? ? " [overrides global]" : ""

          puts "  #{marker} #{s.name.ljust(22)} #{scope_str.ljust(9)} ~#{tokens} tok#{active_str}#{override_str}"
        end
        puts "\nUsage: /skill <name> to toggle/switch, or /skill off\n"
        return
      end

      res = @skills_manager.toggle(trimmed)
      case res.status
      when Skills::ToggleStatus::Deactivated
        if prev = res.previous_skill
          puts "Deactivated skill '#{prev.name}'. Context cleared."
        else
          puts "No active skill to deactivate."
        end
      when Skills::ToggleStatus::Switched
        curr = res.skill.not_nil!
        prev = res.previous_skill.not_nil!
        tok = @calibrator.estimate(curr.content.size)
        puts "Switched skill: '#{prev.name}' ➔ '#{curr.name}' (~#{tok} tokens)."
      when Skills::ToggleStatus::Activated
        curr = res.skill.not_nil!
        tok = @calibrator.estimate(curr.content.size)
        puts "Activated skill '#{curr.name}' (~#{tok} tokens)."
      when Skills::ToggleStatus::NotFound
        puts "No skill found matching '#{trimmed}'. Run /skill to see available skills."
      end
    end

    private def handle_review : Nil
      puts "\n=== Context Review ==="
      puts "--- System Prompt ---"
      puts @current_prompt
      puts

      puts "--- Ephemeral Context ---"
      puts Context::SlidingStore.current_date_note
      puts

      skill_block = @skills_manager.active_skill.try(&.formatted_block)
      if skill = @skills_manager.active_skill
        puts "--- Active Skill (#{skill.name} [#{skill.scope}]) ---"
        puts skill.content
        puts
      end

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
      total_tokens = @store.total_estimated_tokens(@calibrator, @current_prompt, block, skill_block)
      prompt_tokens = @calibrator.estimate(@current_prompt.size)
      skill_tokens = skill ? @calibrator.estimate(skill_block.try(&.size) || 0) : 0

      puts "\n--- Token Budget ---"
      puts "Estimated total tokens: #{total_tokens} / #{@store.hardmax} tokens"
      puts "  System prompt: ~#{prompt_tokens} tokens"
      puts "  Active skill:  ~#{skill_tokens} tokens" if skill
      puts "  Pinned files:  ~#{pinned_tokens} tokens"
      puts "  Calibrator divisor: #{@calibrator.divisor.round(2)}"
      puts "=====================\n"
    end

    private def handle_recover(args : String) : Nil
      candidates = [
        File.join(@env.workspace_state_dir, "failures"),
        File.join(@env.root, ".nightmare", "failures"),
        File.join(Dir.current, ".nightmare", "failures")
      ].uniq

      failures_dir = candidates.find { |d| Dir.exists?(d) && !Dir.children(d).empty? } || candidates.first

      parts = args.strip.split(' ', 2)
      subcmd = parts.first?.try(&.downcase) || ""
      target_arg = parts.size > 1 ? parts[1].strip : ""

      if !subcmd.empty? && subcmd != "list" && subcmd != "view" && subcmd != "restore"
        if File.exists?(subcmd)
          view_dump_details(subcmd)
          return
        elsif subcmd.to_i?
          target_arg = subcmd
          subcmd = "view"
        end
      end

      dump_files = if Dir.exists?(failures_dir)
        Dir.children(failures_dir)
          .select { |f| f.starts_with?("failure_") && f.ends_with?(".json") }
          .sort
          .reverse
      else
        [] of String
      end

      case subcmd
      when "", "list"
        if dump_files.empty?
          puts "No failure dumps found in #{failures_dir}."
          return
        end

        puts "\n=== Recent Failure Dumps ==="
        dump_files.first(10).each_with_index do |filename, idx|
          filepath = File.join(failures_dir, filename)
          info = parse_dump_summary(filepath)
          marker = (idx == 0) ? "● (latest)" : "○"
          puts "  #{marker} [#{idx + 1}] #{filename}"
          puts "      Time: #{info[:time]} | Error: #{info[:error_code]} | Tool: #{info[:tool]} | Tokens: ~#{info[:tokens]}"
        end
        puts "\nUsage:"
        puts "  /recover view [index|file]    - Inspect details of a failure dump"
        puts "  /recover restore [index|file] - Restore dump into active conversation history\n"

      when "view"
        target_file = resolve_dump_file(target_arg.empty? ? "1" : target_arg, dump_files, failures_dir)
        unless target_file
          puts "Failure dump not found: '#{target_arg}'"
          return
        end
        view_dump_details(target_file)

      when "restore"
        target_file = resolve_dump_file(target_arg.empty? ? "1" : target_arg, dump_files, failures_dir)
        unless target_file
          puts "Failure dump not found: '#{target_arg}'"
          return
        end
        restore_dump(target_file)

      else
        puts "Unknown option '#{subcmd}'. Run /recover to list dumps or /recover restore [index]."
      end
    end

    private def resolve_dump_file(target : String, dump_files : Array(String), failures_dir : String) : String?
      return target if File.exists?(target)

      if File.exists?(File.join(failures_dir, target))
        return File.join(failures_dir, target)
      end

      if idx = target.to_i?
        if idx >= 1 && idx <= dump_files.size
          return File.join(failures_dir, dump_files[idx - 1])
        end
      end

      if match = dump_files.find { |f| f.includes?(target) }
        return File.join(failures_dir, match)
      end

      nil
    end

    private def parse_dump_summary(filepath : String) : NamedTuple(time: String, error_code: String, tool: String, tokens: Int32)
      begin
        data = JSON.parse(File.read(filepath))
        time = data["timestamp"]?.try(&.as_s?) || "unknown"
        error_code = data["error_code"]?.try(&.as_s?) || "UNKNOWN"
        tool = data["offending_tool"]?.try(&.as_s?) || "none"
        tokens = data["token_metrics"]?.try(&.[]?("prompt_tokens")).try(&.as_i?) || 0
        {time: time, error_code: error_code, tool: tool, tokens: tokens}
      rescue
        {time: "corrupt", error_code: "PARSE_ERROR", tool: "unknown", tokens: 0}
      end
    end

    private def view_dump_details(filepath : String) : Nil
      data = begin
        JSON.parse(File.read(filepath))
      rescue ex
        puts "Failed to parse dump #{filepath}: #{ex.message}"
        return
      end

      error_code = data["error_code"]?.try(&.as_s?) || "UNKNOWN"
      message = data["message"]?.try(&.as_s?) || ""
      tool = data["offending_tool"]?.try(&.as_s?) || "none"
      time = data["timestamp"]?.try(&.as_s?) || ""
      iter = data["token_metrics"]?.try(&.[]?("iterations")).try(&.as_i?) || 0
      tokens = data["token_metrics"]?.try(&.[]?("prompt_tokens")).try(&.as_i?) || 0
      msgs = data["messages"]?.try(&.as_a?) || [] of JSON::Any

      first_user = msgs.find { |m| m["role"]?.try(&.as_s?) == "user" }
      first_prompt = first_user.try(&.[]?("content")).try(&.as_s?) || "(none)"

      tool_calls_list = [] of String
      msgs.each do |m|
        if tcs = m["tool_calls"]?.try(&.as_a?)
          tcs.each do |tc|
            name = tc["name"]?.try(&.as_s?) || "unknown"
            tool_calls_list << name
          end
        end
      end

      puts "\n=== Failure Dump: #{File.basename(filepath)} ==="
      puts "Timestamp: #{time}"
      puts "Error:     #{error_code} - #{message}"
      puts "Tool:      #{tool}"
      puts "Metrics:   #{iter} iterations | ~#{tokens} tokens | #{msgs.size} messages"
      puts "\nOriginal Request:"
      puts "  #{first_prompt.lines.first(3).join("\n  ")}#{"..." if first_prompt.lines.size > 3}"
      if !tool_calls_list.empty?
        puts "\nTools Executed: #{tool_calls_list.uniq.join(", ")} (total #{tool_calls_list.size} calls)"
      end
      puts "\nTo restore this dump into active conversation history, run:"
      puts "  /recover restore #{File.basename(filepath)}"
      puts "=================================================\n"
    end

    private def restore_dump(filepath : String) : Nil
      data = begin
        JSON.parse(File.read(filepath))
      rescue ex
        puts "Failed to parse dump #{filepath}: #{ex.message}"
        return
      end

      messages_json = data["messages"]?.try(&.as_a?) || [] of JSON::Any
      if messages_json.empty?
        puts "No messages found in failure dump #{filepath}."
        return
      end

      msgs = [] of Mantle::Message
      pending_tool_calls = [] of Mantle::Clients::ToolCall

      messages_json.each do |mj|
        role = mj["role"]?.try(&.as_s?) || "user"
        content = mj["content"]?.try(&.as_s?)

        tool_calls = mj["tool_calls"]?.try(&.as_a?).try do |tcs_json|
          tcs_json.map do |tc_json|
            Mantle::Clients::ToolCall.new(
              id: tc_json["id"]?.try(&.as_s?) || "call_#{Random::Secure.hex(4)}",
              type: "function",
              function: Mantle::Clients::ToolCallFunction.new(
                name: tc_json["name"]?.try(&.as_s?) || "unknown",
                arguments: tc_json["arguments"]?.try(&.as_s?) || "{}"
              )
            )
          end
        end

        raw_tool_id = mj["tool_call_id"]?.try(&.as_s?)
        tool_call_id = if role == "tool" && (raw_tool_id.nil? || raw_tool_id.empty?)
          pending_tool_calls.shift?.try(&.id) || "call_recovered_#{Random::Secure.hex(4)}"
        else
          raw_tool_id
        end

        if role == "assistant" && tool_calls
          pending_tool_calls.concat(tool_calls)
        end

        msgs << Mantle::Message.new(
          role: role,
          content: content,
          tool_calls: tool_calls,
          tool_call_id: tool_call_id
        )
      end

      # Ensure starts with user
      if msgs.first?.try(&.role) != "user"
        msgs.unshift(Mantle::Message.new("user", "Recovered session request"))
      end

      # Disambiguate duplicate tool_call IDs if any
      seen_ids = Set(String).new
      msgs.each_with_index do |m, idx|
        if m.role == "assistant" && (tcs = m.tool_calls)
          tcs.each_with_index do |tc, tc_idx|
            if seen_ids.includes?(tc.id)
              new_id = "#{tc.id}_dup#{idx}_#{tc_idx}"
              ((idx + 1)...msgs.size).each do |tm_idx|
                tm = msgs[tm_idx]
                if tm.role == "tool" && tm.tool_call_id == tc.id
                  msgs[tm_idx] = Mantle::Message.new(
                    role: "tool",
                    content: tm.content,
                    tool_calls: tm.tool_calls,
                    tool_call_id: new_id
                  )
                  break
                end
              end
              tcs[tc_idx] = Mantle::Clients::ToolCall.new(new_id, tc.function, tc.type)
              seen_ids.add(new_id)
            else
              seen_ids.add(tc.id)
            end
          end
        end
      end

      # Close any open tool calls
      open_ids = Set(String).new
      msgs.each_with_index do |m, idx|
        next if idx == 0
        if m.role == "assistant" && (tcs = m.tool_calls)
          tcs.each { |tc| open_ids.add(tc.id) }
        elsif m.role == "tool" && (tid = m.tool_call_id)
          open_ids.delete(tid)
        end
      end

      open_ids.each do |unclosed_id|
        msgs << Mantle::Message.new(
          role: "tool",
          content: %({"error": "Aborted before result was recorded", "refused": true}),
          tool_call_id: unclosed_id
        )
      end

      # Ensure terminates with assistant
      if msgs.last?.try(&.role) != "assistant"
        err_code = data["error_code"]?.try(&.as_s?) || "ERR_ABORTED"
        err_msg = data["message"]?.try(&.as_s?) || "Turn interrupted"
        msgs << Mantle::Message.new("assistant", "Recovered from failure dump (#{err_code}): #{err_msg}")
      end

      turn = Context::Turn.from_messages(msgs)

      # In-turn shed if over budget
      total_chars = turn.messages.sum { |m| (m.content || "").size }
      estimated_toks = @calibrator.estimate(total_chars)
      hardmax = @store.hardmax
      trigger_thold = (hardmax.to_f * 0.75).to_i
      if estimated_toks > trigger_thold
        estimated_toks = Context::Shedder.shed_active_turn!(
          turn,
          current_tokens: estimated_toks,
          hardmax: hardmax,
          calibrator: @calibrator
        )
      end

      @store.push_turn(turn)
      puts "Successfully restored turn from #{File.basename(filepath)} into conversation history (~#{estimated_toks} tokens)."
      puts "Type /review to inspect context."
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

    private def handle_paste(initial_line : String? = nil) : String?
      @stdout.puts " ↳ Multi-line mode active. Paste your text, then type '\"\"\"' or '/end' on a new line to send.".colorize(:yellow)
      lines = [] of String
      lines << initial_line if initial_line && !initial_line.empty?

      lines_read = lines.size
      chars_read = lines.sum(&.size)

      while line = @stdin.gets
        break if line.strip.in?("/end", "\"\"\"")

        lines_read += 1
        chars_read += line.size

        if lines_read > Nightmare::Config::MAX_MULTILINE_LINES || chars_read > Nightmare::Config::MAX_MULTILINE_CHARS
          @stdout.puts "[System] Maximum input limit reached. Truncating input.".colorize(:red)
          if chars_read > Nightmare::Config::MAX_MULTILINE_CHARS && lines_read <= Nightmare::Config::MAX_MULTILINE_LINES
            excess = chars_read - Nightmare::Config::MAX_MULTILINE_CHARS
            allowed = line.size - excess
            lines << line[0, allowed]
          end
          break
        end

        lines << line
      end

      joined = lines.join("\n").strip
      if joined.empty?
        nil
      else
        @stdout.puts " ↳ Text captured. Processing...".colorize(:dark_gray)
        joined
      end
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
