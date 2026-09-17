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

        unless approve_mutation?(diff_text, "overwrite #{rel_path}")
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

    # Helper to strip read_file visual gutter prefixes ("   28 | ")
    private def strip_display_prefixes(text : String) : String
      text.lines(chomp: false).map { |line| line.sub(/^\s*\d+\s*\|\s?/, "") }.join
    end

    private def has_display_prefixes?(text : String) : Bool
      text.lines(chomp: false).any? { |line| line =~ /^\s*\d+\s*\|\s?/ }
    end

    # Replaces unique substring or line-anchored range with replacement in existing file with diff approval
    def replace_in_file(
      path : String,
      target : String = "",
      replacement : String = "",
      start_line : Int32? = nil,
      end_line : Int32? = nil
    ) : String
      full_path = @guard.resolve_write(path)
      rel_path = Path.new(full_path).relative_to(@guard.root).to_s

      unless File.exists?(full_path)
        return {error: "File not found: #{path}"}.to_json
      end

      original = File.read(full_path)

      if start_line || end_line
        lines = original.lines(chomp: false)
        total_lines = lines.size

        if total_lines == 0
          return {error: "File #{rel_path} is empty; use write_file instead"}.to_json
        end

        s_line = start_line || 1
        e_line = end_line || start_line || total_lines

        if s_line < 1 || e_line < s_line || s_line > total_lines || e_line > total_lines
          return {error: "Invalid line range #{s_line}..#{e_line} for #{rel_path} (file has #{total_lines} lines)"}.to_json
        end

        clean_replacement = has_display_prefixes?(replacement) ? strip_display_prefixes(replacement) : replacement
        original_segment = lines[(s_line - 1)...e_line].join

        if original_segment.ends_with?('\n') && !clean_replacement.empty? && !clean_replacement.ends_with?('\n')
          clean_replacement = "#{clean_replacement}\n"
        end

        prefix = lines[0...(s_line - 1)].join
        suffix = lines[e_line...total_lines].join
        updated = "#{prefix}#{clean_replacement}#{suffix}"

        diff_text = Diff.unified_diff(original, updated, rel_path)
        unless approve_mutation?(diff_text, "overwrite #{rel_path} (replace lines #{s_line}..#{e_line})")
          return "[Execution rejected by user]"
        end

        File.write(full_path, updated)
        record_side_effect(rel_path)

        return "Successfully replaced lines #{s_line}..#{e_line} in #{rel_path}"
      end

      # Pure target substring mode
      if target.empty?
        return {error: "Either target or start_line must be specified for #{rel_path}"}.to_json
      end

      active_target = target
      active_replacement = replacement
      count = original.scan(active_target).size

      if count == 0 && has_display_prefixes?(active_target)
        stripped_target = strip_display_prefixes(active_target)
        stripped_count = original.scan(stripped_target).size
        if stripped_count == 1
          active_target = stripped_target
          active_replacement = strip_display_prefixes(active_replacement)
          count = 1
        elsif stripped_count > 1
          count = stripped_count
          active_target = stripped_target
        end
      end

      if count == 0
        return {error: "Target string not found in #{rel_path}"}.to_json
      elsif count > 1
        return {error: "Target string occurs #{count} times in #{rel_path}; must be unique to replace safely"}.to_json
      end

      updated = original.sub(active_target, active_replacement)
      diff_text = Diff.unified_diff(original, updated, rel_path)

      unless approve_mutation?(diff_text, "overwrite #{rel_path} (replace target)")
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

        unless approve_mutation?(diff_text, "append to #{rel_path}")
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
