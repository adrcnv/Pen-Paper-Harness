require "rails_helper"

RSpec.describe Harness::Worldgen::Persister do
  let(:map) {
    Harness::Worldgen::Map.new(
      seed: 1, size: 100,
      cities: [
        Harness::Worldgen::City.new(id: 0, x: 10.0, y: 20.0, biome: "lowland", kingdom_id: 0,
                                    name: "Stormcrag", description: "A high stone city above the sea."),
        Harness::Worldgen::City.new(id: 1, x: 80.0, y: 80.0, biome: "highland", kingdom_id: 1,
                                    name: "Mistmere", description: "A misty hollow town in the southern hills."),
      ],
      kingdoms: [
        Harness::Worldgen::Kingdom.new(id: 0, anchor_city_id: 0,
                                       name: "Karhast", description: "A windswept northern realm."),
        Harness::Worldgen::Kingdom.new(id: 1, anchor_city_id: 1,
                                       name: "Velen", description: "Soft-hilled and rainy."),
      ]
    )
  }

  describe ".persist!" do
    it "creates one Faction per kingdom with is_kingdom: true" do
      expect { described_class.persist!(map: map) }.to change(::Faction, :count).by(2)
      expect(::Faction.where(is_kingdom: true).pluck(:name)).to include("Karhast", "Velen")
    end

    it "creates one Location per city with x, y, biome populated" do
      expect { described_class.persist!(map: map) }.to change(::Location, :count).by(2)
      stormcrag = ::Location.find_by(name: "Stormcrag")
      expect(stormcrag.x).to eq(10.0)
      expect(stormcrag.y).to eq(20.0)
      expect(stormcrag.biome).to eq("lowland")
    end

    it "links each city Location to its kingdom Faction via faction_id" do
      ids = described_class.persist!(map: map)
      stormcrag = ::Location.find(ids[:cities][0])
      karhast   = ::Faction.find(ids[:kingdoms][0])
      expect(stormcrag.faction_id).to eq(karhast.id)
    end

    it "stores kingdom description in faction properties" do
      ids = described_class.persist!(map: map)
      karhast = ::Faction.find(ids[:kingdoms][0])
      expect(karhast.properties["description"]).to eq("A windswept northern realm.")
    end

    it "assigns a culture_id to each kingdom from the naming library" do
      ids = described_class.persist!(map: map)
      ::Faction.where(id: ids[:kingdoms].values).each do |k|
        expect(k.properties["culture_id"]).to be_a(String)
        expect(Harness::Naming::Library.find(k.properties["culture_id"])).not_to be_nil
      end
    end

    it "returns id mappings from internal Map ids to DB row ids" do
      ids = described_class.persist!(map: map)
      expect(ids[:kingdoms]).to eq({ 0 => ::Faction.find_by(name: "Karhast").id, 1 => ::Faction.find_by(name: "Velen").id })
      expect(ids[:cities].keys).to eq([ 0, 1 ])
      expect(ids[:cities].values).to all(be_a(Integer))
    end

    it "rolls back on failure (one transaction)" do
      # Force failure by making a city reference a non-existent kingdom_id.
      bad_map = Harness::Worldgen::Map.new(
        seed: 1, size: 100,
        cities: [ Harness::Worldgen::City.new(id: 0, x: 1.0, y: 1.0, biome: "lowland", kingdom_id: 99,
                                              name: "Ghost", description: "x") ],
        kingdoms: [ Harness::Worldgen::Kingdom.new(id: 0, anchor_city_id: 0, name: "Karhast") ]
      )
      # kingdom_id_map[99] is nil → Location.create! with faction_id: nil is fine,
      # so trip the rollback another way: pass a city with non-string name to
      # blow up `kingdom_id_map[c.kingdom_id]` lookup. Cleanest: poke a transaction
      # by raising mid-persist. Use stub.
      allow(::Location).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(::Location.new))
      expect {
        described_class.persist!(map: map) rescue nil
      }.not_to change { [ ::Faction.count, ::Location.count ] }
    end

    it "tolerates nil names by using a synthetic placeholder" do
      no_name = Harness::Worldgen::Map.new(
        seed: 1, size: 100,
        cities: [ Harness::Worldgen::City.new(id: 0, x: 1.0, y: 1.0, biome: "lowland", kingdom_id: 0) ],
        kingdoms: [ Harness::Worldgen::Kingdom.new(id: 0, anchor_city_id: 0) ]
      )
      described_class.persist!(map: no_name)
      expect(::Location.last.name).to match(/City \d+/)
      expect(::Faction.last.name).to match(/Kingdom \d+/)
    end
  end
end
