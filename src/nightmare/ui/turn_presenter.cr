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

        opened = record_file_open(path, result_str, offset, limit)

        if collapsed_mode?
          render_dashboard(active_file: opened, active_offset: offset || 1, action_label: "read_file('#{path}')")
        else
          # Under threshold: render verbatim inside clean panel
          term_w = Salamander::UI.terminal_width
          box_w = Panel.clamp_width(term_w, @max_width)
          panel = Panel.new(box_w)

          file_title = "#{Theme::TITLE}📄 read_file:#{Theme::RESET} #{Theme::FILENAME}#{opened.path}#{Theme::RESET} #{Theme::META_DIM}(#{opened.lines}L · #{format_bytes(opened.size_bytes)} · #{format_tokens(opened.tokens)})#{Theme::RESET}"
          @output.puts
          @output.puts panel.render_header(file_title, nil, Theme::BORDER)
          opened.content.lines.each_with_index do |l, i|
            lnum = ((offset || 1) + i).to_s.rjust(4)
            formatted = "#{Theme::LINE_NO}#{lnum} │#{Theme::RESET} #{Theme::CODE_TEXT}#{l}#{Theme::RESET}"
            @output.puts panel.render_row(formatted, Theme::BORDER)
          end
          @output.puts panel.render_footer(Theme::BORDER)
          @output.flush
        end
      else
        # For non-file tools, print result or summary
        @output.puts result_str
        @output.flush
      end
    end

    # Clears screen and renders single-turn dashboard with Opened Files Deck & Active Preview
    def render_dashboard(active_file : OpenedFile? = nil, active_offset : Int32 = 1, action_label : String? = nil) : Nil
      term_w = Salamander::UI.terminal_width
      box_w = Panel.clamp_width(term_w, @max_width)
      panel = Panel.new(box_w)

      if @output == STDOUT && STDOUT.tty?
        Salamander::UI.clear_screen
      end

      # 1. Turn Banner & Prompt Card
      turn_title = "#{Theme::TITLE}NIGHTMARE REPL#{Theme::RESET} #{Theme::META_DIM}· TURN #{@turn_number}#{Theme::RESET}"
      status_badge = "#{Theme::TOKEN_BADGE}● CARDS COMPRESSED#{Theme::RESET}"

      @output.puts panel.render_header(turn_title, status_badge, Theme::BORDER)
      prompt_content = "#{Theme::USER_PROMPT}> #{@current_user_prompt}#{Theme::RESET}"
      @output.puts panel.render_row(prompt_content, Theme::BORDER)

      if thought = @agent_thought
        thought_content = "#{Theme::THOUGHT}💭 #{thought}#{Theme::RESET}"
        @output.puts panel.render_row(thought_content, Theme::BORDER)
      end

      total_b = @opened_files.sum(&.size_bytes)
      total_tok = @opened_files.sum(&.tokens)
      stats_content = "#{Theme::META_DIM}Files:#{Theme::RESET} #{@opened_files.size} (#{format_bytes(total_b)}, #{Theme::TOKEN_BADGE}#{format_tokens(total_tok)}#{Theme::RESET}) #{Theme::META_DIM}│ Loaded:#{Theme::RESET} #{total_accumulated_lines}/#{threshold_lines}L #{Theme::META_DIM}│ Layout:#{Theme::RESET} #{box_w}c"
      @output.puts panel.render_divider(Theme::BORDER)
      @output.puts panel.render_row(stats_content, Theme::BORDER)
      @output.puts panel.render_footer(Theme::BORDER)
      @output.puts

      # 2. Grouped Opened Files Deck
      deck_title = "#{Theme::TITLE}📚 Opened Files#{Theme::RESET} #{Theme::META_DIM}(#{@opened_files.size} files · #{format_bytes(total_b)} · #{Theme::TOKEN_BADGE}#{format_tokens(total_tok)}#{Theme::RESET}#{Theme::META_DIM})#{Theme::RESET}"
      badge = "#{Theme::META_DIM}ALL IN ONE BOX#{Theme::RESET}"
      @output.puts panel.render_header(deck_title, badge, Theme::BORDER_ACTIVE)

      @opened_files.each do |f|
        icon = "#{Theme::SUCCESS_ICON}✓#{Theme::RESET}"
        fname = "#{Theme::FILENAME}#{f.path}#{Theme::RESET}"
        meta = "#{Theme::META_DIM}[#{format_bytes(f.size_bytes)} · #{f.lines}L · #{Theme::TOKEN_BADGE}#{format_tokens(f.tokens)}#{Theme::RESET}#{Theme::META_DIM} · #{f.read_range}]#{Theme::RESET}"
        row_str = " #{icon} #{fname} #{meta}"
        @output.puts panel.render_row(row_str, Theme::BORDER_ACTIVE)
      end

      @output.puts panel.render_footer(Theme::BORDER_ACTIVE)
      @output.puts

      # 3. Active File Preview Box
      if active = active_file
        active_lines_count = active.lines
        hi_line = [active_offset + @preview_lines - 1, active_lines_count].min
        prev_title = "#{Theme::TITLE_ACTIVE}🔍 Active Inspection:#{Theme::RESET} #{Theme::FILENAME}#{active.path}#{Theme::RESET} #{Theme::META_DIM}(L#{active_offset}-L#{hi_line} of #{active_lines_count})#{Theme::RESET}"
        prev_badge = "#{Theme::TOKEN_BADGE}#{format_tokens(active.tokens)}#{Theme::RESET}"
        @output.puts panel.render_header(prev_title, prev_badge, Theme::BORDER)

        code_lines = CodePreview.render(
          lines: active.content.lines,
          start_offset: active_offset,
          max_preview_lines: @preview_lines,
          panel: panel,
          border_color: Theme::BORDER
        )
        code_lines.each { |l| @output.puts l }
        @output.puts panel.render_footer(Theme::BORDER)
        @output.puts
      end

      # Action label
      if action = action_label
        @output.puts "  #{Theme::HIGHLIGHT}⚡ Action:#{Theme::RESET} #{action}"
      end
      @output.flush
    end
  end
end
