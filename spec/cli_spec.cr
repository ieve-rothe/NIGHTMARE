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

    it "suggests close flags when an invalid option is passed" do
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      status = Nightmare::CLI.execute(
        args: ["--systm"],
        stdout: stdout,
        stderr: stderr
      )

      status.should eq(1)
      stderr.to_s.should contain("Error: Invalid option: --systm")
      stderr.to_s.should contain("💡 Did you mean '--system'?")
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

    it "processes live /tools and /tokens interactive terminal input commands via execute and exits cleanly" do
      with_temp_dir do |dir|
        stdin = IO::Memory.new([
          "/tools status",
          "/tools limit read_file 3 session",
          "/tools off run_command",
          "/tokens hardmax 9500",
          "/tokens status",
          "/tools status",
          "/exit",
        ].join("\n") + "\n")
        stdout = IO::Memory.new
        stderr = IO::Memory.new

        status = Nightmare::CLI.execute(
          args: ["--no-log", "--no-markdown", dir],
          stdin: stdin,
          stdout: stdout,
          stderr: stderr
        )

        status.should eq(0)
        output = stdout.to_s
        output.should contain("=== Tool Governance & Availability ===")
        output.should contain("Configured quota for 'read_file'")
        output.should contain("Disabled tool(s): run_command")
        output.should contain("Session token hardmax set to 9500")
        output.should contain("=== Session Token Budget & Context Window ===")
        output.should contain("Active Context Tokens:  704 / 9500")
        output.should contain("(Session Override)")
        output.should contain("Max 3/turn (0 used) → Cascade: run_command")
        output.should contain("run_command        \e[31mDISABLED\e[0m")
        stderr.to_s.should be_empty
      end
    end

    it "handles tool presets and resetting tokens/tools back to default via interactive terminal input" do
      with_temp_dir do |dir|
        stdin = IO::Memory.new([
          "/tools preset read-only",
          "/tokens hardmax 6000",
          "/tokens hardmax default",
          "/tools reset",
          "/exit",
        ].join("\n") + "\n")
        stdout = IO::Memory.new
        stderr = IO::Memory.new

        status = Nightmare::CLI.execute(
          args: ["--no-log", "--no-markdown", dir],
          stdin: stdin,
          stdout: stdout,
          stderr: stderr
        )

        status.should eq(0)
        output = stdout.to_s
        output.should contain("Applied tool preset 'read-only'.")
        output.should contain("Session token hardmax set to 6000 (was: 18000)")
        output.should contain("Session token hardmax restored to configured default: 18000 tokens (was: 6000)")
        output.should contain("Reset all tool availability, quotas, and counters.")
        stderr.to_s.should be_empty
      end
    end
  end
end
