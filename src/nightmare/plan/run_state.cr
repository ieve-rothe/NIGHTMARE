# nightmare/plan/run_state.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "json"

module Nightmare::Plan
  enum PlanItemStatus
    Pending
    Running
    Completed
    Failed
    Blocked
    Skipped
    NeedsReview

    def to_s(io : IO) : Nil
      io << case self
      when Pending     then "pending"
      when Running     then "running"
      when Completed   then "completed"
      when Failed      then "failed"
      when Blocked     then "blocked"
      when Skipped     then "skipped"
      when NeedsReview then "needs_review"
      end
    end

    def self.parse?(string : String) : PlanItemStatus?
      case string.downcase.strip
      when "pending"      then Pending
      when "running"      then Running
      when "completed"    then Completed
      when "failed"       then Failed
      when "blocked"      then Blocked
      when "skipped"      then Skipped
      when "needs_review" then NeedsReview
      else                     nil
      end
    end

    def self.from_json(pull : JSON::PullParser) : PlanItemStatus
      raw = pull.read_string
      parse?(raw) || raise JSON::ParseException.new("Unknown PlanItemStatus: #{raw}", pull.line_number, pull.column_number)
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(to_s)
    end
  end

  enum PlanRunStatus
    Running
    Completed
    Partial
    Failed
    Aborted

    def to_s(io : IO) : Nil
      io << case self
      when Running   then "running"
      when Completed then "completed"
      when Partial   then "partial"
      when Failed    then "failed"
      when Aborted   then "aborted"
      end
    end

    def self.parse?(string : String) : PlanRunStatus?
      case string.downcase.strip
      when "running"   then Running
      when "completed" then Completed
      when "partial"   then Partial
      when "failed"    then Failed
      when "aborted"   then Aborted
      else                  nil
      end
    end

    def self.from_json(pull : JSON::PullParser) : PlanRunStatus
      raw = pull.read_string
      parse?(raw) || raise JSON::ParseException.new("Unknown PlanRunStatus: #{raw}", pull.line_number, pull.column_number)
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(to_s)
    end
  end

  class ExecutedCommand
    include JSON::Serializable

    property cmd : Array(String)
    property exit_code : Int32
    property duration_ms : Int64

    def initialize(@cmd : Array(String), @exit_code : Int32, @duration_ms : Int64 = 0_i64)
    end
  end

  class ProposedItem
    include JSON::Serializable

    property title : String
    property files_targeted : Array(String)

    def initialize(@title : String, @files_targeted : Array(String) = [] of String)
    end
  end

  class ItemRunState
    include JSON::Serializable

    property id : String
    property status : PlanItemStatus
    property attempts : Int32
    property max_attempts : Int32
    property base_sha : String?
    property result_sha : String?
    property started_at : Time?
    property finished_at : Time?
    property tokens_used : Int32
    property worker_self_reported_status : String?
    property summary : String?
    property files_touched : Array(String)
    property tool_calls_count : Int32
    property shell_commands : Array(ExecutedCommand)
    property error_history : Array(String)
    property attempt_signatures : Array(String)
    property proposed_items : Array(ProposedItem)
    property proposed_targets : Array(String)

    def initialize(
      @id : String,
      @status : PlanItemStatus = PlanItemStatus::Pending,
      @attempts : Int32 = 0,
      @max_attempts : Int32 = 3,
      @base_sha : String? = nil,
      @result_sha : String? = nil,
      @started_at : Time? = nil,
      @finished_at : Time? = nil,
      @tokens_used : Int32 = 0,
      @worker_self_reported_status : String? = nil,
      @summary : String? = nil,
      @files_touched : Array(String) = [] of String,
      @tool_calls_count : Int32 = 0,
      @shell_commands : Array(ExecutedCommand) = [] of ExecutedCommand,
      @error_history : Array(String) = [] of String,
      @attempt_signatures : Array(String) = [] of String,
      @proposed_items : Array(ProposedItem) = [] of ProposedItem,
      @proposed_targets : Array(String) = [] of String
    )
    end
  end

  class GroupRunState
    include JSON::Serializable

    property group_id : String
    property status : PlanItemStatus
    property attempts : Int32
    property max_attempts : Int32
    property base_sha : String?
    property result_sha : String?

    def initialize(
      @group_id : String,
      @status : PlanItemStatus = PlanItemStatus::Pending,
      @attempts : Int32 = 0,
      @max_attempts : Int32 = 2,
      @base_sha : String? = nil,
      @result_sha : String? = nil
    )
    end
  end

  class BaselineState
    include JSON::Serializable

    property total_tests : Int32
    property known_failing_tests : Array(String)
    property all_test_descriptions : Array(String)

    def initialize(
      @total_tests : Int32 = 0,
      @known_failing_tests : Array(String) = [] of String,
      @all_test_descriptions : Array(String) = [] of String
    )
    end
  end

  class PlanRun
    include JSON::Serializable

    property run_id : String
    property plan_id : String
    property plan_schema_version : String
    property started_at : Time
    property updated_at : Time
    property status : PlanRunStatus
    property base_sha : String?
    property worktree_path : String?
    property baseline : BaselineState
    property items : Hash(String, ItemRunState)
    property groups : Hash(String, GroupRunState)

    def initialize(
      @run_id : String,
      @plan_id : String,
      @plan_schema_version : String = "1.0.0",
      @started_at : Time = Time.utc,
      @updated_at : Time = Time.utc,
      @status : PlanRunStatus = PlanRunStatus::Running,
      @base_sha : String? = nil,
      @worktree_path : String? = nil,
      @baseline : BaselineState = BaselineState.new,
      @items : Hash(String, ItemRunState) = {} of String => ItemRunState,
      @groups : Hash(String, GroupRunState) = {} of String => GroupRunState
    )
    end
  end
end
