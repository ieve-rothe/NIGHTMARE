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

    it "extracts @image.png inline attachments via Clipboard.extract_inline_images" do
      with_temp_dir do |dir|
        png_bytes = Bytes[0x89_u8, 0x50_u8, 0x4E_u8, 0x47_u8, 0x0D_u8, 0x0A_u8, 0x1A_u8, 0x0A_u8]
        File.write(File.join(dir, "shot.png"), png_bytes)
        File.write(File.join(dir, "my diagram.png"), png_bytes)
        Dir.mkdir_p(File.join(dir, "src"))
        File.write(File.join(dir, "src", "main.cr"), "puts 1")

        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)

        prompt = %(Inspect @shot.png and @"my diagram.png" alongside @src/main.cr)
        cleaned, images = Nightmare::UI::Clipboard.extract_inline_images(prompt, guard)

        images.size.should eq(2)
        images[0].label.should eq("shot.png")
        images[0].mime.should eq("image/png")
        images[1].label.should eq("my diagram.png")
        cleaned.should eq("Inspect [Image: shot.png] and [Image: my diagram.png] alongside @src/main.cr")
      end
    end

    it "handles Ctrl+V clipboard image capture and bracketed paste file attachment in InputReader" do
      # Ctrl+V image capture followed by typed text
      stdin_ctrlv = IO::Memory.new("\u0016look at this\n")
      stdout_ctrlv = IO::Memory.new
      line1 = Nightmare::UI::InputReader.read_line(
        stdin: stdin_ctrlv,
        stdout: stdout_ctrlv,
        on_clipboard_paste: -> : String? { "[Image #1: clipboard]" },
        simulate_raw: true
      )
      line1.should eq("look at this")
      out1 = stdout_ctrlv.to_s
      out1.should contain(Nightmare::UI::InputReader::BRACKET_PASTE_ENABLE)
      out1.should contain(Nightmare::UI::InputReader::BRACKET_PASTE_DISABLE)
      out1.should contain("[Image #1: clipboard]")

      # Ctrl+V falls back to text paste when clipboard has no image
      stdin_fallback = IO::Memory.new("\u0016 suffix\n")
      stdout_fallback = IO::Memory.new
      line2 = Nightmare::UI::InputReader.read_line(
        stdin: stdin_fallback,
        stdout: stdout_fallback,
        on_clipboard_paste: -> { nil.as(String?) },
        on_text_paste: -> { "pasted text".as(String?) },
        simulate_raw: true
      )
      line2.should eq("pasted text suffix")

      # Bracketed paste of image file path triggers on_file_paste; regular text inserts into buffer
      stdin_bp = IO::Memory.new("\e[200~/tmp/demo.png\e[201~\e[200~ describe it\e[201~\n")
      stdout_bp = IO::Memory.new
      captured_files = [] of String
      line3 = Nightmare::UI::InputReader.read_line(
        stdin: stdin_bp,
        stdout: stdout_bp,
        on_file_paste: ->(payload : String) {
          if payload.ends_with?(".png")
            captured_files << payload
            "[Image #1: demo.png]".as(String?)
          else
            nil.as(String?)
          end
        },
        simulate_raw: true
      )
      captured_files.should eq(["/tmp/demo.png"])
      line3.should eq(" describe it")
      stdout_bp.to_s.should contain("[Image #1: demo.png]")
    end

    it "stages and clears images cleanly through CLI interactive session (/img, /clip)" do
      with_temp_dir do |dir|
        png_bytes = Bytes[0x89_u8, 0x50_u8, 0x4E_u8, 0x47_u8, 0x0D_u8, 0x0A_u8, 0x1A_u8, 0x0A_u8]
        File.write(File.join(dir, "screen.png"), png_bytes)

        stdin = IO::Memory.new([
          "/img screen.png",
          "/clip list",
          "/clip clear",
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
        output.should contain("Attached [Image #1: screen.png (image/png, 8 B)]")
        output.should contain("[🖼 ×1]")
        output.should contain("Staged images (1):")
        output.should contain("Cleared staged images.")
        stderr.to_s.should be_empty
      end
    end
  end
end
