# nightmare/plan/storage.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "file_utils"
require "./models"
require "./run_state"

module Nightmare::Plan
  class Storage
    # Atomically persists a PlanRun to disk with fsync and rename
    def self.save_run(run : PlanRun, runs_dir : String) : String
      Dir.mkdir_p(runs_dir)
      target_path = File.join(runs_dir, "#{run.run_id}.json")
      temp_path = File.join(runs_dir, "#{run.run_id}.json.tmp.#{Process.pid}.#{Random.rand(1000..9999)}")

      run.updated_at = Time.utc
      json_content = run.to_pretty_json

      File.open(temp_path, "w") do |f|
        f.write(json_content.to_slice)
        f.flush
        f.fsync
      end

      File.rename(temp_path, target_path)
      target_path
    ensure
      File.delete(temp_path) if temp_path && File.exists?(temp_path)
    end

    # Loads a PlanRun from disk
    def self.load_run(path : String) : PlanRun
      File.open(path) do |f|
        PlanRun.from_json(f)
      end
    end

    # Loads or recovers a PlanRun, repairing interrupted items
    def self.load_and_recover(path : String) : PlanRun
      run = load_run(path)
      recover!(run)
      run
    end

    # Repairs in_progress / running state if process was killed mid-run (fail-safe)
    def self.recover!(run : PlanRun) : Bool
      recovered_any = false

      run.items.each do |_id, item|
        if item.status == PlanItemStatus::Running
          item.status = PlanItemStatus::Pending
          item.attempts += 1 # fail-safe: interrupted attempt counts against budget
          item.finished_at = Time.utc
          item.error_history << "[Process interrupted / crashed mid-execution]"
          recovered_any = true
        end
      end

      run.groups.each do |_id, group|
        if group.status == PlanItemStatus::Running
          group.status = PlanItemStatus::Pending
          recovered_any = true
        end
      end

      if run.status == PlanRunStatus::Running && recovered_any
        # Run state remains Running so it can resume
      end

      recovered_any
    end

    # Provides inter-process file locking via flock
    def self.with_lock(lock_path : String, &)
      Dir.mkdir_p(File.dirname(lock_path))
      File.open(lock_path, "w") do |file|
        file.flock_exclusive do
          yield
        end
      end
    end
  end
end
