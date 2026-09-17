# spec/ghost_mode_spec.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "./spec_helper"
require "file_utils"
require "../src/nightmare/workspace/environment"
require "../src/nightmare/repl"
require "../src/nightmare"

describe "Ghost Mode & Logging Control (R7, D6)" do
  describe "T20 — Zero disk footprint under --no-logs (Ghost mode)" do
    it "creates zero files and zero directories across XDG directories" do
      with_temp_dir do |root_sandbox|
        ws_dir = File.join(root_sandbox, "workspace")
        xdg_config = File.join(root_sandbox, "xdg_config")
        xdg_state = File.join(root_sandbox, "xdg_state")
        xdg_cache = File.join(root_sandbox, "xdg_cache")

        Dir.mkdir_p(ws_dir)

        # In ghost mode (--no-logs), ensure_dirs is false
        env = Nightmare::Workspace::Environment.resolve(
          ws_dir,
          xdg_config_home: xdg_config,
          xdg_state_home: xdg_state,
          xdg_cache_home: xdg_cache,
          ensure_dirs: false
        )

        repl = Nightmare::REPL.new(env, no_log: true)

        # 1. Zero XDG directories or files should exist on disk
        Dir.exists?(xdg_config).should be_false
        Dir.exists?(xdg_state).should be_false
        Dir.exists?(xdg_cache).should be_false

        # 2. Transcript is memory-only
        repl.transcript.file_path.should be_nil
        repl.no_log?.should be_true

        # 3. Recording messages leaves no disk trace
        repl.transcript.record(Mantle::Message.new("user", "Top secret prompt"))
        repl.transcript.record(Mantle::Message.new("assistant", "Confidential completion"))

        Dir.exists?(xdg_state).should be_false

        # 4. /save still exports on demand to user-specified path
        export_target = File.join(ws_dir, "manual_save.md")
        saved_path = repl.transcript.save_to(export_target)
        File.exists?(saved_path).should be_true
        File.read(saved_path).should contain("Top secret prompt")
        File.read(saved_path).should contain("Confidential completion")

        # 5. XDG directories are still pristine
        Dir.exists?(xdg_config).should be_false
        Dir.exists?(xdg_state).should be_false
        Dir.exists?(xdg_cache).should be_false

        # 6. Startup banner shows --no-logs mode and nothing is persisted
        banner = env.startup_banner(no_log: repl.no_log?)
        banner.should contain("Mode      : --no-logs (nothing is persisted)")
        banner.should_not contain("Config    :")
        banner.should_not contain("State/Logs:")
      end
    end
  end

  describe "T21 — System config log suppression" do
    it "disables disk audit logs and disk transcripts when logging: false is configured in config.json" do
      with_temp_dir do |root_sandbox|
        ws_dir = File.join(root_sandbox, "workspace")
        xdg_config = File.join(root_sandbox, "xdg_config")
        xdg_state = File.join(root_sandbox, "xdg_state")
        xdg_cache = File.join(root_sandbox, "xdg_cache")

        Dir.mkdir_p(ws_dir)

        # Pre-populate global config.json with logging: false
        global_nightmare_config = File.join(xdg_config, "nightmare")
        Dir.mkdir_p(global_nightmare_config)
        File.write(File.join(global_nightmare_config, "config.json"), %({"logging": false}))

        # Resolve environment normally (no CLI flag)
        env = Nightmare::Workspace::Environment.resolve(
          ws_dir,
          xdg_config_home: xdg_config,
          xdg_state_home: xdg_state,
          xdg_cache_home: xdg_cache,
          ensure_dirs: true
        )

        env.settings.logging.should be_false

        # Initialize REPL without CLI no_log override
        repl = Nightmare::REPL.new(env, no_log: false)

        # REPL should resolve no_log to true due to system settings
        repl.no_log?.should be_true
        repl.transcript.file_path.should be_nil

        # Messages should not write to transcript.md
        repl.transcript.record(Mantle::Message.new("user", "Testing system config suppression"))
        transcript_disk = File.join(env.workspace_state_dir, "transcript.md")
        File.exists?(transcript_disk).should be_false

        # Audit log should not be written
        log_disk = env.log_path
        File.exists?(log_disk).should be_false
      end
    end

    it "maintains logs enabled by default when logging is true" do
      with_temp_dir do |root_sandbox|
        ws_dir = File.join(root_sandbox, "workspace")
        xdg_config = File.join(root_sandbox, "xdg_config")
        xdg_state = File.join(root_sandbox, "xdg_state")
        xdg_cache = File.join(root_sandbox, "xdg_cache")

        Dir.mkdir_p(ws_dir)

        env = Nightmare::Workspace::Environment.resolve(
          ws_dir,
          xdg_config_home: xdg_config,
          xdg_state_home: xdg_state,
          xdg_cache_home: xdg_cache,
          ensure_dirs: true
        )

        env.settings.logging.should be_true

        repl = Nightmare::REPL.new(env, no_log: false)
        repl.no_log?.should be_false
        repl.transcript.file_path.should_not be_nil

        repl.transcript.record(Mantle::Message.new("user", "Normal logging message"))
        transcript_disk = File.join(env.workspace_state_dir, "transcript.md")
        File.exists?(transcript_disk).should be_true
        File.read(transcript_disk).should contain("Normal logging message")
      end
    end
  end

  describe "CLI flag parsing for --no-logs and --no-log" do
    it "sets options.no_log = true when --no-logs is passed" do
      options = Nightmare::CLI::Parser.parse(["--no-logs"])
      options.no_log.should be_true
    end

    it "sets options.no_log = true when --no-log is passed" do
      options = Nightmare::CLI::Parser.parse(["--no-log"])
      options.no_log.should be_true
    end

    it "defaults options.no_log to false when no flag is passed" do
      options = Nightmare::CLI::Parser.parse([] of String)
      options.no_log.should be_false
    end
  end
end
