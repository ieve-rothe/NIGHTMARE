# nightmare/tools/policy.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

module Nightmare::Tools
  enum QuotaScope
    Turn
    Session

    def to_s(io : IO) : Nil
      case self
      when Turn    then io << "turn"
      when Session then io << "session"
      end
    end
  end

  class Quota
    property limit : Int32
    property used : Int32
    property scope : QuotaScope
    property cascade_revocations : Set(String)

    def initialize(
      @limit : Int32,
      @scope : QuotaScope = QuotaScope::Turn,
      cascade : Array(String) = [] of String
    )
      @used = 0
      @cascade_revocations = cascade.to_set
    end

    def remaining : Int32
      {@limit - @used, 0}.max
    end

    def exhausted? : Bool
      @used >= @limit
    end

    def reset : Nil
      @used = 0
    end
  end

  class Policy
    ALL_TOOLS = %w(
      list_files
      search
      read_file
      file_info
      write_file
      replace_in_file
      append_to_file
      run_command
      spawn_subagent
      web_search
    )

    GROUPS = {
      "read"     => Set{"read_file", "search", "list_files", "file_info"},
      "write"    => Set{"write_file", "replace_in_file", "append_to_file"},
      "mutation" => Set{"write_file", "replace_in_file", "append_to_file"},
      "shell"    => Set{"run_command"},
      "subagent" => Set{"spawn_subagent"},
      "web"      => Set{"web_search"},
    }

    getter disabled_tools : Set(String) = Set(String).new
    getter quota_disabled_tools : Set(String) = Set(String).new
    getter quotas : Hash(String, Quota) = Hash(String, Quota).new
    getter turn_calls : Hash(String, Int32) = Hash(String, Int32).new(0)
    getter session_calls : Hash(String, Int32) = Hash(String, Int32).new(0)

    # Normalizes aliases (e.g. "shell" -> "run_command", "subagents" -> "spawn_subagent")
    def self.normalize_tool_name(name : String) : String
      trimmed = name.strip.downcase
      case trimmed
      when "shell", "bash"
        "run_command"
      when "subagent", "subagents"
        "spawn_subagent"
      when "read"
        "read_file"
      when "write"
        "write_file"
      when "web", "search_web"
        "web_search"
      else
        trimmed
      end
    end

    # Checks if a tool is currently disabled
    def disabled?(tool_name : String) : Bool
      norm = Policy.normalize_tool_name(tool_name)
      @disabled_tools.includes?(norm)
    end

    # Explicitly disables a tool or group of tools
    def disable(name_or_group : String) : Array(String)
      trimmed = name_or_group.strip.downcase
      disabled = [] of String

      if group_tools = GROUPS[trimmed]?
        group_tools.each do |tool|
          @disabled_tools << tool
          disabled << tool
        end
      else
        norm = Policy.normalize_tool_name(trimmed)
        @disabled_tools << norm
        disabled << norm
      end

      disabled
    end

    # Explicitly enables a tool or group of tools
    def enable(name_or_group : String) : Array(String)
      trimmed = name_or_group.strip.downcase
      enabled = [] of String

      if group_tools = GROUPS[trimmed]?
        group_tools.each do |tool|
          @disabled_tools.delete(tool)
          @quota_disabled_tools.delete(tool)
          enabled << tool
        end
      else
        norm = Policy.normalize_tool_name(trimmed)
        @disabled_tools.delete(norm)
        @quota_disabled_tools.delete(norm)
        enabled << norm
      end

      enabled
    end

    # Sets a usage quota on a specific tool with optional cascade revocations
    def set_limit(
      tool : String,
      limit : Int32,
      scope : QuotaScope = QuotaScope::Turn,
      cascade : Array(String) = [] of String
    ) : Quota
      norm = Policy.normalize_tool_name(tool)
      effective_cascade = cascade.map { |c| Policy.normalize_tool_name(c) }

      # Default safety cascade: if limiting read_file and no cascade specified,
      # cascade to run_command (to prevent LLM bypassing read tool via bash `cat`)
      if norm == "read_file" && effective_cascade.empty?
        effective_cascade = ["run_command"]
      end

      quota = Quota.new(limit: limit, scope: scope, cascade: effective_cascade)
      @quotas[norm] = quota
      quota
    end

    # Removes a quota from a tool
    def remove_limit(tool : String) : Bool
      norm = Policy.normalize_tool_name(tool)
      @quotas.delete(norm) != nil
    end

    # Evaluates whether a tool execution can proceed and records its invocation.
    # If quota is exceeded, revokes the tool and any linked cascade targets.
    def check_and_record(tool_name : String) : Tuple(Bool, String?)
      norm = Policy.normalize_tool_name(tool_name)

      if quota = @quotas[norm]?
        if quota.exhausted?
          # Tool quota already exhausted
          trip_quota(norm, quota)
          cascades = quota.cascade_revocations.to_a
          msg = if cascades.empty?
            "Tool quota exceeded: '#{norm}' (limit: #{quota.limit}/#{quota.scope}). Tool has been disabled."
          else
            "Tool quota exceeded: '#{norm}' (limit: #{quota.limit}/#{quota.scope}). Tool '#{norm}' and linked tool(s) #{cascades.join(", ")} have been disabled."
          end
          return {false, msg}
        end
      end

      if disabled?(norm)
        msg = if @quota_disabled_tools.includes?(norm)
          "Tool '#{norm}' is currently disabled (cascaded from quota exhaustion)."
        else
          "Tool '#{norm}' is currently disabled by policy."
        end
        return {false, msg}
      end

      if quota = @quotas[norm]?
        quota.used += 1

        if quota.exhausted?
          # This invocation just tripped the quota limit
          trip_quota(norm, quota)
        end
      end

      @turn_calls[norm] = (@turn_calls[norm]? || 0) + 1
      @session_calls[norm] = (@session_calls[norm]? || 0) + 1

      {true, nil}
    end

    private def trip_quota(tool_name : String, quota : Quota) : Nil
      @disabled_tools << tool_name
      @quota_disabled_tools << tool_name

      quota.cascade_revocations.each do |target|
        norm_target = Policy.normalize_tool_name(target)
        @disabled_tools << norm_target
        @quota_disabled_tools << norm_target
      end
    end

    # Resets turn-level counters and re-enables turn-scoped quota-disabled tools
    def reset_turn : Nil
      @turn_calls.clear

      # Re-enable any tools that were disabled purely because of turn-scoped quota trips
      @quotas.each do |tool, quota|
        if quota.scope == QuotaScope::Turn
          quota.reset
          if @quota_disabled_tools.includes?(tool)
            @disabled_tools.delete(tool)
            @quota_disabled_tools.delete(tool)
          end
          quota.cascade_revocations.each do |target|
            norm_target = Policy.normalize_tool_name(target)
            if @quota_disabled_tools.includes?(norm_target)
              @disabled_tools.delete(norm_target)
              @quota_disabled_tools.delete(norm_target)
            end
          end
        end
      end
    end

    # Clears all disabled tools, quotas, and usage counters
    def reset_all : Nil
      @disabled_tools.clear
      @quota_disabled_tools.clear
      @quotas.clear
      @turn_calls.clear
      @session_calls.clear
    end

    # Applies curated security and capability presets
    def apply_preset(name : String) : Bool
      norm = name.strip.downcase.gsub('-', '_')
      case norm
      when "read_only", "readonly"
        reset_all
        disable("write")
        disable("run_command")
        true
      when "locked_down", "lockeddown"
        reset_all
        disable("run_command")
        disable("spawn_subagent")
        disable("web_search")
        true
      when "no_shell", "noshell"
        reset_all
        disable("run_command")
        true
      when "safe_edit", "safeedit"
        reset_all
        disable("run_command")
        disable("spawn_subagent")
        true
      when "default", "full"
        reset_all
        true
      else
        false
      end
    end
  end
end
