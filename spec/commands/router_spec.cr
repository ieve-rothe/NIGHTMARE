# spec/commands/router_spec.cr
require "../spec_helper"
require "../../src/nightmare/commands/router"
require "../../src/nightmare/context/sliding_store"
require "../../src/nightmare/context/pinned_files"
require "../../src/nightmare/context/token_calibrator"

module RouterSpecHelper
  def self.build_test_router(stdin : IO = STDIN, stdout : IO = STDOUT)
    env = Nightmare::Workspace::Environment.new(root_path: "/tmp", ensure_dirs: false)
    Nightmare::Commands::Router.new(
      store: Nightmare::Context::SlidingStore.new,
      pinned_files: Nightmare::Context::PinnedFiles.new,
      calibrator: Nightmare::Context::TokenEstimator.new(3.5),
      guard: Nightmare::Tools::Guard.new(env),
      env: env,
      transcript: Nightmare::Transcript.new("/tmp", enabled: false),
      current_prompt: "Test",
      current_model: "test-model",
      stdin: stdin,
      stdout: stdout
    )
  end
end

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

  it "switches themes dynamically via /theme" do
    temp_dir = File.join(Dir.tempdir, "nightmare_theme_test_#{Time.utc.to_unix_ms}")
    Dir.mkdir_p(temp_dir)

    begin
      env = Nightmare::Workspace::Environment.new(
        root_path: temp_dir,
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

      handled, _ = router.handle("/theme outrun")
      handled.should be_true
      Salamander::UI::Theme.current.name.should eq("outrun")
      env.settings.theme.should eq("outrun")

      handled, _ = router.handle("/theme phosphor")
      handled.should be_true
      Salamander::UI::Theme.current.name.should eq("phosphor")
      env.settings.theme.should eq("phosphor")

      handled, _ = router.handle("/theme cyberpunk")
      handled.should be_true
      Salamander::UI::Theme.current.name.should eq("cyberpunk")
    ensure
      FileUtils.rm_rf(temp_dir)
      Salamander::UI::Theme.set_theme("cyberpunk")
    end
  end

  describe "multiline and triple quote input" do
    it "identifies slash commands and triple quotes" do
      router = RouterSpecHelper.build_test_router

      router.slash_command?("/paste").should be_true
      router.slash_command?("\"\"\"").should be_true
      router.slash_command?("\"\"\"hello").should be_true
      router.slash_command?("hello").should be_false
    end

    it "captures multiple lines and preserves empty lines until \"\"\"" do
      input_text = "def hello\n\n  puts \"world\"\nend\n\"\"\"\n"
      stdin = IO::Memory.new(input_text)
      stdout = IO::Memory.new

      router = RouterSpecHelper.build_test_router(stdin: stdin, stdout: stdout)

      handled, payload = router.handle("\"\"\"")
      handled.should be_true
      payload.should eq("def hello\n\n  puts \"world\"\nend")
      stdout.to_s.should contain("Multi-line mode active")
      stdout.to_s.should contain("Text captured")
    end

    it "captures multiple lines until /end via /paste" do
      input_text = "Line 1\nLine 2\n/end\n"
      stdin = IO::Memory.new(input_text)
      stdout = IO::Memory.new

      router = RouterSpecHelper.build_test_router(stdin: stdin, stdout: stdout)

      handled, payload = router.handle("/paste")
      handled.should be_true
      payload.should eq("Line 1\nLine 2")
    end

    it "handles initial text on the triple-quote line" do
      input_text = "second line\nthird line\n\"\"\"\n"
      stdin = IO::Memory.new(input_text)
      stdout = IO::Memory.new

      router = RouterSpecHelper.build_test_router(stdin: stdin, stdout: stdout)

      handled, payload = router.handle("\"\"\"first line")
      handled.should be_true
      payload.should eq("first line\nsecond line\nthird line")
    end

    it "handles single-line triple quote syntax" do
      router = RouterSpecHelper.build_test_router

      handled, payload = router.handle("\"\"\"single line prompt\"\"\"")
      handled.should be_true
      payload.should eq("single line prompt")
    end

    it "returns nil payload when no content entered before terminator" do
      stdin = IO::Memory.new("\"\"\"\n")
      stdout = IO::Memory.new

      router = RouterSpecHelper.build_test_router(stdin: stdin, stdout: stdout)

      handled, payload = router.handle("\"\"\"")
      handled.should be_true
      payload.should be_nil
    end

    it "truncates input exceeding MAX_MULTILINE_LINES" do
      lines = (1..2005).map { |i| "Line #{i}" }.join("\n") + "\n\"\"\"\n"
      stdin = IO::Memory.new(lines)
      stdout = IO::Memory.new

      router = RouterSpecHelper.build_test_router(stdin: stdin, stdout: stdout)

      handled, payload = router.handle("\"\"\"")
      handled.should be_true
      payload.not_nil!.split("\n").size.should eq(Nightmare::Config::MAX_MULTILINE_LINES)
      stdout.to_s.should contain("Maximum input limit reached")
    end

    it "truncates input exceeding MAX_MULTILINE_CHARS" do
      long_string = "x" * (Nightmare::Config::MAX_MULTILINE_CHARS + 100) + "\n\"\"\"\n"
      stdin = IO::Memory.new(long_string)
      stdout = IO::Memory.new

      router = RouterSpecHelper.build_test_router(stdin: stdin, stdout: stdout)

      handled, payload = router.handle("\"\"\"")
      handled.should be_true
      payload.not_nil!.size.should eq(Nightmare::Config::MAX_MULTILINE_CHARS)
      stdout.to_s.should contain("Maximum input limit reached")
    end
  end
end
