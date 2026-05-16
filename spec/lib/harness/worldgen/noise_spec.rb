require "rails_helper"

RSpec.describe Harness::Worldgen::Noise do
  describe "#at" do
    it "is deterministic: same seed + same coords → same value" do
      a = described_class.new(seed: 42).at(3.7, 9.1)
      b = described_class.new(seed: 42).at(3.7, 9.1)
      expect(a).to eq(b)
    end

    it "differs across seeds" do
      a = described_class.new(seed: 1).at(5.0, 5.0)
      b = described_class.new(seed: 2).at(5.0, 5.0)
      expect(a).not_to eq(b)
    end

    it "returns floats in [0, 1]" do
      noise = described_class.new(seed: 7)
      values = (0..50).flat_map { |x| (0..50).map { |y| noise.at(x * 0.3, y * 0.3) } }
      expect(values.min).to be >= 0.0
      expect(values.max).to be <= 1.0
    end

    it "is smooth: small coord perturbation → small value change" do
      noise = described_class.new(seed: 99)
      v1 = noise.at(10.0, 10.0)
      v2 = noise.at(10.001, 10.0)
      expect((v1 - v2).abs).to be < 0.05
    end

    it "produces both low and high values across the field" do
      noise = described_class.new(seed: 13)
      values = (0..40).flat_map { |x| (0..40).map { |y| noise.at(x * 1.0, y * 1.0) } }
      expect(values.min).to be < 0.4
      expect(values.max).to be > 0.6
    end

    it "supports octave summing without breaking determinism" do
      a = described_class.new(seed: 5).at(7.7, 3.3, octaves: 3, persistence: 0.5)
      b = described_class.new(seed: 5).at(7.7, 3.3, octaves: 3, persistence: 0.5)
      expect(a).to eq(b)
    end
  end
end
