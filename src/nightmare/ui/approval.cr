# nightmare/ui/approval.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "../tools/shell"

module Nightmare::UI
  class Approval
    getter root : String

    def initialize(@root : String)
    end

    # Renders interactive unified diff modal and prompts for line-mode approval
    def approve_diff(diff : String, description : String) : Bool
      puts "\n--- Diff ---"
      puts diff
      puts "------------"
      print "Approve overwrite for #{description}? [y/N/a]: "
      STDOUT.flush

      input = STDIN.gets.try(&.strip) || ""
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
      puts "\nCommand: #{command}"
      puts "Cwd:     #{@root}"
      puts "Timeout: #{timeout_seconds}s"
      print "Approve command? [y/N/e/a/p]: "
      STDOUT.flush

      input = STDIN.gets.try(&.strip) || ""
      case input.downcase
      when "y", "yes"
        {Tools::ApprovalOutcome::Yes, nil}
      when "e"
        print "Edit command: "
        STDOUT.flush
        edited = STDIN.gets.try(&.strip) || ""
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
