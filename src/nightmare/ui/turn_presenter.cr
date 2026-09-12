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

  class TurnPresenter
    property current_user_prompt : String = ""
    property agent_thought : String? = nil
    property turn_number : Int32 = 0
    getter opened_files : Array(OpenedFile) = [] of OpenedFile
    getter calibrator : Context::TokenEstimator
    property threshold_multiplier : Float64
    property preview_lines : Int32
    property max_width : Int32
    property? enabled : Bool
    property output : IO

    def initialize(
      @calibrator : Context::TokenEstimator,
      @threshold_multiplier : Float64 = Config::FILE_CARD_THRESHOLD_SCREENS,
      @preview_lines : Int32 = Config::FILE_CARD_PREVIEW_LINES,
      @max_width : Int32 = Config::MAX_DASHBOARD_WIDTH,
      @enabled : Bool = true,
      @output : IO = STDOUT
    )
    end

    def reset_for_new_turn(user_prompt : String) : Nil
      @opened_files.clear
      @current_user_prompt = user_prompt
      @agent_thought = nil
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
          @output.puts "  #{Theme.status_tag}⚠#{Theme::RESET} #{tag} #{Theme.filename}#{path}#{Theme::RESET}"
          result_str.strip.each_line do |line|
            @output.puts "    #{Theme.meta_dim}│#{Theme::RESET} #{Theme.code_text}#{line}#{Theme::RESET}"
          end
          @output.flush
          return
        elsif result_str.starts_with?("[File is already pinned")
          tag = Theme.bracket_tag("PINNED", "SHORT-CIRCUIT", Theme.status_tag)
          @output.puts "  #{Theme.status_tag}📌#{Theme::RESET} #{tag} #{Theme.filename}#{path}#{Theme::RESET} #{Theme.meta_dim}· already pinned in context#{Theme::RESET}"
          @output.flush
          return
        end

        opened = record_file_open(path, result_str, offset, limit)

        if collapsed_mode?
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
          @output.puts "  #{Theme.status_tag}⚠#{Theme::RESET} #{tag} #{Theme.filename}#{path}#{Theme::RESET} #{Theme.meta_dim}· execution rejected by user#{Theme::RESET}"
        elsif result_str.starts_with?("[SecurityError:") || result_str.starts_with?("[Tool error:") || result_str.starts_with?("{\"error\":")
          tag = Theme.bracket_tag("MUTATION", "ERROR", Theme.border_danger)
          @output.puts "  #{Theme.border_danger}✗#{Theme::RESET} #{tag} #{Theme.filename}#{path}#{Theme::RESET} #{Theme.meta_dim}· #{result_str.strip}#{Theme::RESET}"
        else
          tag = Theme.bracket_tag("MUTATION", name.upcase, Theme.success_icon)
          @output.puts "  #{Theme.success_icon}✓#{Theme::RESET} #{tag} #{Theme.filename}#{path}#{Theme::RESET} #{Theme.meta_dim}· #{result_str.strip}#{Theme::RESET}"
        end
        @output.flush
      elsif name == "shell"
        cmd = args["command"]?.try(&.as_s?) || "shell"
        if result_str.starts_with?("[Execution rejected")
          tag = Theme.bracket_tag("EXEC", "REJECTED", Theme.status_tag)
          @output.puts "  #{Theme.status_tag}⚠#{Theme::RESET} #{tag} #{Theme.highlight}#{cmd}#{Theme::RESET} #{Theme.meta_dim}· execution rejected by user#{Theme::RESET}"
        elsif result_str.starts_with?("[SecurityError:") || result_str.starts_with?("[Tool error:") || result_str.starts_with?("[Timeout") || result_str.starts_with?("{\"error\":")
          tag = Theme.bracket_tag("EXEC", "FAILED", Theme.border_danger)
          @output.puts "  #{Theme.border_danger}✗#{Theme::RESET} #{tag} #{Theme.highlight}#{cmd}#{Theme::RESET} #{Theme.meta_dim}· #{result_str.strip}#{Theme::RESET}"
        else
          tag = Theme.bracket_tag("EXEC", "SHELL", Theme.status_tag)
          @output.puts "  #{Theme.success_icon}✓#{Theme::RESET} #{tag} #{Theme.highlight}#{cmd}#{Theme::RESET}"
          result_str.strip.each_line do |line|
            @output.puts "    #{Theme.meta_dim}│#{Theme::RESET} #{Theme.code_text}#{line}#{Theme::RESET}"
          end
        end
        @output.flush
      else
        # For non-file tools, print result or summary
        @output.puts result_str
        @output.flush
      end
    end

    # Clears screen and renders single-turn dashboard with Opened Files Deck & Active Preview
    def render_dashboard(active_file : OpenedFile? = nil, active_offset : Int32 = 1, action_label : String? = nil) : Nil
      term_w = Salamander::UI.terminal_width
      term_h = Salamander::UI.terminal_height
      box_w = Panel.clamp_width(term_w, @max_width)
      panel = Panel.new(box_w, Theme.box_style)

      if @output == STDOUT && STDOUT.tty?
        Salamander::UI.clear_screen
      end

      # 1. Turn Banner & Prompt Card
      turn_title = "#{Theme.title}NIGHTMARE REPL#{Theme::RESET} #{Theme.meta_dim}· TURN #{@turn_number}#{Theme::RESET}"
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
      @output.puts panel.render_row(stats_content, Theme.border)
      @output.puts panel.render_footer(Theme.border)
      @output.puts

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
        @output.puts panel.render_row(row_str, Theme.border_active)
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

      # Action label
      if action = action_label
        @output.puts "  #{Theme.highlight}⚡ Action:#{Theme::RESET} #{action}"
      end
      @output.flush
    end
  end
end
