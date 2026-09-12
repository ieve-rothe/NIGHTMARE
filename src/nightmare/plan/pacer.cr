# nightmare/plan/pacer.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

module Nightmare::Plan
  class Pacer
    property inter_item_pacing_seconds : Float64
    property inter_turn_pacing_seconds : Float64
    property thermal_ceiling_celsius : Int32
    property thermal_resume_celsius : Int32
    property thermal_poll_interval_seconds : Float64

    @last_thermal_check : Time::Instant?

    def initialize(
      @inter_item_pacing_seconds : Float64 = 3.0,
      @inter_turn_pacing_seconds : Float64 = 0.5,
      @thermal_ceiling_celsius : Int32 = 80,
      @thermal_resume_celsius : Int32 = 70,
      @thermal_poll_interval_seconds : Float64 = 20.0
    )
      @last_thermal_check = nil
    end

    # Enforces item-level breathing room
    def pace_item : Nil
      if @inter_item_pacing_seconds > 0.0
        sleep @inter_item_pacing_seconds.seconds
      end
      check_thermal_rail
    end

    # Enforces turn-level micro-breather
    def pace_turn : Nil
      if @inter_turn_pacing_seconds > 0.0
        sleep @inter_turn_pacing_seconds.seconds
      end
    end

    # Checks GPU thermal rail throttled to at most once every thermal_poll_interval_seconds
    def check_thermal_rail : Nil
      now = Time.instant
      if last = @last_thermal_check
        if (now - last) < @thermal_poll_interval_seconds.seconds
          return # Throttled: don't fork nvidia-smi too frequently
        end
      end

      @last_thermal_check = now
      temp = query_gpu_temperature
      return unless temp

      if temp >= @thermal_ceiling_celsius
        puts "\n[Thermal rail tripwire: GPU at #{temp}°C >= #{@thermal_ceiling_celsius}°C. Pausing execution to cool down...]"
        STDOUT.flush

        while temp && temp >= @thermal_resume_celsius
          sleep 5.seconds
          temp = query_gpu_temperature
        end

        puts "[Thermal rail cleared: GPU settled to #{temp}°C. Resuming execution.]"
        STDOUT.flush
      end
    end

    # Queries temperature from nvidia-smi or Linux sysfs
    def query_gpu_temperature : Int32?
      # Try nvidia-smi first
      begin
        out_io = IO::Memory.new
        res = Process.run(
          "nvidia-smi",
          ["--query-gpu=temperature.gpu", "--format=csv,noheader"],
          output: out_io,
          error: Process::Redirect::Close
        )
        if res.success?
          str = out_io.to_s.strip
          if val = str.to_i?
            return val
          end
        end
      rescue
        # nvidia-smi not available
      end

      # Try Linux hwmon
      begin
        Dir.glob("/sys/class/hwmon/hwmon*/temp1_input").each do |path|
          if content = File.read(path).strip.to_i?
            # hwmon reports millidegrees Celsius
            return (content / 1000).to_i
          end
        end
      rescue
      end

      nil
    end
  end
end
