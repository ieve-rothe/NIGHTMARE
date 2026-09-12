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
