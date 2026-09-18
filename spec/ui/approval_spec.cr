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
      out_str.should contain("Approve Overwrite test.txt? [y/N/a]: ")
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

      # '?' displays help and reprompts
      approval_help = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("?\ny\n"), output: IO::Memory.new)
      approval_help.approve_diff("diff", "desc").should be_true

      # default rejection on blank/other
      approval_reject = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("\n"), output: IO::Memory.new)
      approval_reject.approve_diff("diff", "desc").should be_false
    end

    it "sanitizes terminal escape sequences in diff approval input" do
      # Focus-in event + y
      approval_focus = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("\e[Iy\n"), output: IO::Memory.new)
      approval_focus.approve_diff("diff", "desc").should be_true

      # Bracketed paste + y
      approval_paste = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("\e[200~y\e[201~\n"), output: IO::Memory.new)
      approval_paste.approve_diff("diff", "desc").should be_true
    end

    it "warns and reprompts on unrecognized diff approval option" do
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("invalid\ny\n"), output: output)
      approval.approve_diff("diff", "desc").should be_true

      out_str = output.to_s
      out_str.should contain("Notice: Unrecognized option 'invalid'. Choose [y/N/a] or '?' for help.")
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
      out_str.should contain("Command:")
      out_str.should contain("git")
      out_str.should contain("status")
      out_str.should contain("Cwd:")
      out_str.should contain("/tmp/workspace")
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

    it "sanitizes terminal escape sequences in command approval input" do
      approval_focus = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("\e[Iy\n"), output: IO::Memory.new)
      outcome, _ = approval_focus.approve_command("git status", ["git", "status"], false, 30)
      outcome.should eq(Nightmare::Tools::ApprovalOutcome::Yes)

      approval_paste = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("\e[200~y\e[201~\n"), output: IO::Memory.new)
      outcome, _ = approval_paste.approve_command("git status", ["git", "status"], false, 30)
      outcome.should eq(Nightmare::Tools::ApprovalOutcome::Yes)
    end

    it "warns and reprompts on unrecognized command approval option" do
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("wat\ny\n"), output: output)
      outcome, _ = approval.approve_command("git status", ["git", "status"], false, 30)
      outcome.should eq(Nightmare::Tools::ApprovalOutcome::Yes)

      out_str = output.to_s
      out_str.should contain("Notice: Unrecognized option 'wat'. Choose [y/N/e/a/p] or '?' for help.")
    end

    it "defaults to reject on blank enter or EOF" do
      approval_blank = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new("\n"), output: IO::Memory.new)
      outcome, _ = approval_blank.approve_command("git status", ["git", "status"], false, 30)
      outcome.should eq(Nightmare::Tools::ApprovalOutcome::No)

      approval_eof = Nightmare::UI::Approval.new("/tmp/workspace", input: IO::Memory.new(""), output: IO::Memory.new)
      outcome, _ = approval_eof.approve_command("git status", ["git", "status"], false, 30)
      outcome.should eq(Nightmare::Tools::ApprovalOutcome::No)
    end
  end
end
