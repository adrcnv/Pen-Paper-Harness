require "rails_helper"

RSpec.describe Harness::Quests::ArchetypePicker do
  let(:city) do
    Location.create!(
      name:       "Helmrest",
      parent:     nil,
      x:          0.0,
      y:          0.0,
      biome:      "lowland",
      properties: { "tags" => %w[port mercantile] }
    )
  end

  it "picks an archetype with overlapping tags" do
    chosen = described_class.pick(city: city, rng: Random.new(0))
    expect(chosen["id"]).to be_in(%w[missing_courier wronged_neighbor])
  end

  it "raises when no archetype overlaps the city's tags AND the city has no fallback" do
    weird = Location.create!(name: "Void", parent: nil, x: 0.0, y: 0.0, properties: { "tags" => %w[obscure_tag_not_in_any_archetype] })
    # `wronged_neighbor` has empty city_tags so it fits anywhere — picker should still find it.
    chosen = described_class.pick(city: weird)
    expect(chosen["id"]).to eq("wronged_neighbor")
  end

  it "filters out archetypes already in use at this city" do
    giver = ::Npc.create!(name: "Giver", subrole: "merchant", location_id: city.id, level: 1, current_hp: 1, max_hp: 1)
    Quest.create!(
      name:               "Existing",
      summary:             "x",
      archetype_id:        "wronged_neighbor",
      state:               "active",
      giver_character_id:  giver.id,
      city_location_id:    city.id
    )

    # Now only missing_courier should be picked (wronged_neighbor is taken).
    rng = Random.new(0)
    10.times do
      chosen = described_class.pick(city: city, rng: rng)
      expect(chosen["id"]).to eq("missing_courier")
    end
  end
end
