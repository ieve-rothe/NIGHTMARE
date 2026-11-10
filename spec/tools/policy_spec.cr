# spec/tools/policy_spec.cr
require "../spec_helper"
require "../../src/nightmare/tools/policy"

describe Nightmare::Tools::Policy do
  it "initializes with no disabled tools or quotas" do
    policy = Nightmare::Tools::Policy.new
    policy.disabled_tools.should be_empty
    policy.quotas.should be_empty
    policy.disabled?("read_file").should be_false
  end

  it "disables and enables individual tools by name and alias" do
    policy = Nightmare::Tools::Policy.new

    policy.disable("read_file")
    policy.disabled?("read_file").should be_true
    policy.disabled?("write_file").should be_false

    policy.disable("shell")
    policy.disabled?("run_command").should be_true

    policy.enable("read_file")
    policy.disabled?("read_file").should be_false

    policy.enable("shell")
    policy.disabled?("run_command").should be_false
  end

  it "disables and enables tools by group" do
    policy = Nightmare::Tools::Policy.new

    policy.disable("mutation")
    policy.disabled?("write_file").should be_true
    policy.disabled?("replace_in_file").should be_true
    policy.disabled?("append_to_file").should be_true
    policy.disabled?("read_file").should be_false

    policy.enable("write")
    policy.disabled?("write_file").should be_false
    policy.disabled?("replace_in_file").should be_false
    policy.disabled?("append_to_file").should be_false
  end

  it "enforces quotas and records call counts" do
    policy = Nightmare::Tools::Policy.new
    policy.set_limit("spawn_subagent", limit: 2, scope: Nightmare::Tools::QuotaScope::Turn)

    allowed, err = policy.check_and_record("spawn_subagent")
    allowed.should be_true
    err.should be_nil
    policy.turn_calls["spawn_subagent"].should eq(1)

    allowed, err = policy.check_and_record("spawn_subagent")
    allowed.should be_true
    policy.turn_calls["spawn_subagent"].should eq(2)
    policy.disabled?("spawn_subagent").should be_true

    # Third call should be refused
    allowed, err = policy.check_and_record("spawn_subagent")
    allowed.should be_false
    err.not_nil!.should contain("quota exceeded")
  end

  it "cascades revocation to linked tools (e.g. read_file cascades to run_command)" do
    policy = Nightmare::Tools::Policy.new
    # By default, read_file limit cascades to run_command to prevent bash `cat` fallback
    policy.set_limit("read_file", limit: 2, scope: Nightmare::Tools::QuotaScope::Turn)

    allowed, _ = policy.check_and_record("read_file")
    allowed.should be_true
    policy.disabled?("run_command").should be_false

    allowed, _ = policy.check_and_record("read_file")
    allowed.should be_true
    # Limit is now reached (2/2) -> read_file and run_command must both be disabled
    policy.disabled?("read_file").should be_true
    policy.disabled?("run_command").should be_true

    # Attempting to run bash should be rejected
    allowed, err = policy.check_and_record("run_command")
    allowed.should be_false
    err.not_nil!.should contain("disabled")
  end

  it "resets turn-scoped quotas and counters on reset_turn" do
    policy = Nightmare::Tools::Policy.new
    policy.set_limit("read_file", limit: 1, scope: Nightmare::Tools::QuotaScope::Turn)

    policy.check_and_record("read_file")
    policy.disabled?("read_file").should be_true
    policy.disabled?("run_command").should be_true

    policy.reset_turn
    policy.turn_calls.should be_empty
    policy.disabled?("read_file").should be_false
    policy.disabled?("run_command").should be_false
  end

  it "applies security presets" do
    policy = Nightmare::Tools::Policy.new

    policy.apply_preset("read-only")
    policy.disabled?("write_file").should be_true
    policy.disabled?("replace_in_file").should be_true
    policy.disabled?("append_to_file").should be_true
    policy.disabled?("run_command").should be_true
    policy.disabled?("read_file").should be_false

    policy.apply_preset("default")
    policy.disabled_tools.should be_empty
  end
end
