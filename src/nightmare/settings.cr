# nightmare/settings.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "json"
require "file_utils"
require "./config"

module Nightmare
  class Settings
    include JSON::Serializable

    property model : String = Nightmare::Config::DEFAULT_MODEL
    property api_url : String = "http://127.0.0.1:11434/api/chat"
    property markdown : Bool = true
    property logging : Bool = true
    property temperature : Float64 = 0.2
    property top_p : Float64 = 0.95
    property max_tokens : Int32 = 4096
    property command_timeout_seconds : Int32 = Nightmare::Config::SHELL_COMMAND_TIMEOUT_SECONDS
    property max_command_timeout_seconds : Int32 = Nightmare::Config::SHELL_COMMAND_MAX_TIMEOUT_SECONDS
    property tool_output_max_bytes : Int32 = Nightmare::Config::TOOL_OUTPUT_MAX_BYTES
    property max_iterations : Int32 = Nightmare::Config::MAX_ITERATIONS
    property turn_soft_cap : Int32 = Nightmare::Config::TURN_SOFT_CAP
    property turn_spend_cap_tokens : Int32 = Nightmare::Config::TURN_SPEND_CAP_TOKENS
    property loop_detect_threshold : Int32 = Nightmare::Config::LOOP_DETECT_THRESHOLD
    property rate_limit_retries : Int32 = Nightmare::Config::RATE_LIMIT_RETRIES
    property format_retries : Int32 = Nightmare::Config::FORMAT_RETRIES
    property context_overflow_retries : Int32 = Nightmare::Config::CONTEXT_OVERFLOW_RETRIES
    property token_hardmax : Int32 = Nightmare::Config::TOKEN_HARDMAX
    property per_file_max_tokens : Int32 = Nightmare::Config::PER_FILE_MAX_TOKENS
    property bulk_data_patterns : Array(String) = Nightmare::Config::BULK_DATA_PATTERNS
    property bulk_data_max_lines : Int32 = Nightmare::Config::BULK_DATA_MAX_LINES_DEFAULT
    property pinned_budget_ratio : Float64 = Nightmare::Config::PINNED_BUDGET_RATIO
    property shed_trigger_ratio : Float64 = Nightmare::Config::SHED_TRIGGER_RATIO
    property shed_keep_chars : Int32 = Nightmare::Config::SHED_KEEP_CHARS
    property shed_shell_keep_chars : Int32 = Nightmare::Config::SHED_SHELL_KEEP_CHARS
    property shed_file_keep_chars : Int32 = Nightmare::Config::SHED_FILE_KEEP_CHARS
    property shed_keep_verbatim : Int32 = Nightmare::Config::SHED_KEEP_VERBATIM
    property initial_divisor : Float64 = Nightmare::Config::INITIAL_DIVISOR
    property file_card_threshold_screens : Float64 = Nightmare::Config::FILE_CARD_THRESHOLD_SCREENS
    property file_card_preview_lines : Int32 = Nightmare::Config::FILE_CARD_PREVIEW_LINES
    property max_dashboard_width : Int32 = Nightmare::Config::MAX_DASHBOARD_WIDTH
    property theme : String = Nightmare::Config::DEFAULT_THEME

    def initialize(
      @model : String = Nightmare::Config::DEFAULT_MODEL,
      @api_url : String = "http://127.0.0.1:11434/api/chat",
      @markdown : Bool = true,
      @logging : Bool = true,
      @temperature : Float64 = 0.2,
      @top_p : Float64 = 0.95,
      @max_tokens : Int32 = 4096,
      @command_timeout_seconds : Int32 = Nightmare::Config::SHELL_COMMAND_TIMEOUT_SECONDS,
      @max_command_timeout_seconds : Int32 = Nightmare::Config::SHELL_COMMAND_MAX_TIMEOUT_SECONDS,
      @tool_output_max_bytes : Int32 = Nightmare::Config::TOOL_OUTPUT_MAX_BYTES,
      @max_iterations : Int32 = Nightmare::Config::MAX_ITERATIONS,
      @turn_soft_cap : Int32 = Nightmare::Config::TURN_SOFT_CAP,
      @turn_spend_cap_tokens : Int32 = Nightmare::Config::TURN_SPEND_CAP_TOKENS,
      @loop_detect_threshold : Int32 = Nightmare::Config::LOOP_DETECT_THRESHOLD,
      @rate_limit_retries : Int32 = Nightmare::Config::RATE_LIMIT_RETRIES,
      @format_retries : Int32 = Nightmare::Config::FORMAT_RETRIES,
      @context_overflow_retries : Int32 = Nightmare::Config::CONTEXT_OVERFLOW_RETRIES,
      @token_hardmax : Int32 = Nightmare::Config::TOKEN_HARDMAX,
      @per_file_max_tokens : Int32 = Nightmare::Config::PER_FILE_MAX_TOKENS,
      @bulk_data_patterns : Array(String) = Nightmare::Config::BULK_DATA_PATTERNS,
      @bulk_data_max_lines : Int32 = Nightmare::Config::BULK_DATA_MAX_LINES_DEFAULT,
      @pinned_budget_ratio : Float64 = Nightmare::Config::PINNED_BUDGET_RATIO,
      @shed_trigger_ratio : Float64 = Nightmare::Config::SHED_TRIGGER_RATIO,
      @shed_keep_chars : Int32 = Nightmare::Config::SHED_KEEP_CHARS,
      @shed_shell_keep_chars : Int32 = Nightmare::Config::SHED_SHELL_KEEP_CHARS,
      @shed_file_keep_chars : Int32 = Nightmare::Config::SHED_FILE_KEEP_CHARS,
      @shed_keep_verbatim : Int32 = Nightmare::Config::SHED_KEEP_VERBATIM,
      @initial_divisor : Float64 = Nightmare::Config::INITIAL_DIVISOR,
      @file_card_threshold_screens : Float64 = Nightmare::Config::FILE_CARD_THRESHOLD_SCREENS,
      @file_card_preview_lines : Int32 = Nightmare::Config::FILE_CARD_PREVIEW_LINES,
      @max_dashboard_width : Int32 = Nightmare::Config::MAX_DASHBOARD_WIDTH,
      @theme : String = Nightmare::Config::DEFAULT_THEME
    )
    end

    # Loads settings with precedence:
    # 1. Workspace config.json (if exists, loads & auto-patches)
    # 2. Global config.json (if exists, loads & auto-patches)
    # 3. If neither exists, bootstraps global config.json with defaults
    def self.load_or_bootstrap(
      workspace_config_dir : String,
      global_config_dir : String,
      ensure_dirs : Bool = true
    ) : Settings
      ws_config_file = File.join(workspace_config_dir, "config.json")
      global_config_file = File.join(global_config_dir, "config.json")

      if File.exists?(ws_config_file)
        load_and_patch(ws_config_file)
      elsif File.exists?(global_config_file)
        load_and_patch(global_config_file)
      else
        settings = Settings.new
        if ensure_dirs
          Dir.mkdir_p(global_config_dir) unless Dir.exists?(global_config_dir)
          File.write(global_config_file, settings.to_pretty_json)
          File.chmod(global_config_file, 0o600)
        end
        settings
      end
    end

    # Loads a configuration file, verifying and patching schema if missing keys or mismatch
    def self.load_and_patch(file_path : String) : Settings
      expected_hash = JSON.parse(Settings.new.to_json).as_h
      begin
        raw_content = File.read(file_path)
        current_data = JSON.parse(raw_content).as_h
      rescue
        return give_up_patching_config(file_path)
      end

      patched_data = expected_hash.clone
      merge_json_hashes(patched_data, current_data)

      begin
        settings = Settings.from_json(patched_data.to_json)
        # If schema had missing keys or mismatched values that were repaired, rewrite with patched keys
        if current_data.keys.sort != patched_data.keys.sort
          File.write(file_path, settings.to_pretty_json)
          File.chmod(file_path, 0o600)
        end
        settings
      rescue ex : JSON::SerializableError
        give_up_patching_config(file_path)
      end
    end

    # Recursively merges JSON hashes with type-safe value preservation.
    # User values are preserved when types match; schema defaults are retained for missing keys.
    def self.merge_json_hashes(target : Hash(String, JSON::Any), source : Hash(String, JSON::Any)) : Nil
      source.each do |key, source_value|
        if target.has_key?(key)
          target_value = target[key]
          if target_value.raw.is_a?(Hash) && source_value.raw.is_a?(Hash)
            merge_json_hashes(target_value.as_h, source_value.as_h)
          elsif target_value.raw.class == source_value.raw.class
            target[key] = source_value
          elsif target_value.raw.is_a?(Float64) && (source_value.raw.is_a?(Int64) || source_value.raw.is_a?(Int32))
            target[key] = JSON::Any.new(source_value.as_i64.to_f64)
          end
        end
      end
    end

    # Backs up a broken or unparseable config file and restores defaults
    def self.give_up_patching_config(file_path : String) : Settings
      timestamp = Time.local.to_s("%m%d%H%M%S")
      backup_file = "#{file_path}.old.#{timestamp}"
      if File.exists?(file_path)
        FileUtils.cp(file_path, backup_file)
      end
      settings = Settings.new
      File.write(file_path, settings.to_pretty_json)
      File.chmod(file_path, 0o600)
      settings
    end
  end
end
