# spec/ui/approval_spec.cr
require "../spec_helper"
require "colorize"

describe Nightmare::UI::Approval do
  describe "#approve_diff" do
    it "renders diff with demarcation banners and prompts operator" do
      input = IO::Memory.new("y\n")
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new("/tmp/workspace", input: input, output: output)

      diff_content = "-old line\n+new line"
      result = approval.approve_diff(diff_content, "Overwrite test.txt")

      result.should be_true
      out_str = output.to_s
      out_str.should contain("--- Diff ---")
      out_str.should contain("------------")
      out_str.should contain("Approve overwrite for Overwrite test.txt? [y/N/a]: ")
      out_str.should contain("-old line")
      out_str.should contain("+new line")
    end

    it "colorizes diff output when colorize is enabled" do
      input = IO::Memory.new("n\n")
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new("/tmp/workspace", input: input, output: output)

      diff_content = "-old line\n+new line"

      prev_colorize = Colorize.enabled?
      begin
        Colorize.enabled = true
        result = approval.approve_diff(diff_content, "Overwrite test.txt")
        result.should be_false

        out_str = output.to_s
        out_str.should contain("\e[31m-old line")
        out_str.should contain("\e[32m+new line")
      ensure
        Colorize.enabled = prev_colorize
      end
    end

    it "handles approval choices correctly" do
      # 'a' for all
      approval_a = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("a\n"), output: IO::Memory.new)
      approval_a.approve_diff("diff", "desc").should be_true

      # 'yes'
      approval_yes = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("yes\n"), output: IO::Memory.new)
      approval_yes.approve_diff("diff", "desc").should be_true

      # default rejection on blank/other
      approval_reject = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("\n"), output: IO::Memory.new)
      approval_reject.approve_diff("diff", "desc").should be_false
    end
  end

  describe "#approve_command" do
    it "prompts with command details and returns Yes for 'y'" do
      input = IO::Memory.new("y\n")
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new("/tmp/workspace", input: input, output: output)

      outcome, edit = approval.approve_command("git status", ["git", "status"], false, 30)
      outcome.should eq(Nightmare::Tools::ApprovalOutcome::Yes)
      edit.should be_nil

      out_str = output.to_s
      out_str.should contain("Command: git status")
      out_str.should contain("Cwd:     /tmp/workspace")
      out_str.should contain("Timeout: 30s")
    end

    it "prompts for edit when operator chooses 'e'" do
      input = IO::Memory.new("e\ngit diff\n")
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new("/tmp/workspace", input: input, output: output)

      outcome, edit = approval.approve_command("git status", ["git", "status"], false, 30)
      outcome.should eq(Nightmare::Tools::ApprovalOutcome::Edit)
      edit.should eq("git diff")
    end

    it "displays hint explaining saving behavior for approval choices" do
      input = IO::Memory.new("y\n")
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new("/tmp/workspace", input: input, output: output)

      approval.approve_command("git status", ["git", "status"], false, 30)
      out_str = output.to_s
      out_str.should contain("Approvals: [y] once (don't save)  [N] reject  [e] edit  [a] save exact  [p] save prefix")
    end

    it "returns AllSession for 'a'" do
      input = IO::Memory.new("a\n")
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new("/tmp/workspace", input: input, output: output)

      outcome, edit = approval.approve_command("git status", ["git", "status"], false, 30)
      outcome.should eq(Nightmare::Tools::ApprovalOutcome::AllSession)
      edit.should be_nil
    end

    it "returns PrefixSession for 'p'" do
      input = IO::Memory.new("p\n")
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new("/tmp/workspace", input: input, output: output)

      outcome, edit = approval.approve_command("git status", ["git", "status"], false, 30)
      outcome.should eq(Nightmare::Tools::ApprovalOutcome::PrefixSession)
      edit.should be_nil
    end

    it "displays detailed help on '?' and reprompts" do
      input = IO::Memory.new("?\ny\n")
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new("/tmp/workspace", input: input, output: output)

      outcome, edit = approval.approve_command("git status", ["git", "status"], false, 30)
      outcome.should eq(Nightmare::Tools::ApprovalOutcome::Yes)
      out_str = output.to_s
      out_str.should contain("Approval options:")
      out_str.should contain("Save exact command")
      out_str.should contain("Save command prefix")
    end

    it "warns when command contains shell metacharacters" do
      input = IO::Memory.new("y\n")
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new("/tmp/workspace", input: input, output: output)

      approval.approve_command("git status; ls", ["git", "status;", "ls"], true, 30)
      out_str = output.to_s
      out_str.should contain("metacharacters cannot be saved")
    end
  end
end
