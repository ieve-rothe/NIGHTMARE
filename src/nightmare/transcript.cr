# nightmare/transcript.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"
require "file_utils"
require "./workspace/environment"

module Nightmare
  class Transcript
    getter state_dir : String?
    getter file_path : String?
    getter entries : Array(Mantle::Message)

    def initialize(@state_dir : String? = nil, enabled : Bool = true)
      @entries = [] of Mantle::Message
      if enabled && (dir = @state_dir)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        @file_path = File.join(dir, "transcript.md")
      end
    end

    # Records a pristine message to in-memory storage and appends to disk
    def record(message : Mantle::Message) : Nil
      # Store pristine copy in RAM (Message is a struct, so this is an unmutated snapshot)
      @entries << message.dup

      # Incrementally flush to disk
      if path = @file_path
        File.open(path, "a") do |f|
          f.puts format_message_markdown(message)
          f.flush
        end
      end
    end

    # Records an interruption event and any mutated paths
    def record_interruption(side_effects : Array(String) = [] of String) : Nil
      text = if side_effects.empty?
        "*(Turn interrupted by user)*"
      else
        "*(Turn interrupted by user. Modified files: #{side_effects.join(", ")})*"
      end

      interruption_msg = Mantle::Message.new("system", text)
      record(interruption_msg)
    end

    # Renders the full pristine transcript as clean Markdown
    def render_markdown : String
      String.build do |io|
        io.puts "# NIGHTMARE Session Transcript"
        io.puts ""
        @entries.each do |msg|
          io.puts format_message_markdown(msg)
        end
      end
    end

    # Copies or writes the pristine transcript to target destination path
    def save_to(destination_path : String) : String
      target = File.expand_path(destination_path)
      Dir.mkdir_p(File.dirname(target))

      if (src = @file_path) && File.exists?(src)
        FileUtils.cp(src, target)
      else
        File.write(target, render_markdown)
      end

      target
    end

    private def format_message_markdown(msg : Mantle::Message) : String
      String.build do |io|
        case msg.role
        when "user"
          io.puts "### User"
          io.puts msg.content
          io.puts ""
        when "assistant"
          io.puts "### Assistant"
          if content = msg.content
            io.puts content unless content.empty?
          end
          if calls = msg.tool_calls
            calls.each do |call|
              io.puts "**Tool Call:** `#{call.function.name}(#{call.function.arguments})` [id: `#{call.id}`]"
            end
          end
          io.puts ""
        when "tool"
          io.puts "### Tool Output (`#{msg.tool_call_id || "unspecified"}`)"
          io.puts "```"
          io.puts msg.content
          io.puts "```"
          io.puts ""
        when "system"
          io.puts "### System"
          io.puts msg.content
          io.puts ""
        end
      end
    end
  end
end
