# nightmare/repl.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "json"
require "uuid"
require "mantle"
require "salamander"
require "./config"
require "./workspace/environment"
require "./system_prompt/resolver"
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
require "./harness/subagent_runner"
require "./ui/approval"
require "./ui/stream_controller"
require "./ui/turn_presenter"
require "./ui/cancellation"
require "./ui/editor"
require "./commands/router"
require "./skills"

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
    getter turn_presenter : UI::TurnPresenter
    getter cancellation : UI::Cancellation
    getter router : Commands::Router
    getter skills_manager : Skills::SkillManager
    getter model_name : String
    getter? no_log : Bool
    getter? markdown_formatting : Bool

    def initialize(
      @env : Workspace::Environment,
      system_prompt_path : String? = nil,
      model_override : String? = nil,
      @no_log : Bool = false,
      markdown_override : Bool? = nil
    )
      @markdown_formatting = @env.resolve_markdown_formatting(markdown_override)
      @no_log = @no_log || !@env.resolve_logging(cli_no_log: @no_log)
      Salamander::UI::Theme.set_theme(@env.resolve_theme)

      # 1. System prompt resolution
      prompt = SystemPrompt::Resolver.resolve(@env, system_prompt_path)
      @model_name = @env.resolve_model(model_override)

      # 2. Persisted calibrator
      @calibrator = Context::TokenEstimator.load_or_create(@env.workspace_cache_dir, @env.settings.initial_divisor)

      # 3. Context engine
      @store = Context::SlidingStore.new(
        soft_cap: @env.settings.turn_soft_cap,
        hardmax: @env.settings.token_hardmax
      )
      @pinned_files = Context::PinnedFiles.new

      # 4. Transcript
      @transcript = Transcript.new(@env.workspace_state_dir, enabled: !@no_log)

      # 5. Security & tools
      @guard = Tools::Guard.new(@env)
      allow_path = File.join(@env.workspace_config_dir, "allow")
      @allowlist = Tools::Allowlist.new(allow_path)
      @approval = UI::Approval.new(@env.root)

      # 6. Mantle LLM client
      api_url = @env.resolve_api_url
      model_config = Mantle::Clients::ModelConfig.new(
        model_name: @model_name,
        stream: true,
        temperature: @env.settings.temperature,
        top_p: @env.settings.top_p,
        max_tokens: @env.settings.max_tokens,
        api_url: api_url
      )
      raw_client = Mantle::Clients::OllamaClient.new(model_config)
      client : Mantle::Clients::Client = if @no_log
        raw_client
      else
        Mantle::Clients::LoggingClient.new(raw_client, @env.log_path)
      end

      # 7. UI Presenter & Subagent runner
      @turn_presenter = UI::TurnPresenter.new(
        calibrator: @calibrator,
        threshold_multiplier: @env.settings.file_card_threshold_screens,
        preview_lines: @env.settings.file_card_preview_lines,
        max_width: @env.settings.max_dashboard_width
      )

      diff_cb = ->(diff : String, desc : String) { @approval.approve_diff(diff, desc) }
      shell_cb = ->(cmd : String, argv : Array(String), meta : Bool, to : Int32) {
        @approval.approve_command(cmd, argv, meta, to)
      }

      subagent_runner = Harness::SubagentRunner.new(
        client: client,
        environment: @env,
        pacer: nil,
        diff_approval: diff_cb,
        shell_approval: shell_cb,
        turn_presenter: @turn_presenter
      )

      # 8. Registry & Hardened Tools with Middleware
      loop_detector = Harness::LoopDetector.new(threshold: @env.settings.loop_detect_threshold)
      @registry = Tools::Registry.new(
        guard: @guard,
        client: client,
        allowlist: @allowlist,
        diff_approval: diff_cb,
        shell_approval: shell_cb,
        pinned_files: @pinned_files,
        default_command_timeout: @env.settings.command_timeout_seconds,
        max_command_timeout: @env.settings.max_command_timeout_seconds,
        tool_output_max_bytes: @env.settings.tool_output_max_bytes,
        subagent_runner: subagent_runner
      )
      @registry.middlewares = [
        ToolMiddleware::Presentation.new(@turn_presenter),
        ToolMiddleware::LoopDetector.new(loop_detector),
        ToolMiddleware::ExceptionTrapping.new,
      ] of ToolMiddleware::Base
      tools = @registry.build_tools

      # 9. Harness & StepRunner
      @tool_loop = Harness::ToolLoop.new(
        store: @store,
        calibrator: @calibrator,
        loop_detector: loop_detector,
        spend_cap: @env.settings.turn_spend_cap_tokens,
        shed_trigger_ratio: @env.settings.shed_trigger_ratio,
        shed_keep_chars: @env.settings.shed_keep_chars,
        shed_keep_verbatim: @env.settings.shed_keep_verbatim
      )
      retrier = Harness::Retrier.new(max_retries: @env.settings.rate_limit_retries)
      failures_directory = File.join(@env.workspace_state_dir, "failures")
      @step_runner = Harness::StepRunner.new(
        client: client,
        tools: tools,
        tool_loop: @tool_loop,
        retrier: retrier,
        transcript: @transcript,
        max_iterations: @env.settings.max_iterations,
        format_retries: @env.settings.format_retries,
        overflow_retries: @env.settings.context_overflow_retries,
        failures_dir: failures_directory,
        no_log: @no_log
      )
      @step_runner.turn_presenter = @turn_presenter

      @stream_ctrl = UI::StreamController.new
      @cancellation = UI::Cancellation.new(@tool_loop, @registry.shell)
      @skills_manager = Skills::SkillManager.new(@env.repo_skills_dir, @env.global_skills_dir)
      on_model = ->(new_model : String) {
        @model_name = new_model
        raw_client.model_name = new_model
      }
      @router = Commands::Router.new(
        store: @store,
        pinned_files: @pinned_files,
        calibrator: @calibrator,
        guard: @guard,
        env: @env,
        transcript: @transcript,
        current_prompt: prompt,
        current_model: @model_name,
        on_model_change: on_model,
        client: client,
        skills_manager: @skills_manager
      )
    end

    def start : Nil
      puts @env.startup_banner(no_log: @no_log)
      STDOUT.flush

      loop do
        glyph = if active_skill = @skills_manager.active_skill
          "#{Salamander::UI::Theme.status_tag}[#{active_skill.name}]#{Salamander::UI::Theme::RESET} #{Salamander::UI::Theme.prompt_glyph}"
        else
          Salamander::UI::Theme.prompt_glyph.to_s
        end
        print "#{glyph}#{Salamander::UI::Theme.user_prompt}"
        STDOUT.flush

        line = STDIN.gets
        print Salamander::UI::Theme::RESET
        STDOUT.flush
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

      # Interruption advisory is handled centrally by SlidingStore#start_turn
      # Track side effects during this turn
      side_effects = [] of String
      @registry.set_active_side_effects(side_effects)

      # Start turn in context store
      prev_resp = @store.history.last?.try(&.last_assistant_text)
      @turn_presenter.reset_for_new_turn(user_input, prev_resp)
      @turn_presenter.active_skill_name = @skills_manager.active_skill.try(&.name)
      user_msg = Mantle::Message.new("user", user_input)
      @store.start_turn(user_msg)

      pinned_block = @pinned_files.render_pinned_block(@guard)
      skill_block = @skills_manager.active_skill.try(&.formatted_block)
      start_time = Time.instant

      turn_sequence_id = UUID.random.to_s
      outcome = Mantle::LogContext.with_sequence_id(turn_sequence_id) do
        @step_runner.run_turn(
          store: @store,
          system_prompt: @router.current_prompt,
          pinned_block: pinned_block,
          skill_block: skill_block
        ) do |chunk|
          @stream_ctrl.process_chunk(chunk)
        end
      end

      elapsed = Time.instant - start_time
      @stream_ctrl.finish

      @router.last_thinking = @stream_ctrl.thinking_text || outcome.thinking

      if outcome.ok?
        val = outcome.value.not_nil!
        if @markdown_formatting && STDOUT.tty?
          if !@stream_ctrl.visible_text.empty?
            Salamander::UI.clear_and_reposition(@stream_ctrl.visible_text)
            puts Salamander::UI::MarkdownFormatter.format(@stream_ctrl.visible_text)
          elsif !val.empty?
            puts Salamander::UI::MarkdownFormatter.format(val)
          end
          STDOUT.flush
        else
          # If streaming didn't output visible text, output value
          if @stream_ctrl.visible_text.empty? && !val.empty?
            puts val
            STDOUT.flush
          else
            puts unless @stream_ctrl.visible_text.ends_with?('\n')
            STDOUT.flush
          end
        end

        # Calibrate tokens
        if prompt_tok = outcome.prompt_tokens
          assembled = @store.assemble_messages(@router.current_prompt, pinned_block, skill_block)
          total_chars = assembled.sum { |m| m.content.try(&.size) || 0 }
          @calibrator.calibrate!(total_chars, prompt_tok)
          @calibrator.save(@env.workspace_cache_dir) if @env.ensure_dirs? && !@no_log
        end
      else
        err = outcome.error.not_nil!
        if err.cancelled?
          puts "\n[Turn cancelled by user interrupt]"
        else
          puts "\n[Error: #{err.message}]"
        end
        STDOUT.flush
      end
    ensure
      Mantle::Clients::LoggingClient.flush
      @registry.set_active_side_effects(nil)
      @cancellation.busy = false
    end
  end
end
