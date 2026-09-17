# nightmare/skills/skill.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

module Nightmare::Skills
  enum Scope
    Local
    Global

    def to_s(io : IO) : Nil
      case self
      when Local  then io << "local"
      when Global then io << "global"
      end
    end
  end

  class Skill
    getter name : String
    getter filename : String
    getter source_path : String
    getter scope : Scope
    property? overrides_global : Bool
    getter content : String

    def initialize(
      @name : String,
      @filename : String,
      @source_path : String,
      @scope : Scope,
      @content : String,
      @overrides_global : Bool = false
    )
    end

    def self.from_file(path : String, scope : Scope) : Skill
      filename = File.basename(path)
      name = filename.ends_with?(".md") ? filename[0...-3] : filename
      content = File.read(path).strip
      new(
        name: name,
        filename: filename,
        source_path: File.expand_path(path),
        scope: scope,
        content: content,
        overrides_global: false
      )
    end

    def formatted_block : String
      "=== ACTIVE SKILL: #{@name} (#{@scope}) ===\n#{@content}"
    end
  end
end
