require "rails_helper"

RSpec.describe Harness::Worldgen::Voronoi do
  let(:cities) {
    [
      [ 10.0, 10.0 ],
      [ 12.0, 11.0 ],
      [ 80.0, 80.0 ],
      [ 81.0, 79.0 ],
      [ 50.0, 90.0 ],
    ]
  }

  describe ".pick_anchors" do
    it "is deterministic given the seed" do
      a = described_class.pick_anchors(cities: cities, count: 2, seed: 7)
      b = described_class.pick_anchors(cities: cities, count: 2, seed: 7)
      expect(a).to eq(b)
    end

    it "returns the requested count when there's room" do
      result = described_class.pick_anchors(cities: cities, count: 3, seed: 1)
      expect(result.size).to eq(3)
      expect(result).to all(be_between(0, cities.size - 1))
    end

    it "returns all city indices when count exceeds city count" do
      result = described_class.pick_anchors(cities: cities, count: 10, seed: 1)
      expect(result).to eq([ 0, 1, 2, 3, 4 ])
    end

    it "returns unique indices" do
      result = described_class.pick_anchors(cities: cities, count: 4, seed: 5)
      expect(result.uniq).to eq(result)
    end
  end

  describe ".classify" do
    it "assigns each city to its nearest anchor's kingdom_id" do
      # Anchors at indices 0 and 2: cities 0,1 → kingdom 0; cities 2,3 → kingdom 1; city 4 → kingdom 1 (closer to 80,80).
      kingdom_ids = described_class.classify(cities: cities, anchor_indices: [ 0, 2 ])
      expect(kingdom_ids).to eq([ 0, 0, 1, 1, 1 ])
    end

    it "assigns the anchor itself to its own kingdom (distance 0)" do
      kingdom_ids = described_class.classify(cities: cities, anchor_indices: [ 1, 4 ])
      expect(kingdom_ids[1]).to eq(0)  # city 1 is anchor for kingdom 0
      expect(kingdom_ids[4]).to eq(1)  # city 4 is anchor for kingdom 1
    end
  end
end
