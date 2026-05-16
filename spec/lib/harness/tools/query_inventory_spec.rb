require "rails_helper"

RSpec.describe Harness::Tools::QueryInventory do
  let(:loc)     { Location.create!(name: "Camp") }
  let(:player)  { Player.create!(name: "Hero", location: loc, coins: 25) }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100) }

  it "returns coins + items for the character" do
    Item.create!(name: "blade",  character_id: player.id, properties: { "tags" => [ "weapon" ] })
    Item.create!(name: "amulet", character_id: player.id, properties: { "tags" => [ "magical" ] })

    out = described_class.new.call({ "character_id" => player.id }, context)
    expect(out["error"]).to be_nil
    expect(out["coins"]).to eq(25)
    expect(out["items"].map { |i| i["name"] }).to eq(%w[blade amulet])
    expect(out["items"].first["properties"]["tags"]).to eq([ "weapon" ])
  end

  it "returns empty items array when character has none" do
    out = described_class.new.call({ "character_id" => player.id }, context)
    expect(out["items"]).to eq([])
    expect(out["coins"]).to eq(25)
  end

  it "rejects missing character_id" do
    out = described_class.new.call({}, context)
    expect(out["error"]).to match(/character_id required/)
  end

  it "rejects unknown character_id" do
    out = described_class.new.call({ "character_id" => 999_999 }, context)
    expect(out["error"]).to match(/no character with id=999999/)
  end
end
