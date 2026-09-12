# spec/plan/storage_spec.cr
require "../spec_helper"

describe Nightmare::Plan::Storage do
  it "atomically saves and loads a PlanRun" do
    with_temp_dir do |temp_dir|
      run = Nightmare::Plan::PlanRun.new(
        run_id: "run-test-1",
        plan_id: "plan-test-1",
        status: Nightmare::Plan::PlanRunStatus::Running,
        base_sha: "head123"
      )
      run.items["item-1"] = Nightmare::Plan::ItemRunState.new(id: "item-1")

      saved_path = Nightmare::Plan::Storage.save_run(run, temp_dir)
      File.exists?(saved_path).should be_true

      loaded = Nightmare::Plan::Storage.load_run(saved_path)
      loaded.run_id.should eq("run-test-1")
      loaded.items.has_key?("item-1").should be_true
    end
  end

  it "recovers from a crash by resetting Running items to Pending and incrementing attempts" do
    with_temp_dir do |temp_dir|
      run = Nightmare::Plan::PlanRun.new(
        run_id: "run-crashed",
        plan_id: "plan-crashed",
        status: Nightmare::Plan::PlanRunStatus::Running
      )
      run.items["item-1"] = Nightmare::Plan::ItemRunState.new(
        id: "item-1",
        status: Nightmare::Plan::PlanItemStatus::Running,
        attempts: 1
      )
      run.items["item-2"] = Nightmare::Plan::ItemRunState.new(
        id: "item-2",
        status: Nightmare::Plan::PlanItemStatus::Pending,
        attempts: 0
      )

      saved_path = Nightmare::Plan::Storage.save_run(run, temp_dir)

      # Load and recover
      recovered = Nightmare::Plan::Storage.load_and_recover(saved_path)

      recovered.items["item-1"].status.should eq(Nightmare::Plan::PlanItemStatus::Pending)
      recovered.items["item-1"].attempts.should eq(2) # attempt counted fail-safe
      recovered.items["item-1"].error_history.last.should contain("interrupted")
      recovered.items["item-2"].status.should eq(Nightmare::Plan::PlanItemStatus::Pending)
      recovered.items["item-2"].attempts.should eq(0)
    end
  end

  it "supports exclusive flock locking" do
    with_temp_dir do |temp_dir|
      lock_path = File.join(temp_dir, "test.lock")
      locked = false

      Nightmare::Plan::Storage.with_lock(lock_path) do
        locked = true
      end

      locked.should be_true
    end
  end
end
