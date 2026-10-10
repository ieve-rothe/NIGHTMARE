# nightmare/tools/shell.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "process"
require "json"
require "../config"
require "../plan/run_state"
require "./guard"
require "./allowlist"

module Nightmare::Tools
  enum ApprovalOutcome
    Yes
    No
    AllSession
    PrefixSession
    PrefixPersist
    Edit
  end

  class Shell
    class_property active_pgids : Array(Int64) = [] of Int64

    getter guard : Guard
    getter allowlist : Allowlist
    property approval_handler : Proc(String, Array(String), Bool, Int32, Tuple(ApprovalOutcome, String?))?
    property execution_policy : Mantle::Tools::ExecutionPolicy?
    property active_side_effects : Array(String)?
    property current_pgid : Int64? = nil
    property subagent_mode : Bool = false
    property default_timeout_seconds : Int32
    property max_timeout_seconds : Int32
    property tool_output_max_bytes : Int32
    property executed_commands : Array(Nightmare::Plan::ExecutedCommand) = [] of Nightmare::Plan::ExecutedCommand

    def self.kill_all_active! : Nil
      Mantle::Tools::ProcessGroupSupervisor.kill_all_active!
      pgids = @@active_pgids.dup
      pgids.each do |pgid|
        terminate_process_group_id(pgid)
      end
    end

    def self.terminate_process_group_id(pgid : Int64) : Nil
      begin
        LibC.kill(-pgid.to_i32, Signal::TERM.value)
      rescue
      end
      sleep Config::PROCESS_GRACE_PERIOD
      begin
        LibC.kill(-pgid.to_i32, Signal::KILL.value)
      rescue
      end
    rescue
    end

    getter supervisor : Mantle::Tools::ProcessGroupSupervisor

    def initialize(
      @guard : Guard,
      @allowlist : Allowlist = Allowlist.new,
      @approval_handler : Proc(String, Array(String), Bool, Int32, Tuple(ApprovalOutcome, String?))? = nil,
      @subagent_mode : Bool = false,
      @default_timeout_seconds : Int32 = Config::SHELL_COMMAND_TIMEOUT_SECONDS,
      @max_timeout_seconds : Int32 = Config::SHELL_COMMAND_MAX_TIMEOUT_SECONDS,
      @tool_output_max_bytes : Int32 = Config::TOOL_OUTPUT_MAX_BYTES,
      @execution_policy : Mantle::Tools::ExecutionPolicy? = nil,
    )
      @supervisor = Mantle::Tools::ProcessGroupSupervisor.new(
        default_timeout: @default_timeout_seconds.seconds,
        max_timeout: @max_timeout_seconds.seconds,
        grace_period: Config::PROCESS_GRACE_PERIOD,
        max_output_bytes: @tool_output_max_bytes
      )
    end

    def kill_active_process! : Nil
      if pg = @current_pgid
        @supervisor.terminate_process_group(pg)
      end
    end

    # Executes shell command via argv within process group supervisor and concurrent capped drain
    def run_command(command : String, timeout_seconds : Int32? = nil) : String
      cmd_to_run = command

      raw_to = timeout_seconds || @default_timeout_seconds
      clamped_to = Math.min(@max_timeout_seconds, raw_to)
      effective_timeout_sec = Math.max(1, clamped_to)

      loop do
        argv = begin
          Allowlist.tokenize(cmd_to_run)
        rescue ex
          return {error: "Tokenization error: #{ex.message}"}.to_json
        end

        return {error: "Command cannot be empty"}.to_json if argv.empty?

        if @subagent_mode && argv.first? == "git"
          if Mantle::Subagents::Supervisor.git_mutation_command?(argv)
            subcmd = argv.skip(1).find { |arg| !arg.starts_with?('-') }
            return {error: "Git mutation command '#{subcmd}' is forbidden in subagent mode. Only read-only inspection commands (git status, git diff, git log, git rev-parse) are permitted."}.to_json
          end
        end

        has_metachar = Allowlist.contains_metacharacters?(cmd_to_run)
        has_denylisted = Allowlist.has_denylisted_flags?(argv)
        is_auto = @allowlist.auto_approvable?(cmd_to_run, argv)

        unless is_auto
          if policy = @execution_policy
            req = Mantle::Tools::ExecutionRequest.new(
              tool_name: "bash",
              command: cmd_to_run,
              argv: argv,
              has_metacharacters: has_metachar,
              timeout_seconds: effective_timeout_sec
            )
            decision = policy.call(req)
            case decision.kind
            when Mantle::Tools::PolicyDecisionKind::Deny
              return "[Execution rejected by user]"
            when Mantle::Tools::PolicyDecisionKind::AllowSession
              @allowlist.allow_session_exact(cmd_to_run)
              @allowlist.allow_persist_exact(cmd_to_run)
            when Mantle::Tools::PolicyDecisionKind::AllowPrefixSession, Mantle::Tools::PolicyDecisionKind::AllowPrefixPersist
              unless has_metachar
                prefix_to_save = decision.edited_value || Allowlist.candidate_prefix(argv)
                @allowlist.allow_session_prefix(prefix_to_save)
                @allowlist.allow_persist_prefix(prefix_to_save)
              end
            when Mantle::Tools::PolicyDecisionKind::Edit
              if edited = decision.edited_value
                cmd_to_run = edited
                next
              else
                return "[Execution rejected by user]"
              end
            when Mantle::Tools::PolicyDecisionKind::Allow
              # Approved once
            end
          elsif handler = @approval_handler
            outcome, edit_value = handler.call(cmd_to_run, argv, has_metachar, effective_timeout_sec)
            case outcome
            when ApprovalOutcome::No
              return "[Execution rejected by user]"
            when ApprovalOutcome::AllSession
              @allowlist.allow_session_exact(cmd_to_run)
              @allowlist.allow_persist_exact(cmd_to_run)
            when ApprovalOutcome::PrefixSession, ApprovalOutcome::PrefixPersist
              unless has_metachar
                prefix_to_save = edit_value || Allowlist.candidate_prefix(argv)
                @allowlist.allow_session_prefix(prefix_to_save)
                @allowlist.allow_persist_prefix(prefix_to_save)
              end
            when ApprovalOutcome::Edit
              if edited = edit_value
                cmd_to_run = edited
                next
              else
                return "[Execution rejected by user]"
              end
            when ApprovalOutcome::Yes
              # Approved once
            end
          else
            return "[Execution rejected by user]"
          end
        end

        # Approved or auto-approvable: execute in isolated process group
        return execute_process_group(cmd_to_run, argv, effective_timeout_sec)
      end
    end

    private def execute_process_group(command_string : String, argv : Array(String), requested_timeout : Int32?) : String
      start_time = Time.instant
      to_span = if req = requested_timeout
        Math.min(req.seconds, Config::MAX_COMMAND_TIMEOUT)
      else
        Config::DEFAULT_COMMAND_TIMEOUT
      end

      res = begin
        @supervisor.execute(
          command: command_string,
          cwd: @guard.root,
          timeout: to_span,
          max_output_bytes: @tool_output_max_bytes
        ) do |pgid|
          @current_pgid = pgid
          Shell.active_pgids << pgid
        end
      rescue ex : File::Error
        return {error: "Failed to spawn process after CWD re-anchoring: #{ex.message}"}.to_json
      rescue ex
        return {error: "Failed to spawn process: #{ex.message}"}.to_json
      ensure
        if pg = @current_pgid
          Shell.active_pgids.delete(pg)
          @current_pgid = nil
        end
      end

      duration_ms = (Time.instant - start_time).total_milliseconds.to_i64

      if res[:timed_out]
        @executed_commands << Nightmare::Plan::ExecutedCommand.new(
          cmd: argv,
          exit_code: 124,
          duration_ms: duration_ms
        )
        return "[Execution timed out after #{to_span.total_seconds.to_i} seconds]"
      end

      out_str = res[:stdout]
      err_str = res[:stderr]

      out_lines = out_str.lines
      if out_lines.size > 300
        truncated_out = out_lines[0...300].join("\n")
        out_str = "#{truncated_out}\n[... #{out_lines.size - 300} lines omitted; output truncated]"
      end

      formatted = String.build do |io|
        io << out_str
        if !err_str.empty?
          io << "\n" unless out_str.empty? || out_str.ends_with?('\n')
          io << "STDERR:\n"
          io << err_str
        end
        if (st = res[:status]) && !st.success? && st.normal_exit?
          io << "\n" unless io.empty? || out_str.ends_with?('\n') || err_str.ends_with?('\n')
          io << "[Process exited with code #{st.exit_code}]"
        end
      end

      exit_code = if (st = res[:status]) && st.normal_exit?
                    st.exit_code
                  else
                    -1
                  end
      @executed_commands << Nightmare::Plan::ExecutedCommand.new(
        cmd: argv,
        exit_code: exit_code,
        duration_ms: duration_ms
      )

      Guard.cap_output(formatted, max_bytes: @tool_output_max_bytes)
    end

    private def terminate_process_group(pgid : Int64) : Process::Status?
      @supervisor.terminate_process_group(pgid)
    end
  end
end
