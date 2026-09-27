# spec/diff_spec.cr
require "./spec_helper"
require "colorize"

describe Nightmare::Tools::Diff do
  describe ".unified_diff" do
    it "returns empty string when original and updated strings are identical" do
      content = "line 1\nline 2\nline 3\n"
      diff = Nightmare::Tools::Diff.unified_diff(content, content, "sample.txt")
      diff.should eq("")
    end

    it "generates unified diff with headers and hunk format" do
      original = "alpha\nbeta\ngamma"
      updated = "alpha\nbeta changed\ngamma\ndelta"

      diff = Nightmare::Tools::Diff.unified_diff(original, updated, "test.txt")
      diff.should contain("--- a/test.txt")
      diff.should contain("+++ b/test.txt")
      diff.should contain("@@ -1,3 +1,4 @@")
      diff.should contain(" alpha")
      diff.should contain("-beta")
      diff.should contain("+beta changed")
      diff.should contain(" gamma")
      diff.should contain("+delta")
    end

    it "prunes large contiguous unchanged regions and shows only surrounding context" do
      orig_lines = (1..50).map { |i| "line #{i}" }
      new_lines = orig_lines.dup
      new_lines[24] = "line 25 modified"

      diff = Nightmare::Tools::Diff.unified_diff(orig_lines.join('\n'), new_lines.join('\n'), "large.txt")
      diff.should contain("@@ -22,7 +22,7 @@")
      diff.should contain(" line 22")
      diff.should contain(" line 23")
      diff.should contain(" line 24")
      diff.should contain("-line 25")
      diff.should contain("+line 25 modified")
      diff.should contain(" line 26")
      diff.should contain(" line 27")
      diff.should contain(" line 28")

      # Unchanged lines far away must not appear in the diff
      diff.should_not contain(" line 1\n")
      diff.should_not contain(" line 10\n")
      diff.should_not contain(" line 40\n")
      diff.should_not contain(" line 50")
    end

    it "splits distant changes into separate hunks when separated by more than 2 * context_lines" do
      orig_lines = (1..30).map { |i| "line #{i}" }
      new_lines = orig_lines.dup
      new_lines[5] = "line 6 modified"
      new_lines[19] = "line 20 modified"

      diff = Nightmare::Tools::Diff.unified_diff(orig_lines.join('\n'), new_lines.join('\n'), "split.txt")
      diff.should contain("@@ -3,7 +3,7 @@")
      diff.should contain("-line 6")
      diff.should contain("+line 6 modified")
      diff.should contain("@@ -17,7 +17,7 @@")
      diff.should contain("-line 20")
      diff.should contain("+line 20 modified")

      # Gap lines between hunks (e.g. line 12, 13) should be omitted
      diff.should_not contain(" line 12\n")
      diff.should_not contain(" line 13\n")
    end

    it "merges close changes into a single hunk when separated by 2 * context_lines or fewer" do
      orig_lines = (1..30).map { |i| "line #{i}" }
      new_lines = orig_lines.dup
      new_lines[5] = "line 6 modified"
      new_lines[12] = "line 13 modified" # 6 unchanged lines (7, 8, 9, 10, 11, 12) between changes

      diff = Nightmare::Tools::Diff.unified_diff(orig_lines.join('\n'), new_lines.join('\n'), "merge.txt")
      diff.should contain("@@ -3,14 +3,14 @@")
      diff.should contain("-line 6")
      diff.should contain("+line 6 modified")
      diff.should contain(" line 7")
      diff.should contain(" line 12")
      diff.should contain("-line 13")
      diff.should contain("+line 13 modified")
    end

    it "handles modifications at the very start of the file without preceding context" do
      orig_lines = (1..15).map { |i| "line #{i}" }
      new_lines = orig_lines.dup
      new_lines[0] = "line 1 modified"

      diff = Nightmare::Tools::Diff.unified_diff(orig_lines.join('\n'), new_lines.join('\n'), "start.txt")
      diff.should contain("@@ -1,4 +1,4 @@")
      diff.should contain("-line 1")
      diff.should contain("+line 1 modified")
      diff.should contain(" line 2")
      diff.should contain(" line 4")
      diff.should_not contain(" line 10")
    end

    it "handles modifications at the very end of the file without trailing context" do
      orig_lines = (1..15).map { |i| "line #{i}" }
      new_lines = orig_lines.dup
      new_lines[14] = "line 15 modified"

      diff = Nightmare::Tools::Diff.unified_diff(orig_lines.join('\n'), new_lines.join('\n'), "end.txt")
      diff.should contain("@@ -12,4 +12,4 @@")
      diff.should contain(" line 12")
      diff.should contain(" line 14")
      diff.should contain("-line 15")
      diff.should contain("+line 15 modified")
      diff.should_not contain(" line 5")
    end

    it "handles additions from an empty original string" do
      diff = Nightmare::Tools::Diff.unified_diff("", "first line\nsecond line", "new.txt")
      diff.should contain("@@ -0,0 +1,2 @@")
      diff.should contain("+first line")
      diff.should contain("+second line")
      diff.lines[3..].none?(&.starts_with?('-')).should be_true
    end

    it "handles deletions resulting in an empty updated string" do
      diff = Nightmare::Tools::Diff.unified_diff("first line\nsecond line", "", "empty.txt")
      diff.should contain("@@ -1,2 +0,0 @@")
      diff.should contain("-first line")
      diff.should contain("-second line")
      diff.lines[3..].none?(&.starts_with?('+')).should be_true
    end

    it "respects custom context_lines parameter" do
      orig_lines = (1..20).map { |i| "line #{i}" }
      new_lines = orig_lines.dup
      new_lines[9] = "line 10 modified"

      diff = Nightmare::Tools::Diff.unified_diff(orig_lines.join('\n'), new_lines.join('\n'), "custom.txt", context_lines: 1)
      diff.should contain("@@ -9,3 +9,3 @@")
      diff.should contain(" line 9")
      diff.should contain("-line 10")
      diff.should contain("+line 10 modified")
      diff.should contain(" line 11")
      diff.should_not contain(" line 8")
      diff.should_not contain(" line 12")
    end
  end

  describe ".colorize" do
    it "returns empty string when given an empty diff" do
      Nightmare::Tools::Diff.colorize("").should eq("")
    end

    it "colorizes additions in green, deletions in red, hunks in cyan, and headers in bold" do
      diff = [
        "--- a/file.cr",
        "+++ b/file.cr",
        "@@ -1,2 +1,2 @@",
        "-old code",
        "+new code",
        " unchanged context"
      ].join('\n')

      # Enable Colorize explicitly to verify ANSI escape generation
      prev_colorize = Colorize.enabled?
      begin
        Colorize.enabled = true

        colored = Nightmare::Tools::Diff.colorize(diff)
        lines = colored.split('\n')

        # --- a/file.cr and +++ b/file.cr are bold
        lines[0].should contain("\e[1m--- a/file.cr")
        lines[1].should contain("\e[1m+++ b/file.cr")

        # @@ hunk is cyan
        lines[2].should contain("\e[36m@@ -1,2 +1,2 @@")

        # Deletion is red
        lines[3].should contain("\e[31m-old code")

        # Addition is green
        lines[4].should contain("\e[32m+new code")

        # Context line is uncolored
        lines[5].should eq(" unchanged context")
      ensure
        Colorize.enabled = prev_colorize
      end
    end

    it "leaves lines unmodified when Colorize is disabled" do
      diff = [
        "--- a/file.cr",
        "+++ b/file.cr",
        "@@ -1,2 +1,2 @@",
        "-old",
        "+new",
        " context"
      ].join('\n')

      prev_colorize = Colorize.enabled?
      begin
        Colorize.enabled = false
        colored = Nightmare::Tools::Diff.colorize(diff)
        colored.should eq(diff)
      ensure
        Colorize.enabled = prev_colorize
      end
    end
  end
end
