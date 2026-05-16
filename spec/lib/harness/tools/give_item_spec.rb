require "rails_helper"

RSpec.describe Harness::Tools::GiveItem do
  let(:loc)     { Location.create!(name: "Hall") }
  let(:other)   { Location.create!(name: "Forest") }
  let(:player)  { Player.create!(name: "Hero", location: loc) }
  let(:npc)     { Npc.create!(name: "Marta", location: loc, character_class: "commoner") }
  let(:far_npc) { Npc.create!(name: "Korr",  location: other, character_class: "fighter") }
  let(:gift)    { Item.create!(name: "amulet", character_id: player.id, properties: { "tags" => [ "magical" ] }) }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 100) }

  describe "happy path" do
    it "transfers ownership, logs a personal event with both as participants" do
      expect {
        out = described_class.new.call(
          { "item_id" => gift.id, "from_id" => player.id, "to_id" => npc.id, "reason" => "a parting gift" },
          context
        )
        expect(out["error"]).to be_nil
        expect(out["from_id"]).to eq(player.id)
        expect(out["to_id"]).to eq(npc.id)
      }.to change { Event.count }.by(1)

      expect(gift.reload.character_id).to eq(npc.id)

      ev = Event.order(:id).last
      roles = ev.event_participants.pluck(:character_id, :role).sort
      expect(roles).to include([ player.id, "giver" ], [ npc.id, "recipient" ])
      expect(ev.details["give_item"]["reason"]).to eq("a parting gift")
    end
  end

  describe "validation" do
    it "rejects missing item_id / from_id / to_id" do
      expect(described_class.new.call({}, context)["error"]).to match(/item_id required/)
      expect(described_class.new.call({ "item_id" => gift.id }, context)["error"]).to match(/from_id required/)
      expect(described_class.new.call({ "item_id" => gift.id, "from_id" => player.id }, context)["error"]).to match(/to_id required/)
    end

    it "rejects same-character transfer" do
      out = described_class.new.call({ "item_id" => gift.id, "from_id" => player.id, "to_id" => player.id }, context)
      expect(out["error"]).to match(/must differ/)
    end

    it "rejects unknown characters / item" do
      expect(described_class.new.call({ "item_id" => gift.id, "from_id" => 999_999, "to_id" => npc.id }, context)["error"]).to match(/no character with id=999999/)
      expect(described_class.new.call({ "item_id" => gift.id, "from_id" => player.id, "to_id" => 999_999 }, context)["error"]).to match(/no character with id=999999/)
      expect(described_class.new.call({ "item_id" => 999_999, "from_id" => player.id, "to_id" => npc.id }, context)["error"]).to match(/no item/)
    end

    it "rejects when from doesn't own the item" do
      out = described_class.new.call({ "item_id" => gift.id, "from_id" => npc.id, "to_id" => player.id }, context)
      expect(out["error"]).to match(/does not own/)
    end

    it "rejects when from and to are at different locations" do
      out = described_class.new.call({ "item_id" => gift.id, "from_id" => player.id, "to_id" => far_npc.id }, context)
      expect(out["error"]).to match(/same location/)
    end
  end
end
