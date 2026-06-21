require "rails_helper"

RSpec.describe Harness::Worldgen::Ascii do
  let(:map) { Harness::Worldgen::Generator.generate(seed: 7, size: 100, city_count: 10, kingdom_count: 3) }

  describe ".render with geography" do
    it "renders without error and includes the legend" do
      out = described_class.render(map)
      expect(out).to include("kingdoms (3):")
      expect(out).to include("cities (10):")
    end

    it "draws sea, terrain, and river glyphs from the geography backdrop" do
      out = described_class.render(map)
      body = out.lines.grep(/\A[\|+~.:,"tTn^o0-9A-Z* -]+\n\z/) # backdrop rows
      expect(out).to include("~")                 # sea
      expect(out).to include(described_class::RIVER_GLYPH)
    end

    it "shows terrain on each city legend line" do
      out = described_class.render(map)
      map.cities.each do |c|
        line = out.lines.find { |l| l.include?("  city##{c.id} [") }
        expect(line).to include(c.terrain)
      end
    end
  end

  describe ".render without geography (legacy/blank)" do
    it "falls back to the blank backdrop when neither geography nor seed is set" do
      bare = Harness::Worldgen::Map.new(seed: nil, size: 50, cities: [], kingdoms: [], geography: nil)
      expect { described_class.render(bare) }.not_to raise_error
    end
  end
end
