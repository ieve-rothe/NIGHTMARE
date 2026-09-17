# spec/token_calibrator_spec.cr
require "./spec_helper"

describe Nightmare::Context::TokenEstimator do
  it "initializes with INITIAL_DIVISOR (3.5) per ARCHITECTURE §7" do
    calibrator = Nightmare::Context::TokenEstimator.new
    calibrator.divisor.should eq(3.5)
  end

  it "updates divisor according to EMA formula (T17)" do
    calibrator = Nightmare::Context::TokenEstimator.new(3.5)
    # chars = 700, prompt_eval_count = 200 => sample = 3.5
    # 0.8 * 3.5 + 0.2 * 3.5 = 3.5
    calibrator.calibrate!(700, 200)
    calibrator.divisor.should be_close(3.5, 0.001)

    # Now a sample with 800 chars and 100 prompt_eval_count => sample = 8.0
    # new_d = 0.8 * 3.5 + 0.2 * 8.0 = 2.8 + 1.6 = 4.4
    calibrator.calibrate!(800, 100)
    calibrator.divisor.should be_close(4.4, 0.001)
    calibrator.last_prompt_tokens.should eq(100)
  end

  it "clamps divisor to DIVISOR_CLAMP bounds [1.0, 10.0] (T17)" do
    calibrator = Nightmare::Context::TokenEstimator.new(3.5)

    # Pathological upper sample (100,000 chars / 1 token)
    calibrator.calibrate!(100_000, 1)
    calibrator.divisor.should eq(10.0)

    # Pathological lower sample (1 char / 10,000 tokens)
    calibrator.calibrate!(1, 10_000)
    # Converges downward, clamp min is 1.0
    10.times { calibrator.calibrate!(1, 10_000) }
    calibrator.divisor.should eq(1.0)
  end

  it "tolerates nil or zero prompt_eval_count on every turn without error (T17)" do
    calibrator = Nightmare::Context::TokenEstimator.new(3.5)
    calibrator.calibrate!(500, nil)
    calibrator.divisor.should eq(3.5)

    calibrator.calibrate!(500, 0)
    calibrator.divisor.should eq(3.5)

    calibrator.calibrate!(0, 100)
    calibrator.divisor.should eq(3.5)
  end

  it "saves and loads state from cache directory" do
    with_temp_dir do |dir|
      calibrator = Nightmare::Context::TokenEstimator.new(4.2)
      calibrator.save(dir)

      loaded = Nightmare::Context::TokenEstimator.load_or_create(dir)
      loaded.divisor.should be_close(4.2, 0.001)
    end
  end
end
