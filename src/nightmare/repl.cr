# nightmare/repl.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "json"
require "mantle"
require "./config"
require "./workspace/environment"
require "./directives/resolver"
require "./tools/guard"
require "./tools/allowlist"
require "./tools/registry"
require "./context/token_calibrator"
require "./context/sliding_store"
require "./context/pinned_files"
require "./transcript"
require "./harness/types"
require "./harness/tool_loop"
require "./harness/step_runner"
require "./ui/approval"
require "./ui/stream_controller"
require "./ui/cancellation"
require "./commands/router"

module Nightmare
  class REPL
    getter env : Workspace::Environment
    getter store : Context::SlidingStore
    getter pinned_files : Context::PinnedFiles
    getter calibrator : Context::TokenCalibrator
    getter transcript : Transcript
    getter guard : Tools::Guard
    getter allowlist : Tools::Allowlist
    getter approval : UI::Approval
    getter registry : Tools::Registry
    getter tool_loop : Harness::ToolLoop
    getter step_runner : Harness::StepRunner
    getter stream_ctrl : UI::StreamController
    getter cancellation : UI::Cancellation
    getter router : Commands::Router
    getter model_name : String
    getter? no_log : Bool

    @interrupted_effects : Array(String) = [] of String

    def initialize(
      @env : Workspace::Environment,
      system_prompt_path : String? = nil,
      model_override : String? = nil,
      @no_log : Bool = false
    )
      # 1. Directives resolution
      directive = Directives::Resolver.resolve(@env, system_prompt_path)
      @model_name = model_override || Config::DEFAULT_MODEL

      # 2. Persisted calibrator
      @calibrator = Context::TokenEstimator.load_or_create(@env.workspace_cache_dir)

      # 3. Context engine
      @store = Context::SlidingStore.new
      @pinned_files = Context::PinnedFiles.new

      # 4. Transcript
      @transcript = Transcript.new(@env.workspace_state_dir)

      # 5. Security & tools
      @guard = Tools::Guard.new(@env)
      allow_path = File.join(@env.workspace_config_dir, "allow")
      @allowlist = Tools::Allowlist.new(allow_path)
      @approval = UI::Approval.new(@env.root)

      # 6. Mantle LLM client
      api_url = ENV["MANTLE_API_URL"]? || ENV["OLLAMA_API_URL"]? || "http://127.0.0.1:11434/api/chat"
      model_config = Mantle::Clients::ModelConfig.new(
        model_name: @model_name,
        stream: true,
        temperature: 0.2,
        top_p: 0.95,
        max_tokens: 4096,
        api_url: api_url
      )
      client = Mantle::Clients::OllamaClient.new(model_config)

      # 7. Registry with approval hooks
      diff_cb = ->(diff : String, desc : String) { @approval.approve_diff(diff, desc) }
      shell_cb = ->(cmd : String, argv : Array(String), meta : Bool, to : Int32) {
        @approval.approve_command(cmd, argv, meta, to)
      }

      @registry = Tools::Registry.new(
        guard: @guard,
        client: client,
        allowlist: @allowlist,
        diff_approval: diff_cb,
        shell_approval: shell_cb,
        pinned_files: @pinned_files
      )
      tools = @registry.build_tools

      # 8. Harness
      @tool_loop = Harness::ToolLoop.new(@store, @calibrator)
      @step_runner = Harness::StepRunner.new(client, tools, @tool_loop, transcript: @transcript)

      # 9. UI & Commands
      @stream_ctrl = UI::StreamController.new
      @cancellation = UI::Cancellation.new(@tool_loop, @registry.shell)
      @router = Commands::Router.new(
        store: @store,
        pinned_files: @pinned_files,
        calibrator: @calibrator,
        guard: @guard,
        env: @env,
        transcript: @transcript,
        current_prompt: directive,
        current_model: @model_name
      )
    end

    def start : Nil
      puts @env.startup_banner
      STDOUT.flush

      loop do
        print "> "
        STDOUT.flush

        line = STDIN.gets
        if line.nil?
          if @cancellation.sigint_received?
            @cancellation.sigint_received = false
            next
          else
            break # EOF / closed stdin
          end
        end

        trimmed = line.strip
        next if trimmed.empty?

        if @router.slash_command?(trimmed)
          handled, payload = @router.handle(trimmed)
          if payload
            execute_turn(payload)
          end
        elsif trimmed.ends_with?("/exit")
          @router.handle("/exit")
        else
          execute_turn(trimmed)
        end
      end
    end

    private def execute_turn(user_input : String) : Nil
      @cancellation.busy = true
      @stream_ctrl.reset

      # Check if previous turn had side effects from interruption
      active_input = user_input
      if !@interrupted_effects.empty?
        prefix = "[Previous turn was interrupted after modifying: #{@interrupted_effects.join(", ")}]\n"
        active_input = "#{prefix}#{user_input}"
        @interrupted_effects.clear
      end

      # Track side effects during this turn
      side_effects = [] of String
      @registry.set_active_side_effects(side_effects)

      # Start turn in context store
      user_msg = Mantle::Message.new("user", active_input)
      @store.start_turn(user_msg)

      pinned_block = @pinned_files.render_pinned_block(@guard)
      start_time = Time.instant

      outcome = @step_runner.run_turn(
        directive: @router.current_prompt,
        pinned_block: pinned_block
      ) do |chunk|
        @stream_ctrl.process_chunk(chunk)
      end

      elapsed = Time.instant - start_time
      @stream_ctrl.finish

      @router.last_thinking = @stream_ctrl.thinking_text || outcome.thinking

      if outcome.ok?
        # If streaming didn't output visible text, output value
        val = outcome.value.not_nil!
        if @stream_ctrl.visible_text.empty? && !val.empty?
          puts val
          STDOUT.flush
        else
          puts unless @stream_ctrl.visible_text.ends_with?('\n')
          STDOUT.flush
        end

        # Calibrate tokens
        if prompt_tok = outcome.prompt_tokens
          assembled = @store.assemble_messages(@router.current_prompt, pinned_block)
          total_chars = assembled.sum { |m| m.content.try(&.size) || 0 }
          @calibrator.calibrate!(total_chars, prompt_tok)
          @calibrator.save(@env.workspace_cache_dir)
        end

        # Write audit log if not disabled
        write_audit_log(active_input, val, elapsed.total_milliseconds.to_i) unless @no_log
      else
        err = outcome.error.not_nil!
        if err.cancelled?
          @interrupted_effects = side_effects.dup
          puts "\n[Turn cancelled by user interrupt]"
        else
          puts "\n[Error: #{err.message}]"
        end
        STDOUT.flush
      end
    ensure
      @registry.set_active_side_effects(nil)
      @cancellation.busy = false
    end

    private def write_audit_log(prompt : String, completion : String, latency_ms : Int32) : Nil
      state_dir = @env.workspace_state_dir
      Dir.mkdir_p(state_dir) unless Dir.exists?(state_dir)
      log_file = File.join(state_dir, "llm_calls.jsonl")

      # Rotate at 20 MB, retain 3
      rotate_log_if_needed(log_file)

      entry = {
        timestamp: Time.utc.to_rfc3339,
        model: @router.current_model,
        prompt: prompt,
        completion: completion,
        latency_ms: latency_ms
      }

      File.open(log_file, "a") do |f|
        f.puts(entry.to_json)
      end
    rescue
      # Non-fatal audit log write failure
    end

    private def rotate_log_if_needed(log_file : String) : Nil
      return unless File.exists?(log_file)
      return unless File.size(log_file) >= Config::AUDIT_LOG_MAX_BYTES

      3.downto(1) do |idx|
        src = idx == 1 ? log_file : "#{log_file}.#{idx - 1}"
        dst = "#{log_file}.#{idx}"
        if File.exists?(src)
          File.rename(src, dst)
        end
      end
    rescue
    end
  end
end
