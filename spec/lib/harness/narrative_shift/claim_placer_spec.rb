require "rails_helper"

RSpec.describe Harness::NarrativeShift::ClaimPlacer do
  # A claimed person parked for a place that didn't exist at claim time.
  def parked(name, dest)
    Npc.create!(name: name, subrole: "contact", location: nil,
                properties: { "dormant" => true, "pending_location_name" => dest, "claim_gist" => "the relay contact" })
  end

  it "places a parked person when the player enters the matching location" do
    harek = parked("Harek", "Blackwood Relay")
    relay = Location.create!(name: "Blackwood Relay")

    placed = described_class.place!(relay)

    expect(placed.map(&:id)).to eq([ harek.id ])
    harek.reload
    expect(harek.location_id).to eq(relay.id)
    expect(harek.home_location_id).to eq(relay.id)
    expect(harek.properties["dormant"]).to be_nil
    expect(harek.properties["pending_location_name"]).to be_nil
  end

  it "matches an ancestor's name (arriving at a sublocation of the named city)" do
    harek = parked("Harek", "Blackwood Relay")
    relay = Location.create!(name: "Blackwood Relay")
    yard  = Location.create!(name: "The Sorting Yard", parent: relay)

    placed = described_class.place!(yard)

    expect(placed.map(&:id)).to eq([ harek.id ])
    expect(harek.reload.location_id).to eq(yard.id)
  end

  it "is idempotent — a second enter does not re-place (pending name cleared)" do
    parked("Harek", "Blackwood Relay")
    relay = Location.create!(name: "Blackwood Relay")

    described_class.place!(relay)
    expect(described_class.place!(relay)).to be_empty
  end

  it "leaves a parked person alone at a non-matching location" do
    harek = parked("Harek", "Blackwood Relay")
    other = Location.create!(name: "Saltmere")

    expect(described_class.place!(other)).to be_empty
    expect(harek.reload.location_id).to be_nil
    expect(harek.properties["pending_location_name"]).to eq("Blackwood Relay")
  end

  it "no-ops cleanly when nothing is parked" do
    expect(described_class.place!(Location.create!(name: "Saltmere"))).to eq([])
  end
end
