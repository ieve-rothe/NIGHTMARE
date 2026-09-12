# spec/plan/models_spec.cr
require "../spec_helper"

describe Nightmare::Plan::Plan do
  it "serializes and deserializes a declarative Plan round-trip" do
    item1 = Nightmare::Plan::PlanItem.new(
      id: "item-1",
      title: "First step",
      profile_id: "researcher",
      files_targeted: ["src/a.cr"]
    )
    item2 = Nightmare::Plan::PlanItem.new(
      id: "item-2",
      title: "Second step",
      profile_id: "code_modifier",
      depends_on: ["item-1"],
      files_targeted: ["src/b.cr"],
      verification: Nightmare::Plan::VerificationConfig.new(
        kind: Nightmare::Plan::VerificationKind::Command,
        command: ["crystal", "spec"],
        parser: "junit",
        expect: "no_new_failures",
        allows_test_removal: false
      )
    )

    plan = Nightmare::Plan::Plan.new(
      id: "test-plan",
      goal: "Test plan goal",
      base_ref: "main",
      setup_command: ["shards", "install"],
      items: [item1, item2]
    )

    json = plan.to_json
    reloaded = Nightmare::Plan::Plan.from_json(json)

    reloaded.id.should eq("test-plan")
    reloaded.goal.should eq("Test plan goal")
    reloaded.base_ref.should eq("main")
    reloaded.setup_command.should eq(["shards", "install"])
    reloaded.items.size.should eq(2)
    reloaded.items[0].profile_id.should eq("researcher")
    reloaded.items[1].depends_on.should eq(["item-1"])
    reloaded.items[1].verification.kind.should eq(Nightmare::Plan::VerificationKind::Command)
    reloaded.items[1].verification.expect.should eq("no_new_failures")
  end

  it "parses VerificationKind case-insensitively" do
    Nightmare::Plan::VerificationKind.parse?("none").should eq(Nightmare::Plan::VerificationKind::None)
    Nightmare::Plan::VerificationKind.parse?("diff_nonempty").should eq(Nightmare::Plan::VerificationKind::DiffNonEmpty)
    Nightmare::Plan::VerificationKind.parse?("compile").should eq(Nightmare::Plan::VerificationKind::Compile)
    Nightmare::Plan::VerificationKind.parse?("command").should eq(Nightmare::Plan::VerificationKind::Command)
    Nightmare::Plan::VerificationKind.parse?("invalid").should be_nil
  end

  it "serializes and deserializes PlanRun state round-trip" do
    run = Nightmare::Plan::PlanRun.new(
      run_id: "run-123",
      plan_id: "plan-abc",
      status: Nightmare::Plan::PlanRunStatus::Running,
      base_sha: "sha123"
    )

    run.items["item-1"] = Nightmare::Plan::ItemRunState.new(
      id: "item-1",
      status: Nightmare::Plan::PlanItemStatus::Completed,
      attempts: 1,
      result_sha: "sha456",
      summary: "Fixed bug",
      files_touched: ["src/foo.cr"],
      shell_commands: [
        Nightmare::Plan::ExecutedCommand.new(cmd: ["crystal", "spec"], exit_code: 0, duration_ms: 120_i64)
      ]
    )

    json = run.to_json
    reloaded = Nightmare::Plan::PlanRun.from_json(json)

    reloaded.run_id.should eq("run-123")
    reloaded.status.should eq(Nightmare::Plan::PlanRunStatus::Running)
    reloaded.items["item-1"].status.should eq(Nightmare::Plan::PlanItemStatus::Completed)
    reloaded.items["item-1"].shell_commands.size.should eq(1)
    reloaded.items["item-1"].shell_commands[0].cmd.should eq(["crystal", "spec"])
  end
end
