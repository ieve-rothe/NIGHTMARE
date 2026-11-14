# spec/pinned_files_spec.cr
require "./spec_helper"

describe Nightmare::Context::PinnedFiles do
  it "reads content with safe line slicing and clamping" do
    with_temp_dir do |root|
      env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
      guard = Nightmare::Tools::Guard.new(env)

      File.write(File.join(root, "sample.txt"), "line1\nline2\nline3\nline4\nline5")

      # Slice lines 2 to 4
      pin = Nightmare::Context::PinnedFile.new("sample.txt", 2, 4)
      pin.read_content(guard).should eq("line2\nline3\nline4")

      # Out-of-bounds upper slice clamped safely
      pin_high = Nightmare::Context::PinnedFile.new("sample.txt", 3, 50)
      pin_high.read_content(guard).should eq("line3\nline4\nline5")

      # Inverted slice returns empty string without raising
      pin_inv = Nightmare::Context::PinnedFile.new("sample.txt", 5, 2)
      pin_inv.read_content(guard).should eq("")
    end
  end

  it "enforces 60% token budget cap when adding pinned files" do
    with_temp_dir do |root|
      env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
      guard = Nightmare::Tools::Guard.new(env)
      calibrator = Nightmare::Context::TokenEstimator.new(3.5)
      pinned = Nightmare::Context::PinnedFiles.new

      # hardmax = 1000, 60% budget = 600 tokens = ~2100 chars
      small_file = File.join(root, "small.txt")
      File.write(small_file, "A" * 350) # ~100 tokens

      pinned.add("small.txt", guard, calibrator, hardmax: 1000)
      pinned.files.size.should eq(1)

      huge_file = File.join(root, "huge.txt")
      File.write(huge_file, "B" * 2500) # ~715 tokens -> exceeds 600 token budget

      expect_raises(Nightmare::Error, /exceeds pinned file budget/) do
        pinned.add("huge.txt", guard, calibrator, hardmax: 1000)
      end

      # Did not add huge_file
      pinned.files.size.should eq(1)
    end
  end

  it "renders formatted pinned blocks for prompt assembly" do
    with_temp_dir do |root|
      env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
      guard = Nightmare::Tools::Guard.new(env)
      calibrator = Nightmare::Context::TokenEstimator.new(3.5)
      pinned = Nightmare::Context::PinnedFiles.new

      File.write(File.join(root, "cfg.json"), %({"app":"nightmare"}))
      pinned.add("cfg.json", guard, calibrator)

      block = pinned.render_pinned_block(guard)
      block.should_not be_nil
      block.not_nil!.should contain("=== PINNED FILE: cfg.json ===")
      block.not_nil!.should contain(%({"app":"nightmare"}))
    end
  end

  it "pins and renders files from external readable directories" do
    with_temp_dir do |root|
      with_temp_dir do |ext_dir|
        ext_file = File.join(ext_dir, "shared_skill.md")
        File.write(ext_file, "# Shared Skill Content")

        env = Nightmare::Workspace::Environment.new(
          root,
          ensure_dirs: false,
          cli_readable_directories: [ext_dir]
        )
        guard = Nightmare::Tools::Guard.new(env)
        calibrator = Nightmare::Context::TokenEstimator.new(3.5)
        pinned = Nightmare::Context::PinnedFiles.new

        pinned.add(ext_file, guard, calibrator)
        pinned.files.size.should eq(1)

        block = pinned.render_pinned_block(guard)
        block.should_not be_nil
        block.not_nil!.should contain("=== PINNED FILE: #{ext_file} ===")
        block.not_nil!.should contain("# Shared Skill Content")
      end
    end
  end

  it "windows content preserving head and tail lines when exceeding threshold" do
    with_temp_dir do |root|
      env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
      guard = Nightmare::Tools::Guard.new(env)

      lines = (1..20).map { |i| "line #{i}" }
      File.write(File.join(root, "app.log"), lines.join("\n"))

      # Windowed: head 3, tail 4 => 13 lines elided
      pin = Nightmare::Context::PinnedFile.new("app.log", head_lines: 3, tail_lines: 4)
      content = pin.read_content(guard)
      content.should eq("line 1\nline 2\nline 3\n[... 13 lines elided ...]\nline 17\nline 18\nline 19\nline 20")

      # When file size <= head_lines + tail_lines, no elision occurs
      pin_exact = Nightmare::Context::PinnedFile.new("app.log", head_lines: 10, tail_lines: 10)
      pin_exact.read_content(guard).should eq(lines.join("\n"))
    end
  end

  it "supports head-only and tail-only windowing" do
    with_temp_dir do |root|
      env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
      guard = Nightmare::Tools::Guard.new(env)

      lines = (1..10).map { |i| "entry #{i}" }
      File.write(File.join(root, "stream.log"), lines.join("\n"))

      pin_head = Nightmare::Context::PinnedFile.new("stream.log", head_lines: 3, tail_lines: nil)
      pin_head.read_content(guard).should eq("entry 1\nentry 2\nentry 3\n[... 7 lines elided ...]")

      pin_tail = Nightmare::Context::PinnedFile.new("stream.log", head_lines: nil, tail_lines: 3)
      pin_tail.read_content(guard).should eq("[... 7 lines elided ...]\nentry 8\nentry 9\nentry 10")
    end
  end

  it "dynamically clamps pinned scratchpad/log files as they grow on disk" do
    with_temp_dir do |root|
      env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
      guard = Nightmare::Tools::Guard.new(env)
      calibrator = Nightmare::Context::TokenEstimator.new(3.5)
      pinned = Nightmare::Context::PinnedFiles.new

      log_path = File.join(root, "PROGRESS.md")
      initial_lines = ["# Objective", "Keep tests green", "## Updates", "Step 1"]
      File.write(log_path, initial_lines.join("\n"))

      pinned.add("PROGRESS.md", guard, calibrator, head_lines: 2, tail_lines: 2)
      pinned.render_pinned_block(guard).not_nil!.should_not contain("lines elided")

      # Append 100 more lines on disk after pinning
      expanded = initial_lines + (2..101).map { |i| "Step #{i}" }
      File.write(log_path, expanded.join("\n"))

      rendered = pinned.render_pinned_block(guard).not_nil!
      rendered.should contain("# Objective\nKeep tests green")
      rendered.should contain("[... 100 lines elided ...]")
      rendered.should contain("Step 100\nStep 101")
      rendered.should_not contain("Step 50\n")
    end
  end

  it "auto-windows files matching pinned_window_patterns unless auto_window is false" do
    with_temp_dir do |root|
      env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
      guard = Nightmare::Tools::Guard.new(env)
      calibrator = Nightmare::Context::TokenEstimator.new(3.5)

      lines = (1..100).map { |i| "log line #{i}" }
      File.write(File.join(root, "PROGRESS.md"), lines.join("\n"))
      File.write(File.join(root, "server.log"), lines.join("\n"))
      File.write(File.join(root, "README.md"), lines.join("\n"))

      pinned = Nightmare::Context::PinnedFiles.new
      progress_pin = pinned.add("PROGRESS.md", guard, calibrator)
      progress_pin.head_lines.should eq(Nightmare::Config::PINNED_HEAD_LINES_DEFAULT)
      progress_pin.tail_lines.should eq(Nightmare::Config::PINNED_TAIL_LINES_DEFAULT)
      progress_pin.read_content(guard).should contain("[... 40 lines elided ...]")

      log_pin = pinned.add("server.log", guard, calibrator)
      log_pin.head_lines.should eq(Nightmare::Config::PINNED_HEAD_LINES_DEFAULT)
      log_pin.tail_lines.should eq(Nightmare::Config::PINNED_TAIL_LINES_DEFAULT)

      readme_pin = pinned.add("README.md", guard, calibrator)
      readme_pin.head_lines.should be_nil
      readme_pin.tail_lines.should be_nil
      readme_pin.read_content(guard).should_not contain("lines elided")

      # Opt out of auto_window
      full_pin = pinned.add("PROGRESS.md", guard, calibrator, auto_window: false)
      full_pin.head_lines.should be_nil
      full_pin.tail_lines.should be_nil
      full_pin.read_content(guard).should_not contain("lines elided")
    end
  end
end
