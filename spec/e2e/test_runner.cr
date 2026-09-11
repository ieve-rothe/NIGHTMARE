require "process"
require "file_utils"
require "digest/sha256"
require "json"
require "http/server"
require "socket"

module Nightmare::E2E
  BIN_PATH = File.expand_path("../../bin/nightmare", __DIR__)
  SRC_PATH = File.expand_path("../../src/nightmare.cr", __DIR__)

  def self.binary_exists? : Bool
    File.exists?(BIN_PATH)
  end

  def self.compile_binary! : Bool
    return true if binary_exists?

    bin_dir = File.dirname(BIN_PATH)
    Dir.mkdir_p(bin_dir) unless Dir.exists?(bin_dir)

    status = Process.run(
      "crystal",
      ["build", SRC_PATH, "-o", BIN_PATH, "--no-debug"],
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe
    )
    status.success?
  end

  class WorkspaceSandbox
    getter root_path : String
    getter xdg_config : String
    getter xdg_state : String
    getter xdg_cache : String
    getter workspace_id : String
    getter initial_files : Set(String)

    def self.make_temp_dir(prefix : String) : String
      dir = File.tempname(prefix)
      Dir.mkdir_p(dir)
      File.realpath(dir)
    end

    def initialize(@prefix : String = "nightmare_e2e_")
      @root_path = WorkspaceSandbox.make_temp_dir("#{@prefix}ws_")
      @xdg_config = WorkspaceSandbox.make_temp_dir("#{@prefix}cfg_")
      @xdg_state = WorkspaceSandbox.make_temp_dir("#{@prefix}state_")
      @xdg_cache = WorkspaceSandbox.make_temp_dir("#{@prefix}cache_")

      slug = File.basename(@root_path).gsub(/[^a-zA-Z0-9_-]/, "_")
      hash = Digest::SHA256.hexdigest(@root_path)[0..7]
      @workspace_id = "#{slug}-#{hash}"

      @initial_files = Set(String).new
    end

    def workspace_config_dir : String
      File.join(@xdg_config, "nightmare", "workspaces", @workspace_id)
    end

    def workspace_state_dir : String
      File.join(@xdg_state, "nightmare", "workspaces", @workspace_id)
    end

    def workspace_cache_dir : String
      File.join(@xdg_cache, "nightmare", "workspaces", @workspace_id)
    end

    def write_file(rel_path : String, content : String) : String
      full_path = File.expand_path(rel_path, @root_path)
      Dir.mkdir_p(File.dirname(full_path))
      File.write(full_path, content)
      @initial_files << rel_path
      full_path
    end

    def read_file(rel_path : String) : String
      full_path = File.expand_path(rel_path, @root_path)
      File.read(full_path)
    end

    def file_exists?(rel_path : String) : Bool
      full_path = File.expand_path(rel_path, @root_path)
      File.exists?(full_path)
    end

    def create_symlink(link_rel_path : String, target_path : String) : String
      full_link = File.expand_path(link_rel_path, @root_path)
      Dir.mkdir_p(File.dirname(full_link))
      File.symlink(target_path, full_link)
      @initial_files << link_rel_path
      full_link
    end

    def init_git_repo! : Nil
      git_dir = File.join(@root_path, ".git")
      Dir.mkdir_p(File.join(git_dir, "objects"))
      Dir.mkdir_p(File.join(git_dir, "refs", "heads"))
      Dir.mkdir_p(File.join(git_dir, "hooks"))
      File.write(File.join(git_dir, "HEAD"), "ref: refs/heads/main\n")
      File.write(File.join(git_dir, "config"), "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n")
      @initial_files << ".git"
    end

    def manifest_exists? : Bool
      File.exists?(File.join(workspace_config_dir, "workspace.json"))
    end

    def read_manifest : JSON::Any?
      mpath = File.join(workspace_config_dir, "workspace.json")
      return nil unless File.exists?(mpath)
      JSON.parse(File.read(mpath))
    end

    def read_allowlist : Array(String)
      apath = File.join(workspace_config_dir, "allow")
      return [] of String unless File.exists?(apath)
      File.read_lines(apath).map(&.strip).reject(&.empty?)
    end

    def read_audit_log : Array(JSON::Any)
      log_file = File.join(workspace_state_dir, "llm_calls.jsonl")
      return [] of JSON::Any unless File.exists?(log_file)
      File.read_lines(log_file).reject(&.empty?).map { |line| JSON.parse(line) }
    end

    def assert_zero_repo_litter!(allowed_created_files : Array(String) = [] of String) : Nil
      found_files = [] of String
      scan_dir(@root_path, found_files)

      disallowed = [] of String
      allowed_set = @initial_files + allowed_created_files.to_set

      found_files.each do |f|
        rel = f.sub(/^#{Regex.escape(@root_path)}\/?/, "")
        next if rel.starts_with?(".git")
        unless allowed_set.includes?(rel) || allowed_set.any? { |a| rel.starts_with?("#{a}/") }
          disallowed << rel
        end
      end

      if disallowed.size > 0
        raise "Repository litter violation! Unexpected files found in #{@root_path}: #{disallowed.join(", ")}"
      end
    end

    private def scan_dir(dir : String, acc : Array(String)) : Nil
      Dir.each_child(dir) do |child|
        full = File.join(dir, child)
        if File.directory?(full) && !File.symlink?(full)
          scan_dir(full, acc) unless child == ".git"
        else
          acc << full
        end
      end
    end

    def cleanup! : Nil
      FileUtils.rm_rf(@root_path) if Dir.exists?(@root_path)
      FileUtils.rm_rf(@xdg_config) if Dir.exists?(@xdg_config)
      FileUtils.rm_rf(@xdg_state) if Dir.exists?(@xdg_state)
      FileUtils.rm_rf(@xdg_cache) if Dir.exists?(@xdg_cache)
    end
  end

  class MockLlmServer
    getter port : Int32
    getter requests : Array(NamedTuple(path: String, method: String, body: String))
    @server : HTTP::Server
    @running : Bool = false
    @handlers : Array(Proc(HTTP::Server::Context, Bool))
    @mutex : Mutex = Mutex.new

    def initialize
      @requests = [] of NamedTuple(path: String, method: String, body: String)
      @handlers = [] of Proc(HTTP::Server::Context, Bool)

      @server = HTTP::Server.new do |context|
        req = context.request
        body_str = req.body ? req.body.not_nil!.gets_to_end : ""

        @mutex.synchronize do
          @requests << {path: req.path, method: req.method, body: body_str}
        end

        handled = false
        @mutex.synchronize do
          if handler = @handlers.shift?
            handled = handler.call(context)
          end
        end

        unless handled
          context.response.content_type = "application/json"
          context.response.status_code = 200
          context.response.print({
            model: "mock-model",
            created_at: Time.utc.to_s,
            message: {
              role: "assistant",
              content: "Default mock response"
            },
            done: true,
            prompt_eval_count: 100,
            eval_count: 20
          }.to_json)
        end
      end

      addr = @server.bind_tcp("127.0.0.1", 0)
      @port = addr.port
    end

    def start : Nil
      return if @running
      @running = true
      spawn do
        @server.listen
      end
      Fiber.yield
    end

    def stop : Nil
      return unless @running
      @server.close
      @running = false
    end

    def base_url : String
      "http://127.0.0.1:#{@port}"
    end

    def api_url : String
      "#{base_url}/api/chat"
    end

    def enqueue_text_response(content : String, prompt_tokens : Int32 = 50, completion_tokens : Int32 = 25) : Nil
      @mutex.synchronize do
        @handlers << ->(ctx : HTTP::Server::Context) {
          ctx.response.content_type = "application/json"
          ctx.response.status_code = 200
          ctx.response.print({
            model: "mock-model",
            created_at: Time.utc.to_s,
            message: {
              role: "assistant",
              content: content
            },
            done: true,
            prompt_eval_count: prompt_tokens,
            eval_count: completion_tokens
          }.to_json)
          true
        }
      end
    end

    def enqueue_tool_call(tool_name : String, tool_args : Hash(String, JSON::Any) | Hash(String, String), prompt_tokens : Int32 = 60) : Nil
      @mutex.synchronize do
        @handlers << ->(ctx : HTTP::Server::Context) {
          ctx.response.content_type = "application/json"
          ctx.response.status_code = 200
          ctx.response.print({
            model: "mock-model",
            created_at: Time.utc.to_s,
            message: {
              role: "assistant",
              content: "",
              tool_calls: [
                {
                  id: "call_#{Time.utc.to_unix_ms}",
                  function: {
                    name: tool_name,
                    arguments: tool_args
                  }
                }
              ]
            },
            done: true,
            prompt_eval_count: prompt_tokens,
            eval_count: 30
          }.to_json)
          true
        }
      end
    end

    def enqueue_thinking_response(thinking : String, answer : String) : Nil
      enqueue_text_response("<think>#{thinking}</think>#{answer}")
    end

    def enqueue_rate_limit(retry_after : Int32 = 1) : Nil
      @mutex.synchronize do
        @handlers << ->(ctx : HTTP::Server::Context) {
          ctx.response.content_type = "application/json"
          ctx.response.status_code = 429
          ctx.response.headers["Retry-After"] = retry_after.to_s
          ctx.response.print({
            error: "Rate limit exceeded. Please retry later."
          }.to_json)
          true
        }
      end
    end

    def enqueue_malformed_json(junk : String = "INVALID_JSON{{") : Nil
      @mutex.synchronize do
        @handlers << ->(ctx : HTTP::Server::Context) {
          ctx.response.content_type = "application/json"
          ctx.response.status_code = 200
          ctx.response.print(junk)
          true
        }
      end
    end
  end

  class ProcessSession
    getter process : Process
    @out_buf : IO::Memory = IO::Memory.new
    @err_buf : IO::Memory = IO::Memory.new
    @mutex : Mutex = Mutex.new
    @terminated : Bool = false

    def initialize(@process : Process)
      spawn do
        buf = Bytes.new(4096)
        while (n = @process.output.read(buf)) > 0
          @mutex.synchronize do
            @out_buf.write(buf[0, n])
          end
        end
      rescue IO::Error
      end

      spawn do
        buf = Bytes.new(4096)
        while (n = @process.error.read(buf)) > 0
          @mutex.synchronize do
            @err_buf.write(buf[0, n])
          end
        end
      rescue IO::Error
      end
    end

    def stdout : String
      @mutex.synchronize { @out_buf.to_s }
    end

    def stderr : String
      @mutex.synchronize { @err_buf.to_s }
    end

    def all_output : String
      stdout + stderr
    end

    def send_line(line : String) : Nil
      @process.input.puts(line)
      @process.input.flush
    end

    def send_chars(chars : String) : Nil
      @process.input.print(chars)
      @process.input.flush
    end

    def send_signal(sig : Signal) : Nil
      @process.signal(sig)
    end

    def close_stdin : Nil
      @process.input.close rescue nil
    end

    def wait_for(pattern : Regex | String, timeout : Time::Span = 2.seconds) : String
      deadline = Time.instant + timeout
      loop do
        current = stdout
        if pattern.is_a?(Regex) ? current =~ pattern : current.includes?(pattern)
          return current
        end
        if Time.instant > deadline
          raise "Timeout waiting for #{pattern.inspect} in output. Captured stdout:\n#{current}\nCaptured stderr:\n#{stderr}"
        end
        sleep 25.milliseconds
      end
    end

    def wait_for_error(pattern : Regex | String, timeout : Time::Span = 2.seconds) : String
      deadline = Time.instant + timeout
      loop do
        current = stderr
        if pattern.is_a?(Regex) ? current =~ pattern : current.includes?(pattern)
          return current
        end
        if Time.instant > deadline
          raise "Timeout waiting for #{pattern.inspect} in stderr. Captured stderr:\n#{current}"
        end
        sleep 25.milliseconds
      end
    end

    def wait_exit(timeout : Time::Span = 2.seconds) : Process::Status
      deadline = Time.instant + timeout
      while !@process.terminated?
        if Time.instant > deadline
          terminate!
          raise "Process did not exit within #{timeout}"
        end
        sleep 25.milliseconds
      end
      @process.wait
    end

    def terminate! : Nil
      return if @terminated
      @terminated = true
      @process.signal(Signal::KILL) rescue nil
      @process.wait rescue nil
    end
  end

  def self.with_sandbox(prefix : String = "nightmare_test_", &block : WorkspaceSandbox -> Nil)
    sandbox = WorkspaceSandbox.new(prefix)
    begin
      block.call(sandbox)
    ensure
      sandbox.cleanup!
    end
  end

  def self.with_mock_llm(&block : MockLlmServer -> Nil)
    server = MockLlmServer.new
    server.start
    begin
      block.call(server)
    ensure
      server.stop
    end
  end

  def self.spawn_nightmare(
    sandbox : WorkspaceSandbox,
    args : Array(String) = [] of String,
    extra_env : Hash(String, String) = {} of String => String,
    bin_path : String = BIN_PATH
  ) : ProcessSession
    env = {
      "XDG_CONFIG_HOME" => sandbox.xdg_config,
      "XDG_STATE_HOME"  => sandbox.xdg_state,
      "XDG_CACHE_HOME"  => sandbox.xdg_cache,
      "TERM"            => "dumb",
      "CI"              => "1"
    }.merge(extra_env)

    proc = Process.new(
      bin_path,
      args: args,
      env: env,
      chdir: sandbox.root_path,
      input: Process::Redirect::Pipe,
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe
    )

    session = ProcessSession.new(proc)
    session.wait_for("> ", timeout: 500.milliseconds) rescue nil
    session
  end

  def self.binary_ready? : Bool
    return false unless binary_exists?
    output = `#{BIN_PATH} --help 2>&1` rescue ""
    output.includes?("NIGHTMARE") || output.includes?("Usage:")
  end

  def self.require_binary!
    unless binary_ready?
      pending! "bin/nightmare REPL not yet implemented (Milestones M1-M5 in progress)"
    end
  end

  @@repl_ready : Bool? = nil

  def self.repl_ready? : Bool
    if (cached = @@repl_ready) != nil
      return cached.not_nil!
    end

    result = false
    begin
      return (@@repl_ready = false) unless binary_ready?

      sandbox = WorkspaceSandbox.new("repl_probe_")
      begin
        session = spawn_nightmare(sandbox)
        session.send_line("/help")
        session.send_line("/exit")
        begin
          session.wait_for("/clear", timeout: 500.milliseconds)
          session.wait_exit(timeout: 1.second)
          result = true
        rescue
          session.terminate!
        end
      ensure
        sandbox.cleanup!
      end
    rescue
      # Probe failed, REPL not ready
    end

    @@repl_ready = result
    result
  end

  def self.require_repl!
    unless repl_ready?
      pending! "REPL not yet functional (features in development)"
    end
  end
end
