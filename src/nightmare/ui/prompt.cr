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

    # Builds the prompt string combining formatted cwd, optional active skill tag, and the theme prompt glyph.
    def render(
      cwd : String = Dir.current,
      active_skill_name : String? = nil,
      home : String = Path.home.to_s
    ) : String
      display_path = format_path(cwd, home)
      path_segment = "#{Salamander::UI::Theme.meta_dim}#{display_path}#{Salamander::UI::Theme::RESET}"

      skill_segment = if active_skill_name
                        " #{Salamander::UI::Theme.status_tag}[#{active_skill_name}]#{Salamander::UI::Theme::RESET}"
                      else
                        ""
                      end

      glyph = Salamander::UI::Theme.prompt_glyph.to_s

      "#{path_segment}#{skill_segment} #{glyph}"
    end
  end
end
