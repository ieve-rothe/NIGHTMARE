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

    def initialize(@root : String, @input : IO = STDIN, @output : IO = STDOUT)
    end

    # Renders interactive unified diff modal and prompts for line-mode approval
    def approve_diff(diff : String, description : String) : Bool
      @output.puts "\n--- Diff ---".colorize(:cyan).mode(:bold)
      @output.puts Tools::Diff.colorize(diff)
      @output.puts "------------".colorize(:cyan).mode(:bold)
      @output.print "Approve overwrite for #{description}? [y/N/a]: "
      @output.flush

      input = @input.gets.try(&.strip) || ""
      case input.downcase
      when "y", "yes", "a"
        true
      else
        false
      end
    end

    # Renders shell execution approval modal with command, cwd, and timeout details
    def approve_command(
      command : String,
      argv : Array(String),
      has_metachar : Bool,
      timeout_seconds : Int32
    ) : Tuple(Tools::ApprovalOutcome, String?)
      @output.puts "\nCommand: #{command}"
      @output.puts "Cwd:     #{@root}"
      @output.puts "Timeout: #{timeout_seconds}s"
      if has_metachar
        @output.puts "Note: Shell metacharacters cannot be saved to allowlist (will run once)".colorize(:yellow)
      end
      @output.puts "Approvals: [y] once (don't save)  [N] reject  [e] edit  [a] save exact  [p] save prefix"

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
          return {Tools::ApprovalOutcome::AllSession, nil}
        when "p"
          return {Tools::ApprovalOutcome::PrefixSession, nil}
        when "?", "help"
          @output.puts "\nApproval options:"
          @output.puts "  y - Approve once (don't save)"
          @output.puts "  N - Reject command (default)"
          @output.puts "  e - Edit command inline before running once (don't save)"
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
