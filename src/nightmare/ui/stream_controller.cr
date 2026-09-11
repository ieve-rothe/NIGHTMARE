# nightmare/ui/stream_controller.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

module Nightmare::UI
  class StreamController
    getter visible_text : String = ""
    getter thinking_text : String? = nil

    @visible_buffer : String::Builder = String::Builder.new
    @thinking_buffer : String::Builder = String::Builder.new
    @pending : String = ""
    @in_think : Bool = false
    @had_thinking : Bool = false

    def reset : Nil
      @visible_buffer = String::Builder.new
      @thinking_buffer = String::Builder.new
      @pending = ""
      @in_think = false
      @had_thinking = false
      @visible_text = ""
      @thinking_text = nil
    end

    # Processes a streaming token chunk from Mantle
    def process_chunk(chunk : String) : Nil
      @pending += chunk
      process_pending
    end

    # Flushes any remaining pending text at the end of the stream
    def finish : Nil
      if !@pending.empty?
        if @in_think
          @thinking_buffer << @pending
        else
          print @pending
          STDOUT.flush
          @visible_buffer << @pending
        end
        @pending = ""
      end

      @visible_text = @visible_buffer.to_s
      thinking_str = @thinking_buffer.to_s.strip
      @thinking_text = thinking_str.empty? && !@had_thinking ? nil : thinking_str
    end

    private def process_pending : Nil
      loop do
        if @in_think
          if idx = @pending.index("</think>")
            before = @pending[0...idx]
            @thinking_buffer << before
            @pending = @pending[(idx + 8)..]
            @in_think = false
          else
            # Check if pending ends with partial "</think>"
            prefix_len = matching_prefix_length(@pending, "</think>")
            if prefix_len > 0
              safe_part = @pending[0...(@pending.size - prefix_len)]
              @thinking_buffer << safe_part
              @pending = @pending[(@pending.size - prefix_len)..]
              break
            else
              @thinking_buffer << @pending
              @pending = ""
              break
            end
          end
        else
          if idx = @pending.index("<think>")
            before = @pending[0...idx]
            if !before.empty?
              print before
              STDOUT.flush
              @visible_buffer << before
            end
            @pending = @pending[(idx + 7)..]
            @in_think = true
            @had_thinking = true
          else
            prefix_len = matching_prefix_length(@pending, "<think>")
            if prefix_len > 0
              safe_part = @pending[0...(@pending.size - prefix_len)]
              if !safe_part.empty?
                print safe_part
                STDOUT.flush
                @visible_buffer << safe_part
              end
              @pending = @pending[(@pending.size - prefix_len)..]
              break
            else
              if !@pending.empty?
                print @pending
                STDOUT.flush
                @visible_buffer << @pending
                @pending = ""
              end
              break
            end
          end
        end
      end
    end

    private def matching_prefix_length(str : String, target : String) : Int32
      max_len = Math.min(str.size, target.size - 1)
      max_len.downto(1) do |len|
        return len if str.ends_with?(target[0...len])
      end
      0
    end
  end
end
