require "rails_helper"

RSpec.describe Harness::Worldgen::Generator do
  describe ".generate" do
    it "produces a Map struct with cities and kingdoms" do
      map = described_class.generate(seed: 42, size: 100, city_count: 10, kingdom_count: 3)
      expect(map).to be_a(Harness::Worldgen::Map)
      expect(map.cities.size).to be > 0
      expect(map.kingdoms.size).to eq(3)
    end

    it "is deterministic given the seed" do
      a = described_class.generate(seed: 99, size: 100, city_count: 10, kingdom_count: 3)
      b = described_class.generate(seed: 99, size: 100, city_count: 10, kingdom_count: 3)
      expect(a.cities.map { |c| [ c.x, c.y, c.biome, c.kingdom_id ] })
        .to eq(b.cities.map { |c| [ c.x, c.y, c.biome, c.kingdom_id ] })
    end

    it "differs across seeds" do
      a = described_class.generate(seed: 1, city_count: 10, kingdom_count: 3)
      b = described_class.generate(seed: 2, city_count: 10, kingdom_count: 3)
      expect(a.cities.map { |c| [ c.x, c.y ] })
        .not_to eq(b.cities.map { |c| [ c.x, c.y ] })
    end

    it "assigns every city a valid biome" do
      map = described_class.generate(seed: 7)
      expect(map.cities.map(&:biome).uniq - Harness::Worldgen::Biome::ALL).to be_empty
    end

    it "assigns every city a kingdom_id within range" do
      map = described_class.generate(seed: 7, kingdom_count: 4)
      expect(map.cities.map(&:kingdom_id).uniq).to all(be_between(0, 3))
    end

    it "kingdom anchors point at real cities" do
      map = described_class.generate(seed: 7, city_count: 12, kingdom_count: 3)
      map.kingdoms.each do |k|
        expect(k.anchor_city_id).to be_between(0, map.cities.size - 1)
      end
    end

    it "every kingdom has at least one member city (its anchor)" do
      map = described_class.generate(seed: 7, city_count: 12, kingdom_count: 3)
      map.kingdoms.each do |k|
        members = map.cities.count { |c| c.kingdom_id == k.id }
        expect(members).to be >= 1
      end
    end

    it "carries the geography the cities were placed on" do
      map = described_class.generate(seed: 7)
      expect(map.geography).to be_a(Harness::Worldgen::Geography)
    end

    it "places cities on habitable land, never in the open sea" do
      map = described_class.generate(seed: 7, city_count: 12)
      geo = map.geography
      map.cities.each do |c|
        expect(geo.sea?(c.x, c.y)).to be(false), "city #{c.id} sits in the sea"
      end
    end

    it "denormalizes terrain + coastal/riverside facts onto each city" do
      map = described_class.generate(seed: 7, city_count: 12)
      map.cities.each do |c|
        expect(Harness::Worldgen::Terrain::LAND.map(&:to_s)).to include(c.terrain)
        expect([ true, false ]).to include(c.coastal)
        expect([ true, false ]).to include(c.riverside)
      end
    end

  end
end
