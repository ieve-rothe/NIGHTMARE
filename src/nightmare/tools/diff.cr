# nightmare/tools/diff.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "colorize"

module Nightmare::Tools
  module Diff
    # Formats unified diff text with ANSI syntax highlighting for terminal presentation
    def self.colorize(diff : String) : String
      return "" if diff.empty?

      lines = diff.split('\n')
      colored_lines = lines.map do |line|
        if line.starts_with?("--- ") || line.starts_with?("+++ ")
          line.colorize.mode(:bold).to_s
        elsif line.starts_with?("@@")
          line.colorize(:cyan).to_s
        elsif line.starts_with?('+')
          line.colorize(:green).to_s
        elsif line.starts_with?('-')
          line.colorize(:red).to_s
        else
          line
        end
      end

      colored_lines.join('\n')
    end

    # Generates a standard unified diff between original and updated strings
    def self.unified_diff(
      original : String,
      updated : String,
      path : String = "file",
      context_lines : Int32 = 3
    ) : String
      orig_lines = original.empty? ? [] of String : original.split('\n')
      new_lines = updated.empty? ? [] of String : updated.split('\n')

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
      ctx = Math.max(0, context_lines)

      # Annotate each operation with pre-operation line positions
      cur_orig = 1
      cur_new = 1
      annotated = diff_ops.map do |op|
        ob = cur_orig
        nb = cur_new
        formatted = case op[:type]
                    when :keep
                      cur_orig += 1
                      cur_new += 1
                      " #{op[:orig_line]}"
                    when :del
                      cur_orig += 1
                      "-#{op[:orig_line]}"
                    when :add
                      cur_new += 1
                      "+#{op[:new_line]}"
                    else
                      ""
                    end

        {
          type:        op[:type],
          orig_line:   op[:orig_line],
          new_line:    op[:new_line],
          orig_before: ob,
          new_before:  nb,
          formatted:   formatted,
        }
      end

      # Find indices of all change operations
      change_indices = [] of Int32
      annotated.each_with_index do |item, idx|
        change_indices << idx if item[:type] != :keep
      end

      return [] of NamedTuple(orig_start: Int32, orig_count: Int32, new_start: Int32, new_count: Int32, lines: Array(String)) if change_indices.empty?

      # Group consecutive change indices into clusters when the keep gap between them <= 2 * ctx
      clusters = [] of Array(Int32)
      cur_cluster = [change_indices[0]]

      (1...change_indices.size).each do |c_idx|
        prev = change_indices[c_idx - 1]
        curr = change_indices[c_idx]
        keep_gap = curr - prev - 1
        if keep_gap <= 2 * ctx
          cur_cluster << curr
        else
          clusters << cur_cluster
          cur_cluster = [curr]
        end
      end
      clusters << cur_cluster

      # Build each hunk from its cluster and surrounding context
      hunks = [] of NamedTuple(orig_start: Int32, orig_count: Int32, new_start: Int32, new_count: Int32, lines: Array(String))

      clusters.each do |cluster|
        c_start = cluster.first
        c_end = cluster.last

        h_start = Math.max(0, c_start - ctx)
        h_end = Math.min(annotated.size - 1, c_end + ctx)

        orig_count = 0
        new_count = 0
        hunk_lines = [] of String

        (h_start..h_end).each do |idx|
          item = annotated[idx]
          case item[:type]
          when :keep
            orig_count += 1
            new_count += 1
            hunk_lines << item[:formatted]
          when :del
            orig_count += 1
            hunk_lines << item[:formatted]
          when :add
            new_count += 1
            hunk_lines << item[:formatted]
          end
        end

        start_item = annotated[h_start]
        orig_start = orig_count == 0 ? start_item[:orig_before] - 1 : start_item[:orig_before]
        new_start = new_count == 0 ? start_item[:new_before] - 1 : start_item[:new_before]

        hunks << {
          orig_start: orig_start,
          orig_count: orig_count,
          new_start:  new_start,
          new_count:  new_count,
          lines:      hunk_lines,
        }
      end

      hunks
    end
  end
end
