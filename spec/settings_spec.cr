require "./spec_helper"
require "file_utils"
require "../src/nightmare/settings"

describe Nightmare::Settings do
  it "initializes with sane defaults" do
    settings = Nightmare::Settings.new
    settings.model.should eq(Nightmare::Config::DEFAULT_MODEL)
    settings.api_url.should eq("http://127.0.0.1:11434/api/chat")
    settings.markdown.should be_true
    settings.logging.should be_true
    settings.temperature.should eq(0.2)
    settings.top_p.should eq(0.95)
    settings.max_tokens.should eq(4096)
    settings.command_timeout_seconds.should eq(60)
    settings.max_command_timeout_seconds.should eq(600)
    settings.tool_output_max_bytes.should eq(24_576)
    settings.per_file_max_tokens.should eq(10_000)
    settings.bulk_data_patterns.should eq(["*.jsonl", "*.log", "*.trace", "*.ndjson"])
    settings.bulk_data_max_lines.should eq(50)
    settings.max_iterations.should eq(25)
    settings.turn_soft_cap.should eq(10)
    settings.turn_spend_cap_tokens.should eq(200_000)
    settings.loop_detect_threshold.should eq(3)
    settings.rate_limit_retries.should eq(3)
    settings.format_retries.should eq(1)
    settings.context_overflow_retries.should eq(1)
    settings.token_hardmax.should eq(12_000)
    settings.pinned_budget_ratio.should eq(0.60)
    settings.shed_trigger_ratio.should eq(0.85)
    settings.shed_keep_chars.should eq(200)
    settings.shed_keep_verbatim.should eq(2)
    settings.initial_divisor.should eq(3.5)
  end

  it "bootstraps ~/.config/nightmare/config.json when no config exists" do
    with_temp_dir do |dir|
      ws_dir = File.join(dir, "ws_config")
      global_dir = File.join(dir, "global_config")
      global_file = File.join(global_dir, "config.json")

      File.exists?(global_file).should be_false

      settings = Nightmare::Settings.load_or_bootstrap(ws_dir, global_dir, ensure_dirs: true)
      File.exists?(global_file).should be_true

      parsed = JSON.parse(File.read(global_file))
      parsed["model"].as_s.should eq(Nightmare::Config::DEFAULT_MODEL)
      parsed["markdown"].as_bool.should be_true
      parsed["logging"].as_bool.should be_true
      parsed["api_url"].as_s.should eq("http://127.0.0.1:11434/api/chat")
      parsed["temperature"].as_f.should eq(0.2)
      parsed["top_p"].as_f.should eq(0.95)
      parsed["max_tokens"].as_i.should eq(4096)
      parsed["command_timeout_seconds"].as_i.should eq(60)
      parsed["max_command_timeout_seconds"].as_i.should eq(600)
      parsed["tool_output_max_bytes"].as_i.should eq(24_576)
      parsed["per_file_max_tokens"].as_i.should eq(10_000)
      parsed["bulk_data_patterns"].as_a.map(&.as_s).should eq(["*.jsonl", "*.log", "*.trace", "*.ndjson"])
      parsed["bulk_data_max_lines"].as_i.should eq(50)
      parsed["max_iterations"].as_i.should eq(25)
      parsed["turn_soft_cap"].as_i.should eq(10)
      parsed["turn_spend_cap_tokens"].as_i.should eq(200_000)
      parsed["loop_detect_threshold"].as_i.should eq(3)
      parsed["rate_limit_retries"].as_i.should eq(3)
      parsed["format_retries"].as_i.should eq(1)
      parsed["context_overflow_retries"].as_i.should eq(1)
      parsed["token_hardmax"].as_i.should eq(12_000)
      parsed["pinned_budget_ratio"].as_f.should eq(0.60)
      parsed["shed_trigger_ratio"].as_f.should eq(0.85)
      parsed["shed_keep_chars"].as_i.should eq(200)
      parsed["shed_keep_verbatim"].as_i.should eq(2)
      parsed["initial_divisor"].as_f.should eq(3.5)
    end
  end

  it "does not bootstrap config.json when ensure_dirs is false" do
    with_temp_dir do |dir|
      ws_dir = File.join(dir, "ws_config")
      global_dir = File.join(dir, "global_config")
      global_file = File.join(global_dir, "config.json")

      settings = Nightmare::Settings.load_or_bootstrap(ws_dir, global_dir, ensure_dirs: false)
      File.exists?(global_file).should be_false
      settings.logging.should be_true
    end
  end

  it "prefers workspace config over global config" do
    with_temp_dir do |dir|
      ws_dir = File.join(dir, "ws_config")
      global_dir = File.join(dir, "global_config")
      Dir.mkdir_p(ws_dir)
      Dir.mkdir_p(global_dir)

      File.write(File.join(ws_dir, "config.json"), %({"model":"ws-model","markdown":false}))
      File.write(File.join(global_dir, "config.json"), %({"model":"global-model","markdown":true}))

      settings = Nightmare::Settings.load_or_bootstrap(ws_dir, global_dir, ensure_dirs: true)
      settings.model.should eq("ws-model")
      settings.markdown.should be_false
    end
  end

  it "auto-patches legacy config files adding missing schema keys and defaults" do
    with_temp_dir do |dir|
      cfg_file = File.join(dir, "config.json")
      File.write(cfg_file, %({"model": "custom-ollama:14b"}))

      settings = Nightmare::Settings.load_and_patch(cfg_file)
      settings.model.should eq("custom-ollama:14b")
      settings.markdown.should be_true
      settings.api_url.should eq("http://127.0.0.1:11434/api/chat")

      # File should be updated on disk with full schema
      disk_json = JSON.parse(File.read(cfg_file))
      disk_json["model"].as_s.should eq("custom-ollama:14b")
      disk_json["markdown"].as_bool.should be_true
      disk_json["max_tokens"].as_i.should eq(4096)
      disk_json["max_iterations"].as_i.should eq(25)
      disk_json["turn_soft_cap"].as_i.should eq(10)
    end
  end

  it "preserves user values when types match during merge_json_hashes" do
    target = JSON.parse(%({"model":"default","markdown":true,"max_tokens":100})).as_h
    source = JSON.parse(%({"model":"custom","markdown":false,"max_tokens":500})).as_h

    Nightmare::Settings.merge_json_hashes(target, source)
    target["model"].as_s.should eq("custom")
    target["markdown"].as_bool.should be_false
    target["max_tokens"].as_i.should eq(500)
  end

  it "rejects mismatched types during merge_json_hashes" do
    target = JSON.parse(%({"markdown":true})).as_h
    source = JSON.parse(%({"markdown":"not_a_bool"})).as_h

    Nightmare::Settings.merge_json_hashes(target, source)
    target["markdown"].as_bool.should be_true
  end

  it "backs up corrupted config file and restores defaults" do
    with_temp_dir do |dir|
      cfg_file = File.join(dir, "config.json")
      File.write(cfg_file, "INVALID_JSON_CONTENT{{{")

      settings = Nightmare::Settings.load_and_patch(cfg_file)
      settings.model.should eq(Nightmare::Config::DEFAULT_MODEL)

      # Fresh defaults written to config.json
      File.read(cfg_file).should contain("\"model\"")

      # Backup file created
      backup_files = Dir.children(dir).select { |f| f.starts_with?("config.json.old.") }
      backup_files.size.should eq(1)
      File.read(File.join(dir, backup_files.first)).should eq("INVALID_JSON_CONTENT{{{")
    end
  end
end
