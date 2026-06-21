require "rails_helper"

RSpec.describe Harness::Worldgen::Biome do
  describe ".coarse (projection of fine terrain)" do
    it "collapses elevated terrain to highland" do
      %i[mountain crags forest_upland moor].each do |t|
        expect(described_class.coarse(t)).to eq(described_class::HIGHLAND)
      end
    end

    it "collapses low/flat terrain to lowland" do
      %i[coastal river_valley marsh floodplain grassland forest_lowland].each do |t|
        expect(described_class.coarse(t)).to eq(described_class::LOWLAND)
      end
    end

    it "accepts strings as well as symbols" do
      expect(described_class.coarse("mountain")).to eq(described_class::HIGHLAND)
      expect(described_class.coarse("grassland")).to eq(described_class::LOWLAND)
    end

    it "returns a value from the enum for every fine terrain" do
      Harness::Worldgen::Terrain::LAND.each do |t|
        expect(described_class::ALL).to include(described_class.coarse(t))
      end
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
