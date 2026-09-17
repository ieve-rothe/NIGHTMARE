require "../spec_helper"
require "../../src/nightmare/ui/turn_presenter"
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
end

