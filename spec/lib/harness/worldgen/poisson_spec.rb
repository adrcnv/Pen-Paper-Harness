require "rails_helper"

RSpec.describe Harness::Worldgen::Poisson do
  describe "#sample" do
    it "is deterministic given the seed" do
      a = described_class.new(size: 100, seed: 7).sample(count: 10, min_dist: 8)
      b = described_class.new(size: 100, seed: 7).sample(count: 10, min_dist: 8)
      expect(a).to eq(b)
    end

    it "differs across seeds" do
      a = described_class.new(size: 100, seed: 1).sample(count: 10, min_dist: 8)
      b = described_class.new(size: 100, seed: 2).sample(count: 10, min_dist: 8)
      expect(a).not_to eq(b)
    end

    it "respects the minimum distance between every pair" do
      points = described_class.new(size: 100, seed: 13).sample(count: 12, min_dist: 10)
      points.combination(2).each do |a, b|
        d = Math.hypot(a[0] - b[0], a[1] - b[1])
        expect(d).to be >= 10
      end
    end

    it "stays within the grid bounds" do
      points = described_class.new(size: 50, seed: 4).sample(count: 8, min_dist: 6)
      points.each do |x, y|
        expect(x).to be_between(0, 50)
        expect(y).to be_between(0, 50)
      end
    end

    it "may return fewer than requested when the grid saturates" do
      # 4 points min_dist=10 on a 5x5 grid is impossible; should return ≤ 1.
      points = described_class.new(size: 5, seed: 1).sample(count: 4, min_dist: 10)
      expect(points.size).to be <= 1
    end
  end
end
