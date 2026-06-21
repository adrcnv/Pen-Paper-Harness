require "rails_helper"

RSpec.describe World do
  let(:geo) { Harness::Worldgen::Geography.generate(seed: 4242, size: 100) }

  describe ".record! / reconstruction" do
    it "is a singleton — record! replaces any prior row" do
      World.record!(geo)
      World.record!(geo)
      expect(World.count).to eq(1)
    end

    it "round-trips rivers through persistence (same polylines)" do
      World.record!(geo)
      restored = World.current.geography
      expect(restored.rivers.map(&:points)).to eq(geo.rivers.map(&:points))
      expect(restored.rivers.map(&:ends_in)).to eq(geo.rivers.map(&:ends_in))
    end

    it "restored geography samples terrain identically to the original seed" do
      World.record!(geo)
      restored = World.current.geography
      [ [ 50.0, 50.0 ], [ 30.0, 70.0 ], [ 12.0, 88.0 ] ].each do |x, y|
        expect(restored.elevation(x, y)).to eq(geo.elevation(x, y))
        expect(Harness::Worldgen::Terrain.at(geo: restored, x: x, y: y))
          .to eq(Harness::Worldgen::Terrain.at(geo: geo, x: x, y: y))
      end
    end
  end

  describe "class convenience lookups" do
    it "return nil when no world is recorded (caller falls back to biome)" do
      expect(World.terrain_at(50.0, 50.0)).to be_nil
      expect(World.cost_multiplier_at(50.0, 50.0)).to be_nil
    end

    it "return terrain + cost once a world exists" do
      World.record!(geo)
      t = World.terrain_at(50.0, 50.0)
      expect(Harness::Worldgen::Terrain::ALL).to include(t)
      expect(World.cost_multiplier_at(50.0, 50.0))
        .to eq(Harness::Worldgen::Terrain.cost_multiplier(t))
    end
  end
end
