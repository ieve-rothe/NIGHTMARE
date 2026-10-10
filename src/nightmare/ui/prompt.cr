# nightmare/src/nightmare/ui/prompt.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "path"
require "salamander"

module Nightmare::UI
  module Prompt
    extend self

    # Formats a directory path for compact display in the prompt area,
    # replacing the user's home directory prefix with '~'.
    def format_path(path : String, home : String = Path.home.to_s) : String
      clean_home = home.rchop('/')
      if path == clean_home
        "~"
      elsif path.starts_with?(clean_home + "/")
        "~" + path[clean_home.size..]
      else
        path
      end
    end

    # Builds the prompt string combining ambient human-agent pairing header
    # and an explicit speech-act input line ("You › ").
    def render(
      cwd : String = Dir.current,
      active_skill_name : String? = nil,
      home : String = Path.home.to_s
    ) : String
      display_path = format_path(cwd, home)
      theme = Salamander::UI::Theme

      reset = Salamander::UI::Theme::RESET
      glyph_icon = "#{theme.highlight}⯌#{reset}"
      pairing_label = "#{theme.title}Human ⇄ Assistant#{reset}"
      dot = "#{theme.meta_dim}·#{reset}"
      path_segment = "#{theme.meta_dim}#{display_path}#{reset}"

      skill_segment = if active_skill_name
                        " #{theme.status_tag}[#{active_skill_name}]#{reset}"
                      else
                        ""
                      end

      header = "#{glyph_icon} #{pairing_label} #{dot} #{path_segment}#{skill_segment}"
      lead = "#{theme.status_tag}You#{reset} #{theme.prompt_glyph}"

      "#{header}\n#{lead}"
    end
  end
end
