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
    getter guard : Guard
    getter allowlist : Allowlist
    property approval_handler : Proc(String, Array(String), Bool, Int32, Tuple(ApprovalOutcome, String?))?
    property active_side_effects : Array(String)?
    property current_pgid : Int64? = nil
    property subagent_mode : Bool = false
    property default_timeout_seconds : Int32
    property max_timeout_seconds : Int32
    property tool_output_max_bytes : Int32
    property executed_commands : Array(Nightmare::Plan::ExecutedCommand) = [] of Nightmare::Plan::ExecutedCommand

    def initialize(
      @guard : Guard,
      @allowlist : Allowlist = Allowlist.new,
      @approval_handler : Proc(String, Array(String), Bool, Int32, Tuple(ApprovalOutcome, String?))? = nil,
      @subagent_mode : Bool = false,
      @default_timeout_seconds : Int32 = Config::SHELL_COMMAND_TIMEOUT_SECONDS,
      @max_timeout_seconds : Int32 = Config::SHELL_COMMAND_MAX_TIMEOUT_SECONDS,
      @tool_output_max_bytes : Int32 = Config::TOOL_OUTPUT_MAX_BYTES
    )
    end

    def kill_active_process! : Nil
      if pg = @current_pgid
        terminate_process_group(pg)
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
          subcmd = argv.skip(1).find { |arg| !arg.starts_with?('-') }
          allowed_git = {"status", "diff", "log", "rev-parse", "show"}
          if subcmd && !allowed_git.includes?(subcmd)
            return {error: "Git mutation command '#{subcmd}' is forbidden in subagent mode. Only read-only inspection commands (git status, git diff, git log, git rev-parse) are permitted."}.to_json
          end
        end

        has_metachar = Allowlist.contains_metacharacters?(cmd_to_run)
        has_denylisted = Allowlist.has_denylisted_flags?(argv)
        is_auto = !has_metachar && !has_denylisted && @allowlist.matches?(argv)

        unless is_auto
          if handler = @approval_handler
            outcome, edit_value = handler.call(cmd_to_run, argv, has_metachar, effective_timeout_sec)
            case outcome
            when ApprovalOutcome::No
              return "[Execution rejected by user]"
            when ApprovalOutcome::AllSession
              unless has_metachar
                @allowlist.allow_session_exact(argv)
                @allowlist.allow_persist_exact(argv)
              end
            when ApprovalOutcome::PrefixSession
              unless has_metachar
                @allowlist.allow_session_prefix(argv)
                @allowlist.allow_persist_prefix(argv)
              end
            when ApprovalOutcome::PrefixPersist
              unless has_metachar
                @allowlist.allow_session_prefix(argv)
                @allowlist.allow_persist_prefix(argv)
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
      timed_out = false
      final_status : Process::Status? = nil

      timeout = if req = requested_timeout
        Math.min(req.seconds, Config::MAX_COMMAND_TIMEOUT)
      else
        Config::DEFAULT_COMMAND_TIMEOUT
      end

      # Environment per ARCHITECTURE_R3 §4.3 & Security Hardening (VULN-01)
      # clear_env: true prevents parent process API keys and secrets from leaking into child processes.
      env = {
        "PATH"                => ENV["PATH"]? || "/usr/local/bin:/usr/bin:/bin",
        "HOME"                => ENV["HOME"]? || "/root",
        "USER"                => ENV["USER"]? || "user",
        "GIT_TERMINAL_PROMPT" => "0",
        "CI"                  => "1",
        "PAGER"               => "cat",
        "GIT_PAGER"           => "cat",
        "NO_COLOR"            => "1",
        "TERM"                => "dumb",
        "TMPDIR"              => ENV["TMPDIR"]? || "/tmp"
      }

      # Launch via direct argv (ARCHITECTURE_R3 §4.2)
      # Launch under setsid -w to establish independent session & process group
      has_setsid = File.exists?("/usr/bin/setsid") || File.exists?("/bin/setsid")
      setsid_bin = File.exists?("/usr/bin/setsid") ? "/usr/bin/setsid" : "/bin/setsid"

      executable = has_setsid ? setsid_bin : argv[0]
      cmd_args = has_setsid ? (["-w", argv[0]] + argv[1..]) : argv[1..]

      dev_null = File.open("/dev/null", "r")

      process = begin
        Process.new(
          executable,
          args: cmd_args,
          chdir: @guard.root,
          env: env,
          clear_env: true,
          input: dev_null,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe
        )
      rescue ex
        dev_null.close
        return {error: "Failed to spawn process: #{ex.message}"}.to_json
      ensure
        dev_null.close rescue nil
      end

      pgid = process.pid
      @current_pgid = pgid.to_i64
      max_stream_bytes = @tool_output_max_bytes // 2

      stdout_io = IO::Memory.new
      stderr_io = IO::Memory.new
      stdout_done = Channel(Nil).new
      stderr_done = Channel(Nil).new

      begin
        # Concurrent drain of stdout and stderr to prevent pipe deadlocks (T10)
        spawn do
          drain_stream(process.output, stdout_io, max_stream_bytes)
          stdout_done.send(nil)
        end

        spawn do
          drain_stream(process.error, stderr_io, max_stream_bytes)
          stderr_done.send(nil)
        end

        # Supervise with timeout
        exit_status_channel = Channel(Process::Status).new
        spawn do
          status = process.wait
          exit_status_channel.send(status)
        end

        select
        when status = exit_status_channel.receive
          final_status = status
        when timeout(timeout)
          timed_out = true
          final_status = terminate_process_group(pgid, exit_status_channel)
        end

        # Drain output streams with grace period, then force-close to prevent grandchild pipe deadlocks (VULN-07)
        select
        when stdout_done.receive
        when timeout(100.milliseconds)
          process.output.close rescue nil
        end

        select
        when stderr_done.receive
        when timeout(100.milliseconds)
          process.error.close rescue nil
        end

        if timed_out
          return "[Execution timed out after #{timeout.total_seconds.to_i} seconds]"
        end

        out_str = stdout_io.to_s
        err_str = stderr_io.to_s

        out_lines = out_str.lines
        if out_lines.size > 300
          truncated_out = out_lines[0...300].join("\n")
          out_str = "#{truncated_out}\n[... #{out_lines.size - 300} lines omitted; output truncated]"
        end

        String.build do |io|
          io << out_str
          if !err_str.empty?
            io << "\n" unless out_str.empty? || out_str.ends_with?('\n')
            io << "STDERR:\n"
            io << err_str
          end
          if (st = final_status) && !st.success? && st.normal_exit?
            io << "\n" unless io.empty? || out_str.ends_with?('\n') || err_str.ends_with?('\n')
            io << "[Process exited with code #{st.exit_code}]"
          end
        end
      ensure
        process.output.close rescue nil
        process.error.close rescue nil

        duration_ms = (Time.instant - start_time).total_milliseconds.to_i64
        exit_code = if (st = final_status) && st.normal_exit?
                      st.exit_code
                    elsif timed_out
                      124
                    else
                      -1
                    end
        @executed_commands << Nightmare::Plan::ExecutedCommand.new(
          cmd: argv,
          exit_code: exit_code,
          duration_ms: duration_ms
        )
        @current_pgid = nil
      end
    end

    private def drain_stream(pipe : IO, sink : IO::Memory, max_bytes : Int32) : Nil
      buffer = Bytes.new(4096)
      total_read = 0
      truncated = false

      loop do
        bytes_read = pipe.read(buffer)
        break if bytes_read == 0

        if total_read + bytes_read <= max_bytes
          sink.write(buffer[0, bytes_read])
          total_read += bytes_read
        else
          if !truncated
            remaining = max_bytes - total_read
            sink.write(buffer[0, remaining]) if remaining > 0
            sink << "\n[... stream truncated at #{max_bytes} bytes; output truncated]"
            truncated = true
          end
          # continue draining pipe to avoid blocking child
        end
      end
    rescue
      # Pipe closed or interrupted
    ensure
      pipe.close rescue nil
    end

    private def terminate_process_group(pgid : Int64, exit_status_channel : Channel(Process::Status)? = nil) : Process::Status?
      # Termination ladder: SIGTERM -> grace -> SIGKILL to -pgid (T9 / §4.3 / VULN-06)
      begin
        LibC.kill(-pgid.to_i32, Signal::TERM.value)
      rescue
      end

      st : Process::Status? = nil
      # Wait for child to exit on SIGTERM up to grace period
      if ch = exit_status_channel
        select
        when s = ch.receive
          st = s
        when timeout(Config::PROCESS_GRACE_PERIOD)
        end
      else
        sleep Config::PROCESS_GRACE_PERIOD
      end

      # Always send SIGKILL to the process group to ensure any descendants ignoring SIGTERM are eliminated
      begin
        LibC.kill(-pgid.to_i32, Signal::KILL.value)
      rescue
      end

      if ch = exit_status_channel
        if st.nil?
          select
          when s = ch.receive
            st = s
          when timeout(200.milliseconds)
          end
        end
      end
      st
    end
  end
end
