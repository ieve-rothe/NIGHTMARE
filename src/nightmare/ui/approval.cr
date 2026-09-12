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
      @output.print "Approve command? [y/N/e/a/p]: "
      @output.flush

      input = @input.gets.try(&.strip) || ""
      case input.downcase
      when "y", "yes"
        {Tools::ApprovalOutcome::Yes, nil}
      when "e"
        @output.print "Edit command: "
        @output.flush
        edited = @input.gets.try(&.strip) || ""
        {Tools::ApprovalOutcome::Edit, edited}
      when "a"
        {Tools::ApprovalOutcome::AllSession, nil}
      when "p"
        {Tools::ApprovalOutcome::PrefixSession, nil}
      else
        {Tools::ApprovalOutcome::No, nil}
      end
    end
  end
end
