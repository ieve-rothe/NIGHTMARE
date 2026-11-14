# nightmare/src/nightmare/ui/input_reader.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "salamander"

module Nightmare::UI
  module InputReader
    extend self

    BRACKET_PASTE_ENABLE  = "\e[?2004h"
    BRACKET_PASTE_DISABLE = "\e[?2004l"
    BRACKET_PASTE_END     = "\e[201~"

    def read_line(
      stdin : IO,
      stdout : IO,
      on_clipboard_paste : Proc(String?)? = nil,
      on_file_paste : Proc(String, String?)? = nil,
      on_text_paste : Proc(String?)? = nil,
      on_interrupt : Proc(Nil)? = nil,
      simulate_raw : Bool = false,
    ) : String?
      fd = stdin.as?(IO::FileDescriptor)
      is_tty = fd.try(&.tty?) || false

      unless is_tty || simulate_raw
        return stdin.gets
      end

      if is_tty && fd
        interrupted = false
        result : String? = nil
        stdout.print BRACKET_PASTE_ENABLE
        stdout.flush
        begin
          fd.raw do
            result, interrupted = read_raw_loop(
              stdin: fd,
              stdout: stdout,
              on_clipboard_paste: on_clipboard_paste,
              on_file_paste: on_file_paste,
              on_text_paste: on_text_paste
            )
          end
        ensure
          stdout.print BRACKET_PASTE_DISABLE
          stdout.flush
        end

        if interrupted
          on_interrupt.try(&.call)
          return nil
        end

        result
      else
        stdout.print BRACKET_PASTE_ENABLE
        stdout.flush
        begin
          result, interrupted = read_raw_loop(
            stdin: stdin,
            stdout: stdout,
            on_clipboard_paste: on_clipboard_paste,
            on_file_paste: on_file_paste,
            on_text_paste: on_text_paste
          )
        ensure
          stdout.print BRACKET_PASTE_DISABLE
          stdout.flush
        end

        if interrupted
          on_interrupt.try(&.call)
          return nil
        end

        result
      end
    end

    private def read_raw_loop(
      stdin : IO,
      stdout : IO,
      on_clipboard_paste : Proc(String?)?,
      on_file_paste : Proc(String, String?)?,
      on_text_paste : Proc(String?)?,
    ) : Tuple(String?, Bool)
      buffer = [] of Char
      theme = Salamander::UI::Theme
      reset = Salamander::UI::Theme::RESET

      loop do
        ch = stdin.read_char
        if ch.nil?
          return {buffer.empty? ? nil : buffer.join, false}
        end

        case ch
        when '\r', '\n'
          stdout.print "\r\n"
          stdout.flush
          return {buffer.join, false}
        when '\u0003' # Ctrl+C
          return {nil, true}
        when '\u0004' # Ctrl+D
          if buffer.empty?
            stdout.print "\r\n"
            stdout.flush
            return {nil, false}
          end
        when '\u007f', '\b' # Backspace
          unless buffer.empty?
            removed = buffer.pop
            if removed != '\n'
              stdout.print "\b \b"
              stdout.flush
            end
          end
        when '\u0015' # Ctrl+U (kill line)
          while !buffer.empty?
            removed = buffer.pop
            break if removed == '\n'
            stdout.print "\b \b"
          end
          stdout.flush
        when '\u0016' # Ctrl+V
          if badge = on_clipboard_paste.try(&.call)
            stdout.print "#{reset}#{theme.status_tag}#{badge}#{reset} #{theme.user_prompt}"
            stdout.flush
          elsif pasted_txt = on_text_paste.try(&.call)
            insert_pasted_text(pasted_txt, buffer, stdout)
          end
        when '\e'
          handle_escape_sequence(
            stdin: stdin,
            stdout: stdout,
            buffer: buffer,
            on_file_paste: on_file_paste,
            theme: theme,
            reset: reset
          )
        else
          if ch.ord >= 32
            buffer << ch
            stdout.print ch
            stdout.flush
          end
        end
      end
    end

    private def handle_escape_sequence(
      stdin : IO,
      stdout : IO,
      buffer : Array(Char),
      on_file_paste : Proc(String, String?)?,
      theme,
      reset : String,
    ) : Nil
      next_ch = stdin.read_char
      return unless next_ch

      if next_ch == '['
        seq = String::Builder.new
        while c = stdin.read_char
          seq << c
          break if c.ord >= 0x40 && c.ord <= 0x7E
          break if seq.bytesize > 32
        end

        if seq.to_s == "200~"
          pasted = [] of Char
          end_chars = BRACKET_PASTE_END.chars
          end_len = end_chars.size
          while pc = stdin.read_char
            pasted << pc
            if pasted.size >= end_len && pasted[-end_len, end_len] == end_chars
              payload = pasted[0...-end_len].join
              if badge = on_file_paste.try(&.call(payload))
                stdout.print "#{reset}#{theme.status_tag}#{badge}#{reset} #{theme.user_prompt}"
                stdout.flush
              else
                insert_pasted_text(payload, buffer, stdout)
              end
              break
            end
          end
        end
      elsif next_ch == 'O'
        # Consume SS3 sequence (e.g. arrow/F-keys)
        stdin.read_char
      end
    end

    private def insert_pasted_text(text : String, buffer : Array(Char), stdout : IO) : Nil
      normalized = text.gsub("\r\n", "\n").gsub('\r', '\n')
      normalized.each_char do |c|
        if c == '\n'
          buffer << '\n'
          stdout.print "\r\n"
        elsif c.ord >= 32 || c == '\t'
          buffer << c
          stdout.print c
        end
      end
      stdout.flush
    end
  end
end
