# nightmare/context/token_calibrator.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "json"
require "../config"

module Nightmare::Context
  class TokenEstimator
    include JSON::Serializable

    property divisor : Float64 = Config::INITIAL_DIVISOR

    @[JSON::Field(ignore: true)]
    property last_prompt_tokens : Int32? = nil

    def initialize(@divisor : Float64 = Config::INITIAL_DIVISOR)
    end

    # Estimates tokens from character count using the current calibrated divisor
    def estimate(chars : Int32) : Int32
      return 0 if chars <= 0
      (chars.to_f / @divisor).ceil.to_i
    end

    # Calibrates the divisor using real prompt_eval_count from LLM response.
    # Tolerates nil or zero on prompt_eval_count gracefully without raising.
    def calibrate!(assembled_chars : Int32, prompt_eval_count : Int32?) : Nil
      return if assembled_chars <= 0
      return if prompt_eval_count.nil? || prompt_eval_count <= 0

      @last_prompt_tokens = prompt_eval_count

      sample = assembled_chars.to_f / prompt_eval_count.to_f
      new_divisor = ((1.0 - Config::DIVISOR_ALPHA) * @divisor) + (Config::DIVISOR_ALPHA * sample)
      @divisor = new_divisor.clamp(Config::DIVISOR_CLAMP_MIN, Config::DIVISOR_CLAMP_MAX)
    end

    # Saves the calibrator state to the workspace cache directory
    def save(cache_dir : String) : Nil
      Dir.mkdir_p(cache_dir) unless Dir.exists?(cache_dir)
      path = File.join(cache_dir, "calibrator.json")
      File.write(path, self.to_json)
    end

    # Loads saved calibrator from cache or creates a new one
    def self.load_or_create(cache_dir : String) : TokenEstimator
      path = File.join(cache_dir, "calibrator.json")
      if File.exists?(path)
        begin
          from_json(File.read(path))
        rescue
          new
        end
      else
        new
      end
    end
  end

  alias TokenCalibrator = TokenEstimator
end
