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
