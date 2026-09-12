# spec/plan/subagent_runner_spec.cr
require "../spec_helper"
require "../../src/nightmare/harness/subagent_runner"

describe Nightmare::Harness::SubagentRunner do
  it "blocks relative path traversal outside files_targeted" do
    temp_dir = File.tempname("guard_targeted_test")
    Dir.mkdir_p(File.join(temp_dir, "src"))
    Dir.mkdir_p(File.join(temp_dir, "spec"))

    begin
      env = Nightmare::Workspace::Environment.new(
        root_path: temp_dir,
        xdg_config_home: File.join(temp_dir, ".config"),
        xdg_state_home: File.join(temp_dir, ".state"),
        xdg_cache_home: File.join(temp_dir, ".cache"),
        ensure_dirs: false
      )

      guard = Nightmare::Tools::Guard.new(env, files_targeted: ["src/**"])
      mutation = Nightmare::Tools::Mutation.new(guard, approval_handler: ->(_diff : String, _desc : String) { true })

      # Writing inside src/** should succeed
      mutation.write_file("src/hello.cr", "puts 123")
      File.exists?(File.join(temp_dir, "src", "hello.cr")).should be_true

      # Attempting relative path traversal to bypass glob
      expect_raises(Nightmare::SecurityError, /not within allowed files_targeted/) do
        mutation.write_file("src/../spec/bypass.cr", "puts 456")
      end

      # Attempting direct write outside src/**
      expect_raises(Nightmare::SecurityError, /not within allowed files_targeted/) do
        mutation.write_file("spec/direct.cr", "puts 789")
      end
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "blocks git mutation commands in subagent mode while allowing inspection" do
    temp_dir = File.tempname("shell_subagent_test")
    Dir.mkdir_p(temp_dir)

    begin
      env = Nightmare::Workspace::Environment.new(
        root_path: temp_dir,
        xdg_config_home: File.join(temp_dir, ".config"),
        xdg_state_home: File.join(temp_dir, ".state"),
        xdg_cache_home: File.join(temp_dir, ".cache"),
        ensure_dirs: false
      )

      guard = Nightmare::Tools::Guard.new(env)
      shell = Nightmare::Tools::Shell.new(guard, subagent_mode: true)

      # Git mutations should be rejected with structured error
      res_commit = shell.run_command("git commit -m 'evil'")
      res_commit.should contain("forbidden in subagent mode")

      res_checkout = shell.run_command("git checkout -b evil-branch")
      res_checkout.should contain("forbidden in subagent mode")

      res_reset = shell.run_command("git reset --hard HEAD~1")
      res_reset.should contain("forbidden in subagent mode")

      # Allowed inspection commands are not rejected by subagent filter
      # (They may fail in git because temp_dir is not a git repo, but they are not blocked by subagent mode)
      res_status = shell.run_command("git status")
      res_status.should_not contain("forbidden in subagent mode")
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "records command telemetry for executed shell commands" do
    temp_dir = File.tempname("shell_telemetry_test")
    Dir.mkdir_p(temp_dir)

    begin
      env = Nightmare::Workspace::Environment.new(
        root_path: temp_dir,
        xdg_config_home: File.join(temp_dir, ".config"),
        xdg_state_home: File.join(temp_dir, ".state"),
        xdg_cache_home: File.join(temp_dir, ".cache"),
        ensure_dirs: false
      )

      guard = Nightmare::Tools::Guard.new(env)
      shell_approval = ->(_cmd : String, _argv : Array(String), _metachar : Bool, _timeout : Int32) {
        {Nightmare::Tools::ApprovalOutcome::Yes, nil.as(String?)}
      }
      shell = Nightmare::Tools::Shell.new(guard, subagent_mode: true, approval_handler: shell_approval)

      shell.run_command("echo telemetry_check")
      shell.executed_commands.size.should eq(1)

      cmd = shell.executed_commands.first
      cmd.cmd.should eq(["echo", "telemetry_check"])
      cmd.exit_code.should eq(0)
      cmd.duration_ms.should be >= 0
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end
end
