# spec/support/integration_harness.cr
require "process"
require "file_utils"
require "digest/sha256"
require "json"
require "http/server"
require "socket"

module Nightmare::Integration
  BIN_PATH = File.expand_path("../../bin/nightmare", __DIR__)
  SRC_PATH = File.expand_path("../../src/nightmare.cr", __DIR__)

  def self.binary_exists? : Bool
    return false unless File.exists?(BIN_PATH)
    bin_mtime = File.info(BIN_PATH).modification_time
    Dir.glob(File.expand_path("../../src/**/*.cr", __DIR__)).all? do |file|
      bin_mtime >= File.info(file).modification_time
    end
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

  def self.ensure_binary! : Nil
    unless binary_exists?
      success = compile_binary!
      raise "Failed to compile #{BIN_PATH}" unless success
    end
  end

  class WorkspaceSandbox
    getter root_path : String
    getter xdg_config : String
    getter xdg_state : String
    getter xdg_cache : String
    getter xdg_data : String
    getter home_dir : String
    getter workspace_id : String
    getter initial_files : Set(String)

    def self.make_temp_dir(prefix : String) : String
      dir = File.tempname(prefix)
      Dir.mkdir_p(dir)
      File.realpath(dir)
    end

    def initialize(@prefix : String = "nightmare_integration_")
      @root_path = WorkspaceSandbox.make_temp_dir("#{@prefix}ws_")
      @xdg_config = WorkspaceSandbox.make_temp_dir("#{@prefix}cfg_")
      @xdg_state = WorkspaceSandbox.make_temp_dir("#{@prefix}state_")
      @xdg_cache = WorkspaceSandbox.make_temp_dir("#{@prefix}cache_")
      @xdg_data = WorkspaceSandbox.make_temp_dir("#{@prefix}data_")
      @home_dir = WorkspaceSandbox.make_temp_dir("#{@prefix}home_")

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

    private def safe_rm_rf(dir : String) : Nil
      temp_root = File.realpath(Dir.tempdir)
      real = File.realpath(dir) rescue nil
      if real && real.starts_with?(temp_root) && real != temp_root
        FileUtils.rm_rf(real)
      end
    end

    def cleanup! : Nil
      safe_rm_rf(@root_path) if Dir.exists?(@root_path)
      safe_rm_rf(@xdg_config) if Dir.exists?(@xdg_config)
      safe_rm_rf(@xdg_state) if Dir.exists?(@xdg_state)
      safe_rm_rf(@xdg_cache) if Dir.exists?(@xdg_cache)
      safe_rm_rf(@xdg_data) if Dir.exists?(@xdg_data)
      safe_rm_rf(@home_dir) if Dir.exists?(@home_dir)
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

        # Dequeue under mutex, execute handler outside mutex to prevent socket IO blocking
        handler = @mutex.synchronize { @handlers.shift? }
        handled = handler ? handler.call(context) : false

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

    def recorded_requests : Array(NamedTuple(path: String, method: String, body: String))
      @mutex.synchronize { @requests.dup }
    end

    def assert_all_consumed! : Nil
      remaining = @mutex.synchronize { @handlers.size }
      if remaining > 0
        raise "MockLlmServer still has #{remaining} unconsumed response handler(s)!"
      end
    end

    def start : Nil
      return if @running
      @running = true
      spawn do
        @server.listen
      rescue Socket::Error
        # Clean exit on close
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

    def enqueue_stream_response(chunks : Array(String), prompt_tokens : Int32 = 50, chunk_delay : Time::Span = 30.milliseconds) : Nil
      @mutex.synchronize do
        @handlers << ->(ctx : HTTP::Server::Context) {
          ctx.response.content_type = "application/x-ndjson"
          ctx.response.status_code = 200
          chunks.each_with_index do |chunk, idx|
            is_last = (idx == chunks.size - 1)
            payload = {
              model: "mock-model",
              created_at: Time.utc.to_s,
              message: {
                role: "assistant",
                content: chunk
              },
              done: is_last,
              prompt_eval_count: is_last ? prompt_tokens : nil,
              eval_count: is_last ? chunks.size * 5 : nil
            }
            ctx.response.puts(payload.to_json)
            ctx.response.flush
            sleep chunk_delay unless is_last
          end
          true
        }
      end
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

    @out_cursor : Int32 = 0
    @err_cursor : Int32 = 0

    def reset_cursor! : Nil
      @mutex.synchronize do
        @out_cursor = 0
        @err_cursor = 0
      end
    end

    def wait_for(pattern : Regex | String, timeout : Time::Span = 2.seconds, from_start : Bool = false) : String
      deadline = Time.instant + timeout
      loop do
        matched = false
        match_len = 0
        match_idx = 0
        current = ""

        @mutex.synchronize do
          current = @out_buf.to_s
          search_start = from_start ? 0 : @out_cursor
          slice = search_start < current.size ? current[search_start..] : ""

          if pattern.is_a?(Regex)
            if m = pattern.match(slice)
              matched = true
              match_idx = search_start + m.begin(0)
              match_len = m[0].size
            end
          else
            if idx = slice.index(pattern)
              matched = true
              match_idx = search_start + idx
              match_len = pattern.size
            end
          end

          if matched
            @out_cursor = match_idx + match_len
            return current
          end
        end

        if Time.instant > deadline
          raise "Timeout waiting for #{pattern.inspect} in output. Captured stdout:\n#{current}\nCaptured stderr:\n#{stderr}"
        end
        sleep 10.milliseconds
      end
    end

    def wait_for_error(pattern : Regex | String, timeout : Time::Span = 2.seconds, from_start : Bool = false) : String
      deadline = Time.instant + timeout
      loop do
        matched = false
        match_len = 0
        match_idx = 0
        current = ""

        @mutex.synchronize do
          current = @err_buf.to_s
          search_start = from_start ? 0 : @err_cursor
          slice = search_start < current.size ? current[search_start..] : ""

          if pattern.is_a?(Regex)
            if m = pattern.match(slice)
              matched = true
              match_idx = search_start + m.begin(0)
              match_len = m[0].size
            end
          else
            if idx = slice.index(pattern)
              matched = true
              match_idx = search_start + idx
              match_len = pattern.size
            end
          end

          if matched
            @err_cursor = match_idx + match_len
            return current
          end
        end

        if Time.instant > deadline
          raise "Timeout waiting for #{pattern.inspect} in stderr. Captured stderr:\n#{current}"
        end
        sleep 10.milliseconds
      end
    end

    def wait_exit(timeout : Time::Span = 2.seconds) : Process::Status
      deadline = Time.instant + timeout
      while !@process.terminated?
        if Time.instant > deadline
          terminate!
          raise "Process did not exit within #{timeout}"
        end
        sleep 10.milliseconds
      end
      @process.wait
    end

    def terminate! : Nil
      return if @terminated
      @terminated = true
      # Kill the process group first to reap any child processes
      Process.run("kill", ["-KILL", "-#{@process.pid}"]) rescue nil
      @process.signal(Signal::KILL) rescue nil
      @process.wait rescue nil
      @process.input.close rescue nil
      @process.output.close rescue nil
      @process.error.close rescue nil
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
    ensure_binary!

    env = {
      "HOME"            => sandbox.home_dir,
      "XDG_CONFIG_HOME" => sandbox.xdg_config,
      "XDG_STATE_HOME"  => sandbox.xdg_state,
      "XDG_CACHE_HOME"  => sandbox.xdg_cache,
      "XDG_DATA_HOME"   => sandbox.xdg_data,
      "TMPDIR"          => sandbox.root_path,
      "TERM"            => "dumb",
      "CI"              => "1"
    }.merge(extra_env)

    # Launch with setsid -w to establish an isolated process group for clean process tree termination
    proc = Process.new(
      "setsid",
      ["-w", bin_path] + args,
      env: env,
      chdir: sandbox.root_path,
      input: Process::Redirect::Pipe,
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe
    )

    session = ProcessSession.new(proc)
    if proc.terminated?
      raise "Nightmare terminated on boot! Exit code: #{proc.wait.exit_code}. Stderr:\n#{session.stderr}"
    end

    session.wait_for(/(?:>|❯|▶)/, timeout: 1.second) rescue nil
    session
  end

  def self.with_session(
    sandbox : WorkspaceSandbox,
    args : Array(String) = [] of String,
    extra_env : Hash(String, String) = {} of String => String,
    bin_path : String = BIN_PATH,
    &block : ProcessSession -> Nil
  ) : Nil
    session = spawn_nightmare(sandbox, args, extra_env, bin_path)
    begin
      block.call(session)
    ensure
      session.terminate!
    end
  end
end

module Nightmare
  alias E2E = Integration
end
