# spec/ui/approval_cancellation_spec.cr
require "../spec_helper"

describe "Nightmare::UI::Approval cancellation and session recovery" do
  it "raises CancelledException immediately in approve_diff when cancellation_check is true" do
    input = IO::Memory.new("y\n")
    output = IO::Memory.new
    approval = Nightmare::UI::Approval.new("/tmp/workspace", input: input, output: output)
    approval.cancellation_check = ->{ true }

    expect_raises(Nightmare::Harness::CancelledException, /Turn cancelled by user interrupt/) do
      approval.approve_diff("-old\n+new", "overwrite test.txt")
    end
  end

  it "raises CancelledException immediately in approve_command when cancellation_check is true" do
    input = IO::Memory.new("y\n")
    output = IO::Memory.new
    approval = Nightmare::UI::Approval.new("/tmp/workspace", input: input, output: output)
    approval.cancellation_check = ->{ true }

    expect_raises(Nightmare::Harness::CancelledException, /Turn cancelled by user interrupt/) do
      approval.approve_command("rm -rf /tmp/test", ["rm", "-rf", "/tmp/test"], false, 30)
    end
  end

  it "unblocks and raises CancelledException asynchronously while waiting on IO::FileDescriptor" do
    pipe_r, pipe_w = IO.pipe
    output = IO::Memory.new
    approval = Nightmare::UI::Approval.new("/tmp/workspace", input: pipe_r, output: output)

    cancelled = false
    approval.cancellation_check = ->{ cancelled }

    # Spawn an asynchronous fiber to trigger cancellation while approve_diff is polling
    spawn do
      sleep 0.1.seconds
      cancelled = true
    end

    start_time = Time.instant
    expect_raises(Nightmare::Harness::CancelledException, /Turn cancelled by user interrupt/) do
      approval.approve_diff("-old\n+new", "overwrite test.txt")
    end
    elapsed = Time.instant - start_time

    # Should have unblocked within ~200ms due to 50ms polling loop
    elapsed.should be < 1.second

    pipe_r.close
    pipe_w.close
  end

  it "unblocks and raises CancelledException asynchronously in approve_command while waiting on IO::FileDescriptor" do
    pipe_r, pipe_w = IO.pipe
    output = IO::Memory.new
    approval = Nightmare::UI::Approval.new("/tmp/workspace", input: pipe_r, output: output)

    cancelled = false
    approval.cancellation_check = ->{ cancelled }

    spawn do
      sleep 0.1.seconds
      cancelled = true
    end

    start_time = Time.instant
    expect_raises(Nightmare::Harness::CancelledException, /Turn cancelled by user interrupt/) do
      approval.approve_command("ls", ["ls"], false, 10)
    end
    elapsed = Time.instant - start_time

    elapsed.should be < 1.second

    pipe_r.close
    pipe_w.close
  end

  it "prevents file mutation on disk when cancelled during diff approval" do
    with_temp_dir do |temp_dir|
      target_file = File.join(temp_dir, "ellie_journal.md")
      File.write(target_file, "Original journal entry\n")

      input = IO::Memory.new
      output = IO::Memory.new
      approval = Nightmare::UI::Approval.new(temp_dir, input: input, output: output)
      approval.cancellation_check = ->{ true }

      diff_cb = ->(diff : String, desc : String) { approval.approve_diff(diff, desc) }
      env = Nightmare::Workspace::Environment.new(temp_dir, ensure_dirs: false)
      guard = Nightmare::Tools::Guard.new(env)
      mutation = Nightmare::Tools::Mutation.new(guard, diff_cb)

      expect_raises(Nightmare::Harness::CancelledException) do
        mutation.append_to_file("ellie_journal.md", "Malicious / off-track entry\n")
      end

      # Confirm original file was not modified
      File.read(target_file).should eq("Original journal entry\n")
    end
  end
end
