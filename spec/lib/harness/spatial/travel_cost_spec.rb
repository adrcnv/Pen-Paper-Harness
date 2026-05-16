require "rails_helper"

RSpec.describe Harness::Spatial::TravelCost do
  describe ".for" do
    it "is deterministic given a seeded rng" do
      a = described_class.for(category: :cross_kingdom, from_terrain: "coast", to_terrain: "coast", rng: Random.new(1))
      b = described_class.for(category: :cross_kingdom, from_terrain: "coast", to_terrain: "coast", rng: Random.new(1))
      expect(a).to eq(b)
    end

    it "returns integer minutes inside the category's base range for neutral terrain" do
      100.times do |seed|
        minutes = described_class.for(category: :intra_kingdom, from_terrain: "plains", to_terrain: "plains", rng: Random.new(seed))
        expect(minutes).to be_between(160, 435)
      end
    end

    it "scales up across mountain terrain" do
      plains = described_class.for(category: :intra_kingdom, from_terrain: "plains", to_terrain: "plains", rng: Random.new(42))
      mtn    = described_class.for(category: :intra_kingdom, from_terrain: "mountain", to_terrain: "mountain", rng: Random.new(42))
      expect(mtn).to be > plains * 2
    end

    it "uses a default multiplier for unknown terrain strings" do
      expect {
        described_class.for(category: :intra_kingdom, from_terrain: "volcano", to_terrain: "coast", rng: Random.new(1))
      }.not_to raise_error
    end

    it "raises on an unknown category" do
      expect {
        described_class.for(category: :teleport, from_terrain: "coast", to_terrain: "coast")
      }.to raise_error(KeyError)
    end
  end
end
