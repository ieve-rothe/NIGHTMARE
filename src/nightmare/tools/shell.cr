# nightmare/tools/shell.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "process"
require "json"
require "../config"
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

    def initialize(
      @guard : Guard,
      @allowlist : Allowlist = Allowlist.new,
      @approval_handler : Proc(String, Array(String), Bool, Int32, Tuple(ApprovalOutcome, String?))? = nil
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

      raw_to = timeout_seconds || Config::SHELL_COMMAND_TIMEOUT_SECONDS
      clamped_to = Math.min(Config::SHELL_COMMAND_MAX_TIMEOUT_SECONDS, raw_to)
      effective_timeout_sec = Math.max(1, clamped_to)

      loop do
        argv = begin
          Allowlist.tokenize(cmd_to_run)
        rescue ex
          return {error: "Tokenization error: #{ex.message}"}.to_json
        end

        return {error: "Command cannot be empty"}.to_json if argv.empty?

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
                edited_argv = begin
                  Allowlist.tokenize(cmd_to_run)
                rescue ex
                  return {error: "Tokenization error: #{ex.message}"}.to_json
                end
                return execute_process_group(cmd_to_run, edited_argv, effective_timeout_sec)
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
      timeout = if req = requested_timeout
        Math.min(req.seconds, Config::MAX_COMMAND_TIMEOUT)
      else
        Config::DEFAULT_COMMAND_TIMEOUT
      end

      # Environment per ARCHITECTURE_R3 §4.3
      env = {
        "GIT_TERMINAL_PROMPT" => "0",
        "CI"                  => "1",
        "PAGER"               => "cat",
        "GIT_PAGER"           => "cat",
        "NO_COLOR"            => "1",
        "TERM"                => "dumb"
      }

      # Launch under setsid -w to establish independent session & process group
      has_setsid = File.exists?("/usr/bin/setsid") || File.exists?("/bin/setsid")
      setsid_bin = File.exists?("/usr/bin/setsid") ? "/usr/bin/setsid" : "/bin/setsid"

      executable = has_setsid ? setsid_bin : "/bin/bash"
      cmd_args = has_setsid ? ["-w", "/bin/bash", "-c", command_string] : ["-c", command_string]

      dev_null = File.open("/dev/null", "r")

      process = begin
        Process.new(
          executable,
          args: cmd_args,
          chdir: @guard.root,
          env: env,
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
      max_stream_bytes = Config::TOOL_OUTPUT_MAX_BYTES // 2

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

        timed_out = false
        final_status : Process::Status? = nil

        select
        when status = exit_status_channel.receive
          final_status = status
        when timeout(timeout)
          timed_out = true
          final_status = terminate_process_group(pgid, exit_status_channel)
        end

        stdout_done.receive rescue nil
        stderr_done.receive rescue nil

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
          if (st = final_status) && !st.success?
            io << "\n" unless io.empty? || out_str.ends_with?('\n') || err_str.ends_with?('\n')
            io << "[Process exited with code #{st.exit_code}]"
          end
        end
      ensure
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
      # Termination ladder: SIGTERM -> grace -> SIGKILL to -pgid (T9 / §4.3)
      begin
        LibC.kill(-pgid.to_i32, Signal::TERM.value)
      rescue
      end

      # Wait for child to exit on SIGTERM up to grace period
      if ch = exit_status_channel
        select
        when st = ch.receive
          return st
        when timeout(Config::PROCESS_GRACE_PERIOD)
        end
      else
        sleep 50.milliseconds
      end

      begin
        LibC.kill(-pgid.to_i32, Signal::KILL.value)
      rescue
      end

      if ch = exit_status_channel
        select
        when st = ch.receive
          return st
        when timeout(200.milliseconds)
          return nil
        end
      end
      nil
    end
  end
end
