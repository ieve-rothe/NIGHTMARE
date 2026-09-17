# nightmare/ui/approval.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "colorize"
require "../tools/diff"
require "../tools/shell"

module Nightmare::UI
  class Approval
    getter root : String
    getter input : IO
    getter output : IO

    lib LibC
      fun ioctl(fd : Int32, request : UInt64, ...) : Int32
    end

    def initialize(@root : String, @input : IO = STDIN, @output : IO = STDOUT)
    end

    # Drains any unconsumed input pending on a FileDescriptor (e.g. STDIN) before prompting
    private def flush_input : Nil
      if fd_io = @input.as?(IO::FileDescriptor)
        bytes_avail = 0
        if LibC.ioctl(fd_io.fd, 0x541Bu64, pointerof(bytes_avail)) == 0 && bytes_avail > 0
          buf = Bytes.new(bytes_avail)
          fd_io.read(buf)
        end
      end
    rescue
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

        input = @input.gets.try(&.strip) || ""
        case input.downcase
        when "y", "yes", "a"
          return true
        when "n", "no"
          return false
        when ""
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
          return false
        end
      end
    end

    # Renders shell execution approval modal with command, cwd, and timeout details
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
      sanitized_argv = argv.map { |a| a.gsub('\r', "\\r").gsub('\e', "\\e") }

      @output.puts
      @output.puts panel.render_header(header_title, header_badge, border, Salamander::UI::BoxStyle::Armored)
      @output.puts panel.render_row("Command: #{sanitized_cmd}", border, Salamander::UI::BoxStyle::Armored)
      @output.puts panel.render_row("Argv:    #{sanitized_argv.join(" ")}", border, Salamander::UI::BoxStyle::Armored)
      @output.puts panel.render_row("Cwd:     #{@root}", border, Salamander::UI::BoxStyle::Armored)
      @output.puts panel.render_row("Timeout: #{timeout_seconds}s", border, Salamander::UI::BoxStyle::Armored)
      if has_metachar
        note = "Note: Shell metacharacters cannot be saved to allowlist (will run once)".colorize(:yellow).to_s
        @output.puts panel.render_row(note, border, Salamander::UI::BoxStyle::Armored)
      end
      @output.puts panel.render_divider(border, Salamander::UI::BoxStyle::Armored)
      @output.puts panel.render_row("Approvals: [y] once (don't save)  [N] reject  [e] edit  [a] save exact  [p] save prefix", border, Salamander::UI::BoxStyle::Armored)
      @output.puts panel.render_footer(border, Salamander::UI::BoxStyle::Armored)

      loop do
        @output.print "Approve command? [y/N/e/a/p]: "
        @output.flush

        input = @input.gets.try(&.strip) || ""
        case input.downcase
        when "y", "yes"
          return {Tools::ApprovalOutcome::Yes, nil}
        when "e"
          @output.print "Edit command: "
          @output.flush
          edited = @input.gets.try(&.strip) || ""
          return {Tools::ApprovalOutcome::Edit, edited}
        when "a"
          if has_metachar
            @output.puts "Notice: Shell metacharacters cannot be saved to allowlist. Running once without saving."
          end
          return {Tools::ApprovalOutcome::AllSession, nil}
        when "p"
          if has_metachar
            @output.puts "Notice: Shell metacharacters cannot be saved to allowlist. Running once without saving."
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
          return {Tools::ApprovalOutcome::No, nil}
        end
      end
    end
  end
end
