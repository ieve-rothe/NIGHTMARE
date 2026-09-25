# nightmare/ui/approval.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "colorize"
require "../tools/diff"
require "../tools/shell"
require "../harness/tool_loop"
require "./cancellation"

module Nightmare::UI
  class Approval
    getter root : String
    getter input : IO
    getter output : IO
    property cancellation_check : Proc(Bool)? = nil

    lib LibC
      struct PollFd
        fd : Int32
        events : Int16
        revents : Int16
      end
      POLLIN   = 0x0001_i16
      POLLHUP  = 0x0010_i16
      POLLERR  = 0x0008_i16
      TCIFLUSH =          0

      fun ioctl(fd : Int32, request : UInt64, ...) : Int32
      fun poll(fds : PollFd*, nfds : UInt64, timeout : Int32) : Int32
      fun tcflush(fd : Int32, queue_selector : Int32) : Int32
    end

    def initialize(@root : String, @input : IO = STDIN, @output : IO = STDOUT)
    end

    private def cancelled? : Bool
      if check = @cancellation_check
        check.call
      else
        Nightmare::UI::Cancellation.cancelled?
      end
    end

    # Drains any unconsumed input pending on a FileDescriptor (e.g. STDIN) before prompting
    private def flush_input : Nil
      if fd_io = @input.as?(IO::FileDescriptor)
        LibC.tcflush(fd_io.fd, LibC::TCIFLUSH)
        bytes_avail = 0
        if LibC.ioctl(fd_io.fd, 0x541Bu64, pointerof(bytes_avail)) == 0 && bytes_avail > 0
          buf = Bytes.new(bytes_avail)
          fd_io.read(buf)
        end
      end
    rescue
    end

    # Reads a line of input while cooperatively checking for cancellation interrupts.
    # When cancelled via SIGINT / Cancellation.cancelled?, raises CancelledException
    # immediately instead of blocking the main fiber indefinitely on STDIN.
    private def gets_interactive : String?
      if cancelled?
        flush_input
        raise Harness::CancelledException.new("Turn cancelled by user interrupt")
      end

      if fd_io = @input.as?(IO::FileDescriptor)
        pfd = LibC::PollFd.new(
          fd: fd_io.fd,
          events: LibC::POLLIN | LibC::POLLHUP | LibC::POLLERR,
          revents: 0_i16
        )

        loop do
          if cancelled?
            flush_input
            raise Harness::CancelledException.new("Turn cancelled by user interrupt")
          end

          # Poll with short 50ms timeout to maintain responsive signal checking
          ret = LibC.poll(pointerof(pfd), 1_u64, 50)
          if ret > 0
            break
          end
          Fiber.yield
        end
      end

      if cancelled?
        flush_input
        raise Harness::CancelledException.new("Turn cancelled by user interrupt")
      end

      @input.gets
    end

    # Strips ANSI escape sequences (CSI, OSC, focus tracking, bracketed paste)
    # and ASCII control characters from interactive terminal input.
    private def sanitize_terminal_input(input : String) : String
      clean = input.gsub(/\e\[[0-9;?]*[a-zA-Z~]/, "")
      clean = clean.gsub(/\e\][^\a\e]*(\a|\e\\)/, "").gsub(/\e/, "")
      clean.gsub(/[\x00-\x08\x0B-\x1F\x7F]/, "").strip
    end

    # Renders interactive unified diff modal and prompts for line-mode approval
    def approve_diff(diff : String, description : String) : Bool
      flush_input
      @output.puts "\n--- Diff ---".colorize(:cyan).mode(:bold)
      @output.puts Tools::Diff.colorize(diff)
      @output.puts "------------".colorize(:cyan).mode(:bold)

      loop do
        @output.print "Approve #{description}? [y/N/a]: "
        @output.flush

        raw = gets_interactive
        return false if raw.nil?

        input = sanitize_terminal_input(raw)
        case input.downcase
        when "y", "yes", "a"
          return true
        when "n", "no", ""
          # Default is N on empty/blank enter
          return false
        when "?", "help"
          @output.puts "\nApproval options:"
          @output.puts "  y - Approve file mutation once"
          @output.puts "  N - Reject file mutation (default)"
          @output.puts "  a - Approve file mutation once"
          @output.puts
          next
        else
          @output.puts "Notice: Unrecognized option '#{input}'. Choose [y/N/a] or '?' for help."
          next
        end
      end
    end

    # Splits a compound shell command string on bash separators (&&, ||, ;, |, newlines)
    # into individual sub-commands, preserving the separator tokens for display.
    # Returns an array of {separator, command} tuples. The first entry has an empty separator.
    private def split_shell_commands(command : String) : Array(Tuple(String, String))
      parts = [] of Tuple(String, String)
      # Split on &&, ||, ;, |, or literal \n while preserving delimiters
      segments = command.split(/(\s*(?:&&|\|\||;|\|)\s*|\n)/)
      current_sep = ""
      segments.each do |seg|
        stripped = seg.strip
        if stripped == "&&" || stripped == "||" || stripped == ";" || stripped == "|"
          current_sep = stripped
        elsif seg == "\n"
          current_sep = "↵"
        elsif !stripped.empty?
          parts << {current_sep, stripped}
          current_sep = ""
        end
      end
      parts = [{"", command.strip}] if parts.empty?
      parts
    end

    # Applies bash-aware syntax coloring to a single command string.
    # Colors: executable in highlight/bold, flags in cyan, strings in green,
    # env vars in violet, redirects in yellow, rest in code_text.
    private def colorize_command(cmd : String) : String
      theme = Salamander::UI::Theme
      result = IO::Memory.new
      tokens = cmd.split(/(\s+)/)
      is_first_word = true

      tokens.each do |token|
        if token =~ /\A\s+\z/
          result << token
        elsif token =~ /\A[A-Z_][A-Z0-9_]*=/ # ENV_VAR=value
          result << "#{theme.token_badge}#{token}#{Salamander::UI::Theme::RESET}"
        elsif is_first_word
          # Executable / command name — bold highlight
          result << "#{Salamander::UI::Theme::BOLD}#{theme.highlight}#{token}#{Salamander::UI::Theme::RESET}"
          is_first_word = false
        elsif token.starts_with?('-')
          # Flags
          result << "#{theme.status_tag}#{token}#{Salamander::UI::Theme::RESET}"
        elsif token.starts_with?('"') || token.starts_with?('\'')
          # Quoted strings
          result << "#{theme.success_icon}#{token}#{Salamander::UI::Theme::RESET}"
        elsif token =~ /\A[>|<&]+\z/ || token =~ /\A\d*[>|<&]+/
          # Redirects
          result << "#{theme.filename}#{token}#{Salamander::UI::Theme::RESET}"
        elsif token.starts_with?('$') || token.starts_with?("${")
          # Shell variables
          result << "#{theme.token_badge}#{token}#{Salamander::UI::Theme::RESET}"
        else
          result << "#{theme.code_text}#{token}#{Salamander::UI::Theme::RESET}"
        end
      end
      result.to_s
    end

    # Renders shell execution approval modal with command, cwd, and timeout details.
    # The command is split on bash separators and each sub-command is displayed on
    # its own line with syntax coloring for quick human parsing.
    def approve_command(
      command : String,
      argv : Array(String),
      has_metachar : Bool,
      timeout_seconds : Int32
    ) : Tuple(Tools::ApprovalOutcome, String?)
      flush_input
      term_w = Salamander::UI.terminal_width
      box_w = Salamander::UI::Panel.clamp_width(term_w, 105)
      panel = Salamander::UI::Panel.new(box_w, Salamander::UI::BoxStyle::Armored)
      border = Salamander::UI::Theme.border_active
      header_title = "#{Salamander::UI::Theme.title_active}⚡ SECURITY GATEWAY // SHELL EXECUTION#{Salamander::UI::Theme::RESET}"
      header_badge = "#{Salamander::UI::Theme.token_badge}#{timeout_seconds}s timeout#{Salamander::UI::Theme::RESET}"

      sanitized_cmd = command.gsub('\r', "\\r").gsub('\e', "\\e")

      @output.puts
      @output.puts panel.render_header(header_title, header_badge, border, Salamander::UI::BoxStyle::Armored)

      # Split compound commands and render each on its own line with syntax coloring
      sub_cmds = split_shell_commands(sanitized_cmd)
      sep_color = Salamander::UI::Theme.meta_dim
      if sub_cmds.size == 1
        # Single command — inline label
        colored = colorize_command(sub_cmds[0][1])
        @output.puts panel.render_row("Command: #{colored}", border, Salamander::UI::BoxStyle::Armored)
      else
        # Multiple sub-commands — one per line with separator glyphs
        @output.puts panel.render_row("Command:", border, Salamander::UI::BoxStyle::Armored)
        sub_cmds.each_with_index do |(sep, sub_cmd), i|
          colored = colorize_command(sub_cmd)
          if i == 0
            @output.puts panel.render_row("  #{colored}", border, Salamander::UI::BoxStyle::Armored)
          else
            @output.puts panel.render_row("  #{sep_color}#{sep}#{Salamander::UI::Theme::RESET} #{colored}", border, Salamander::UI::BoxStyle::Armored)
          end
        end
      end

      @output.puts panel.render_row("Cwd:     #{Salamander::UI::Theme.filename}#{@root}#{Salamander::UI::Theme::RESET}", border, Salamander::UI::BoxStyle::Armored)
      @output.puts panel.render_row("Timeout: #{timeout_seconds}s", border, Salamander::UI::BoxStyle::Armored)
      if has_metachar
        note = "Note: Shell metacharacters cannot be saved as prefix [p]; [a] saves exact command".colorize(:yellow).to_s
        @output.puts panel.render_row(note, border, Salamander::UI::BoxStyle::Armored)
      end
      @output.puts panel.render_divider(border, Salamander::UI::BoxStyle::Armored)
      @output.puts panel.render_row("Approvals: [y] once (don't save)  [N] reject  [e] edit  [a] save exact  [p] save prefix", border, Salamander::UI::BoxStyle::Armored)
      @output.puts panel.render_footer(border, Salamander::UI::BoxStyle::Armored)
      flush_input
      loop do
        @output.print "Approve command? [y/N/e/a/p]: "
        @output.flush

        raw = gets_interactive
        return {Tools::ApprovalOutcome::No, nil} if raw.nil?

        input = sanitize_terminal_input(raw)
        case input.downcase
        when "y", "yes"
          return {Tools::ApprovalOutcome::Yes, nil}
        when "n", "no", ""
          return {Tools::ApprovalOutcome::No, nil}
        when "e"
          @output.print "Edit command: "
          @output.flush
          edited_raw = gets_interactive
          edited = edited_raw ? sanitize_terminal_input(edited_raw) : ""
          return {Tools::ApprovalOutcome::Edit, edited}
        when "a"
          return {Tools::ApprovalOutcome::AllSession, nil}
        when "p"
          if has_metachar
            @output.puts "Notice: Prefix cannot be saved for compound commands. Running once without saving."
          end
          return {Tools::ApprovalOutcome::PrefixSession, nil}
        when "?", "help"
          @output.puts "\nApproval options:"
          @output.puts "  y - Approve once (don't save)"
          @output.puts "  N - Reject command (default)"
          @output.puts "  e - Edit command inline (re-prompts for approval before running)"
          @output.puts "  a - Save exact command to allowlist (auto-approved in future)"
          @output.puts "  p - Save command prefix to allowlist (commands matching prefix auto-approved in future)"
          @output.puts
          next
        else
          @output.puts "Notice: Unrecognized option '#{input}'. Choose [y/N/e/a/p] or '?' for help."
          next
        end
      end
    end
  end
end
