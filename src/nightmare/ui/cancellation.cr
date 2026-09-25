# nightmare/ui/cancellation.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "../harness/tool_loop"
require "../tools/shell"

module Nightmare::UI
  class Cancellation
    class_property current_instance : Cancellation? = nil

    property? busy : Bool = false
    property? sigint_received : Bool = false
    property last_sigint_at : Time::Instant? = nil

    getter tool_loop : Harness::ToolLoop
    getter shell : Tools::Shell

    def initialize(@tool_loop : Harness::ToolLoop, @shell : Tools::Shell)
      @@current_instance = self
    end

    def self.cancelled? : Bool
      if inst = @@current_instance
        inst.cancelled?
      else
        false
      end
    end

    def self.cancel! : Nil
      if inst = @@current_instance
        inst.sigint_received = true
        inst.tool_loop.cancelled = true
      end
    end

    def cancelled? : Bool
      @tool_loop.cancelled? || @sigint_received
    end

    def self.install_early_trap : Nil
      Signal::INT.trap do
        if inst = @@current_instance
          inst.handle_sigint
        end
      end
    end

    def handle_sigint : Nil
      @sigint_received = true
      now = Time.instant

      if @busy
        # Check double Ctrl+C within 1.5s while busy -> emergency force exit
        if (last = @last_sigint_at) && (now - last) < 1.5.seconds
          puts "\n[Double interrupt received; exiting immediately]"
          STDOUT.flush
          exit(130)
        end
        @last_sigint_at = now

        flush_stdin
        # Active turn/tool running -> cancel cooperatively (D3 / §5 Pipeline 5)
        @tool_loop.cancelled = true
        @shell.kill_active_process!
        Tools::Shell.kill_all_active!
        puts "\n[Interrupt received; cancelling active turn...]"
        STDOUT.flush
      else
        # Idle at prompt -> flush any partially typed input
        flush_stdin
        # Check double Ctrl+C within 1.5s
        if (last = @last_sigint_at) && (now - last) < 1.5.seconds
          puts "\nExiting."
          exit(0)
        else
          @last_sigint_at = now
          puts "\n(Press Ctrl+C again to exit, or type /exit)"
          print "> "
          STDOUT.flush
        end
      end
    end

    lib LibC
      TCIFLUSH = 0
      fun ioctl(fd : Int32, request : UInt64, ...) : Int32
      fun tcflush(fd : Int32, queue_selector : Int32) : Int32
    end

    private def flush_stdin : Nil
      LibC.tcflush(STDIN.fd, LibC::TCIFLUSH)
      bytes_avail = 0
      if LibC.ioctl(STDIN.fd, 0x541Bu64, pointerof(bytes_avail)) == 0 && bytes_avail > 0
        buf = Bytes.new(bytes_avail)
        STDIN.read(buf)
      end
    rescue
    end
  end
end

Nightmare::UI::Cancellation.install_early_trap
