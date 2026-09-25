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

    # Lists files in the workspace with glob filtering, excluding git/nightmare/sensitive files
    def list_files(path : String? = nil, glob : String? = nil) : String
      target_dir = if p = path
        @guard.resolve_read(p)
      else
        @guard.root
      end

      unless Dir.exists?(target_dir)
        return {error: "Directory not found: #{path || "."}"}.to_json
      end

      results = [] of String
      filter_glob = glob || "**/*"

      Dir.glob(File.join(target_dir, filter_glob), match: :all) do |entry|
        next if Dir.exists?(entry) # only files
        rel = Path.new(entry).relative_to(@guard.root).to_s

        # Exclude protected/sensitive files
        next if @guard.protected_path?(rel)
        next if @guard.sensitive_read?(rel)

        results << rel
      end

      results.sort!
      output = results.join("\n")
      output = "(no matching files)" if output.empty?

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

      Dir.glob(File.join(target_dir, filter_glob), match: :all) do |entry|
        next if Dir.exists?(entry)
        rel = Path.new(entry).relative_to(@guard.root).to_s

        next if @guard.protected_path?(rel)
        next if @guard.sensitive_read?(rel)

        begin
          idx = 0
          File.each_line(entry) do |line|
            idx += 1
            if line.matches?(regex)
              matches << "#{rel}:#{idx}: #{line}"
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
      rel_path = Path.new(full_path).relative_to(@guard.root).to_s

      if @pinned_files.try &.pinned?(rel_path)
        return "[File is already pinned in context: #{rel_path}]"
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

      {
        path: Path.new(full_path).relative_to(@guard.root).to_s,
        size_bytes: info.size,
        directory: is_dir,
        lines: lines_count,
        permissions: info.permissions.to_s,
        modification_time: info.modification_time.to_utc.to_s
      }.to_json
    end
  end
end
