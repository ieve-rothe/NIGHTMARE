require "./spec_helper"

describe Nightmare::CLI do
  describe ".execute" do
    it "prints version and exits with 0 on --version" do
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      status = Nightmare::CLI.execute(
        args: ["--version"],
        stdout: stdout,
        stderr: stderr
      )

      status.should eq(0)
      stdout.to_s.should eq("NIGHTMARE #{Nightmare::VERSION}\n")
      stderr.to_s.should be_empty
    end

    it "prints version and exits with 0 on -v" do
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      status = Nightmare::CLI.execute(
        args: ["-v"],
        stdout: stdout,
        stderr: stderr
      )

      status.should eq(0)
      stdout.to_s.should eq("NIGHTMARE #{Nightmare::VERSION}\n")
      stderr.to_s.should be_empty
    end

    it "prints help banner and usage information on --help" do
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      status = Nightmare::CLI.execute(
        args: ["--help"],
        stdout: stdout,
        stderr: stderr
      )

      status.should eq(0)
      output = stdout.to_s
      output.should contain("NIGHTMARE - Developer REPL")
      output.should contain("Usage: nightmare [options] [workspace_path]")
      output.should contain("--system=PATH")
      output.should contain("--read-dir=PATH")
      output.should contain("--write-dir=PATH")
      output.should contain("--writable-dir=PATH")
      output.should contain("--no-logs")
      output.should contain("--model=MODEL")
      output.should contain("--markdown")
      output.should contain("--no-markdown")
      output.should contain("--version")
      output.should contain("--help")
      stderr.to_s.should be_empty
    end

    it "prints help banner on -h" do
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      status = Nightmare::CLI.execute(
        args: ["-h"],
        stdout: stdout,
        stderr: stderr
      )

      status.should eq(0)
      stdout.to_s.should contain("NIGHTMARE - Developer REPL")
      stderr.to_s.should be_empty
    end

    it "returns 1 and prints an error with help text on invalid options" do
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      status = Nightmare::CLI.execute(
        args: ["--unknown-flag"],
        stdout: stdout,
        stderr: stderr
      )

      status.should eq(1)
      error_output = stderr.to_s
      error_output.should contain("Error: Invalid option: --unknown-flag")
      error_output.should contain("Usage: nightmare")
      stdout.to_s.should be_empty
    end

    it "fails gracefully with exit code 1 for options missing their required arguments" do
      flags = [
        "-s",
        "--system",
        "-m",
        "--model",
        "-R",
        "--read-dir",
        "-W",
        "--write-dir",
        "--writable-dir",
        "--writeable-dir",
      ]

      flags.each do |flag|
        stdout = IO::Memory.new
        stderr = IO::Memory.new

        status = Nightmare::CLI.execute(
          args: [flag],
          stdout: stdout,
          stderr: stderr
        )

        status.should eq(1)
        stderr.to_s.should contain("Missing option: #{flag}")
        stderr.to_s.should contain("Usage: nightmare")
        stdout.to_s.should be_empty
      end
    end

    it "returns 1 and reports fatal error when target workspace directory does not exist" do
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      nonexistent_dir = "/tmp/nightmare_nonexistent_workspace_#{UUID.random}"

      status = Nightmare::CLI.execute(
        args: [nonexistent_dir],
        stdout: stdout,
        stderr: stderr
      )

      status.should eq(1)
      stderr.to_s.should contain("Fatal Error: Workspace directory does not exist: #{nonexistent_dir}")
      stdout.to_s.should be_empty
    end

    it "resolves environment and invokes REPL runner hook with configured options" do
      with_temp_dir do |dir|
        readable_sub = File.join(dir, "readable_sub")
        writable_sub = File.join(dir, "writable_sub")
        Dir.mkdir_p(readable_sub)
        Dir.mkdir_p(writable_sub)

        stdout = IO::Memory.new
        stderr = IO::Memory.new
        runner_called = false
        captured_repl : Nightmare::REPL? = nil

        status = Nightmare::CLI.execute(
          args: [
            "--no-log",
            "--no-markdown",
            "-m", "test-model-alias",
            "-R", readable_sub,
            "-W", writable_sub,
            dir,
          ],
          stdout: stdout,
          stderr: stderr
        ) do |repl|
          runner_called = true
          captured_repl = repl
        end

        status.should eq(0)
        runner_called.should be_true
        stderr.to_s.should be_empty

        repl = captured_repl.not_nil!
        repl.env.root.should eq(dir)
        repl.no_log?.should be_true
        repl.markdown_formatting?.should be_false
        repl.model_name.should eq("test-model-alias")
        repl.env.readable_directories.should contain(readable_sub)
        repl.env.writable_directories.should contain(writable_sub)
      end
    end
  end
end
