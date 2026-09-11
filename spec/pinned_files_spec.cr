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
end
