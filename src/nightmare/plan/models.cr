# nightmare/plan/models.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "json"

module Nightmare::Plan
  enum VerificationKind
    None
    DiffNonEmpty
    Compile
    Command

    def to_s(io : IO) : Nil
      io << case self
      when None         then "none"
      when DiffNonEmpty then "diff_nonempty"
      when Compile      then "compile"
      when Command      then "command"
      end
    end

    def self.parse?(string : String) : VerificationKind?
      case string.downcase.strip
      when "none"          then None
      when "diff_nonempty" then DiffNonEmpty
      when "compile"       then Compile
      when "command"       then Command
      else                      nil
      end
    end

    def self.from_json(pull : JSON::PullParser) : VerificationKind
      raw = pull.read_string
      parse?(raw) || raise JSON::ParseException.new("Unknown VerificationKind: #{raw}", pull.line_number, pull.column_number)
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(to_s)
    end
  end

  class VerificationConfig
    include JSON::Serializable

    property kind : VerificationKind = VerificationKind::None
    property command : Array(String) = [] of String
    property parser : String? = nil
    property expect : String = "pass"
    property allows_test_removal : Bool = false

    def initialize(
      @kind : VerificationKind = VerificationKind::None,
      @command : Array(String) = [] of String,
      @parser : String? = nil,
      @expect : String = "pass",
      @allows_test_removal : Bool = false
    )
    end
  end

  class BaselineConfig
    include JSON::Serializable

    property command : Array(String) = [] of String
    property parser : String? = nil
    property expected_known_failures : Array(String) = [] of String

    def initialize(
      @command : Array(String) = [] of String,
      @parser : String? = nil,
      @expected_known_failures : Array(String) = [] of String
    )
    end
  end

  class PlanItem
    include JSON::Serializable

    property id : String
    property title : String
    property prompt : String? = nil
    property profile_id : String = "code_modifier"
    property depends_on : Array(String) = [] of String
    property group_id : String? = nil
    property files_targeted : Array(String) = [] of String
    property verification : VerificationConfig = VerificationConfig.new
    property max_attempts : Int32 = 3
    property budget_iterations : Int32? = nil
    property allows_test_removal : Bool = false

    def initialize(
      @id : String,
      @title : String,
      @prompt : String? = nil,
      @profile_id : String = "code_modifier",
      @depends_on : Array(String) = [] of String,
      @group_id : String? = nil,
      @files_targeted : Array(String) = [] of String,
      @verification : VerificationConfig = VerificationConfig.new,
      @max_attempts : Int32 = 3,
      @budget_iterations : Int32? = nil,
      @allows_test_removal : Bool = false
    )
    end
  end

  class Plan
    include JSON::Serializable

    property schema_version : String = "1.0.0"
    property id : String
    property goal : String
    property base_ref : String? = nil
    property setup_command : Array(String)? = nil
    property baseline_verification : BaselineConfig? = nil
    property max_run_duration_seconds : Int32 = 14400
    property max_total_tokens : Int32 = 500000
    property items : Array(PlanItem) = [] of PlanItem

    def initialize(
      @id : String,
      @goal : String,
      @schema_version : String = "1.0.0",
      @base_ref : String? = nil,
      @setup_command : Array(String)? = nil,
      @baseline_verification : BaselineConfig? = nil,
      @max_run_duration_seconds : Int32 = 14400,
      @max_total_tokens : Int32 = 500000,
      @items : Array(PlanItem) = [] of PlanItem
    )
    end

    def find_item(item_id : String) : PlanItem?
      @items.find { |it| it.id == item_id }
    end
  end
end
