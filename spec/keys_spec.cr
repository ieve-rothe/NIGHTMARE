# spec/keys_spec.cr
require "./spec_helper"

describe Nightmare::Keys do
  it "resolves key from ENV variable with _API_KEY suffix" do
    old = ENV["TAVILY_API_KEY"]?
    ENV["TAVILY_API_KEY"] = "env-tavily-test-key-123"
    begin
      Nightmare::Keys.get?("tavily").should eq("env-tavily-test-key-123")
      Nightmare::Keys.get!("tavily").should eq("env-tavily-test-key-123")
    ensure
      if old
        ENV["TAVILY_API_KEY"] = old
      else
        ENV.delete("TAVILY_API_KEY")
      end
    end
  end

  it "resolves key from ENV variable with _KEY suffix" do
    old_api = ENV["TAVILY_API_KEY"]?
    old_key = ENV["TAVILY_KEY"]?
    ENV.delete("TAVILY_API_KEY")
    ENV["TAVILY_KEY"] = "alt-key-456"
    begin
      Nightmare::Keys.get?("tavily").should eq("alt-key-456")
    ensure
      ENV.delete("TAVILY_KEY")
      ENV["TAVILY_API_KEY"] = old_api if old_api
      ENV["TAVILY_KEY"] = old_key if old_key
    end
  end

  it "resolves key from global keys directory (~/.config/nightmare/keys/<name>)" do
    old_api = ENV["TAVILY_API_KEY"]?
    old_key = ENV["TAVILY_KEY"]?
    ENV.delete("TAVILY_API_KEY")
    ENV.delete("TAVILY_KEY")

    with_temp_dir do |root|
      env = Nightmare::Workspace::Environment.new(root, xdg_config_home: File.join(root, ".config"), ensure_dirs: true)
      key_file = File.join(env.global_keys_dir, "tavily")
      File.write(key_file, "  file-secret-key-789  \n")

      Nightmare::Keys.get?("tavily", env).should eq("file-secret-key-789")
    end
  ensure
    ENV["TAVILY_API_KEY"] = old_api if old_api
    ENV["TAVILY_KEY"] = old_key if old_key
  end

  it "resolves key from global flat file (~/.config/nightmare/<name>_key)" do
    old_api = ENV["TAVILY_API_KEY"]?
    old_key = ENV["TAVILY_KEY"]?
    ENV.delete("TAVILY_API_KEY")
    ENV.delete("TAVILY_KEY")

    with_temp_dir do |root|
      env = Nightmare::Workspace::Environment.new(root, xdg_config_home: File.join(root, ".config"), ensure_dirs: true)
      flat_file = File.join(env.global_config_dir, "tavily_key")
      File.write(flat_file, "flat-key-abc")

      Nightmare::Keys.get?("tavily", env).should eq("flat-key-abc")
    end
  ensure
    ENV["TAVILY_API_KEY"] = old_api if old_api
    ENV["TAVILY_KEY"] = old_key if old_key
  end

  it "resolves key from workspace keys directory" do
    old_api = ENV["TAVILY_API_KEY"]?
    old_key = ENV["TAVILY_KEY"]?
    ENV.delete("TAVILY_API_KEY")
    ENV.delete("TAVILY_KEY")

    with_temp_dir do |root|
      env = Nightmare::Workspace::Environment.new(root, xdg_config_home: File.join(root, ".config"), ensure_dirs: true)
      Dir.mkdir_p(env.workspace_keys_dir)
      ws_key_file = File.join(env.workspace_keys_dir, "tavily")
      File.write(ws_key_file, "ws-specific-key")

      Nightmare::Keys.get?("tavily", env).should eq("ws-specific-key")
    end
  ensure
    ENV["TAVILY_API_KEY"] = old_api if old_api
    ENV["TAVILY_KEY"] = old_key if old_key
  end

  it "raises informative error on get! when key is missing" do
    old_api = ENV["TAVILY_API_KEY"]?
    old_key = ENV["TAVILY_KEY"]?
    ENV.delete("TAVILY_API_KEY")
    ENV.delete("TAVILY_KEY")

    with_temp_dir do |root|
      env = Nightmare::Workspace::Environment.new(root, xdg_config_home: File.join(root, ".config"), ensure_dirs: false)
      expect_raises(Exception, /Missing non_existent API key in ENV or ~\/.config\/nightmare\/keys\/non_existent/) do
        Nightmare::Keys.get!("non_existent", env)
      end
    end
  ensure
    ENV["TAVILY_API_KEY"] = old_api if old_api
    ENV["TAVILY_KEY"] = old_key if old_key
  end
end
