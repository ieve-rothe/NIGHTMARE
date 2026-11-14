require "../spec_helper"
require "../../src/nightmare/ui/turn_presenter"
require "../../src/nightmare/ui/stream_controller"
require "../../src/nightmare/context/token_calibrator"

describe Nightmare::UI::TurnPresenter do
  it "records opened files with line counts, byte sizes, and estimated tokens" do
    calibrator = Nightmare::Context::TokenEstimator.new(divisor: 4.0)
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(
      calibrator: calibrator,
      threshold_multiplier: 1.5,
      preview_lines: 5,
      max_width: 80,
      output: io
    )

    presenter.reset_for_new_turn("Check config")
    content = "line 1\nline 2\nline 3\nline 4\nline 5\n"
    file = presenter.record_file_open("src/config.cr", content)

    file.path.should eq("src/config.cr")
    file.lines.should eq(5)
    file.size_bytes.should eq(content.bytesize.to_i64)
    file.tokens.should eq(calibrator.estimate(content.size))
    file.read_range.should eq("all (5 lines)")
    presenter.total_accumulated_lines.should eq(5)
  end

  it "toggles collapsed_mode? based on screen height and threshold multiplier" do
    calibrator = Nightmare::Context::TokenEstimator.new
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(
      calibrator: calibrator,
      threshold_multiplier: 1.0,
      output: io
    )

    presenter.reset_for_new_turn("Inspect files")
    # threshold_lines is based on terminal_height * threshold_multiplier
    thresh = presenter.threshold_lines

    # Under threshold
    content_small = (1..(thresh - 2)).map { |i| "line_#{i}" }.join("\n")
    presenter.record_file_open("small.cr", content_small)
    presenter.collapsed_mode?.should be_false

    # Exceed threshold
    content_extra = (1..5).map { |i| "extra_#{i}" }.join("\n")
    presenter.record_file_open("extra.cr", content_extra)
    presenter.collapsed_mode?.should be_true
  end

  it "formats bytes and tokens human-readably" do
    calibrator = Nightmare::Context::TokenEstimator.new
    presenter = Nightmare::UI::TurnPresenter.new(calibrator: calibrator)

    presenter.format_bytes(500_i64).should eq("500 B")
    presenter.format_bytes(2048_i64).should eq("2.0 KB")
    presenter.format_bytes(5_242_880_i64).should eq("5.0 MB")

    presenter.format_tokens(450).should eq("~450 tok")
    presenter.format_tokens(2500).should eq("~2.5k tok")
  end

  it "renders verbatim panel when under threshold and collapsed deck when over threshold" do
    calibrator = Nightmare::Context::TokenEstimator.new
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(
      calibrator: calibrator,
      threshold_multiplier: 0.5, # very low threshold for testing collapse
      output: io
    )
    presenter.reset_for_new_turn("Review logic")

    args = {"path" => JSON::Any.new("test.cr")}
    small_content = "def test\n  true\nend\n"

    # Call 1: small file (under threshold)
    presenter.present_tool_result("read_file", args, small_content)
    clean1 = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean1.should contain("read_file: test.cr")
    clean1.should contain("def test")

    # Call 2: large file pushing over threshold
    io.clear
    large_args = {"path" => JSON::Any.new("large.cr")}
    large_content = (1..60).map { |i| "func_#{i}" }.join("\n")
    presenter.present_tool_result("read_file", large_args, large_content)

    clean2 = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean2.should contain("Opened Files")
    clean2.should contain("test.cr")
    clean2.should contain("large.cr")
  end

  it "renders cleanly in a narrow/short terminal without overflowing width or height" do
    calibrator = Nightmare::Context::TokenEstimator.new
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(
      calibrator: calibrator,
      threshold_multiplier: 0.5,
      preview_lines: 8,
      max_width: 65,
      output: io
    )

    with_env({"LINES" => "27", "COLUMNS" => "65"}) do
      long_prompt = "Please see if you need to make any updates to the daily ledger or decision log, or the current bead.md, based on our current progress. Also, please evaluate, what is the current goal described in bead.md, have we been on track or did we get sidetracked?"
      presenter.reset_for_new_turn(long_prompt)

      (1..5).each do |idx|
        presenter.record_file_open("file_#{idx}.md", "content for file #{idx}\n" * 10)
      end

      presenter.render_dashboard(
        active_file: presenter.opened_files.first,
        active_offset: 1,
        action_label: "read_file('bead.md')"
      )

      rendered = io.to_s
      lines = rendered.lines

      # Verify no line exceeds max_width
      lines.each_with_index do |l, idx|
        v_w = Salamander::UI::Panel.visual_width(l)
        v_w.should be <= 65, "Line #{idx + 1} width #{v_w} exceeded 65: '#{l}'"
      end

      # Verify total lines fit within a 27-row terminal budget
      lines.size.should be <= 27
    end
  end

  it "renders mutations with correct success, rejection, and error badges" do
    calibrator = Nightmare::Context::TokenEstimator.new
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(calibrator: calibrator, output: io)
    presenter.reset_for_new_turn("Mutations test")

    args = {"path" => JSON::Any.new("PROGRESS.md")}

    # 1. Success
    presenter.present_tool_result("append_to_file", args, "Successfully appended 42 bytes to PROGRESS.md")
    clean1 = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean1.should contain("✓")
    clean1.should contain("MUTATION: APPEND_TO_FILE")
    clean1.should contain("PROGRESS.md")
    clean1.should contain("Successfully appended 42 bytes to PROGRESS.md")

    # 2. Rejection
    io.clear
    presenter.present_tool_result("append_to_file", args, "[Execution rejected by user]")
    clean2 = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean2.should_not contain("✓")
    clean2.should contain("⚠")
    clean2.should contain("MUTATION: REJECTED")
    clean2.should contain("PROGRESS.md")
    clean2.should contain("execution rejected by user")

    # 3. Error
    io.clear
    presenter.present_tool_result("replace_in_file", args, "[SecurityError: path escape]")
    clean3 = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean3.should_not contain("✓")
    clean3.should contain("✗")
    clean3.should contain("MUTATION: ERROR")
    clean3.should contain("PROGRESS.md")
  end

  it "renders shell execution with correct rejection and failure badges" do
    calibrator = Nightmare::Context::TokenEstimator.new
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(calibrator: calibrator, output: io)
    presenter.reset_for_new_turn("Shell test")

    args = {"command" => JSON::Any.new("rm -rf /")}

    # 1. Rejection
    presenter.present_tool_result("shell", args, "[Execution rejected by user]")
    clean1 = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean1.should_not contain("✓")
    clean1.should contain("⚠")
    clean1.should contain("EXEC: REJECTED")

    # 2. Timeout/Failure
    io.clear
    presenter.present_tool_result("shell", args, "[Timeout after 60s]")
    clean2 = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean2.should_not contain("✓")
    clean2.should contain("✗")
    clean2.should contain("EXEC: FAILED")
  end

  it "renders run_command tool results identically to shell" do
    calibrator = Nightmare::Context::TokenEstimator.new
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(calibrator: calibrator, output: io)
    presenter.reset_for_new_turn("Run command test")

    args = {"command" => JSON::Any.new("python3 evaluate_exp1.py")}

    # 1. Rejection
    presenter.present_tool_result("run_command", args, "[Execution rejected by user]")
    clean1 = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean1.should_not contain("✓")
    clean1.should contain("⚠")
    clean1.should contain("EXEC: REJECTED")
    clean1.should contain("python3 evaluate_exp1.py")

    # 2. Success
    io.clear
    presenter.present_tool_result("run_command", args, "Evaluation passed: 100%")
    clean2 = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean2.should contain("✓")
    clean2.should contain("EXEC: SHELL")
    clean2.should contain("Evaluation passed: 100%")
  end

  it "renders the last agent response as a first-class card and truncates when long" do
    calibrator = Nightmare::Context::TokenEstimator.new
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(
      calibrator: calibrator,
      output: io,
      max_response_lines: 4
    )

    # 1. Short response fits in card
    presenter.reset_for_new_turn("Check progress", "I inspected the configuration and everything looks ready.")
    presenter.record_file_open("dummy.cr", "1\n2\n3\n")
    presenter.render_dashboard(action_label: "test")

    clean1 = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean1.should contain("AGENT RESPONSE")
    clean1.should contain("I inspected the configuration and everything looks ready.")
    clean1.should_not contain("earlier lines hidden")

    # 2. Long response truncates with notice
    io.clear
    long_response = (1..10).map { |i| "Explanation paragraph #{i} with detailed analysis" }.join("\n")
    presenter.last_agent_response = long_response
    presenter.render_dashboard(action_label: "test")

    clean2 = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean2.should contain("AGENT RESPONSE")
    clean2.should contain("earlier lines hidden")
    clean2.should contain("Explanation paragraph 10")
    clean2.should_not contain("Explanation paragraph 1 with")
  end

  it "renders live subagent telemetry in the dashboard when subagent is active" do
    calibrator = Nightmare::Context::TokenEstimator.new
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(calibrator: calibrator, output: io)
    presenter.reset_for_new_turn("Run autonomous research")

    telemetry = Nightmare::UI::SubagentTelemetry.new(
      task: "Deep dive into AST parsing",
      iteration: 3,
      max_iterations: 12,
      active_tool: "read_file(parser.cr)",
      last_thought: "Let me check the token definitions next",
      tool_calls_count: 5,
      files_touched: ["src/parser.cr", "src/lexer.cr"]
    )
    presenter.active_subagent = telemetry
    presenter.render_dashboard(action_label: "subagent")

    clean = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean.should contain("SUBAGENT ENGAGED")
    clean.should contain("ITER 3/12 ∷ 5 TOOLS")
    clean.should contain("Deep dive into AST parsing")
    clean.should contain("read_file(parser.cr)")
    clean.should contain("Let me check the token definitions next")
    clean.should contain("src/parser.cr, src/lexer.cr")
  end

  it "formats file_info, search, and list_files cleanly instead of dumping raw JSON" do
    calibrator = Nightmare::Context::TokenEstimator.new
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(calibrator: calibrator, output: io)
    presenter.reset_for_new_turn("Inspect metadata")

    # 1. file_info
    raw_info = %({"path":"src/main.cr","size_bytes":2048,"lines":80})
    presenter.present_tool_result("file_info", {"path" => JSON::Any.new("src/main.cr")}, raw_info)
    clean_info = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean_info.should contain("INFO")
    clean_info.should contain("src/main.cr")
    clean_info.should contain("2.0 KB · 80L")
    clean_info.should_not contain(%("size_bytes":2048))

    # 2. search
    io.clear
    presenter.present_tool_result("search", {"pattern" => JSON::Any.new("def run")}, "src/a.cr:10:def run\nsrc/b.cr:20:def run")
    clean_search = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean_search.should contain("SEARCH")
    clean_search.should contain("'def run'")
    clean_search.should contain("2 match lines")

    # 3. list_files
    io.clear
    presenter.present_tool_result("list_files", {"path" => JSON::Any.new("src")}, "a.cr\nb.cr\nc.cr")
    clean_list = Salamander::UI::Panel.strip_ansi(io.to_s)
    clean_list.should contain("LIST")
    clean_list.should contain("src")
    clean_list.should contain("3 entries")
  end

  it "tracks mutated files in context deck and renders the System Events card as source of truth" do
    calibrator = Nightmare::Context::TokenEstimator.new
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(calibrator: calibrator, output: io)
    presenter.reset_for_new_turn("Create health tracking page")

    args = {
      "path"    => JSON::Any.new("chili/Seven_Health_Tracking.md"),
      "content" => JSON::Any.new("# Seven Health Tracking\n- Diabetes\n- Myositis\n"),
    }

    presenter.present_tool_result("write_file", args, "Successfully wrote 45 bytes to chili/Seven_Health_Tracking.md")

    # Verify presenter recorded system message
    presenter.system_messages.size.should eq(1)
    presenter.system_messages.first.should contain("MUTATION: WRITE_FILE")
    presenter.system_messages.first.should contain("chili/Seven_Health_Tracking.md")

    # Verify mutated file is tracked in opened_files and active inspection
    presenter.opened_files.map(&.path).should contain("chili/Seven_Health_Tracking.md")
    presenter.last_active_file.try(&.path).should eq("chili/Seven_Health_Tracking.md")

    # Render dashboard at turn complete
    io.clear
    presenter.render_dashboard(
      active_file: presenter.last_active_file,
      active_offset: 1,
      action_label: "Turn Complete · 1 file modified (chili/Seven_Health_Tracking.md)"
    )

    rendered = Salamander::UI::Panel.strip_ansi(io.to_s)
    rendered.should contain("System Events (1 event)")
    rendered.should contain("MUTATION: WRITE_FILE")
    rendered.should contain("chili/Seven_Health_Tracking.md")
    rendered.should contain("Turn Complete · 1 file modified (chili/Seven_Health_Tracking.md)")
    rendered.should contain("Opened Files")
    rendered.should contain("Active Inspection: chili/Seven_Health_Tracking.md")

    # Reset for next turn clears system messages
    presenter.reset_for_new_turn("Next turn")
    presenter.system_messages.should be_empty
    presenter.opened_files.should be_empty
  end

  it "routes StreamController chunks through on_print in split mode and preserves separated multi-turn right-pane history" do
    calibrator = Nightmare::Context::TokenEstimator.new
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(
      calibrator: calibrator,
      max_width: 105,
      output: io
    )
    presenter.split_mode_override = true

    stream_ctrl = Nightmare::UI::StreamController.new
    on_print_chunks = [] of String
    stream_ctrl.on_print = ->(s : String) {
      on_print_chunks << s
      presenter.append_stream_text(s)
    }

    with_env({"LINES" => "40", "COLUMNS" => "180"}) do
      term_w = 180
      box_w = Salamander::UI::Panel.clamp_width(term_w, 105)
      right_w = term_w - box_w - 3

      # --- Turn 1 ---
      presenter.reset_for_new_turn("hie")
      presenter.last_render.should be_nil
      stream_ctrl.reset

      stream_ctrl.process_chunk("Oh hey! Emma here. ")
      stream_ctrl.process_chunk("<think>internal thought</think>")
      stream_ctrl.process_chunk("*waves*\nWelcome!")
      stream_ctrl.finish

      on_print_chunks.join.should eq("Oh hey! Emma here. *waves*\nWelcome!")
      stream_ctrl.thinking_text.should eq("internal thought")

      # Before formatting on turn 1, raw text is shown without Turn 1 divider
      raw_t1_render = presenter.last_render.not_nil!
      raw_t1_render.ends_with?("\n").should be_true
      Salamander::UI::Panel.strip_ansi(raw_t1_render).should contain("*waves*")
      Salamander::UI::Panel.strip_ansi(raw_t1_render).should_not contain("Turn 1")

      # Complete Turn 1 with Markdown formatting
      io.clear
      presenter.render_dashboard(action_label: "Turn Complete", format_right_pane: true, final_response: stream_ctrl.visible_text)
      t1_final = presenter.last_render.not_nil!
      t1_final.should contain("\e[3mwaves\e[0m")
      t1_final_clean = Salamander::UI::Panel.strip_ansi(t1_final)
      t1_final_clean.should contain("NIGHTMARE REPL · TURN 1")
      t1_final_clean.should contain("Oh hey! Emma here. waves")
      t1_final_clean.should contain("Welcome!")

      # --- Turn 2 ---
      presenter.reset_for_new_turn("Hi friend. I'm Cam.", stream_ctrl.visible_text)
      presenter.last_render.should be_nil
      stream_ctrl.reset
      io.clear

      stream_ctrl.process_chunk("Oh wow, Cam! *spins*\nThis is exciting!")
      stream_ctrl.finish

      # During streaming of Turn 2: Turn 2 separator sized to right_w, raw *spins* below it, Turn 1 still above
      t2_streaming = presenter.last_render.not_nil!
      t2_streaming_clean = Salamander::UI::Panel.strip_ansi(t2_streaming)
      t2_streaming_clean.should contain("NIGHTMARE REPL · TURN 2")
      t2_streaming_clean.should_not contain("NIGHTMARE REPL · TURN 1")
      t2_streaming_clean.should contain("Turn 2")
      t2_streaming_clean.should contain("*spins*")
      t2_streaming_clean.should contain("Oh hey! Emma here. waves")

      # Verify separator line in stream_history has exact right_w visual width
      sep_t2 = presenter.stream_history.find { |l| Salamander::UI::Panel.strip_ansi(l).includes?("Turn 2") }.not_nil!
      Salamander::UI::Panel.visual_width(sep_t2).should eq(right_w)

      # Intra-turn completion redraw emits clear_and_reposition with exact line count - 1
      prev_lines = Salamander::UI.count_physical_lines(t2_streaming)
      io.clear
      presenter.render_dashboard(action_label: "Turn Complete", format_right_pane: true, final_response: stream_ctrl.visible_text)
      io.to_s.should start_with("\r\e[#{prev_lines - 1}A\e[J")

      t2_final = presenter.last_render.not_nil!
      t2_final.should contain("\e[3mspins\e[0m")
      t2_final_clean = Salamander::UI::Panel.strip_ansi(t2_final)
      t2_final_clean.should_not contain("*spins*")
      t2_final_clean.should contain("Oh wow, Cam! spins")
      t2_final_clean.should contain("This is exciting!")

      # --- Turn 3 ---
      presenter.reset_for_new_turn("Islands don't sing do they?", stream_ctrl.visible_text)
      presenter.last_render.should be_nil
      stream_ctrl.reset
      io.clear

      stream_ctrl.process_chunk("Oh, absolutely they do! *grins*")
      stream_ctrl.finish
      presenter.render_dashboard(action_label: "Turn Complete", format_right_pane: true, final_response: stream_ctrl.visible_text)

      t3_final_clean = Salamander::UI::Panel.strip_ansi(presenter.last_render.not_nil!)
      t3_final_clean.should contain("NIGHTMARE REPL · TURN 3")
      t3_final_clean.should_not contain("NIGHTMARE REPL · TURN 1")
      t3_final_clean.should_not contain("NIGHTMARE REPL · TURN 2")

      # Right pane preserves Turn 1, Turn 2 separator, Turn 2, Turn 3 separator, Turn 3 in order
      idx1 = t3_final_clean.index("Oh hey! Emma here. waves").not_nil!
      idx_sep2 = t3_final_clean.index("─── Turn 2").not_nil!
      idx2 = t3_final_clean.index("Oh wow, Cam! spins").not_nil!
      idx_sep3 = t3_final_clean.index("─── Turn 3").not_nil!
      idx3 = t3_final_clean.index("Oh, absolutely they do! grins").not_nil!

      idx1.should be < idx_sep2
      idx_sep2.should be < idx2
      idx2.should be < idx_sep3
      idx_sep3.should be < idx3
    end
  end

  it "presents image_loaded read_file tool results cleanly without counting base64 as text lines" do
    calibrator = Nightmare::Context::TokenEstimator.new(divisor: 4.0)
    io = IO::Memory.new
    presenter = Nightmare::UI::TurnPresenter.new(
      calibrator: calibrator,
      max_width: 100,
      output: io
    )
    presenter.reset_for_new_turn("Inspect shot.png")

    img_payload = {
      "status"     => "image_loaded",
      "path"       => "shot.png",
      "mime"       => "image/png",
      "size_bytes" => 2048,
      "images"     => ["AAAA"],
    }.to_json

    args = JSON.parse(%({"path":"shot.png"})).as_h
    presenter.present_tool_result("read_file", args, img_payload)

    presenter.opened_files.size.should eq(1)
    opened = presenter.opened_files.first
    opened.path.should eq("shot.png")
    opened.lines.should eq(1)
    opened.tokens.should eq(Mantle::Storage::Shedder::IMAGE_TOKEN_ESTIMATE)
    opened.read_range.should eq("image (image/png)")

    rendered = Salamander::UI::Panel.strip_ansi(io.to_s)
    rendered.should contain("[READ: IMAGE]")
    rendered.should contain("shot.png")
    rendered.should contain("image/png")
  end

  it "resets turn_number and right-pane history on /clear and clears last_render on /cls" do
    with_temp_dir do |dir|
      calibrator = Nightmare::Context::TokenEstimator.new
      io = IO::Memory.new
      presenter = Nightmare::UI::TurnPresenter.new(
        calibrator: calibrator,
        max_width: 105,
        output: io
      )
      presenter.split_mode_override = true

      env = Nightmare::Workspace::Environment.new(root_path: dir, ensure_dirs: false)
      store = Nightmare::Context::SlidingStore.new
      router = Nightmare::Commands::Router.new(
        store: store,
        pinned_files: Nightmare::Context::PinnedFiles.new,
        calibrator: calibrator,
        guard: Nightmare::Tools::Guard.new(env),
        env: env,
        transcript: Nightmare::Transcript.new(dir, enabled: false),
        current_prompt: "Test",
        current_model: "test-model",
        stdout: io,
        turn_presenter: presenter
      )

      with_env({"LINES" => "40", "COLUMNS" => "180"}) do
        # Run 2 turns
        presenter.reset_for_new_turn("first prompt")
        presenter.append_stream_text("First turn text")
        presenter.render_dashboard(action_label: "Turn Complete", format_right_pane: true, final_response: "First turn text")

        presenter.reset_for_new_turn("second prompt", "First turn text")
        presenter.append_stream_text("Second turn text")
        presenter.render_dashboard(action_label: "Turn Complete", format_right_pane: true, final_response: "Second turn text")

        presenter.turn_number.should eq(2)
        presenter.stream_history.should_not be_empty
        presenter.last_render.should_not be_nil

        # /cls resets last_render only
        handled_cls, _ = router.handle("/cls")
        handled_cls.should be_true
        presenter.last_render.should be_nil
        presenter.turn_number.should eq(2)
        presenter.stream_history.should_not be_empty

        # /clear resets turn_number and clears right-pane history & cards
        handled_clear, _ = router.handle("/clear")
        handled_clear.should be_true
        presenter.turn_number.should eq(0)
        presenter.stream_history.should be_empty
        presenter.stream_current.should eq("")
        presenter.last_render.should be_nil
        presenter.last_agent_response.should be_nil

        # Next turn starts cleanly as TURN 1 with no stale history or Turn divider
        presenter.reset_for_new_turn("fresh prompt")
        presenter.append_stream_text("Fresh turn text")
        presenter.render_dashboard(action_label: "Turn Complete", format_right_pane: true, final_response: "Fresh turn text")

        clean = Salamander::UI::Panel.strip_ansi(presenter.last_render.not_nil!)
        clean.should contain("NIGHTMARE REPL · TURN 1")
        clean.should_not contain("NIGHTMARE REPL · TURN 3")
        clean.should contain("Fresh turn text")
        clean.should_not contain("First turn text")
        clean.should_not contain("Second turn text")
        clean.should_not contain("─── Turn")
      end
    end
  end
end

