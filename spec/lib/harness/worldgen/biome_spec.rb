require "rails_helper"

RSpec.describe Harness::Worldgen::Biome do
  let(:noise) { Harness::Worldgen::Noise.new(seed: 42) }

  describe ".at" do
    it "returns a value from the enum" do
      result = described_class.at(noise: noise, x: 5.0, y: 5.0)
      expect(described_class::ALL).to include(result)
    end

    it "is deterministic given the noise and coords" do
      a = described_class.at(noise: noise, x: 3.0, y: 8.0)
      b = described_class.at(noise: noise, x: 3.0, y: 8.0)
      expect(a).to eq(b)
    end

    it "produces both biomes across a sampled field" do
      tiles = (0..30).flat_map { |x| (0..30).map { |y| described_class.at(noise: noise, x: x * 1.0, y: y * 1.0) } }
      expect(tiles).to include(described_class::LOWLAND)
      expect(tiles).to include(described_class::HIGHLAND)
    end
  end

  describe ".cost_multiplier" do
    it "returns 1.0 for lowland (baseline)" do
      expect(described_class.cost_multiplier(described_class::LOWLAND)).to eq(1.0)
    end

    it "returns > 1.0 for highland (rougher)" do
      expect(described_class.cost_multiplier(described_class::HIGHLAND)).to be > 1.0
    end

    it "falls back to 1.0 for unknown biome strings" do
      expect(described_class.cost_multiplier("sea")).to eq(1.0)
    end
  end
end
