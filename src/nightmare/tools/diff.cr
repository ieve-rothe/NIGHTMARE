# nightmare/tools/diff.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

module Nightmare::Tools
  module Diff
    # Generates a standard unified diff between original and updated strings
    def self.unified_diff(
      original : String,
      updated : String,
      path : String = "file",
      context_lines : Int32 = 3
    ) : String
      orig_lines = original.split('\n')
      new_lines = updated.split('\n')

      diff_ops = compute_lcs_diff(orig_lines, new_lines)

      # If no changes
      return "" if diff_ops.all? { |op| op[:type] == :keep }

      String.build do |io|
        io.puts "--- a/#{path}"
        io.puts "+++ b/#{path}"

        # Group into hunks
        hunks = create_hunks(diff_ops, orig_lines, new_lines, context_lines)
        hunks.each do |hunk|
          io.puts "@@ -#{hunk[:orig_start]},#{hunk[:orig_count]} +#{hunk[:new_start]},#{hunk[:new_count]} @@"
          hunk[:lines].each do |line|
            io.puts line
          end
        end
      end
    end

    private def self.compute_lcs_diff(orig_lines : Array(String), new_lines : Array(String))
      m = orig_lines.size
      n = new_lines.size

      # dp table for LCS
      dp = Array.new(m + 1) { Array.new(n + 1, 0) }
      (0...m).each do |i|
        (0...n).each do |j|
          if orig_lines[i] == new_lines[j]
            dp[i + 1][j + 1] = dp[i][j] + 1
          else
            dp[i + 1][j + 1] = Math.max(dp[i + 1][j], dp[i][j + 1])
          end
        end
      end

      # Backtrack to build diff operations
      ops = [] of NamedTuple(type: Symbol, orig_line: String?, new_line: String?)
      i = m
      j = n
      while i > 0 || j > 0
        if i > 0 && j > 0 && orig_lines[i - 1] == new_lines[j - 1]
          ops << {type: :keep, orig_line: orig_lines[i - 1], new_line: new_lines[j - 1]}
          i -= 1
          j -= 1
        elsif j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j])
          ops << {type: :add, orig_line: nil, new_line: new_lines[j - 1]}
          j -= 1
        elsif i > 0 && (j == 0 || dp[i][j - 1] < dp[i - 1][j])
          ops << {type: :del, orig_line: orig_lines[i - 1], new_line: nil}
          i -= 1
        end
      end

      ops.reverse
    end

    private def self.create_hunks(
      diff_ops : Array(NamedTuple(type: Symbol, orig_line: String?, new_line: String?)),
      orig_lines : Array(String),
      new_lines : Array(String),
      context_lines : Int32
    )
      # For concise display, format as a single hunk or continuous diff
      hunk_lines = [] of String
      orig_line_num = 1
      new_line_num = 1
      orig_count = 0
      new_count = 0

      diff_ops.each do |op|
        case op[:type]
        when :keep
          hunk_lines << " #{op[:orig_line]}"
          orig_count += 1
          new_count += 1
        when :del
          hunk_lines << "-#{op[:orig_line]}"
          orig_count += 1
        when :add
          hunk_lines << "+#{op[:new_line]}"
          new_count += 1
        end
      end

      [{
        orig_start: 1,
        orig_count: orig_count,
        new_start: 1,
        new_count: new_count,
        lines: hunk_lines
      }]
    end
  end
end
