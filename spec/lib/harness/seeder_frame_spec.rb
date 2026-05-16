require "rails_helper"

RSpec.describe Harness::Seeder, "#seed_frame" do
  let(:frame_json) do
    <<~JSON
      {
        "kingdoms": [
          { "name": "Vanthir", "subrole": "kingdom",     "disposition": "militant"   },
          { "name": "Ostmark", "subrole": "trade_league", "disposition": "mercantile" }
        ],
        "cities": [
          { "name": "Duskwatch",    "description": "Fortress capital of Vanthir",    "kingdom": "Vanthir", "coastal": false, "terrain": "highland" },
          { "name": "Saltmere",     "description": "Salt-stained harbor town",       "kingdom": "Vanthir", "coastal": true,  "terrain": "coast"    },
          { "name": "Ostmark City", "description": "Mercantile heart of the league", "kingdom": "Ostmark", "coastal": true,  "terrain": "coast"    }
        ],
        "paths": [
          { "from": "Duskwatch", "to": "Saltmere",     "cost_minutes": 600,  "description": "The Salt Road" },
          { "from": "Saltmere",  "to": "Ostmark City", "cost_minutes": 1800, "description": "Coastal shipping lane" }
        ]
      }
    JSON
  end

  let(:frame) { JSON.parse(frame_json) }

  subject(:seeder) { described_class.new }

  let!(:result) { seeder.seed_frame(frame) }

  it "creates one faction per kingdom, preserving extra fields in properties" do
    expect(Faction.count).to eq(2)

    vanthir = Faction.find_by!(name: "Vanthir")
    expect(vanthir.subrole).to eq("kingdom")
    expect(vanthir.properties["disposition"]).to eq("militant")

    ostmark = Faction.find_by!(name: "Ostmark")
    expect(ostmark.subrole).to eq("trade_league")
    expect(ostmark.properties["disposition"]).to eq("mercantile")
  end

  it "marks every frame-seeded faction as is_kingdom" do
    expect(Faction.kingdoms.count).to eq(2)
    expect(Faction.pluck(:is_kingdom)).to all(be true)
  end

  it "creates each city as a top-level location with description and metadata" do
    expect(Location.count).to eq(3)

    saltmere = Location.find_by!(name: "Saltmere")
    expect(saltmere.description).to match(/harbor/)
    expect(saltmere.properties["coastal"]).to eq(true)
    expect(saltmere.properties["terrain"]).to eq("coast")
    expect(saltmere.parent).to be_nil
  end

  it "links each city Location to its kingdom faction via faction_id" do
    vanthir = Faction.find_by!(name: "Vanthir")
    expect(Location.where(faction: vanthir).pluck(:name)).to contain_exactly("Duskwatch", "Saltmere")

    ostmark = Faction.find_by!(name: "Ostmark")
    expect(Location.where(faction: ostmark).pluck(:name)).to contain_exactly("Ostmark City")
  end

  # Paths are no longer persisted (Path model retired). The frame JSON may
  # still include a "paths" array; Seeder ignores it.

  it "does not create characters, items, or events in the frame step" do
    expect(Npc.count).to eq(0)
    expect(Item.count).to eq(0)
    expect(Event.count).to eq(0)
  end

  it "returns handles to created factions and locations keyed by name" do
    expect(result[:factions].keys).to contain_exactly("Vanthir", "Ostmark")
    expect(result[:locations].keys).to contain_exactly("Duskwatch", "Saltmere", "Ostmark City")
    expect(result[:locations]["Saltmere"]).to be_a(Location)
    expect(result[:factions]["Vanthir"]).to be_a(Faction)
  end
end
