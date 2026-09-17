# spec/integration/workflows_spec.cr
require "../spec_helper"
require "../support/integration_harness"

describe "Core Developer Workflows (Integration)" do
  # Workflow 1: Codebase Survey & Zero Repository Litter
  describe "Workflow 1: Codebase Survey & Zero Repository Litter" do
    it "executes autonomous read-only exploration tools and leaves zero repo litter" do
      Nightmare::Integration.with_sandbox("survey_workflow_") do |sandbox|
        sandbox.init_git_repo!
        sandbox.write_file("src/app.cr", "module App\n  def self.run; puts 'running'; end\nend\n")
        sandbox.write_file("shard.yml", "name: app\nversion: 0.1.0\n")

        Nightmare::Integration.with_mock_llm do |mock|
          # Enqueue model actions: list_files, then file_info, then text response
          mock.enqueue_tool_call("list_files", {"directory" => "."})
          mock.enqueue_tool_call("file_info", {"path" => "src/app.cr"})
          mock.enqueue_text_response("Workspace survey completed. Found App module in src/app.cr.")

          session = Nightmare::Integration.spawn_nightmare(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          )

          # Send instruction
          session.send_line("Survey this project")

          # Read tools execute autonomously (zero approval modals needed)
          session.wait_for("Workspace survey completed")

          session.send_line("/exit")
          status = session.wait_exit
          status.exit_code.should eq(0)

          # 1. Output assertion: Agent confirmed findings in stdout
          session.stdout.should contain("Found App module in src/app.cr")

          # 2. State assertion: Central XDG directories were created
          Dir.exists?(sandbox.workspace_config_dir).should be_true
          sandbox.manifest_exists?.should be_true

          # 3. Security & Cleanliness invariant: Repo root contains ZERO agent litter
          sandbox.assert_zero_repo_litter!
        end
      end
    end
  end

  # Workflow 2: File Mutation with Unified Diff Approval Modal
  describe "Workflow 2: File Mutation with Unified Diff Approval Modal" do
    it "presents diff modal; user rejection [N] leaves file untouched" do
      Nightmare::Integration.with_sandbox("mutation_reject_") do |sandbox|
        original_code = "def calculate(x)\n  x * 2\nend\n"
        sandbox.write_file("src/calc.cr", original_code)

        Nightmare::Integration.with_mock_llm do |mock|
          mock.enqueue_tool_call("replace_in_file", {
            "path"        => "src/calc.cr",
            "target"      => "x * 2",
            "replacement" => "x * 99",
          })
          mock.enqueue_text_response("Mutation handled after rejection.")

          session = Nightmare::Integration.spawn_nightmare(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          )

          session.send_line("Multiply by 99 instead")

          # REPL must suspend and prompt for approval
          session.wait_for(/(?:Approve|overwrite|replace)/i)

          # User rejects with 'N'
          session.send_line("N")

          session.wait_for("Mutation handled after rejection")
          session.send_line("/exit")
          session.wait_exit

          # Strict assertion: Target file on disk MUST NOT have changed
          sandbox.read_file("src/calc.cr").should eq(original_code)
        end
      end
    end

    it "presents diff modal; user approval [y] updates file on disk" do
      Nightmare::Integration.with_sandbox("mutation_approve_") do |sandbox|
        original_code = "def calculate(x)\n  x * 2\nend\n"
        sandbox.write_file("src/calc.cr", original_code)

        Nightmare::Integration.with_mock_llm do |mock|
          mock.enqueue_tool_call("replace_in_file", {
            "path"        => "src/calc.cr",
            "target"      => "x * 2",
            "replacement" => "x * 10",
          })
          mock.enqueue_text_response("Calculation updated successfully.")

          session = Nightmare::Integration.spawn_nightmare(
            sandbox,
            extra_env: {"MANTLE_API_URL" => mock.api_url}
          )

          session.send_line("Update calculation to times 10")

          # REPL must suspend and prompt for approval
          session.wait_for(/(?:Approve|overwrite|replace)/i)

          # User approves with 'y'
          session.send_line("y")

          session.wait_for("Calculation updated successfully")
          session.send_line("/exit")
          session.wait_exit

          # Strict assertion: Target file on disk MUST be mutated
          sandbox.read_file("src/calc.cr").should eq("def calculate(x)\n  x * 10\nend\n")
        end
      end
    end
  end
end
