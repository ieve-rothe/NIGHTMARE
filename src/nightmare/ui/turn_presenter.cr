# nightmare/ui/turn_presenter.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "salamander"
require "json"
require "../context/token_calibrator"

module Nightmare::UI
  alias Theme = Salamander::UI::Theme
  alias Panel = Salamander::UI::Panel
  alias CodePreview = Salamander::UI::CodePreview

  record OpenedFile,
    path : String,
    size_bytes : Int64,
    lines : Int32,
    tokens : Int32,
    read_range : String,
    content : String

  class SubagentTelemetry
    property task : String
    property iteration : Int32
    property max_iterations : Int32
    property active_tool : String?
    property last_thought : String?
    property tool_calls_count : Int32
    property files_touched : Array(String)

    def initialize(
      @task : String,
      @max_iterations : Int32,
      @iteration : Int32 = 1,
      @active_tool : String? = nil,
      @last_thought : String? = nil,
      @tool_calls_count : Int32 = 0,
      @files_touched : Array(String) = [] of String
    )
    end
  end

  class TurnPresenter
    property current_user_prompt : String = ""
    property agent_thought : String? = nil
    property last_agent_response : String? = nil
    property active_subagent : SubagentTelemetry? = nil
    property active_skill_name : String? = nil
    property max_response_lines : Int32 = 6
    property turn_number : Int32 = 0
    getter opened_files : Array(OpenedFile) = [] of OpenedFile
    getter calibrator : Context::TokenEstimator
    property threshold_multiplier : Float64
    property preview_lines : Int32
    property max_width : Int32
    property? enabled : Bool
property output : IO

# Split mode properties
property stream_history : Array(String) = [] of String
property stream_current : String = ""
property last_render : String? = nil
property last_active_file : OpenedFile? = nil
property last_active_offset : Int32 = 1
property last_action_label : String? = nil
property system_messages : Array(String) = [] of String


    def initialize(
      @calibrator : Context::TokenEstimator,
      @threshold_multiplier : Float64 = Config::FILE_CARD_THRESHOLD_SCREENS,
      @preview_lines : Int32 = Config::FILE_CARD_PREVIEW_LINES,
      @max_width : Int32 = Config::MAX_DASHBOARD_WIDTH,
      @enabled : Bool = true,
      @output : IO = STDOUT,
      @max_response_lines : Int32 = 6
    )
    end

    def split_mode_active? : Bool
  @enabled && Salamander::UI.terminal_width > @max_width + 50 && STDOUT.tty?
end

def append_right_pane(msg : String) : Nil
  msg.lines.each do |l|
    @stream_history << l
  end
  enforce_history_limit
  if split_mode_active?
    render_dashboard(@last_active_file, @last_active_offset, @last_action_label)
  end
end

def append_stream_text(chunk : String) : Nil
  chunk.each_char do |c|
    if c == '\n'
      @stream_history << @stream_current
      @stream_current = ""
    else
      @stream_current += c
    end
  end
  enforce_history_limit
  if split_mode_active?
    render_dashboard(@last_active_file, @last_active_offset, @last_action_label)
  end
end

private def enforce_history_limit : Nil
  term_h = Salamander::UI.terminal_height
  limit = Math.max(10, term_h - 2)
  if @stream_history.size > limit
    @stream_history.shift(@stream_history.size - limit)
  end
end

def display_msg(msg : String) : Nil
  msg.each_line do |l|
    @system_messages << l unless l.strip.empty?
  end
  if split_mode_active?
    append_right_pane(msg)
  else
    @output.puts msg
    @output.flush
  end
end

    def reset_for_new_turn(user_prompt : String, previous_response : String? = nil) : Nil
      @opened_files.clear
      @system_messages.clear
      @current_user_prompt = user_prompt
      @agent_thought = nil
      @last_agent_response = previous_response
      @active_subagent = nil
      @turn_number += 1
    end

    def record_file_open(path : String, content : String, offset : Int32? = nil, limit : Int32? = nil) : OpenedFile
      raw_lines = content.lines
      lines_count = raw_lines.size
      range_str = if offset || limit
        start_l = offset || 1
        end_l = start_l + lines_count - 1
        "L#{start_l}-L#{end_l}"
      else
        "all (#{lines_count} lines)"
      end

      tok = @calibrator.estimate(content.size)
      file = OpenedFile.new(
        path: path,
        size_bytes: content.bytesize.to_i64,
        lines: lines_count,
        tokens: tok,
        read_range: range_str,
        content: content
      )
      @opened_files << file
      file
    end

    def total_accumulated_lines : Int32
      @opened_files.sum(&.lines)
    end

    def threshold_lines : Int32
      term_h = Salamander::UI.terminal_height
      (term_h.to_f * @threshold_multiplier).to_i
    end

    def collapsed_mode? : Bool
      total_accumulated_lines > threshold_lines
    end

    # Formats byte size human-readably (e.g. 1.2 KB)
    def format_bytes(bytes : Int64) : String
      if bytes < 1024
        "#{bytes} B"
      elsif bytes < 1024 * 1024
        "#{(bytes / 1024.0).round(1)} KB"
      else
        "#{(bytes / (1024.0 * 1024.0)).round(2)} MB"
      end
    end

    # Formats token count human-readably (e.g. ~1.4k tok)
    def format_tokens(toks : Int32) : String
      if toks < 1000
        "~#{toks} tok"
      else
        "~#{(toks / 1000.0).round(1)}k tok"
      end
    end

    # Presents a tool output. If read_file and above threshold, renders the collapsed dashboard.
    def present_tool_result(name : String, args : Hash(String, JSON::Any), result_str : String) : Nil
      return unless @enabled

      if name == "read_file"
        path = args["path"]?.try(&.as_s?) || args["filepath"]?.try(&.as_s?) || "unknown"
        raw_offset = args["offset"]?
        offset = raw_offset.try(&.as_i?) || raw_offset.try(&.as_s?.try(&.to_i?))
        raw_limit = args["limit"]?
        limit = raw_limit.try(&.as_i?) || raw_limit.try(&.as_s?.try(&.to_i?))

        if result_str.starts_with?("[Refused:")
          tag = Theme.bracket_tag("GUARD", "REFUSED", Theme.status_tag)
          display_msg "  #{Theme.status_tag}⚠#{Theme::RESET} #{tag} #{Theme.filename}#{path}#{Theme::RESET}"
          result_str.strip.each_line do |line|
            display_msg "    #{Theme.meta_dim}│#{Theme::RESET} #{Theme.code_text}#{line}#{Theme::RESET}"
          end
          @output.flush
          return
        elsif result_str.starts_with?("[File is already pinned")
          tag = Theme.bracket_tag("PINNED", "SHORT-CIRCUIT", Theme.status_tag)
          display_msg "  #{Theme.status_tag}📌#{Theme::RESET} #{tag} #{Theme.filename}#{path}#{Theme::RESET} #{Theme.meta_dim}· already pinned in context#{Theme::RESET}"
          @output.flush
          return
        elsif result_str.starts_with?("[SecurityError:") || result_str.starts_with?("[Tool error:") || result_str.starts_with?("{\"error\":")
          tag = Theme.bracket_tag("READ", "FAILED", Theme.border_danger)
          display_msg "  #{Theme.border_danger}✗#{Theme::RESET} #{tag} #{Theme.filename}#{path}#{Theme::RESET} #{Theme.meta_dim}· #{result_str.strip}#{Theme::RESET}"
          @output.flush
          return
        end

        opened = record_file_open(path, result_str, offset, limit)

        if collapsed_mode? || split_mode_active?
          render_dashboard(active_file: opened, active_offset: offset || 1, action_label: "read_file('#{path}')")
        else
          # Under threshold: render verbatim inside clean panel
          term_w = Salamander::UI.terminal_width
          box_w = Panel.clamp_width(term_w, @max_width)
          panel = Panel.new(box_w, Theme.box_style)

          file_title = "#{Theme.title}📄 read_file:#{Theme::RESET} #{Theme.filename}#{opened.path}#{Theme::RESET} #{Theme.meta_dim}(#{opened.lines}L · #{format_bytes(opened.size_bytes)} · #{format_tokens(opened.tokens)})#{Theme::RESET}"
          @output.puts
          @output.puts panel.render_header(file_title, nil, Theme.border)
          opened.content.lines.each_with_index do |l, i|
            lnum = ((offset || 1) + i).to_s.rjust(4)
            formatted = "#{Theme.line_no}#{lnum} │#{Theme::RESET} #{Theme.code_text}#{l}#{Theme::RESET}"
            @output.puts panel.render_row(formatted, Theme.border)
          end
          @output.puts panel.render_footer(Theme.border)
          @output.flush
        end
      elsif name == "write_file" || name == "replace_in_file" || name == "append_to_file"
        path = args["path"]?.try(&.as_s?) || args["filepath"]?.try(&.as_s?) || "file"
        if result_str.starts_with?("[Execution rejected")
          tag = Theme.bracket_tag("MUTATION", "REJECTED", Theme.status_tag)
          display_msg "  #{Theme.status_tag}⚠#{Theme::RESET} #{tag} #{Theme.filename}#{path}#{Theme::RESET} #{Theme.meta_dim}· execution rejected by user#{Theme::RESET}"
        elsif result_str.starts_with?("[SecurityError:") || result_str.starts_with?("[Tool error:") || result_str.starts_with?("{\"error\":")
          tag = Theme.bracket_tag("MUTATION", "ERROR", Theme.border_danger)
          display_msg "  #{Theme.border_danger}✗#{Theme::RESET} #{tag} #{Theme.filename}#{path}#{Theme::RESET} #{Theme.meta_dim}· #{result_str.strip}#{Theme::RESET}"
        else
          tag = Theme.bracket_tag("MUTATION", name.upcase, Theme.success_icon)
          display_msg "  #{Theme.success_icon}✓#{Theme::RESET} #{tag} #{Theme.filename}#{path}#{Theme::RESET} #{Theme.meta_dim}· #{result_str.strip}#{Theme::RESET}"

          file_content = if File.exists?(path)
            File.read(path) rescue nil
          else
            args["content"]?.try(&.as_s?)
          end
          if file_content
            opened = record_file_open(path, file_content)
            @last_active_file = opened
            @last_active_offset = 1
            if collapsed_mode? || split_mode_active?
              render_dashboard(active_file: opened, active_offset: 1, action_label: "#{name}('#{path}')")
            end
          end
        end
        @output.flush
      elsif name == "shell" || name == "run_command"
        cmd = args["command"]?.try(&.as_s?) || "shell"
        if result_str.starts_with?("[Execution rejected")
          tag = Theme.bracket_tag("EXEC", "REJECTED", Theme.status_tag)
          display_msg "  #{Theme.status_tag}⚠#{Theme::RESET} #{tag} #{Theme.highlight}#{cmd}#{Theme::RESET} #{Theme.meta_dim}· execution rejected by user#{Theme::RESET}"
        elsif result_str.starts_with?("[SecurityError:") || result_str.starts_with?("[Tool error:") || result_str.starts_with?("[Timeout") || result_str.starts_with?("{\"error\":")
          tag = Theme.bracket_tag("EXEC", "FAILED", Theme.border_danger)
          display_msg "  #{Theme.border_danger}✗#{Theme::RESET} #{tag} #{Theme.highlight}#{cmd}#{Theme::RESET} #{Theme.meta_dim}· #{result_str.strip}#{Theme::RESET}"
        else
          tag = Theme.bracket_tag("EXEC", "SHELL", Theme.status_tag)
          display_msg "  #{Theme.success_icon}✓#{Theme::RESET} #{tag} #{Theme.highlight}#{cmd}#{Theme::RESET}"
          result_str.strip.each_line do |line|
            display_msg "    #{Theme.meta_dim}│#{Theme::RESET} #{Theme.code_text}#{line}#{Theme::RESET}"
          end
        end
        @output.flush
      elsif name == "file_info"
        path = args["path"]?.try(&.as_s?) || ""
        if result_str.starts_with?("[SecurityError:") || result_str.starts_with?("[Tool error:") || result_str.starts_with?("{\"error\":")
          tag = Theme.bracket_tag("INFO", "FAILED", Theme.border_danger)
          display_msg "  #{Theme.border_danger}✗#{Theme::RESET} #{tag} #{Theme.bracket_tag("INFO", path)} #{Theme.meta_dim}· #{result_str.strip}#{Theme::RESET}"
        else
          info = JSON.parse(result_str) rescue nil
          if info
            size = format_bytes(info["size_bytes"]?.try(&.as_i64?) || 0_i64)
            lines = info["lines"]?.try(&.as_i?) || 0
            display_msg "  #{Theme.status_tag}ℹ#{Theme::RESET} #{Theme.bracket_tag("INFO", path)} #{Theme.meta_dim}(#{size} · #{lines}L)#{Theme::RESET}"
          else
            display_msg "  #{Theme.status_tag}ℹ#{Theme::RESET} #{Theme.bracket_tag("INFO", path)} #{Theme.meta_dim}#{result_str.strip}#{Theme::RESET}"
          end
        end
        @output.flush
      elsif name == "search"
        pattern = args["pattern"]?.try(&.as_s?) || args["query"]?.try(&.as_s?) || ""
        if result_str.starts_with?("[SecurityError:") || result_str.starts_with?("[Tool error:") || result_str.starts_with?("{\"error\":")
          tag = Theme.bracket_tag("SEARCH", "FAILED", Theme.border_danger)
          display_msg "  #{Theme.border_danger}✗#{Theme::RESET} #{tag} #{Theme.bracket_tag("SEARCH", "'#{pattern}'")} #{Theme.meta_dim}· #{result_str.strip}#{Theme::RESET}"
        else
          match_count = result_str.lines.size
          display_msg "  #{Theme.highlight}🔍#{Theme::RESET} #{Theme.bracket_tag("SEARCH", "'#{pattern}'")} #{Theme.meta_dim}(#{match_count} match lines)#{Theme::RESET}"
        end
        @output.flush
      elsif name == "list_files"
        path = args["path"]?.try(&.as_s?) || args["directory"]?.try(&.as_s?) || "."
        if result_str.starts_with?("[SecurityError:") || result_str.starts_with?("[Tool error:") || result_str.starts_with?("{\"error\":")
          tag = Theme.bracket_tag("LIST", "FAILED", Theme.border_danger)
          display_msg "  #{Theme.border_danger}✗#{Theme::RESET} #{tag} #{Theme.bracket_tag("LIST", path)} #{Theme.meta_dim}· #{result_str.strip}#{Theme::RESET}"
        else
          file_count = result_str.lines.size
          display_msg "  #{Theme.status_tag}📁#{Theme::RESET} #{Theme.bracket_tag("LIST", path)} #{Theme.meta_dim}(#{file_count} entries)#{Theme::RESET}"
        end
        @output.flush
      else
        # For non-file tools, print result or summary
        display_msg result_str
      end
    end

    # Clears screen and renders single-turn dashboard with Opened Files Deck & Active Preview
    def render_dashboard(active_file : OpenedFile? = nil, active_offset : Int32 = 1, action_label : String? = nil, format_right_pane : Bool = false, final_response : String? = nil) : Nil
  @last_active_file = active_file
  @last_active_offset = active_offset
  @last_action_label = action_label

  term_w = Salamander::UI.terminal_width
  term_h = Salamander::UI.terminal_height
  box_w = Panel.clamp_width(term_w, @max_width)

  mem = IO::Memory.new
  old_out = @output
  @output = mem
  render_dashboard_inner(active_file, active_offset, action_label, box_w, term_h)
  @output = old_out
  left_str = mem.to_s

  if split_mode_active?
  right_w = term_w - box_w - 3
  left_lines = left_str.lines
  
  right_lines = [] of String
  if format_right_pane
  text_to_format = final_response || begin
    t = @stream_history.join("\n")
    t += "\n" + @stream_current unless @stream_current.empty?
    t
  end
  text_to_format = " " if text_to_format.empty?
  formatted = Salamander::UI::MarkdownFormatter.format(text_to_format)
  formatted.each_line do |line|
    right_lines.concat(Panel.wrap_text(line, right_w))
  end
  if right_lines.empty? && !formatted.empty?
    right_lines << formatted
  end
  else
    @stream_history.each do |line|
       right_lines.concat(Panel.wrap_text(line, right_w))
    end
    if !@stream_current.empty?
       right_lines.concat(Panel.wrap_text(@stream_current, right_w))
    end
  end
  
  disp_h = term_h - 1
  if right_lines.size > disp_h
     right_lines = right_lines.last(disp_h)
  end
  
  out_lines = [] of String
  max_lines = [left_lines.size, right_lines.size].max
  max_lines = Math.min(max_lines, disp_h)
    
    (0...max_lines).each do |i|
      l = left_lines[i]? || ""
      l_vis = Panel.visual_width(l)
      pad = Math.max(0, box_w - l_vis)
      r = right_lines[i]? || ""
      out_lines << "#{l}#{" " * pad} │ #{r}"
    end
    
    screen = out_lines.join("\n")
    if last = @last_render
      Salamander::UI.clear_and_reposition(last, @output)
    else
      Salamander::UI.clear_screen if @output == STDOUT
    end
    @output.puts screen
    @output.flush
    @last_render = screen
  else
    if @output == STDOUT && STDOUT.tty?
      Salamander::UI.clear_screen
    end
    @output.print left_str
    @output.flush
    @last_render = left_str
  end
end

def render_dashboard_inner(active_file : OpenedFile?, active_offset : Int32, action_label : String?, box_w : Int32, term_h : Int32) : Nil
  panel = Panel.new(box_w, Theme.box_style)

      

      # 1. Turn Banner & Prompt Card
      turn_title = "#{Theme.title}NIGHTMARE REPL#{Theme::RESET} #{Theme.meta_dim}· TURN #{@turn_number}#{Theme::RESET}"
      if sname = @active_skill_name
        turn_title = "#{turn_title} #{Theme.meta_dim}·#{Theme::RESET} #{Theme.status_tag}SKILL:#{sname}#{Theme::RESET}"
      end
      status_badge = "#{Theme.token_badge}● CARDS COMPRESSED#{Theme::RESET}"

      @output.puts panel.render_header(turn_title, status_badge, Theme.border)
      prompt_content = "#{Theme.user_prompt}#{Theme.prompt_glyph}#{@current_user_prompt}#{Theme::RESET}"
      max_prompt_lines = term_h <= 30 ? 2 : 4
      panel.render_wrapped_row(prompt_content, Theme.border, max_lines: max_prompt_lines).each do |line|
        @output.puts line
      end

      if thought = @agent_thought
        thought_content = "#{Theme.thought}💭 #{thought}#{Theme::RESET}"
        @output.puts panel.render_row(thought_content, Theme.border)
      end

      total_b = @opened_files.sum(&.size_bytes)
      total_tok = @opened_files.sum(&.tokens)
      stats_content = "#{Theme.meta_dim}Files:#{Theme::RESET} #{@opened_files.size} (#{format_bytes(total_b)}, #{Theme.token_badge}#{format_tokens(total_tok)}#{Theme::RESET}) #{Theme.meta_dim}│ Loaded:#{Theme::RESET} #{total_accumulated_lines}/#{threshold_lines}L #{Theme.meta_dim}│ Layout:#{Theme::RESET} #{box_w}c"
      @output.puts panel.render_divider(Theme.border)
      panel.render_wrapped_row(stats_content, Theme.border, max_lines: 2).each { |w| @output.puts w }
      @output.puts panel.render_footer(Theme.border)
      @output.puts

      # 1.5. Last Agent Response (First-Class Information Card)
      if resp = @last_agent_response
        raw_lines = resp.strip.lines
        unless raw_lines.empty?
          resp_title = "#{Theme.title}✦ AGENT RESPONSE#{Theme::RESET}"
          max_resp_lines = term_h <= 30 ? 3 : @max_response_lines
          if raw_lines.size <= max_resp_lines
            resp_badge = "#{Theme.meta_dim}#{raw_lines.size} lines#{Theme::RESET}"
            @output.puts panel.render_header(resp_title, resp_badge, Theme.border)
            raw_lines.each do |line|
              panel.render_wrapped_row("  #{Theme.code_text}#{line}#{Theme::RESET}", Theme.border, max_lines: 2).each do |w|
                @output.puts w
              end
            end
            @output.puts panel.render_footer(Theme.border)
            @output.puts
          else
            hidden_count = raw_lines.size - max_resp_lines
            resp_badge = "#{Theme.meta_dim}latest #{max_resp_lines} of #{raw_lines.size}L#{Theme::RESET}"
            @output.puts panel.render_header(resp_title, resp_badge, Theme.border)
            @output.puts panel.render_row("  #{Theme.notice_dim}... [+#{hidden_count} earlier lines hidden; latest #{max_resp_lines} lines shown] ...#{Theme::RESET}", Theme.border)
            raw_lines.last(max_resp_lines).each do |line|
              panel.render_wrapped_row("  #{Theme.code_text}#{line}#{Theme::RESET}", Theme.border, max_lines: 2).each do |w|
                @output.puts w
              end
            end
            @output.puts panel.render_footer(Theme.border)
            @output.puts
          end
        end
      end

      # 1.6. Active Subagent Engaged Card (Live Subagent Telemetry)
      if subagent = @active_subagent
        sub_title = "#{Theme.title_active}🤖 SUBAGENT ENGAGED#{Theme::RESET}"
        sub_badge = "#{Theme.token_badge}ITER #{subagent.iteration}/#{subagent.max_iterations} ∷ #{subagent.tool_calls_count} TOOLS#{Theme::RESET}"
        @output.puts panel.render_header(sub_title, sub_badge, Theme.border_active)
        panel.render_wrapped_row("Task   : #{Theme.code_text}#{subagent.task}#{Theme::RESET}", Theme.border_active, max_lines: 2).each do |w|
          @output.puts w
        end
        if action = subagent.active_tool
          panel.render_wrapped_row("Action : #{Theme.highlight}#{action}#{Theme::RESET}", Theme.border_active, max_lines: 2).each { |w| @output.puts w }
        end
        if th = subagent.last_thought
          panel.render_wrapped_row("Thought: #{Theme.thought}💭 #{th.lines.first}#{Theme::RESET}", Theme.border_active, max_lines: 3).each { |w| @output.puts w }
        end
        unless subagent.files_touched.empty?
          panel.render_wrapped_row("Touched: #{Theme.filename}#{subagent.files_touched.uniq.join(", ")}#{Theme::RESET}", Theme.border_active, max_lines: 2).each { |w| @output.puts w }
        end
        @output.puts panel.render_footer(Theme.border_active)
        @output.puts
      end

      # 2. Grouped Opened Files Deck
      deck_title = "#{Theme.title}📚 Opened Files#{Theme::RESET} #{Theme.meta_dim}(#{@opened_files.size} files · #{format_bytes(total_b)} · #{Theme.token_badge}#{format_tokens(total_tok)}#{Theme::RESET}#{Theme.meta_dim})#{Theme::RESET}"
      badge = box_w < 75 ? nil : "#{Theme.meta_dim}ALL IN ONE BOX#{Theme::RESET}"
      @output.puts panel.render_header(deck_title, badge, Theme.border_active)

      max_deck_files = term_h <= 28 ? 4 : 8
      displayed_files = if @opened_files.size > max_deck_files
        @opened_files.last(max_deck_files)
      else
        @opened_files
      end

      if @opened_files.size > displayed_files.size
        overflow_count = @opened_files.size - displayed_files.size
        @output.puts panel.render_row("  #{Theme.meta_dim}... [+#{overflow_count} earlier files in context] ...#{Theme::RESET}", Theme.border_active)
      end

      displayed_files.each do |f|
        icon = "#{Theme.success_icon}✓#{Theme::RESET}"
        fname = "#{Theme.filename}#{f.path}#{Theme::RESET}"
        meta = if box_w < 70
          "#{Theme.meta_dim}[#{format_bytes(f.size_bytes)} · #{Theme.token_badge}#{format_tokens(f.tokens)}#{Theme::RESET}#{Theme.meta_dim}]#{Theme::RESET}"
        else
          "#{Theme.meta_dim}[#{format_bytes(f.size_bytes)} · #{f.lines}L · #{Theme.token_badge}#{format_tokens(f.tokens)}#{Theme::RESET}#{Theme.meta_dim} · #{f.read_range}]#{Theme::RESET}"
        end
        row_str = " #{icon} #{fname} #{meta}"
        @output.puts panel.render_row(row_str, Theme.border_active, truncate: true)
      end

      @output.puts panel.render_footer(Theme.border_active)
      @output.puts

      # 3. Active File Preview Box
      if active = active_file
        active_lines_count = active.lines
        effective_preview = if term_h <= 28
          Math.min(@preview_lines, 4)
        elsif term_h <= 35
          Math.min(@preview_lines, 6)
        else
          @preview_lines
        end

        hi_line = [active_offset + effective_preview - 1, active_lines_count].min
        prev_title = if box_w < 70
          "#{Theme.title_active}🔍 Inspection:#{Theme::RESET} #{Theme.filename}#{active.path}#{Theme::RESET} #{Theme.meta_dim}(L#{active_offset}-L#{hi_line})#{Theme::RESET}"
        else
          "#{Theme.title_active}🔍 Active Inspection:#{Theme::RESET} #{Theme.filename}#{active.path}#{Theme::RESET} #{Theme.meta_dim}(L#{active_offset}-L#{hi_line} of #{active_lines_count})#{Theme::RESET}"
        end
        prev_badge = "#{Theme.token_badge}#{format_tokens(active.tokens)}#{Theme::RESET}"
        @output.puts panel.render_header(prev_title, prev_badge, Theme.border)

        code_lines = CodePreview.render(
          lines: active.content.lines,
          start_offset: active_offset,
          max_preview_lines: effective_preview,
          panel: panel,
          border_color: Theme.border
        )
        code_lines.each { |l| @output.puts l }
        @output.puts panel.render_footer(Theme.border)
        @output.puts
      end

      # 3.5. System Events Card (Mutations, Shell Commands, Tool Outputs - Source of Truth)
      unless @system_messages.empty?
        events_title = "#{Theme.title}⚡ System Events#{Theme::RESET} #{Theme.meta_dim}(#{@system_messages.size} event#{@system_messages.size == 1 ? "" : "s"})#{Theme::RESET}"
        events_badge = box_w < 75 ? nil : "#{Theme.status_tag}SOURCE OF TRUTH#{Theme::RESET}"
        @output.puts panel.render_header(events_title, events_badge, Theme.border_active)

        max_events = if term_h <= 28
          3
        elsif term_h <= 35
          5
        else
          8
        end

        displayed_events = if @system_messages.size > max_events
          @system_messages.last(max_events)
        else
          @system_messages
        end

        if @system_messages.size > displayed_events.size
          overflow = @system_messages.size - displayed_events.size
          @output.puts panel.render_row("  #{Theme.meta_dim}... [+#{overflow} earlier system events in turn] ...#{Theme::RESET}", Theme.border_active)
        end

        displayed_events.each do |msg|
          clean = msg.strip
          formatted_row = clean.starts_with?("│") ? "   #{clean}" : " #{clean}"
          panel.render_wrapped_row(formatted_row, Theme.border_active, max_lines: 2).each do |w|
            @output.puts w
          end
        end

        @output.puts panel.render_footer(Theme.border_active)
        @output.puts
      end

      # Action label
      if action = action_label
        @output.puts "  #{Theme.highlight}⚡ Action:#{Theme::RESET} #{action}"
      end
      @output.flush
    end
  end
end
