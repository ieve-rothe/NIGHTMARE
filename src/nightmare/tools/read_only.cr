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

      Guard.cap_output(output)
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

      Guard.cap_output(output)
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

      lines = File.read_lines(full_path)
      start_line = offset ? Math.max(1, offset) : 1
      max_lines = limit ? Math.max(0, limit) : lines.size

      lo = Math.max(0, start_line - 1)
      hi = Math.min(lines.size - 1, lo + max_lines - 1)

      selected_lines = if lo <= hi && lo < lines.size
        lines[lo..hi]
      else
        [] of String
      end

      formatted = selected_lines.map_with_index do |line, idx|
        line_num = start_line + idx
        "#{line_num.to_s.rjust(5)} | #{line}"
      end.join("\n")

      Guard.cap_output(formatted)
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
