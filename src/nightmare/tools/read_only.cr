# nightmare/tools/read_only.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "path"
require "json"
require "file_utils"
require "../config"
require "./guard"

module Nightmare::Tools
  class ReadOnly
    getter guard : Guard
    property pinned_files : Context::PinnedFiles?

    def initialize(@guard : Guard, @pinned_files : Context::PinnedFiles? = nil)
    end

    # Lists files in the workspace with glob filtering and adaptive depth collapsing, excluding git/nightmare/sensitive files
    def list_files(path : String? = nil, glob : String? = nil, depth : Int32? = nil) : String
      target_dir = if p = path
        @guard.resolve_read(p)
      else
        @guard.root
      end

      unless Dir.exists?(target_dir)
        return {error: "Directory not found: #{path || "."}"}.to_json
      end

      max_results = @guard.env.settings.list_files_max_results
      target_in_root = @guard.env.inside_root?(target_dir)

      # Mode 1: Explicit glob pattern provided
      if glob && !glob.empty?
        results = [] of String
        Dir.glob(File.join(target_dir, glob), match: :all) do |entry|
          next if Dir.exists?(entry) # only files
          rel_to_root = Path.new(entry).relative_to(@guard.root).to_s rescue entry
          rel_to_target = Path.new(entry).relative_to(target_dir).to_s rescue entry

          # Exclude protected/sensitive files
          next if @guard.protected_path?(rel_to_root) || @guard.protected_path?(rel_to_target)
          next if @guard.sensitive_read?(rel_to_root) || @guard.sensitive_read?(rel_to_target) || @guard.sensitive_read?(File.basename(entry))

          display_path = format_display_path(entry, target_dir, rel_to_root, rel_to_target, path, target_in_root)
          results << display_path
        end

        results.sort!
        if results.empty?
          output = "(no matching files)"
        elsif results.size > max_results
          truncated = results.first(max_results)
          remaining = results.size - max_results
          output = (truncated + ["[... #{remaining} more matching files truncated. Narrow 'glob' pattern or specify a more specific 'path'.]"]).join("\n")
        else
          output = results.join("\n")
        end

        return Guard.cap_output(output, max_bytes: @guard.env.settings.tool_output_max_bytes)
      end

      # Mode 2: Explicit depth requested
      if requested_depth = depth
        clamped_depth = Math.max(1, requested_depth)
        entries = [] of String
        collect_depth_bounded(target_dir, target_dir, 1, clamped_depth, path, target_in_root, entries)
        entries.sort!

        if entries.empty?
          output = "(no matching files)"
        elsif entries.size > max_results
          truncated = entries.first(max_results)
          remaining = entries.size - max_results
          output = (truncated + ["[... #{remaining} more entries truncated. Call list_files with 'path' set to a subdirectory or specify a narrower 'glob'.]"]).join("\n")
        else
          output = entries.join("\n")
        end

        return Guard.cap_output(output, max_bytes: @guard.env.settings.tool_output_max_bytes)
      end

      # Mode 3: Adaptive mode (no glob, no depth)
      all_recursive_files = [] of String
      is_over_budget = false

      Dir.glob(File.join(target_dir, "**/*"), match: :all) do |entry|
        next if Dir.exists?(entry)
        rel_to_root = Path.new(entry).relative_to(@guard.root).to_s rescue entry
        rel_to_target = Path.new(entry).relative_to(target_dir).to_s rescue entry

        next if @guard.protected_path?(rel_to_root) || @guard.protected_path?(rel_to_target)
        next if @guard.sensitive_read?(rel_to_root) || @guard.sensitive_read?(rel_to_target) || @guard.sensitive_read?(File.basename(entry))

        if all_recursive_files.size >= max_results
          is_over_budget = true
          break
        end

        display_path = format_display_path(entry, target_dir, rel_to_root, rel_to_target, path, target_in_root)
        all_recursive_files << display_path
      end

      unless is_over_budget
        all_recursive_files.sort!
        output = all_recursive_files.empty? ? "(no matching files)" : all_recursive_files.join("\n")
        return Guard.cap_output(output, max_bytes: @guard.env.settings.tool_output_max_bytes)
      end

      # Large directory exceeding budget -> collapse to depth 1
      entries = [] of String
      collect_depth_bounded(target_dir, target_dir, 1, 1, path, target_in_root, entries)
      entries.sort!

      if entries.size > max_results
        truncated = entries.first(max_results)
        remaining = entries.size - max_results
        output = (truncated + ["[... #{remaining} more entries truncated. Call list_files with 'path' set to a subdirectory or specify a narrower 'glob'.]"]).join("\n")
      else
        footer = "[Directory contains >#{max_results} files. Showing top-level structure. Call list_files with 'path' set to a subdirectory or specify a 'glob' to inspect deeper.]"
        output = (entries + [footer]).join("\n")
      end

      Guard.cap_output(output, max_bytes: @guard.env.settings.tool_output_max_bytes)
    end

    # Greps for pattern in files across workspace, excluding git/nightmare/sensitive files
    def search(pattern : String, path : String? = nil, glob : String? = nil) : String
      target_dir = if p = path
        @guard.resolve_read(p)
      else
        @guard.root
      end

      unless Dir.exists?(target_dir)
        return {error: "Directory not found: #{path || "."}"}.to_json
      end

      regex = begin
        Regex.new(pattern, Regex::Options::MULTILINE)
      rescue ex
        return {error: "Invalid regex pattern: #{ex.message}"}.to_json
      end

      filter_glob = glob || "**/*"
      matches = [] of String
      target_in_root = @guard.env.inside_root?(target_dir)

      Dir.glob(File.join(target_dir, filter_glob), match: :all) do |entry|
        next if Dir.exists?(entry)
        rel_to_root = Path.new(entry).relative_to(@guard.root).to_s
        rel_to_target = Path.new(entry).relative_to(target_dir).to_s

        next if @guard.protected_path?(rel_to_root) || @guard.protected_path?(rel_to_target)
        next if @guard.sensitive_read?(rel_to_root) || @guard.sensitive_read?(rel_to_target) || @guard.sensitive_read?(File.basename(entry))

        display_path = if target_in_root
          rel_to_root
        elsif p = path
          p.ends_with?('/') ? "#{p}#{rel_to_target}" : "#{p}/#{rel_to_target}"
        else
          entry
        end

        begin
          idx = 0
          File.each_line(entry) do |line|
            idx += 1
            if line.matches?(regex)
              matches << "#{display_path}:#{idx}: #{line}"
              break if matches.size >= 1000
            end
          end
        rescue
          # skip non-UTF8 or unreadable files
        end
      end

      output = matches.join("\n")
      output = "(no matches found)" if output.empty?

      Guard.cap_output(output, max_bytes: @guard.env.settings.tool_output_max_bytes)
    end

    # Reads file contents with optional 1-based line offset and limit
    def read_file(path : String, offset : Int32? = nil, limit : Int32? = nil) : String
      full_path = @guard.resolve_read(path)
      rel_path = if @guard.env.inside_root?(full_path)
        Path.new(full_path).relative_to(@guard.root).to_s
      else
        full_path
      end

      if @pinned_files.try &.pinned?(rel_path) || @pinned_files.try &.pinned?(path)
        return "[File is already pinned in context: #{path}]"
      end

      unless File.exists?(full_path)
        return {error: "File not found: #{path}"}.to_json
      end

      settings = @guard.env.settings

      # Guard against unpaginated bulk/log file reads
      if bulk_data_file?(rel_path, settings.bulk_data_patterns)
        if limit.nil? || limit > settings.bulk_data_max_lines
          return "[Refused: '#{rel_path}' matches bulk data/log pattern (#{settings.bulk_data_patterns.join(", ")}). " \
                 "To prevent context saturation, specify 'offset' and 'limit' (max #{settings.bulk_data_max_lines} lines per read), " \
                 "or use 'search' to locate specific entries.]"
        end
      end

      start_line = offset ? Math.max(1, offset) : 1

      selected_lines = [] of String
      if offset || limit
        max_lines = limit ? Math.max(0, limit) : nil
        if max_lines.nil? || max_lines > 0
          idx = 0
          File.each_line(full_path) do |line|
            idx += 1
            next if idx < start_line

            selected_lines << line
            break if max_lines && selected_lines.size >= max_lines
          end
        end
      else
        # If no offset/limit, perform quick size pre-check against per_file_max_tokens
        # At minimum 1 char/byte and divisor 3.5, if size in bytes > per_file_max_tokens * 8, it's definitely over limit
        file_bytes = File.size(full_path)
        if file_bytes > (settings.per_file_max_tokens.to_i64 * 8)
          rough_tok = (file_bytes.to_f / settings.initial_divisor).ceil.to_i
          return "[Refused: File '#{rel_path}' (~#{rough_tok} estimated tokens) exceeds the per-file context limit of #{settings.per_file_max_tokens} tokens. " \
                 "To inspect this file without saturating context: " \
                 "1) use read_file with 'offset' and 'limit' to read a smaller window, " \
                 "2) use 'search' to locate specific patterns, or " \
                 "3) extract key lessons into a smaller artifact using spawn_subagent.]"
        end
        selected_lines = File.read_lines(full_path)
      end

      formatted = selected_lines.map_with_index do |line, idx|
        line_num = start_line.to_i64 + idx
        "#{line_num.to_s.rjust(5)} | #{line}"
      end.join("\n")

      # Token ceiling verification
      divisor = settings.initial_divisor
      estimated_tokens = (formatted.size.to_f / divisor).ceil.to_i
      if estimated_tokens > settings.per_file_max_tokens
        return "[Refused: Content for '#{rel_path}' (~#{estimated_tokens} tokens) exceeds the per-file context limit of #{settings.per_file_max_tokens} tokens. " \
               "To inspect this file without saturating context: " \
               "1) use read_file with 'offset' and 'limit' to read a smaller window, " \
               "2) use 'search' to locate specific patterns, or " \
               "3) extract key lessons into a smaller artifact using spawn_subagent.]"
      end

      Guard.cap_output(formatted, max_bytes: settings.tool_output_max_bytes)
    end

    private def format_display_path(
      entry : String,
      root_target_dir : String,
      rel_to_root : String,
      rel_to_target : String,
      path_param : String?,
      target_in_root : Bool,
      is_dir : Bool = false
    ) : String
      base = if target_in_root
        rel_to_root
      elsif p = path_param
        p.ends_with?('/') ? "#{p}#{rel_to_target}" : "#{p}/#{rel_to_target}"
      else
        entry
      end

      if is_dir && !base.ends_with?('/')
        "#{base}/"
      else
        base
      end
    end

    private def collect_depth_bounded(
      dir : String,
      root_target_dir : String,
      current_depth : Int32,
      max_depth : Int32,
      path_param : String?,
      target_in_root : Bool,
      results : Array(String)
    ) : Nil
      children = begin
        Dir.children(dir)
      rescue
        return
      end

      children.sort!
      children.each do |child|
        full_child = File.join(dir, child)
        rel_to_root = Path.new(full_child).relative_to(@guard.root).to_s rescue full_child
        rel_to_target = Path.new(full_child).relative_to(root_target_dir).to_s rescue child

        next if @guard.protected_path?(rel_to_root) || @guard.protected_path?(child)
        next if @guard.sensitive_read?(rel_to_root) || @guard.sensitive_read?(child)

        is_directory = File.directory?(full_child) rescue false

        if is_directory
          if current_depth >= max_depth
            count = count_files_in_dir(full_child)
            display_dir = format_display_path(full_child, root_target_dir, rel_to_root, rel_to_target, path_param, target_in_root, is_dir: true)
            count_label = count == 1 ? "1 file" : "#{count} files"
            results << "#{display_dir} (#{count_label})"
          else
            collect_depth_bounded(full_child, root_target_dir, current_depth + 1, max_depth, path_param, target_in_root, results)
          end
        else
          display_file = format_display_path(full_child, root_target_dir, rel_to_root, rel_to_target, path_param, target_in_root, is_dir: false)
          results << display_file
        end
      end
    end

    private def count_files_in_dir(dir_path : String) : Int32
      count = 0
      begin
        Dir.glob(File.join(dir_path, "**/*"), match: :all) do |entry|
          next if Dir.exists?(entry)
          rel_to_root = Path.new(entry).relative_to(@guard.root).to_s rescue entry
          next if @guard.protected_path?(rel_to_root) || @guard.protected_path?(File.basename(entry))
          next if @guard.sensitive_read?(rel_to_root) || @guard.sensitive_read?(File.basename(entry))
          count += 1
          break if count >= 10_000
        end
      rescue
      end
      count
    end

    private def bulk_data_file?(rel_path : String, patterns : Array(String)) : Bool
      clean_rel = rel_path
      basename = File.basename(clean_rel)
      patterns.any? do |pattern|
        File.match?(pattern, clean_rel) || File.match?(pattern, basename)
      end
    end

    # Returns metadata for a file in the workspace
    def file_info(path : String) : String
      full_path = @guard.resolve_read(path)

      unless File.exists?(full_path)
        return {error: "File not found: #{path}"}.to_json
      end

      info = File.info(full_path)
      is_dir = info.directory?
      lines_count = is_dir ? 0 : File.read_lines(full_path).size rescue 0

      display_path = if @guard.env.inside_root?(full_path)
        Path.new(full_path).relative_to(@guard.root).to_s
      else
        full_path
      end

      {
        path: display_path,
        size_bytes: info.size,
        directory: is_dir,
        lines: lines_count,
        permissions: info.permissions.to_s,
        modification_time: info.modification_time.to_utc.to_s
      }.to_json
    end
  end
end
