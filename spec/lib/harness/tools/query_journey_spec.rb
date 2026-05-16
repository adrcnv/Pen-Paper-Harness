require "rails_helper"

RSpec.describe Harness::Tools::QueryJourney do
  let(:saltmere) { Location.create!(name: "Saltmere", x: 10.0, y: 10.0, biome: "lowland") }
  let(:saltkeep) { Location.create!(name: "Saltkeep", x: 80.0, y: 10.0, biome: "lowland") }
  let(:context)  { Harness::Turn::Context.new(player_location: saltmere, game_time: 100) }

  it "returns active=false when no journey exists" do
    saltmere
    result = described_class.new.call({}, context)
    expect(result).to eq({ "active" => false })
  end

  it "returns the active journey state when one exists" do
    journey = Journey.start_or_replace(
      destination: saltkeep, origin_x: saltmere.x, origin_y: saltmere.y, started_at_game_time: 50
    )
    journey.update!(elapsed_minutes: 120, cooldown_until_game_time: 200, cursor_x: 30.0, cursor_y: 10.0)

    result = described_class.new.call({}, context)
    expect(result["active"]).to be(true)
    expect(result["destination"]).to include("name" => "Saltkeep")
    expect(result["origin"]).to eq({ "x" => 10.0, "y" => 10.0 })
    expect(result["cursor"]).to eq({ "x" => 30.0, "y" => 10.0 })
    expect(result["elapsed_minutes"]).to eq(120)
    expect(result["cooldown_until_game_time"]).to eq(200)
    expect(result["remaining_distance"]).to eq(50.0)  # |80 - 30|
  end
end
