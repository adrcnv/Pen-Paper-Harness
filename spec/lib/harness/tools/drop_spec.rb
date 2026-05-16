require "rails_helper"

RSpec.describe Harness::Tools::Drop do
  let(:loc)     { Location.create!(name: "Tavern") }
  let(:player)  { Player.create!(name: "Hero", location: loc) }
  let(:held)    { Item.create!(name: "amulet", character_id: player.id, properties: { "tags" => [ "magical" ] }) }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100) }

  describe "happy path" do
    it "moves the item out of inventory and anchors it to the actor's location, logs an event" do
      expect {
        out = described_class.new.call({ "item_id" => held.id, "by_character_id" => player.id }, context)
        expect(out["error"]).to be_nil
        expect(out["location_id"]).to eq(loc.id)
      }.to change { Event.count }.by(1)

      held.reload
      expect(held.character_id).to be_nil
      expect(held.location_id).to eq(loc.id)
    end
  end

  describe "validation" do
    it "rejects missing args" do
      expect(described_class.new.call({}, context)["error"]).to match(/item_id required/)
      expect(described_class.new.call({ "item_id" => held.id }, context)["error"]).to match(/by_character_id required/)
    end

    it "rejects unknown actor / unknown item" do
      expect(described_class.new.call({ "item_id" => held.id, "by_character_id" => 999_999 }, context)["error"]).to match(/no character/)
      expect(described_class.new.call({ "item_id" => 999_999, "by_character_id" => player.id }, context)["error"]).to match(/no item/)
    end

    it "rejects when actor doesn't own the item" do
      other = Npc.create!(name: "Korr", location: loc, character_class: "fighter")
      out = described_class.new.call({ "item_id" => held.id, "by_character_id" => other.id }, context)
      expect(out["error"]).to match(/does not own/)
    end

    it "rejects when actor has no location to drop into" do
      orphan = Npc.create!(name: "Wraith", location: nil, character_class: "commoner")
      orphan_item = Item.create!(name: "ghost knife", character_id: orphan.id, properties: {})
      out = described_class.new.call({ "item_id" => orphan_item.id, "by_character_id" => orphan.id }, context)
      expect(out["error"]).to match(/no location/)
    end
  end
end
