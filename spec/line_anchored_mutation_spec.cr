# spec/line_anchored_mutation_spec.cr
require "./spec_helper"
require "../src/nightmare/tools/mutation"
require "../src/nightmare/tools/registry"

describe "Line-Anchored Mutation & Prefix Stripping (TKT-008)" do
  describe "Nightmare::Tools::Mutation#replace_in_file" do
    it "replaces a single line when start_line and end_line are equal" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        mutation = Nightmare::Tools::Mutation.new(guard, ->(diff : String, desc : String) { true })

        file_path = File.join(dir, "sample.txt")
        File.write(file_path, "line 1\nline 2\nline 3\n")

        res = mutation.replace_in_file("sample.txt", replacement: "updated line 2", start_line: 2, end_line: 2)
        res.should contain("Successfully replaced lines 2..2 in sample.txt")

        File.read(file_path).should eq("line 1\nupdated line 2\nline 3\n")
      end
    end

    it "defaults end_line to start_line if only start_line is provided without target" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        mutation = Nightmare::Tools::Mutation.new(guard, ->(diff : String, desc : String) { true })

        file_path = File.join(dir, "sample.txt")
        File.write(file_path, "line 1\nline 2\nline 3\n")

        res = mutation.replace_in_file("sample.txt", replacement: "updated line 2", start_line: 2)
        res.should contain("Successfully replaced lines 2..2 in sample.txt")

        File.read(file_path).should eq("line 1\nupdated line 2\nline 3\n")
      end
    end

    it "derives end_line from multi-line target when start_line is provided and end_line is omitted" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        mutation = Nightmare::Tools::Mutation.new(guard, ->(diff : String, desc : String) { true })

        file_path = File.join(dir, "sample.txt")
        File.write(file_path, "line 1\nline 2\nline 3\nline 4\nline 5\n")

        target = "line 2\nline 3\nline 4"
        res = mutation.replace_in_file("sample.txt", target: target, replacement: "new 2..4\n", start_line: 2)
        res.should contain("Successfully replaced lines 2..4 in sample.txt")

        File.read(file_path).should eq("line 1\nnew 2..4\nline 5\n")
      end
    end

    it "reproduces table replacement without duplicating subsequent rows when target is supplied with start_line" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        mutation = Nightmare::Tools::Mutation.new(guard, ->(diff : String, desc : String) { true })

        file_path = File.join(dir, "index.md")
        original_table = "## Open Tickets\n\n| Ticket ID | Title |\n| :--- | :--- |\n| TKT-001 | First |\n| TKT-002 | Second |\n\n## Closed Tickets\n"
        File.write(file_path, original_table)

        # Agent targets lines 3..6 (header + separator + 2 tickets) starting at line 3 without end_line
        target_table = "| Ticket ID | Title |\n| :--- | :--- |\n| TKT-001 | First |\n| TKT-002 | Second |"
        replacement_table = "| [TKT-001](tkt1.md) | First |\n| [TKT-002](tkt2.md) | Second |\n| [TKT-003](tkt3.md) | Third |"

        res = mutation.replace_in_file("index.md", target: target_table, replacement: replacement_table, start_line: 3)
        res.should contain("Successfully replaced lines 3..6 in index.md")

        expected = "## Open Tickets\n\n| [TKT-001](tkt1.md) | First |\n| [TKT-002](tkt2.md) | Second |\n| [TKT-003](tkt3.md) | Third |\n\n## Closed Tickets\n"
        File.read(file_path).should eq(expected)
      end
    end

    it "returns error when target content does not match lines start_line..end_line" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        mutation = Nightmare::Tools::Mutation.new(guard, ->(diff : String, desc : String) { true })

        file_path = File.join(dir, "sample.txt")
        File.write(file_path, "line 1\nline 2\nline 3\n")

        res = mutation.replace_in_file("sample.txt", target: "mismatched target\n", replacement: "new\n", start_line: 1, end_line: 2)
        res.should contain("Target content does not match lines 1..2 in sample.txt")

        File.read(file_path).should eq("line 1\nline 2\nline 3\n")
      end
    end

    it "strips read_file display prefixes from target when verifying line-anchored replacement" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        mutation = Nightmare::Tools::Mutation.new(guard, ->(diff : String, desc : String) { true })

        file_path = File.join(dir, "sample.txt")
        File.write(file_path, "line 1\nline 2\nline 3\nline 4\n")

        target = "    2 | line 2\n    3 | line 3\n"
        res = mutation.replace_in_file("sample.txt", target: target, replacement: "updated 2..3\n", start_line: 2)
        res.should contain("Successfully replaced lines 2..3 in sample.txt")

        File.read(file_path).should eq("line 1\nupdated 2..3\nline 4\n")
      end
    end

    it "replaces a multi-line range" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        mutation = Nightmare::Tools::Mutation.new(guard, ->(diff : String, desc : String) { true })

        file_path = File.join(dir, "sample.txt")
        File.write(file_path, "header\nold 1\nold 2\nold 3\nfooter\n")

        res = mutation.replace_in_file("sample.txt", replacement: "new middle\n", start_line: 2, end_line: 4)
        res.should contain("Successfully replaced lines 2..4 in sample.txt")

        File.read(file_path).should eq("header\nnew middle\nfooter\n")
      end
    end

    it "strips read_file display prefixes from replacement in line-anchored mode" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        mutation = Nightmare::Tools::Mutation.new(guard, ->(diff : String, desc : String) { true })

        file_path = File.join(dir, "sample.txt")
        File.write(file_path, "line 1\nline 2\nline 3\n")

        # Agent accidentally passed read_file numbered lines into replacement
        decorated_replacement = "   28 | line 2 modified"
        res = mutation.replace_in_file("sample.txt", replacement: decorated_replacement, start_line: 2, end_line: 2)
        res.should contain("Successfully replaced lines 2..2 in sample.txt")

        File.read(file_path).should eq("line 1\nline 2 modified\nline 3\n")
      end
    end

    it "rejects out of bounds line coordinates" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        mutation = Nightmare::Tools::Mutation.new(guard, ->(diff : String, desc : String) { true })

        file_path = File.join(dir, "sample.txt")
        File.write(file_path, "line 1\nline 2\n")

        res = mutation.replace_in_file("sample.txt", replacement: "foo", start_line: 0, end_line: 1)
        res.should contain("Invalid line range 0..1")

        res2 = mutation.replace_in_file("sample.txt", replacement: "foo", start_line: 2, end_line: 1)
        res2.should contain("Invalid line range 2..1")

        res3 = mutation.replace_in_file("sample.txt", replacement: "foo", start_line: 1, end_line: 5)
        res3.should contain("Invalid line range 1..5 for sample.txt (file has 2 lines)")
      end
    end

    it "falls back to stripping display prefixes when pure substring match fails" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        mutation = Nightmare::Tools::Mutation.new(guard, ->(diff : String, desc : String) { true })

        file_path = File.join(dir, "sample.txt")
        File.write(file_path, "def run\n  puts \"hello world\"\nend\n")

        # Target copied straight out of read_file with line numbers
        target = "    2 |   puts \"hello world\""
        replacement = "  puts \"hello nightmare\""

        res = mutation.replace_in_file("sample.txt", target: target, replacement: replacement)
        res.should contain("Successfully replaced content in sample.txt")

        File.read(file_path).should eq("def run\n  puts \"hello nightmare\"\nend\n")
      end
    end

    it "strips display prefixes from both target and replacement in fallback mode" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        mutation = Nightmare::Tools::Mutation.new(guard, ->(diff : String, desc : String) { true })

        file_path = File.join(dir, "sample.txt")
        File.write(file_path, "first\nsecond\nthird\n")

        target = "    2 | second"
        replacement = "    2 | updated second"

        res = mutation.replace_in_file("sample.txt", target: target, replacement: replacement)
        res.should contain("Successfully replaced content in sample.txt")

        File.read(file_path).should eq("first\nupdated second\nthird\n")
      end
    end
  end

  describe "Registry Tool Schemas" do
    it "exposes start_line and end_line in replace_in_file tool" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        client = FakeClient.new([] of Mantle::Clients::Response)
        registry = Nightmare::Tools::Registry.new(
          guard: guard,
          client: client,
          diff_approval: ->(d : String, desc : String) { true }
        )

        tools = registry.build_tools
        replace_tool = tools.find { |t| t.function.name == "replace_in_file" }.not_nil!
        replace_tool.function.description.should contain("line-anchored range")
        replace_tool.function.parameters.properties.has_key?("start_line").should be_true
        replace_tool.function.parameters.properties.has_key?("end_line").should be_true

        # Test tool execution with start_line / end_line
        file_path = File.join(dir, "test.txt")
        File.write(file_path, "alpha\nbeta\ngamma\n")

        args = {
          "path" => JSON::Any.new("test.txt"),
          "replacement" => JSON::Any.new("BETA"),
          "start_line" => JSON::Any.new(2_i64),
          "end_line" => JSON::Any.new(2_i64)
        }
        res = replace_tool.execute(args)
        res.should contain("Successfully replaced lines 2..2 in test.txt")
        File.read(file_path).should eq("alpha\nBETA\ngamma\n")
      end
    end

    it "clarifies line numbering decoration in read_file description" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)
        client = FakeClient.new([] of Mantle::Clients::Response)
        registry = Nightmare::Tools::Registry.new(guard, client)

        tools = registry.build_tools
        read_tool = tools.find { |t| t.function.name == "read_file" }.not_nil!
        read_tool.function.description.should contain("<line> |")
        read_tool.function.description.should contain("replace_in_file")
      end
    end
  end
end
