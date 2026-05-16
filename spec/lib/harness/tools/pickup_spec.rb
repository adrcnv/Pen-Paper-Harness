require "rails_helper"

RSpec.describe Harness::Tools::Pickup do
  let(:loc)     { Location.create!(name: "Tavern") }
  let(:other)   { Location.create!(name: "Forest") }
  let(:player)  { Player.create!(name: "Hero", location: loc) }
  let(:floor_item) { Item.create!(name: "dagger", location_id: loc.id, properties: { "tags" => [ "weapon" ] }) }
  let(:far_item)   { Item.create!(name: "ring",   location_id: other.id, properties: {}) }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100) }

  describe "happy path" do
    it "moves the item from location into the actor's inventory and logs an event" do
      expect {
        out = described_class.new.call({ "item_id" => floor_item.id, "by_character_id" => player.id }, context)
        expect(out["error"]).to be_nil
        expect(out["item_id"]).to eq(floor_item.id)
        expect(out["owner_id"]).to eq(player.id)
      }.to change { Event.count }.by(1)

      floor_item.reload
      expect(floor_item.character_id).to eq(player.id)
      expect(floor_item.location_id).to be_nil
    end
  end

  describe "validation" do
    it "rejects missing item_id" do
      out = described_class.new.call({ "by_character_id" => player.id }, context)
      expect(out["error"]).to match(/item_id required/)
    end

    it "rejects missing by_character_id" do
      out = described_class.new.call({ "item_id" => floor_item.id }, context)
      expect(out["error"]).to match(/by_character_id required/)
    end

    it "rejects unknown actor" do
      out = described_class.new.call({ "item_id" => floor_item.id, "by_character_id" => 999_999 }, context)
      expect(out["error"]).to match(/no character with id=999999/)
    end

    it "rejects unknown item" do
      out = described_class.new.call({ "item_id" => 999_999, "by_character_id" => player.id }, context)
      expect(out["error"]).to match(/no item with id=999999/)
    end

    it "rejects an item already owned by someone" do
      held = Item.create!(name: "knife", character_id: player.id, properties: {})
      other_actor = Npc.create!(name: "Korr", location: loc, character_class: "fighter")
      out = described_class.new.call({ "item_id" => held.id, "by_character_id" => other_actor.id }, context)
      expect(out["error"]).to match(/already owned/)
    end

    it "rejects an item at a different location" do
      out = described_class.new.call({ "item_id" => far_item.id, "by_character_id" => player.id }, context)
      expect(out["error"]).to match(/cannot pick up across locations/)
    end
  end
end
