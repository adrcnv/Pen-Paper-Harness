require "rails_helper"

RSpec.describe Harness::Tools::Pickup do
  let(:loc)     { Location.create!(name: "Tavern") }
  let(:other)   { Location.create!(name: "Forest") }
  let(:player)  { Player.create!(name: "Hero", location: loc) }
  let(:floor_item) { Item.create!(name: "dagger", location_id: loc.id, properties: { "tags" => [ "weapon" ] }) }
  let(:far_item)   { Item.create!(name: "ring",   location_id: other.id, properties: {}) }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100) }

  describe "a ware taken off the table without paying" do
    let(:seller) { Npc.create!(name: "Eldri", subrole: "tanner", location: loc) }
    let(:pelt)   { Item.create!(name: "fox pelt", location_id: loc.id, properties: { "tags" => %w[goods hide], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => seller.id }) }
    let(:active) { Harness::Scene::Active.new(location: loc, snapshot: nil, narrations: []) }
    before { context.active_scene = active }

    it "is theft under the seller's eyes: the thing moves, its price is owed, the seller turns hostile and remembers" do
      out = described_class.new.call({ "item_id" => pelt.id, "by_character_id" => player.id }, context)
      expect(out["stolen_from"]).to eq("Eldri")
      expect(out["price"]).to be >= 1
      expect(pelt.reload.character_id).to eq(player.id)
      expect(pelt.properties).not_to include("for_sale", "seller_id")
      ob = Obligation.open_now.sole
      expect([ ob.debtor_id, ob.creditor_id, ob.kind, ob.amount ]).to eq([ player.id, seller.id, "coins", out["price"] ])
      expect(active.disposition_for(seller.id)).to eq("hostile")
      expect(active.state_for(seller.id)).to include("robbed")
      ev = Event.order(:id).last
      expect(ev.details["summary"]).to include("without paying")
      expect(EventParticipant.where(event_id: ev.id).pluck(:character_id)).to include(seller.id)
    end

    it "is a plain pickup when nobody is watching the table" do
      seller.update!(location: other)
      out = described_class.new.call({ "item_id" => pelt.id, "by_character_id" => player.id }, context)
      expect(out).not_to have_key("stolen_from")
      expect(Obligation.count).to eq(0)
      expect(pelt.reload.properties).not_to include("for_sale")
      expect(active.disposition_for(seller.id)).to eq("neutral")
    end

    it "shop stock has its keeper: the staff at their post is the wronged party" do
      Npc.create!(name: "Bram", subrole: "smith", location: loc, home_location_id: loc.id)
      ware = Item.create!(name: "knife", location_id: loc.id, properties: { "tags" => %w[goods tool], "modifiers" => [], "effects" => [], "for_sale" => true })
      out = described_class.new.call({ "item_id" => ware.id, "by_character_id" => player.id }, context)
      expect(out["stolen_from"]).to eq("Bram")
    end
  end

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
