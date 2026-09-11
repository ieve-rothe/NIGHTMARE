# nightmare/context/pinned_files.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "../config"
require "../tools/guard"
require "./token_calibrator"

module Nightmare::Context
  class PinnedFile
    getter path : String                     # workspace-relative, as displayed
    getter slice_start : Int32?              # 1-based, inclusive
    getter slice_end : Int32?                # 1-based, inclusive
    property cached_mtime : Time?
    property cached_tokens : Int32?

    def initialize(@path : String, @slice_start : Int32? = nil, @slice_end : Int32? = nil)
    end

    # Root containment belongs to Tools::Guard.resolve_read (§4.1), which
    # raises SecurityError outside @root or on a sensitive pattern.
    def read_content(guard : Tools::Guard) : String
      full = guard.resolve_read(@path)
      lines = File.read_lines(full)
      s, e = @slice_start, @slice_end
      return lines.join("\n") if s.nil? || e.nil?
      lo = Math.max(s - 1, 0)
      hi = Math.min(e - 1, lines.size - 1)
      return "" if lo > hi                   # clamp; never raise on a stale slice
      lines[lo..hi].join("\n")
    end
  end

  class PinnedFiles
    getter files : Array(PinnedFile)

    def initialize
      @files = [] of PinnedFile
    end

    def add(
      path : String,
      guard : Tools::Guard,
      calibrator : TokenEstimator,
      slice_start : Int32? = nil,
      slice_end : Int32? = nil,
      hardmax : Int32 = Config::TOKEN_HARDMAX,
      budget_ratio : Float64 = Config::PINNED_BUDGET_RATIO
    ) : PinnedFile
      candidate = PinnedFile.new(path, slice_start, slice_end)
      content = candidate.read_content(guard)
      candidate_tokens = calibrator.estimate(content.size)
      candidate.cached_tokens = candidate_tokens

      # Check budget excluding existing pin for this path if updating
      other_files = @files.reject { |f| f.path == path }
      existing_tokens = other_files.sum do |f|
        c = f.read_content(guard)
        calibrator.estimate(c.size)
      end

      new_total = existing_tokens + candidate_tokens
      max_budget = (hardmax.to_f * budget_ratio).to_i

      if new_total > max_budget
        raise Nightmare::Error.new(
          "Adding '#{path}' (#{candidate_tokens} tokens) exceeds pinned file budget: total #{new_total} tokens > max #{max_budget} tokens (#{(budget_ratio * 100).to_i}% of #{hardmax})"
        )
      end

      # Update or add
      @files.reject! { |f| f.path == path }
      @files << candidate
      candidate
    end

    def remove(path : String) : Bool
      prev_size = @files.size
      @files.reject! { |f| f.path == path || f.path.lchop("./") == path.lchop("./") }
      @files.size < prev_size
    end

    def pinned?(path : String) : Bool
      norm = path.lchop("./")
      @files.any? { |f| f.path == path || f.path.lchop("./") == norm }
    end

    def clear : Nil
      @files.clear
    end

    def total_estimated_tokens(guard : Tools::Guard, calibrator : TokenEstimator) : Int32
      @files.sum do |f|
        content = f.read_content(guard)
        calibrator.estimate(content.size)
      end
    end

    # Renders the formatted pinned files block for prompt assembly
    def render_pinned_block(guard : Tools::Guard) : String?
      return nil if @files.empty?

      blocks = @files.compact_map do |f|
        content = f.read_content(guard)
        next nil if content.empty?
        "=== PINNED FILE: #{f.path} ===\n#{content}"
      end

      return nil if blocks.empty?
      blocks.join("\n\n")
    end
  end
end
