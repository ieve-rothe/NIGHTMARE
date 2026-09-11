# nightmare/tools/mutation.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "path"
require "json"
require "file_utils"
require "../exceptions"
require "./guard"
require "./diff"

module Nightmare::Tools
  class Mutation
    getter guard : Guard
    property approval_handler : Proc(String, String, Bool)?
    property active_side_effects : Array(String)?

    def initialize(@guard : Guard, @approval_handler : Proc(String, String, Bool)? = nil)
    end

    # Creates a new file or overwrites an existing file with interactive diff approval
    def write_file(path : String, content : String) : String
      full_path = @guard.resolve_write(path)
      rel_path = Path.new(full_path).relative_to(@guard.root).to_s

      if File.exists?(full_path)
        # Existing file: requires unified diff and approval modal
        original = File.read(full_path)
        diff_text = Diff.unified_diff(original, content, rel_path)

        # If identical, no-op
        if diff_text.empty?
          return "File #{rel_path} is already up to date (no changes)."
        end

        unless approve_mutation?(diff_text, "Overwrite #{rel_path}")
          return "[Execution rejected by user]"
        end
      else
        # New file creation: auto-approved per R3 / §4.1
        Dir.mkdir_p(File.dirname(full_path))
      end

      File.write(full_path, content)
      record_side_effect(rel_path)

      "Successfully wrote #{content.bytesize} bytes to #{rel_path}"
    end

    # Replaces exact single target string with replacement in existing file with diff approval
    def replace_in_file(path : String, target : String, replacement : String) : String
      full_path = @guard.resolve_write(path)
      rel_path = Path.new(full_path).relative_to(@guard.root).to_s

      unless File.exists?(full_path)
        return {error: "File not found: #{path}"}.to_json
      end

      original = File.read(full_path)
      count = original.scan(target).size

      if count == 0
        return {error: "Target string not found in #{rel_path}"}.to_json
      elsif count > 1
        return {error: "Target string occurs #{count} times in #{rel_path}; must be unique to replace safely"}.to_json
      end

      updated = original.sub(target, replacement)
      diff_text = Diff.unified_diff(original, updated, rel_path)

      unless approve_mutation?(diff_text, "Replace target in #{rel_path}")
        return "[Execution rejected by user]"
      end

      File.write(full_path, updated)
      record_side_effect(rel_path)

      "Successfully replaced content in #{rel_path}"
    end

    # Appends content to a file with diff approval if existing
    def append_to_file(path : String, content : String) : String
      full_path = @guard.resolve_write(path)
      rel_path = Path.new(full_path).relative_to(@guard.root).to_s

      if File.exists?(full_path)
        original = File.read(full_path)
        updated = original.ends_with?('\n') ? "#{original}#{content}" : "#{original}\n#{content}"
        diff_text = Diff.unified_diff(original, updated, rel_path)

        unless approve_mutation?(diff_text, "Append to #{rel_path}")
          return "[Execution rejected by user]"
        end

        File.write(full_path, updated)
      else
        Dir.mkdir_p(File.dirname(full_path))
        File.write(full_path, content)
      end

      record_side_effect(rel_path)
      "Successfully appended #{content.bytesize} bytes to #{rel_path}"
    end

    private def approve_mutation?(diff : String, desc : String) : Bool
      if handler = @approval_handler
        handler.call(diff, desc)
      else
        # In non-interactive contexts where no handler is configured, reject for safety
        false
      end
    end

    private def record_side_effect(path : String) : Nil
      if effects = @active_side_effects
        effects << path unless effects.includes?(path)
      end
    end
  end
end
