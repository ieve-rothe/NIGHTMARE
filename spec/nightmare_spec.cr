require "./spec_helper"

describe Nightmare do
  it "defines VERSION" do
    Nightmare::VERSION.should eq("0.3.2")
  end

  it "defines SecurityError exception type" do
    ex = Nightmare::SecurityError.new("Test violation")
    ex.should be_a(Exception)
    ex.message.should eq("Test violation")
  end
end
