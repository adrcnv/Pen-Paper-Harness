require "rails_helper"

RSpec.describe Harness::Tools::DestroyItem do
  let(:loc)     { Location.create!(name: "Forge") }
  let(:holder)  { Npc.create!(name: "Bertha", location: loc) }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100) }

  it "destroys an anchored item and logs a destruction event" do
    item = Item.create!(name: "cracked buckler", subrole: "shield", location: loc)
    result = described_class.new.call({ "item_id" => item.id, "reason" => "botched mend" }, context)
    expect(result["destroyed"]).to eq(true)
    expect(result["item_name"]).to eq("cracked buckler")
    expect(Item.exists?(item.id)).to be(false)
    event = Event.order(:id).last
    expect(event.details.dig("destruction", "target_name")).to eq("cracked buckler")
    expect(event.details.dig("destruction", "reason")).to eq("botched mend")
  end

  it "destroys a held item with the holder as participant" do
    item = Item.create!(name: "old knife", subrole: "weapon", character_id: holder.id)
    described_class.new.call({ "item_id" => item.id }, context)
    expect(Item.exists?(item.id)).to be(false)
    event = Event.order(:id).last
    expect(event.event_participants.map(&:character_id)).to eq([ holder.id ])
  end

  it "errors cleanly on a missing item" do
    result = described_class.new.call({ "item_id" => 999_999 }, context)
    expect(result["error"]).to match(/no item/)
  end
end
