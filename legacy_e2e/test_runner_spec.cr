require "../spec_helper"
require "./test_runner"
require "http/client"

describe Nightmare::E2E::WorkspaceSandbox do
  it "creates isolated temporary root and XDG directories with deterministic workspace ID" do
    Nightmare::E2E.with_sandbox("test_infra_") do |sandbox|
      Dir.exists?(sandbox.root_path).should be_true
      Dir.exists?(sandbox.xdg_config).should be_true
      Dir.exists?(sandbox.xdg_state).should be_true
      Dir.exists?(sandbox.xdg_cache).should be_true

      sandbox.workspace_id.should match(/^[a-zA-Z0-9_-]+-[a-f0-9]{8}$/)
      sandbox.workspace_config_dir.should end_with("/nightmare/workspaces/#{sandbox.workspace_id}")
      sandbox.workspace_state_dir.should end_with("/nightmare/workspaces/#{sandbox.workspace_id}")
      sandbox.workspace_cache_dir.should end_with("/nightmare/workspaces/#{sandbox.workspace_id}")
    end
  end

  it "tracks created files and verifies zero repo litter" do
    Nightmare::E2E.with_sandbox("test_litter_") do |sandbox|
      sandbox.write_file("src/main.cr", "puts 123")
      sandbox.file_exists?("src/main.cr").should be_true
      sandbox.read_file("src/main.cr").should eq("puts 123")

      sandbox.init_git_repo!
      sandbox.file_exists?(".git/HEAD").should be_true

      # Verify zero repo litter succeeds when only allowed files exist
      sandbox.assert_zero_repo_litter!

      # Write an unexpected file directly without registering
      unauth = File.join(sandbox.root_path, "unexpected.log")
      File.write(unauth, "dirty")

      expect_raises(Exception, /Repository litter violation/) do
        sandbox.assert_zero_repo_litter!
      end

      # Remove unauth file and verify clean assertion passes
      File.delete(unauth)
      sandbox.assert_zero_repo_litter!
    end
  end

  it "creates symlinks inside workspace" do
    Nightmare::E2E.with_sandbox("test_symlink_") do |sandbox|
      sandbox.write_file("target.txt", "target content")
      sandbox.create_symlink("link.txt", File.join(sandbox.root_path, "target.txt"))

      sandbox.file_exists?("link.txt").should be_true
      sandbox.read_file("link.txt").should eq("target content")
    end
  end
end

describe Nightmare::E2E::MockLlmServer do
  it "serves canned text responses with token counts" do
    Nightmare::E2E.with_mock_llm do |server|
      server.enqueue_text_response("Hello from mock LLM", prompt_tokens: 15, completion_tokens: 5)

      response = HTTP::Client.post(
        server.api_url,
        body: {messages: [{role: "user", content: "hi"}]}.to_json,
        headers: HTTP::Headers{"Content-Type" => "application/json"}
      )

      response.status_code.should eq(200)
      json = JSON.parse(response.body)
      json["message"]["content"].as_s.should eq("Hello from mock LLM")
      json["prompt_eval_count"].as_i.should eq(15)
      json["eval_count"].as_i.should eq(5)
      server.requests.size.should eq(1)
    end
  end

  it "serves tool calls and handles 429 rate limit responses" do
    Nightmare::E2E::MockLlmServer.new.tap do |server|
      server.start
      begin
        server.enqueue_tool_call("read_file", {"path" => "src/app.cr"})
        server.enqueue_rate_limit(retry_after: 2)

        # First request: Tool Call
        res1 = HTTP::Client.post(server.api_url, body: "{}")
        res1.status_code.should eq(200)
        json1 = JSON.parse(res1.body)
        json1["message"]["tool_calls"].size.should eq(1)
        json1["message"]["tool_calls"][0]["function"]["name"].as_s.should eq("read_file")

        # Second request: Rate Limit 429
        res2 = HTTP::Client.post(server.api_url, body: "{}")
        res2.status_code.should eq(429)
        res2.headers["Retry-After"].should eq("2")
      ensure
        server.stop
      end
    end
  end
end

describe Nightmare::E2E::ProcessSession do
  it "executes process, streams input and captures output" do
    p = Process.new(
      "sh",
      ["-c", "read line; echo \"Echo: $line\""],
      input: Process::Redirect::Pipe,
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe
    )
    session = Nightmare::E2E::ProcessSession.new(p)
    session.send_line("test-token-42")
    session.wait_for("Echo: test-token-42")
    status = session.wait_exit
    status.exit_code.should eq(0)
    session.stdout.should contain("Echo: test-token-42")
  end

  it "handles process signals" do
    p = Process.new(
      "sh",
      ["-c", "trap \"echo got_sigint; exit 0\" INT; while true; do sleep 0.01; done"],
      input: Process::Redirect::Pipe,
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe
    )
    session = Nightmare::E2E::ProcessSession.new(p)
    sleep 50.milliseconds
    session.send_signal(Signal::INT)
    session.wait_for("got_sigint")
    status = session.wait_exit
    status.exit_code.should eq(0)
  end
end
