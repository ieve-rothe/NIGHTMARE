# nightmare/commands/router.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "../context/sliding_store"
require "../context/pinned_files"
require "../context/token_calibrator"
require "../transcript"
require "../tools/guard"
require "../workspace/environment"

module Nightmare::Commands
  class Router
    getter store : Context::SlidingStore
    getter pinned_files : Context::PinnedFiles
    getter calibrator : Context::TokenCalibrator
    getter guard : Tools::Guard
    getter env : Workspace::Environment
    property transcript : Transcript
    property current_prompt : String
    property current_model : String
    property last_thinking : String? = nil
    property on_model_change : Proc(String, Nil)? = nil

    def initialize(
      @store : Context::SlidingStore,
      @pinned_files : Context::PinnedFiles,
      @calibrator : Context::TokenCalibrator,
      @guard : Tools::Guard,
      @env : Workspace::Environment,
      @transcript : Transcript,
      @current_prompt : String,
      @current_model : String,
      @on_model_change : Proc(String, Nil)? = nil
    )
    end

    # Checks if an input line is a slash command
    def slash_command?(input : String) : Bool
      input.strip.starts_with?('/')
    end

    # Routes and executes a slash command. Returns true if handled, false if not a command.
    # May return a String if the command produces input for the LLM (e.g. /paste).
    def handle(input : String) : Tuple(Bool, String?)
      trimmed = input.strip
      return {false, nil} unless trimmed.starts_with?('/')

      parts = trimmed.split(' ', 2)
      cmd = parts[0].downcase
      args = parts.size > 1 ? parts[1].strip : ""

      case cmd
      when "/help"
        print_help
        {true, nil}
      when "/clear"
        @store.clear
        puts "Conversation history cleared."
        {true, nil}
      when "/cls"
        print "\e[2J\e[H"
        STDOUT.flush
        {true, nil}
      when "/drop", "/rm"
        handle_drop(args)
        {true, nil}
      when "/add"
        handle_add(args)
        {true, nil}
      when "/save"
        handle_save(args)
        {true, nil}
      when "/prompt"
        handle_prompt(args)
        {true, nil}
      when "/review"
        handle_review
        {true, nil}
      when "/thinking"
        handle_thinking
        {true, nil}
      when "/model"
        handle_model(args)
        {true, nil}
      when "/paste"
        text = handle_paste
        {true, text}
      when "/exit", "/quit"
        exit(0)
      else
        puts "Unknown command: #{cmd}. Type /help for available commands."
        {true, nil}
      end
    end

    private def print_help : Nil
      puts <<-HELP
Available Slash Commands:
  /help            Show this help reference
  /clear           Wipe active turn history (retains pinned files)
  /cls             Clear terminal screen ANSI display
  /add <path>      Pin a workspace file into context
  /drop [path]     Unpin a file from context (or /rm)
  /save [path]     Export pristine RAM transcript to Markdown
  /prompt [edit]   View or edit in-memory system prompt
  /review          Inspect assembled prompt, pinned files, and token usage
  /thinking        View model internal chain-of-thought from last turn
  /model [name]    Inspect or change the active LLM model
  /paste           Enter multi-line input paste mode
  /exit            Exit the session
HELP
    end

    private def handle_drop(path : String) : Nil
      if path.empty?
        @pinned_files.clear
        puts "Dropped all pinned files."
      else
        if @pinned_files.remove(path)
          puts "Dropped pinned file: #{path}"
        else
          puts "No pinned file found matching: #{path}"
        end
      end
    end

    private def handle_add(path : String) : Nil
      if path.empty?
        puts "Usage: /add <path>"
        return
      end

      begin
        file = @pinned_files.add(
          path: path,
          guard: @guard,
          calibrator: @calibrator,
          hardmax: @store.hardmax
        )
        puts "Pinned #{file.path} (estimated #{file.cached_tokens} tokens)."
      rescue ex : SecurityError
        puts "SecurityError: #{ex.message}"
      rescue ex : Nightmare::Error
        puts ex.message
      rescue ex
        puts "Failed to pin file: #{ex.message}"
      end
    end

    private def handle_save(path : String) : Nil
      target_path = if path.empty?
        File.join(@env.workspace_state_dir, "transcript.md")
      else
        @guard.resolve_write(path)
      end

      begin
        @transcript.save_to(target_path)
        puts "Transcript saved to #{target_path}"
      rescue ex
        puts "Failed to save transcript: #{ex.message}"
      end
    end

    private def handle_prompt(args : String) : Nil
      if args.empty?
        puts "Current System Prompt:"
        puts "----------------------"
        puts @current_prompt
        puts "----------------------"
      elsif args.starts_with?("edit")
        sub_args = args[4..].strip
        if !sub_args.empty?
          @current_prompt = sub_args
          puts "Updated in-memory system prompt."
        else
          puts "Enter new in-memory system prompt (single line or empty to cancel):"
          print "> "
          STDOUT.flush
          if input = STDIN.gets.try(&.strip)
            if !input.empty?
              @current_prompt = input
              puts "Updated in-memory system prompt."
            else
              puts "Prompt edit cancelled."
            end
          end
        end
      else
        puts "Usage: /prompt [edit [text]]"
      end
    end

    private def handle_review : Nil
      puts "\n=== Context Review ==="
      puts "--- System Prompt ---"
      puts @current_prompt
      puts

      if block = @pinned_files.render_pinned_block(@guard)
        puts "--- Pinned Files ---"
        puts block
        puts
      end

      puts "--- Conversation History (#{@store.history.size} turns) ---"
      @store.history.each_with_index do |turn, idx|
        puts "[Turn #{idx + 1}]"
        turn.messages.each do |msg|
          role = msg.role.capitalize
          content = msg.content
          puts "  #{role}: #{content}"
        end
      end

      if active = @store.active_turn
        puts "[Active Turn]"
        active.messages.each do |msg|
          puts "  #{msg.role.capitalize}: #{msg.content}"
        end
      end

      pinned_tokens = @pinned_files.total_estimated_tokens(@guard, @calibrator)
      total_tokens = @store.total_estimated_tokens(@calibrator, @current_prompt, block)
      prompt_tokens = @calibrator.estimate(@current_prompt.size)

      puts "\n--- Token Budget ---"
      puts "Estimated total tokens: #{total_tokens} / #{@store.hardmax} tokens"
      puts "  System prompt: ~#{prompt_tokens} tokens"
      puts "  Pinned files:  ~#{pinned_tokens} tokens"
      puts "  Calibrator divisor: #{@calibrator.divisor.round(2)}"
      puts "=====================\n"
    end

    private def handle_thinking : Nil
      if t = @last_thinking
        puts "\n=== Model Internal Reasoning ==="
        puts t
        puts "================================\n"
      else
        puts "No thinking recorded for the last turn."
      end
    end

    private def handle_model(name : String) : Nil
      if name.empty?
        puts "Active model: #{@current_model}"
      else
        @current_model = name
        @on_model_change.try &.call(name)
        puts "Model set to: #{@current_model}"
      end
    end

    private def handle_paste : String?
      puts "Paste mode enabled. Enter lines below. Submit with a line containing '/end' or empty line:"
      lines = [] of String
      while line = STDIN.gets
        break if line.strip == "/end" || line.strip.empty?
        lines << line
      end
      joined = lines.join("\n")
      joined.empty? ? nil : joined
    end
  end
end
