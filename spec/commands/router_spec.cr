# spec/commands/router_spec.cr
require "../spec_helper"
require "../../src/nightmare/commands/router"
require "../../src/nightmare/context/sliding_store"
require "../../src/nightmare/context/pinned_files"
require "../../src/nightmare/context/token_calibrator"

describe Nightmare::Commands::Router do
  it "configures pacing via /mode commands" do
    temp_dir = File.tempname("router_test")
    Dir.mkdir_p(temp_dir)

    begin
      env = Nightmare::Workspace::Environment.new(
        root_path: temp_dir,
        xdg_config_home: File.join(temp_dir, ".config"),
        xdg_state_home: File.join(temp_dir, ".state"),
        xdg_cache_home: File.join(temp_dir, ".cache"),
        ensure_dirs: false
      )
      store = Nightmare::Context::SlidingStore.new
      pinned = Nightmare::Context::PinnedFiles.new
      calibrator = Nightmare::Context::TokenEstimator.load_or_create(File.join(temp_dir, ".cache"))
      guard = Nightmare::Tools::Guard.new(env)
      transcript = Nightmare::Transcript.new(File.join(temp_dir, ".state"), enabled: false)

      router = Nightmare::Commands::Router.new(
        store: store,
        pinned_files: pinned,
        calibrator: calibrator,
        guard: guard,
        env: env,
        transcript: transcript,
        current_prompt: "Test prompt",
        current_model: "test-model"
      )

      # 1. /mode sprint
      handled, _ = router.handle("/mode sprint")
      handled.should be_true
      router.pacer.inter_item_pacing_seconds.should eq(0.0)
      router.pacer.inter_turn_pacing_seconds.should eq(0.0)

      # 2. /mode pace
      handled, _ = router.handle("/mode pace")
      handled.should be_true
      router.pacer.inter_item_pacing_seconds.should eq(3.0)
      router.pacer.inter_turn_pacing_seconds.should eq(0.5)

      # 3. /mode step
      handled, _ = router.handle("/mode step")
      handled.should be_true
      router.pacer.inter_item_pacing_seconds.should eq(6.0)
      router.pacer.inter_turn_pacing_seconds.should eq(1.0)
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "reviews plan file via /plan review" do
    temp_dir = File.tempname("router_plan_test")
    Dir.mkdir_p(temp_dir)

    begin
      env = Nightmare::Workspace::Environment.new(
        root_path: temp_dir,
        xdg_config_home: File.join(temp_dir, ".config"),
        xdg_state_home: File.join(temp_dir, ".state"),
        xdg_cache_home: File.join(temp_dir, ".cache"),
        ensure_dirs: false
      )
      store = Nightmare::Context::SlidingStore.new
      pinned = Nightmare::Context::PinnedFiles.new
      calibrator = Nightmare::Context::TokenEstimator.load_or_create(File.join(temp_dir, ".cache"))
      guard = Nightmare::Tools::Guard.new(env)
      transcript = Nightmare::Transcript.new(File.join(temp_dir, ".state"), enabled: false)

      router = Nightmare::Commands::Router.new(
        store: store,
        pinned_files: pinned,
        calibrator: calibrator,
        guard: guard,
        env: env,
        transcript: transcript,
        current_prompt: "Test prompt",
        current_model: "test-model"
      )

      # Create a test plan file
      plan = Nightmare::Plan::Plan.new(
        id: "review-plan",
        goal: "Validate review command",
        items: [
          Nightmare::Plan::PlanItem.new(id: "step-1", title: "First step")
        ]
      )
      plan_path = File.join(temp_dir, "plan.json")
      File.write(plan_path, plan.to_pretty_json)

      handled, _ = router.handle("/plan review #{plan_path}")
      handled.should be_true
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "clears conversation history via /clear" do
    temp_dir = File.tempname("router_clear_test")
    Dir.mkdir_p(temp_dir)

    begin
      env = Nightmare::Workspace::Environment.new(
        root_path: temp_dir,
        xdg_config_home: File.join(temp_dir, ".config"),
        xdg_state_home: File.join(temp_dir, ".state"),
        xdg_cache_home: File.join(temp_dir, ".cache"),
        ensure_dirs: false
      )
      store = Nightmare::Context::SlidingStore.new
      store.start_turn(Mantle::Message.new("user", "Hello!"))
      store.active_turn.should_not be_nil

      pinned = Nightmare::Context::PinnedFiles.new
      calibrator = Nightmare::Context::TokenEstimator.load_or_create(File.join(temp_dir, ".cache"))
      guard = Nightmare::Tools::Guard.new(env)
      transcript = Nightmare::Transcript.new(File.join(temp_dir, ".state"), enabled: false)

      router = Nightmare::Commands::Router.new(
        store: store,
        pinned_files: pinned,
        calibrator: calibrator,
        guard: guard,
        env: env,
        transcript: transcript,
        current_prompt: "Test prompt",
        current_model: "test-model"
      )

      handled, _ = router.handle("/clear")
      handled.should be_true
      store.history.should be_empty
      store.active_turn.should be_nil
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end
end
