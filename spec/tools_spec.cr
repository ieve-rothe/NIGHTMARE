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

    it "recursively lists all files when total count is within max_results" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        env.settings.list_files_max_results = 10
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        Dir.mkdir_p(File.join(root, "src", "nested"))
        File.write(File.join(root, "src", "a.cr"), "a")
        File.write(File.join(root, "src", "nested", "b.cr"), "b")
        File.write(File.join(root, "README.md"), "# Readme")

        output = tools.list_files
        output.should contain("README.md")
        output.should contain("src/a.cr")
        output.should contain("src/nested/b.cr")
        output.should_not contain("src/ (")
        output.should_not contain("[Directory contains")
      end
    end

    it "collapses to depth 1 directory summaries when total files exceed max_results" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        env.settings.list_files_max_results = 3
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        Dir.mkdir_p(File.join(root, "src"))
        File.write(File.join(root, "README.md"), "# Readme")
        4.times do |i|
          File.write(File.join(root, "src", "file_#{i}.cr"), "puts #{i}")
        end

        output = tools.list_files
        output.should contain("README.md")
        output.should contain("src/ (4 files)")
        output.should contain("[Directory contains >3 files. Showing top-level structure.")
        output.should_not contain("src/file_0.cr")
      end
    end

    it "truncates depth 1 entries when depth 1 items exceed max_results" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        env.settings.list_files_max_results = 2
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        File.write(File.join(root, "a.txt"), "a")
        File.write(File.join(root, "b.txt"), "b")
        File.write(File.join(root, "c.txt"), "c")

        output = tools.list_files
        output.should contain("a.txt")
        output.should contain("b.txt")
        output.should_not contain("c.txt")
        output.should contain("[... 1 more entries truncated. Call list_files with 'path' set to a subdirectory or specify a narrower 'glob'.]")
      end
    end

    it "respects explicit depth parameter" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        env.settings.list_files_max_results = 50
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        Dir.mkdir_p(File.join(root, "src", "models"))
        File.write(File.join(root, "README.md"), "# Readme")
        File.write(File.join(root, "src", "main.cr"), "main")
        File.write(File.join(root, "src", "models", "user.cr"), "user")

        depth_1 = tools.list_files(depth: 1)
        depth_1.should contain("README.md")
        depth_1.should contain("src/ (2 files)")
        depth_1.should_not contain("src/main.cr")

        depth_2 = tools.list_files(depth: 2)
        depth_2.should contain("README.md")
        depth_2.should contain("src/main.cr")
        depth_2.should contain("src/models/ (1 file)")
        depth_2.should_not contain("src/models/user.cr")
      end
    end

    it "truncates explicit glob matches when matching files exceed max_results" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        env.settings.list_files_max_results = 2
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        File.write(File.join(root, "a.cr"), "a")
        File.write(File.join(root, "b.cr"), "b")
        File.write(File.join(root, "c.cr"), "c")

        output = tools.list_files(glob: "*.cr")
        output.should contain("a.cr")
        output.should contain("b.cr")
        output.should_not contain("c.cr")
        output.should contain("[... 1 more matching files truncated. Narrow 'glob' pattern or specify a more specific 'path'.]")
      end
    end

    it "excludes protected and sensitive paths from directory counts in collapsed listings" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        env.settings.list_files_max_results = 2
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        Dir.mkdir_p(File.join(root, "src", ".git"))
        Dir.mkdir_p(File.join(root, "src", ".nightmare"))
        File.write(File.join(root, "src", "app.cr"), "app")
        File.write(File.join(root, "src", "b.cr"), "b")
        File.write(File.join(root, "src", "c.cr"), "c")
        File.write(File.join(root, "src", ".env"), "SECRET=1")
        File.write(File.join(root, "src", ".git", "config"), "git")
        File.write(File.join(root, "src", ".nightmare", "state.json"), "state")

        output = tools.list_files
        output.should contain("src/ (3 files)")
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

    it "reads file lines with offset and omitted limit without arithmetic overflow" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        File.write(File.join(root, "lines.txt"), "one\ntwo\nthree\nfour\nfive")

        result = tools.read_file("lines.txt", offset: 3)
        result.should contain("3 | three")
        result.should contain("4 | four")
        result.should contain("5 | five")
        result.should_not contain("1 | one")
        result.should_not contain("2 | two")
      end
    end

    it "handles offset beyond line count gracefully" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        File.write(File.join(root, "lines.txt"), "one\ntwo\nthree\nfour\nfive")

        result = tools.read_file("lines.txt", offset: 150)
        result.should eq("")
      end
    end

    it "returns empty output when limit is 0" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        File.write(File.join(root, "lines.txt"), "one\ntwo\nthree\nfour\nfive")

        result = tools.read_file("lines.txt", offset: 2, limit: 0)
        result.should eq("")
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

    it "refuses unpaginated bulk data files (*.jsonl, *.log)" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        File.write(File.join(root, "events.jsonl"), "{\"k\":\"v\"}\n" * 10)

        # Unpaginated read should be refused
        result = tools.read_file("events.jsonl")
        result.should contain("[Refused:")
        result.should contain("matches bulk data/log pattern")

        # Exceeding bulk_data_max_lines should also be refused
        result_excessive = tools.read_file("events.jsonl", limit: env.settings.bulk_data_max_lines + 10)
        result_excessive.should contain("[Refused:")
        result_excessive.should contain("matches bulk data/log pattern")

        # Paginated read within limit should succeed
        result_paginated = tools.read_file("events.jsonl", offset: 1, limit: 5)
        result_paginated.should_not contain("[Refused:")
        result_paginated.should contain("1 | {\"k\":\"v\"}")
      end
    end

    it "refuses files exceeding per_file_max_tokens ceiling" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        env.settings.per_file_max_tokens = 50 # very low ceiling for test
        guard = Nightmare::Tools::Guard.new(env)
        tools = Nightmare::Tools::ReadOnly.new(guard)

        # 30 lines of 30 chars = 900 chars => ~257 tokens > 50 tokens
        File.write(File.join(root, "huge.txt"), ("long line of content text here\n" * 30))

        result = tools.read_file("huge.txt")
        result.should contain("[Refused:")
        result.should contain("exceeds the per-file context limit of 50 tokens")
        result.should contain("use read_file with 'offset' and 'limit'")

        # Reading small slice under 50 tokens should succeed
        slice_result = tools.read_file("huge.txt", offset: 1, limit: 2)
        slice_result.should_not contain("[Refused:")
        slice_result.should contain("1 | long line of content text here")
      end
    end

    it "lists files, searches, reads, and inspects files in external readable directories" do
      with_temp_dir do |root|
        with_temp_dir do |ext_dir|
          File.write(File.join(ext_dir, "skill_a.md"), "# Skill Alpha\nImportant guidelines here")
          Dir.mkdir_p(File.join(ext_dir, "guides"))
          File.write(File.join(ext_dir, "guides", "deploy.md"), "# Deploy Guide\nStep 1: test")

          env = Nightmare::Workspace::Environment.new(
            root,
            ensure_dirs: false,
            cli_readable_directories: [ext_dir]
          )
          guard = Nightmare::Tools::Guard.new(env)
          tools = Nightmare::Tools::ReadOnly.new(guard)

          # 1. list_files on external directory
          list_out = tools.list_files(path: ext_dir)
          list_out.should contain("#{ext_dir}/skill_a.md")
          list_out.should contain("#{ext_dir}/guides/deploy.md")

          # 2. search on external directory
          search_out = tools.search("Alpha", path: ext_dir)
          search_out.should contain("#{ext_dir}/skill_a.md:1: # Skill Alpha")

          # 3. read_file on external directory
          read_out = tools.read_file(File.join(ext_dir, "skill_a.md"), offset: 1, limit: 2)
          read_out.should contain("1 | # Skill Alpha")
          read_out.should contain("2 | Important guidelines here")

          # 4. file_info on external directory
          info_json = JSON.parse(tools.file_info(File.join(ext_dir, "skill_a.md")))
          info_json["path"].as_s.should eq(File.join(ext_dir, "skill_a.md"))
          info_json["directory"].as_bool.should be_false
          info_json["lines"].as_i.should eq(2)
        end
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

    it "performs write_file, replace_in_file, and append_to_file in external writable directories" do
      with_temp_dir do |root|
        with_temp_dir do |ext_dir|
          env = Nightmare::Workspace::Environment.new(
            root,
            ensure_dirs: false,
            cli_writable_directories: [ext_dir]
          )
          guard = Nightmare::Tools::Guard.new(env)
          effects = [] of String
          handler = ->(_diff : String, _desc : String) { true }
          mutation = Nightmare::Tools::Mutation.new(guard, handler)
          mutation.active_side_effects = effects

          # 1. write_file (new file in external dir)
          target_file = File.join(ext_dir, "test.txt")
          res1 = mutation.write_file(target_file, "First line\n")
          res1.should contain("Successfully wrote")
          File.read(target_file).should eq("First line\n")
          effects.should contain(target_file)

          # 2. append_to_file (existing file in external dir)
          res2 = mutation.append_to_file(target_file, "Second line\n")
          res2.should contain("Successfully appended")
          File.read(target_file).should eq("First line\nSecond line\n")

          # 3. replace_in_file (existing file in external dir)
          res3 = mutation.replace_in_file(target_file, "First line", "Initial line")
          res3.should contain("Successfully replaced")
          File.read(target_file).should eq("Initial line\nSecond line\n")

          # 4. write_file to an external directory without approval is rejected
          with_temp_dir do |unauthorized_dir|
            reject_handler = ->(_diff : String, _desc : String) { false }
            reject_mutation = Nightmare::Tools::Mutation.new(guard, reject_handler)
            res = reject_mutation.write_file(File.join(unauthorized_dir, "hack.txt"), "bad")
            res.should eq("[Execution rejected by user]")
            File.exists?(File.join(unauthorized_dir, "hack.txt")).should be_false
          end

          # 5. write_file to sensitive or protected external paths raises SecurityError
          with_temp_dir do |unauthorized_dir|
            expect_raises(Nightmare::SecurityError, /is a sensitive path/) do
              mutation.write_file(File.join(unauthorized_dir, ".env"), "bad")
            end
            expect_raises(Nightmare::SecurityError, /is a protected path/) do
              mutation.write_file(File.join(unauthorized_dir, ".git", "config"), "bad")
            end
          end
        end
      end
    end

    it "elevates mutations outside pwd to approval and auto-approves new files inside pwd (TKT-037)" do
      with_temp_dir do |root|
        with_temp_dir do |ext_dir|
          env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
          guard = Nightmare::Tools::Guard.new(env)
          prompts = [] of String
          handler = ->(_diff : String, desc : String) {
            prompts << desc
            true
          }
          mutation = Nightmare::Tools::Mutation.new(guard, handler)

          # 1. New file inside pwd is auto-approved without prompting handler
          res_in = mutation.write_file("internal.txt", "content inside pwd")
          res_in.should contain("Successfully wrote")
          prompts.size.should eq(0)
          File.read(File.join(root, "internal.txt")).should eq("content inside pwd")

          # 2. New file outside pwd prompts handler with [outside pwd]
          ext_target = File.join(ext_dir, "service.conf")
          res_out = mutation.write_file(ext_target, "service config")
          res_out.should contain("Successfully wrote")
          prompts.size.should eq(1)
          prompts.last.should contain("[outside pwd]")
          prompts.last.should contain("create new file")
          File.read(ext_target).should eq("service config")

          # 3. Existing file outside pwd prompts handler with [outside pwd]
          res_edit = mutation.write_file(ext_target, "service config v2")
          res_edit.should contain("Successfully wrote")
          prompts.size.should eq(2)
          prompts.last.should contain("[outside pwd]")
          prompts.last.should contain("overwrite")
          File.read(ext_target).should eq("service config v2")

          # 4. Appending to external file prompts handler with [outside pwd]
          res_append = mutation.append_to_file(ext_target, "\nnew line")
          res_append.should contain("Successfully appended")
          prompts.size.should eq(3)
          prompts.last.should contain("[outside pwd]")
          prompts.last.should contain("append to")

          # 5. Workspace root has no ~ directory created
          File.exists?(File.join(root, "~")).should be_false
        end
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

    it "caps shell command formatted output at tool_output_max_bytes" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        allowlist = Nightmare::Tools::Allowlist.new

        allowlist.allow_session_prefix(["python3"])
        script_file = File.join(root, "large_lines.py")
        File.write(script_file, <<-PY
import sys
for i in range(50):
    print("X" * 100)
PY
        )

        shell = Nightmare::Tools::Shell.new(guard, allowlist, tool_output_max_bytes: 1000)
        result = shell.run_command("python3 large_lines.py", timeout_seconds: 5)

        result.should contain("truncated")
        result.bytesize.should be <= 1000
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

    it "configures run_command with shell alias in both primary and subagent toolsets" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        client = FakeClient.new
        registry = Nightmare::Tools::Registry.new(guard, client)

        primary_run = registry.build_tools.find { |t| t.function.name == "run_command" }
        primary_run.should_not be_nil
        primary_run.not_nil!.aliases.should contain("shell")

        subagent_run = registry.build_subagent_tools.find { |t| t.function.name == "run_command" }
        subagent_run.should_not be_nil
        subagent_run.not_nil!.aliases.should contain("shell")
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
          Mantle::Clients::Response.new(content: "[SUMMARY]\nFound 3 occurrences of issue", tool_calls: nil),
        ])
        runner = Nightmare::Harness::SubagentRunner.new(client, env)
        registry = Nightmare::Tools::Registry.new(guard, client, subagent_runner: runner)

        tool = registry.build_tools.find { |t| t.function.name == "spawn_subagent" }
        result = tool.not_nil!.execute({"task" => JSON::Any.new("check code")})

        result.should contain("[Subagent completed - 0 tool calls]")
        result.should contain("Found 3 occurrences of issue")
      end
    end

    it "forwards budget_iterations from tool args to runner" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        client = FakeClient.new([
          Mantle::Clients::Response.new(content: "[SUMMARY]\nDone in budget", tool_calls: nil),
        ])
        runner = Nightmare::Harness::SubagentRunner.new(client, env)
        registry = Nightmare::Tools::Registry.new(guard, client, subagent_runner: runner)

        tool = registry.build_tools.find { |t| t.function.name == "spawn_subagent" }
        tool.should_not be_nil

        props = tool.not_nil!.function.parameters.properties
        props.has_key?("budget_iterations").should be_true

        result = tool.not_nil!.execute({
          "task"              => JSON::Any.new("test budget"),
          "budget_iterations" => JSON::Any.new(3_i64),
        })
        result.should contain("Done in budget")
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

  describe "web_search tool integration" do
    it "includes web_search in both primary tools and subagent tools" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        client = FakeClient.new
        registry = Nightmare::Tools::Registry.new(guard, client)

        primary_names = registry.build_tools.map(&.function.name)
        primary_names.should contain("web_search")

        subagent_names = registry.build_subagent_tools.map(&.function.name)
        subagent_names.should contain("web_search")
      end
    end

    it "executes web_search tool and enforces required parameters and API key checks" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, xdg_config_home: File.join(root, "config"), ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        client = FakeClient.new
        registry = Nightmare::Tools::Registry.new(guard, client)

        tool = registry.build_tools.find { |t| t.function.name == "web_search" }
        tool.should_not be_nil

        # Missing query
        missing_query_res = tool.not_nil!.execute({} of String => JSON::Any)
        parsed_missing = JSON.parse(missing_query_res)
        parsed_missing["success"].as_bool.should be_false
        parsed_missing["error"].as_s.should contain("Missing required parameter: query")

        # Missing API key
        old_key = ENV["TAVILY_API_KEY"]?
        old_tavily_key = ENV["TAVILY_KEY"]?
        old_xdg = ENV["XDG_CONFIG_HOME"]?
        ENV.delete("TAVILY_API_KEY")
        ENV.delete("TAVILY_KEY")
        ENV["XDG_CONFIG_HOME"] = root
        begin
          res = tool.not_nil!.execute({"query" => JSON::Any.new("test search")})
          parsed = JSON.parse(res)
          parsed["success"].as_bool.should be_false
          parsed["error"].as_s.should contain("TAVILY_API_KEY")
        ensure
          ENV["TAVILY_API_KEY"] = old_key if old_key
          ENV["TAVILY_KEY"] = old_tavily_key if old_tavily_key
          if old_xdg
            ENV["XDG_CONFIG_HOME"] = old_xdg
          else
            ENV.delete("XDG_CONFIG_HOME")
          end
        end
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

    it "deduces prefix candidates and supports generalized tokenized prefix approvals" do
      # Candidate deduction across tool types
      Nightmare::Tools::Allowlist.candidate_prefix(["git", "status", "-s"]).should eq("git status")
      Nightmare::Tools::Allowlist.candidate_prefix(["crystal", "spec", "spec/tools_spec.cr"]).should eq("crystal spec")
      Nightmare::Tools::Allowlist.candidate_prefix(["sed", "-n", "51,100p", "file.sh"]).should eq("sed -n")
      Nightmare::Tools::Allowlist.candidate_prefix(["head", "-n", "20", "file.txt"]).should eq("head -n")
      Nightmare::Tools::Allowlist.candidate_prefix(["grep", "-rn", "foo", "src/"]).should eq("grep -rn")
      Nightmare::Tools::Allowlist.candidate_prefix(["cat", "PROGRESS.md"]).should eq("cat")
      Nightmare::Tools::Allowlist.candidate_prefix(["ls", "-la"]).should eq("ls -la")

      allowlist = Nightmare::Tools::Allowlist.new

      # Approving candidate prefix for repetitive reads (sed -n)
      allowlist.allow_session_prefix(["sed", "-n", "1,50p", "file.sh"])
      allowlist.session_prefix.should contain("sed -n")

      # Subsequent slices match the prefix
      allowlist.auto_approvable?("sed -n 51,100p file.sh", ["sed", "-n", "51,100p", "file.sh"]).should be_true
      allowlist.auto_approvable?("sed -n 101,150p other.sh", ["sed", "-n", "101,150p", "other.sh"]).should be_true
      # Mutating or different flag does NOT match prefix
      allowlist.auto_approvable?("sed -i s/a/b/ file.sh", ["sed", "-i", "s/a/b/", "file.sh"]).should be_false

      # Approving a specific edited prefix (e.g. cat PROGRESS.md)
      allowlist.allow_session_prefix("cat PROGRESS.md")
      allowlist.auto_approvable?("cat PROGRESS.md", ["cat", "PROGRESS.md"]).should be_true
      # Different operand is blocked when explicit prefix was narrowed
      allowlist.auto_approvable?("cat /etc/shadow", ["cat", "/etc/shadow"]).should be_false

      # Commands with metacharacters (pipes, semicolons, redirects) are strictly barred from prefix auto-approval
      allowlist.auto_approvable?("sed -n 1,50p file.sh | grep foo", ["sed", "-n", "1,50p", "file.sh", "|", "grep", "foo"]).should be_false
      allowlist.auto_approvable?("sed -n 1,50p file.sh; rm -rf /", ["sed", "-n", "1,50p", "file.sh;", "rm", "-rf", "/"]).should be_false
      allowlist.auto_approvable?("sed -n 1,50p file.sh > /tmp/out", ["sed", "-n", "1,50p", "file.sh", ">", "/tmp/out"]).should be_false

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

    it "executes shell pipelines cleanly under bash -c when approved" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        allowlist = Nightmare::Tools::Allowlist.new

        handler = ->(_cmd : String, _argv : Array(String), has_meta : Bool, _timeout : Int32) {
          has_meta.should be_true
          {Nightmare::Tools::ApprovalOutcome::Yes, nil.as(String?)}
        }

        shell = Nightmare::Tools::Shell.new(guard, allowlist, approval_handler: handler)
        result = shell.run_command("echo 'hello pipeline' | tr 'a-z' 'A-Z'")
        result.should contain("HELLO PIPELINE")
      end
    end

    it "saves exact compound/pipeline commands to allowlist on [a] approval and auto-approves subsequent identical runs" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        allowlist = Nightmare::Tools::Allowlist.new

        handler_calls = 0
        handler = ->(_cmd : String, _argv : Array(String), _has_meta : Bool, _timeout : Int32) {
          handler_calls += 1
          {Nightmare::Tools::ApprovalOutcome::AllSession, nil.as(String?)}
        }

        shell = Nightmare::Tools::Shell.new(guard, allowlist, approval_handler: handler)
        cmd = "echo foo | grep foo"
        res1 = shell.run_command(cmd)
        res1.should contain("foo")
        handler_calls.should eq(1)

        # Exact command is saved and auto-approvable
        allowlist.session_exact.should contain(cmd)
        allowlist.auto_approvable?(cmd, Nightmare::Tools::Allowlist.tokenize(cmd)).should be_true

        # Second identical invocation runs autonomously without prompting
        res2 = shell.run_command(cmd)
        res2.should contain("foo")
        handler_calls.should eq(1)

        # A variation with different arguments forces approval again
        diff_cmd = "echo bar | grep foo"
        shell.run_command(diff_cmd)
        handler_calls.should eq(2)
      end
    end

    it "refuses to save prefix for compound commands on [p] approval" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        allowlist = Nightmare::Tools::Allowlist.new

        handler_calls = 0
        handler = ->(_cmd : String, _argv : Array(String), _has_meta : Bool, _timeout : Int32) {
          handler_calls += 1
          {Nightmare::Tools::ApprovalOutcome::PrefixSession, nil.as(String?)}
        }

        shell = Nightmare::Tools::Shell.new(guard, allowlist, approval_handler: handler)
        cmd = "echo foo | grep foo"
        shell.run_command(cmd)

        handler_calls.should eq(1)
        # Prefix is not saved
        allowlist.session_prefix.should be_empty
        allowlist.auto_approvable?(cmd, Nightmare::Tools::Allowlist.tokenize(cmd)).should be_false

        # Second invocation still prompts
        shell.run_command(cmd)
        handler_calls.should eq(2)
      end
    end
  end
end
