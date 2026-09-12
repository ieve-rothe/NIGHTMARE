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
